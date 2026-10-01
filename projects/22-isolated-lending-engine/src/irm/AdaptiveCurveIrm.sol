// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IIrm} from "../interfaces/IIrm.sol";
import {Id, Market, MarketParams} from "../interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../libraries/MarketParamsLib.sol";
import {MathLib, WAD} from "../libraries/MathLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title AdaptiveCurveIrm
/// @notice Interest rate model whose curve slides toward a 90 % utilization target.
/// @dev The rate is `rateAtTarget * curve(err)`, where `err` is the utilization error normalized to [-1, 1]:
///      `(u - 0.9) / 0.1` above the target and `(u - 0.9) / 0.9` below it. `curve` is piecewise linear, from
///      `1/4` at `err = -1` through `1` at the target to `4` at full utilization.
///
///      Between interactions `err` is constant, so `rateAtTarget` evolves as `r0 * exp(speed * err * t)`, clamped to
///      [0.1 %, 200 %] APR, with `speed = 50 / year`: sustained 100 % utilization multiplies the curve by e (2.72x)
///      in ~7.3 days. The value returned to the engine is the time-average of the rate over the elapsed period,
///      computed with Simpson's rule on the clamped path (`(r0 + 4 * r_mid + r_end) / 6`). For an idle week at full
///      adaptation speed its error against the closed-form integral is below 0.1 % (see `AdaptiveCurveIrm.t.sol`).
///
///      The curve shape and its parameter values follow Morpho's AdaptiveCurveIrm (morpho-org/morpho-blue-irm,
///      GPL-2.0-or-later); the code is an independent implementation (Solady's `expWad`, Simpson's-rule averaging,
///      exponent clamp) and is MIT-licensed. See the README's License section.
contract AdaptiveCurveIrm is IIrm {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Emitted when the rate at target of a market is updated.
    /// @param id The market id.
    /// @param avgBorrowRate Average borrow rate over the elapsed period (per second, WAD).
    /// @param rateAtTarget New rate at target (per second, WAD).
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    /// @notice Only the engine may mutate the model's state.
    /// @param caller The rejected caller.
    error NotEngine(address caller);

    /// @notice The engine address was zero.
    error ZeroAddress();

    /// @notice Utilization the curve steers toward (90 %).
    uint256 public constant TARGET_UTILIZATION = 0.9e18;

    /// @notice Ratio between the rate at full utilization and the rate at target (and target / zero utilization).
    uint256 public constant CURVE_STEEPNESS = 4e18;

    /// @notice Speed at which the rate at target adapts, per second, at |err| = 1 (50 per year).
    uint256 public constant ADJUSTMENT_SPEED = 50e18 / uint256(365 days);

    /// @notice Rate at target of a new market (4 % APR, per second).
    uint256 public constant INITIAL_RATE_AT_TARGET = 0.04e18 / uint256(365 days);

    /// @notice Floor of the rate at target (0.1 % APR, per second).
    uint256 public constant MIN_RATE_AT_TARGET = 0.001e18 / uint256(365 days);

    /// @notice Ceiling of the rate at target (200 % APR, per second).
    uint256 public constant MAX_RATE_AT_TARGET = 2e18 / uint256(365 days);

    /// @dev Bound on the exponent fed to `expWad`. Beyond ln(MAX / MIN) = ln(2000) ~= 7.6 the result is clamped
    ///      anyway, so clamping the exponent to +-20 changes nothing and keeps `expWad` far from its overflow domain.
    int256 internal constant MAX_EXPONENT = 20e18;

    /// @dev Signed copies of the constants above, so the signed arithmetic needs no casts.
    int256 internal constant WAD_INT = 1e18;
    int256 internal constant TARGET_UTILIZATION_INT = 0.9e18;
    int256 internal constant CURVE_STEEPNESS_INT = 4e18;
    int256 internal constant ADJUSTMENT_SPEED_INT = 50e18 / int256(365 days);

    /// @notice The lending engine allowed to update state.
    address public immutable ENGINE;

    /// @notice Current rate at target of each market (per second, WAD). Zero before the first update.
    mapping(Id id => uint256) public rateAtTarget;

    /// @param engine The lending engine.
    constructor(address engine) {
        require(engine != address(0), ZeroAddress());
        ENGINE = engine;
    }

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams calldata marketParams, Market calldata market)
        external
        view
        returns (uint256)
    {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return avgRate;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams calldata marketParams, Market calldata market) external returns (uint256) {
        require(msg.sender == ENGINE, NotEngine(msg.sender));
        Id id = marketParams.id();
        (uint256 avgRate, uint256 endRateAtTarget) = _borrowRate(id, market);
        rateAtTarget[id] = endRateAtTarget;
        emit BorrowRateUpdate(id, avgRate, endRateAtTarget);
        return avgRate;
    }

    /// @notice The curve multiplier applied to the rate at target for a given utilization.
    /// @param utilization Utilization (WAD, at most 1e18).
    /// @return err The normalized error in [-1e18, 1e18].
    /// @return multiplier `curve(err)` (WAD), between 0.25e18 and 4e18.
    function curveMultiplier(uint256 utilization) public pure returns (int256 err, uint256 multiplier) {
        err = _error(utilization);
        multiplier = _curve(WAD, err);
    }

    /// @dev Returns the average rate over the elapsed period and the rate at target at its end.
    ///      (Slither triage, incorrect-equality) `startRateAtTarget == 0` and `exponent == 0` are sentinel checks
    ///      ("never updated", "nothing elapsed or zero error"), not balance or timestamp equalities.
    // slither-disable-next-line incorrect-equality
    function _borrowRate(Id id, Market calldata market) internal view returns (uint256, uint256) {
        int256 err = _error(_utilization(market));
        uint256 startRateAtTarget = rateAtTarget[id];

        if (startRateAtTarget == 0) {
            // First interaction: start the curve at its initial position.
            return (_curve(INITIAL_RATE_AT_TARGET, err), INITIAL_RATE_AT_TARGET);
        }

        int256 elapsed = (block.timestamp - uint256(market.lastUpdate)).toInt256();
        // exponent = ADJUSTMENT_SPEED * err * elapsed (WAD). Multiplying before dividing keeps full precision, and
        // |product| <= 1.6e12 * 1e18 * 2^64 < 2^255 for any elapsed time below 2^64 seconds.
        int256 exponent = (ADJUSTMENT_SPEED_INT * err * elapsed) / WAD_INT;

        if (exponent == 0) return (_curve(startRateAtTarget, err), startRateAtTarget);

        uint256 endRateAtTarget = _adapt(startRateAtTarget, exponent);
        uint256 midRateAtTarget = _adapt(startRateAtTarget, exponent / 2);
        uint256 avgRateAtTarget = (startRateAtTarget + 4 * midRateAtTarget + endRateAtTarget) / 6;

        return (_curve(avgRateAtTarget, err), endRateAtTarget);
    }

    /// @dev `clamp(start * e^exponent, MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET)`.
    function _adapt(uint256 start, int256 exponent) internal pure returns (uint256) {
        if (exponent > MAX_EXPONENT) exponent = MAX_EXPONENT;
        if (exponent < -MAX_EXPONENT) exponent = -MAX_EXPONENT;
        uint256 growth = FixedPointMathLib.expWad(exponent).toUint256();
        uint256 adapted = start.wMulDown(growth);
        if (adapted < MIN_RATE_AT_TARGET) return MIN_RATE_AT_TARGET;
        if (adapted > MAX_RATE_AT_TARGET) return MAX_RATE_AT_TARGET;
        return adapted;
    }

    /// @dev Utilization `totalBorrow / totalSupply` (WAD), capped at 1.
    function _utilization(Market calldata market) internal pure returns (uint256) {
        if (market.totalSupplyAssets == 0) return 0;
        uint256 utilization = uint256(market.totalBorrowAssets).wDivDown(market.totalSupplyAssets);
        return MathLib.min(utilization, WAD);
    }

    /// @dev Normalized utilization error in [-1e18, 1e18].
    function _error(uint256 utilization) internal pure returns (int256) {
        int256 normalizer = utilization > TARGET_UTILIZATION ? WAD_INT - TARGET_UTILIZATION_INT : TARGET_UTILIZATION_INT;
        return ((utilization.toInt256() - TARGET_UTILIZATION_INT) * WAD_INT) / normalizer;
    }

    /// @dev `rate * (coefficient * err + 1)`, coefficient = 1 - 1/steepness below target, steepness - 1 above.
    function _curve(uint256 rate, int256 err) internal pure returns (uint256) {
        int256 coefficient =
            err < 0 ? WAD_INT - (WAD_INT * WAD_INT) / CURVE_STEEPNESS_INT : CURVE_STEEPNESS_INT - WAD_INT;
        // coefficient * err / WAD >= -0.75e18, so the factor stays in [0.25e18, 4e18].
        uint256 factor = ((coefficient * err) / WAD_INT + WAD_INT).toUint256();
        return rate.wMulDown(factor);
    }
}
