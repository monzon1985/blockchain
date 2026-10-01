// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IOracle} from "../interfaces/IOracle.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title RouterOracleAdapter
/// @notice Turns two USD-denominated `IPriceOracle` sources into the collateral/loan price a market needs.
/// @dev Source selection, in order:
///      1. Primary source, if both legs are `OK` and non-zero.
///      2. Secondary source, if both legs are `OK` and non-zero. This is what keeps liquidations running when the
///         primary is stale, returns zero or negative answers, is out of bounds, or trips its deviation breaker.
///      3. The primary's own TWAP (`FALLBACK_USED`) as a last resort. It ranks below a live secondary because a
///         time-weighted price lags a crash, which delays liquidations and grows bad debt.
///      Otherwise it reverts with every status observed.
///
///      Sequencer outages are the exception: if either source reports `SEQUENCER_DOWN` or `GRACE_PERIOD` the adapter
///      reverts without falling back. A second source on the same L2 is just as unreachable for users, and the grace
///      period exists so borrowers can top up before liquidations resume.
///
///      Rounding: the collateral leg uses `Intent.Collateral` (rounded down), the loan leg `Intent.Debt` (rounded
///      up), and the quotient rounds down, so the market never overvalues collateral.
contract RouterOracleAdapter is IOracle {
    /// @notice Which source produced a quote.
    enum Source {
        Primary,
        Secondary,
        PrimaryFallback
    }

    /// @notice No source produced a usable price.
    /// @param primaryCollateral Status of the primary collateral leg.
    /// @param primaryLoan Status of the primary loan leg.
    /// @param secondaryCollateral Status of the secondary collateral leg.
    /// @param secondaryLoan Status of the secondary loan leg.
    error PriceUnavailable(
        IPriceOracle.Status primaryCollateral,
        IPriceOracle.Status primaryLoan,
        IPriceOracle.Status secondaryCollateral,
        IPriceOracle.Status secondaryLoan
    );

    /// @notice A source reported an L2 sequencer outage or grace period; no fallback is attempted.
    /// @param status The sequencer status observed.
    error SequencerUnavailable(IPriceOracle.Status status);

    /// @notice The token decimals cannot be folded into a 1e36-scaled price.
    /// @param collateralDecimals Decimals of the collateral token.
    /// @param loanDecimals Decimals of the loan token.
    error InvalidDecimals(uint256 collateralDecimals, uint256 loanDecimals);

    /// @notice A constructor address was zero.
    error ZeroAddress();

    /// @notice Preferred price source.
    IPriceOracle public immutable PRIMARY;

    /// @notice Independent source used when the primary cannot be trusted.
    IPriceOracle public immutable SECONDARY;

    /// @notice Collateral token of the market.
    address public immutable COLLATERAL_TOKEN;

    /// @notice Loan token of the market.
    address public immutable LOAN_TOKEN;

    /// @notice `10 ** (36 + loanDecimals - collateralDecimals)`: converts a USD ratio into the 1e36 base-unit price.
    uint256 public immutable SCALE_FACTOR;

    /// @param primary Preferred source.
    /// @param secondary Independent source.
    /// @param collateralToken Collateral token (decimals read on construction).
    /// @param loanToken Loan token (decimals read on construction).
    constructor(IPriceOracle primary, IPriceOracle secondary, address collateralToken, address loanToken) {
        require(
            address(primary) != address(0) && address(secondary) != address(0) && collateralToken != address(0)
                && loanToken != address(0),
            ZeroAddress()
        );
        uint256 collateralDecimals = IERC20Metadata(collateralToken).decimals();
        uint256 loanDecimals = IERC20Metadata(loanToken).decimals();
        require(
            collateralDecimals <= 36 + loanDecimals && 36 + loanDecimals - collateralDecimals <= 77,
            InvalidDecimals(collateralDecimals, loanDecimals)
        );
        PRIMARY = primary;
        SECONDARY = secondary;
        COLLATERAL_TOKEN = collateralToken;
        LOAN_TOKEN = loanToken;
        SCALE_FACTOR = 10 ** (36 + loanDecimals - collateralDecimals);
    }

    /// @inheritdoc IOracle
    function price() external view returns (uint256) {
        (uint256 value,) = quote();
        return value;
    }

    /// @notice Price and the source it came from (for keepers and dashboards).
    /// @return value Price of one collateral base unit in loan base units, scaled by 1e36.
    /// @return source The source that produced `value`.
    function quote() public view returns (uint256 value, Source source) {
        (uint256 primaryCollateral, IPriceOracle.Status primaryCollateralStatus) =
            PRIMARY.tryGetPrice(COLLATERAL_TOKEN, IPriceOracle.Intent.Collateral);
        (uint256 primaryLoan, IPriceOracle.Status primaryLoanStatus) =
            PRIMARY.tryGetPrice(LOAN_TOKEN, IPriceOracle.Intent.Debt);
        _revertOnSequencerOutage(primaryCollateralStatus);
        _revertOnSequencerOutage(primaryLoanStatus);

        if (_isLive(primaryCollateralStatus, primaryCollateral) && _isLive(primaryLoanStatus, primaryLoan)) {
            return (_toMarketPrice(primaryCollateral, primaryLoan), Source.Primary);
        }

        (uint256 secondaryCollateral, IPriceOracle.Status secondaryCollateralStatus) =
            SECONDARY.tryGetPrice(COLLATERAL_TOKEN, IPriceOracle.Intent.Collateral);
        (uint256 secondaryLoan, IPriceOracle.Status secondaryLoanStatus) =
            SECONDARY.tryGetPrice(LOAN_TOKEN, IPriceOracle.Intent.Debt);
        _revertOnSequencerOutage(secondaryCollateralStatus);
        _revertOnSequencerOutage(secondaryLoanStatus);

        if (_isLive(secondaryCollateralStatus, secondaryCollateral) && _isLive(secondaryLoanStatus, secondaryLoan)) {
            return (_toMarketPrice(secondaryCollateral, secondaryLoan), Source.Secondary);
        }

        if (_isUsable(primaryCollateralStatus, primaryCollateral) && _isUsable(primaryLoanStatus, primaryLoan)) {
            return (_toMarketPrice(primaryCollateral, primaryLoan), Source.PrimaryFallback);
        }

        revert PriceUnavailable(
            primaryCollateralStatus, primaryLoanStatus, secondaryCollateralStatus, secondaryLoanStatus
        );
    }

    /// @dev `collateralUsd * SCALE_FACTOR / loanUsd`, rounded down, with a 512-bit intermediate product.
    function _toMarketPrice(uint256 collateralUsd, uint256 loanUsd) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(collateralUsd, SCALE_FACTOR, loanUsd);
    }

    /// @dev A live spot price: status OK and a non-zero value.
    function _isLive(IPriceOracle.Status status, uint256 value) internal pure returns (bool) {
        return status == IPriceOracle.Status.OK && value != 0;
    }

    /// @dev A spot or TWAP-fallback price with a non-zero value.
    function _isUsable(IPriceOracle.Status status, uint256 value) internal pure returns (bool) {
        return (status == IPriceOracle.Status.OK || status == IPriceOracle.Status.FALLBACK_USED) && value != 0;
    }

    /// @dev Sequencer outages halt pricing outright.
    function _revertOnSequencerOutage(IPriceOracle.Status status) internal pure {
        require(
            status != IPriceOracle.Status.SEQUENCER_DOWN && status != IPriceOracle.Status.GRACE_PERIOD,
            SequencerUnavailable(status)
        );
    }
}
