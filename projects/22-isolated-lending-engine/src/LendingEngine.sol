// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs (https://github.com/morpho-org/morpho-blue, src/Morpho.sol and
// src/periphery/MorphoBalancesLib.sol, GPL-2.0-or-later): market, position and authorization bookkeeping, the supply,
// withdraw, borrow, repay, collateral, flash-loan and authorization entry points, and `expectedMarketBalances`.
// Modified for this project in 2026: reverse-Dutch liquidations bound to the LLTV, the health guard, the closeout
// rules and bad-debt write-off, and the per-market transient lock are original. See the README's License section.
pragma solidity 0.8.37;

import {IIrm} from "./interfaces/IIrm.sol";
import {
    IFlashLoanCallback,
    ILiquidateCallback,
    IRepayCallback,
    ISupplyCallback,
    ISupplyCollateralCallback
} from "./interfaces/ILendingCallbacks.sol";
import {
    Authorization,
    ILendingEngine,
    Id,
    LiquidationConfig,
    Market,
    MarketParams,
    Position
} from "./interfaces/ILendingEngine.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {LiquidationMath} from "./libraries/LiquidationMath.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LendingEngine
/// @notice Isolated-market lending singleton. Anyone can create a market from an allowlisted interest rate model
///         and an allowlisted LLTV; each market's risk (its oracle, its collateral, its bad debt) is borne only by
///         that market's suppliers.
/// @dev Design notes:
///      - Accounting is share-based with a 1e6 virtual-share offset (`SharesMathLib`). Every conversion rounds in
///        the protocol's favor, so no sequence of operations can extract more than it deposits.
///      - Liquidations follow a reverse-Dutch schedule: the bonus grows with the health deficit up to a cap bound
///        to the LLTV. A partial liquidation may never lower the health factor. Once collateral can no longer cover
///        debt plus bonus, the only valid liquidation closes the position: while the collateral still covers the
///        debt, the liquidator repays all of it and the bonus is capped at the borrower's equity (no supplier loss);
///        under water, all collateral is seized and the residual debt is written off against the market's suppliers
///        in the same transaction (no zombie positions). Requests at or above the position's size close it, so a
///        dust deposit or repayment cannot block a closeout.
///      - Reentrancy is prevented per market with a transient lock rather than a global guard, so a flash loan or a
///        callback can still act on *other* markets (e.g. a flash-loan-funded liquidation) while the market being
///        mutated stays sealed until its token transfers settle. Slither's `reentrancy-no-eth` cannot see this lock
///        (it flags the IRM call inside `_accrueInterest`, made before the accrual writes); those findings are
///        suppressed inline on the entry points that take the lock, and `FlashLoanReentrancy.t.sol` proves that
///        every entry point reverts with `MarketLocked` when re-entered.
contract LendingEngine is ILendingEngine, Ownable2Step, EIP712 {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SlotDerivation for bytes32;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /// @notice Maximum share of interest that governance can route to the fee recipient (25 %).
    uint256 public constant MAX_FEE = 0.25e18;

    /// @notice Maximum liquidation bonus cap governance can bind to an LLTV (25 %).
    uint256 public constant MAX_BONUS = 0.25e18;

    /// @notice Maximum slope of the reverse-Dutch schedule (20 bonus points per point of health deficit).
    uint256 public constant MAX_BONUS_SLOPE = 20e18;

    /// @notice EIP-712 type hash of `Authorization`.
    bytes32 public constant AUTHORIZATION_TYPEHASH = keccak256(
        "Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)"
    );

    /// @dev Base transient slot of the per-market lock, derived ERC-7201 style so it cannot collide with storage
    ///      layouts: keccak256(abi.encode(uint256(keccak256("isolated-lending.market-lock")) - 1)) & ~0xff.
    bytes32 private constant MARKET_LOCK_SLOT = 0xca540b57ea7c54395033237ab4809e5314fe1685f5699a4b3ae741259b361300;

    /// @notice Account credited with fee shares on every market.
    address public feeRecipient;

    /// @notice Whether an interest rate model may be used by new markets.
    mapping(address irm => bool enabled) public isIrmEnabled;

    /// @notice Whether `authorized` may withdraw, borrow and withdraw collateral on behalf of `authorizer`.
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;

    /// @notice Next EIP-712 authorization nonce of each account.
    mapping(address authorizer => uint256) public nonce;

    /// @dev Liquidation schedule bound to each allowlisted LLTV (immutable once set).
    mapping(uint256 lltv => LiquidationConfig) internal _liquidationConfig;

    /// @dev Accounting of each market.
    mapping(Id id => Market) internal _market;

    /// @dev Positions of each account in each market.
    mapping(Id id => mapping(address user => Position)) internal _position;

    /// @dev Parameters of each created market.
    mapping(Id id => MarketParams) internal _idToMarketParams;

    /// @dev Working set of `liquidate`, grouped to keep the stack shallow.
    struct LiquidationState {
        uint256 price;
        uint256 health;
        uint256 bonus;
        uint256 seizedAssets;
        uint256 repaidShares;
        uint256 repaidAssets;
        uint256 badDebtAssets;
        uint256 badDebtShares;
    }

    /// @param initialOwner Governance account (allowlists, fees). It cannot move user funds.
    /// @param initialFeeRecipient Account credited with fee shares.
    constructor(address initialOwner, address initialFeeRecipient)
        Ownable(initialOwner)
        EIP712("IsolatedLendingEngine", "1")
    {
        require(initialFeeRecipient != address(0), ZeroAddress());
        feeRecipient = initialFeeRecipient;
        emit SetFeeRecipient(initialFeeRecipient);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    function enableIrm(address irm) external onlyOwner {
        require(irm != address(0), ZeroAddress());
        require(!isIrmEnabled[irm], IrmAlreadyEnabled(irm));
        isIrmEnabled[irm] = true;
        emit EnableIrm(irm);
    }

    /// @inheritdoc ILendingEngine
    function enableLltv(uint256 lltv, uint256 maxBonus, uint256 bonusSlope) external onlyOwner {
        require(!_liquidationConfig[lltv].enabled, LltvAlreadyEnabled(lltv));
        // A max-bonus liquidation of a position sitting exactly at the LLTV must leave it solvent:
        // lltv * (1 + maxBonus) < 1. This also keeps every bound below uint96.
        require(
            lltv > 0 && lltv < WAD && maxBonus > 0 && maxBonus <= MAX_BONUS && bonusSlope > 0
                && bonusSlope <= MAX_BONUS_SLOPE && lltv.wMulDown(WAD + maxBonus) < WAD,
            InvalidLiquidationConfig(lltv, maxBonus, bonusSlope)
        );
        _liquidationConfig[lltv] =
            LiquidationConfig({maxBonus: maxBonus.toUint96(), bonusSlope: bonusSlope.toUint96(), enabled: true});
        emit EnableLltv(lltv, maxBonus, bonusSlope);
    }

    /// @inheritdoc ILendingEngine
    // slither-disable-next-line reentrancy-no-eth
    function setFee(MarketParams calldata marketParams, uint256 newFee) external onlyOwner {
        Id id = marketParams.id();
        Market storage m = _market[id];
        require(m.lastUpdate != 0, MarketNotCreated(id));
        require(newFee != m.fee, FeeAlreadySet(newFee));
        require(newFee <= MAX_FEE, MaxFeeExceeded(newFee));
        _lock(id);
        // Interest accrued so far is charged at the old fee.
        _accrueInterest(marketParams, id);
        m.fee = newFee.toUint128();
        emit SetFee(id, newFee);
        _unlock(id);
    }

    /// @inheritdoc ILendingEngine
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != address(0), ZeroAddress());
        require(newFeeRecipient != feeRecipient, FeeRecipientAlreadySet(newFeeRecipient));
        feeRecipient = newFeeRecipient;
        emit SetFeeRecipient(newFeeRecipient);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Market creation
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    function createMarket(MarketParams calldata marketParams) external returns (Id id) {
        id = marketParams.id();
        require(isIrmEnabled[marketParams.irm], IrmNotEnabled(marketParams.irm));
        require(_liquidationConfig[marketParams.lltv].enabled, LltvNotEnabled(marketParams.lltv));
        require(
            marketParams.loanToken != address(0) && marketParams.collateralToken != address(0)
                && marketParams.oracle != address(0),
            ZeroAddress()
        );
        require(marketParams.loanToken != marketParams.collateralToken, SameTokens(marketParams.loanToken));
        Market storage m = _market[id];
        require(m.lastUpdate == 0, MarketAlreadyCreated(id));

        m.lastUpdate = block.timestamp.toUint128();
        _idToMarketParams[id] = marketParams;
        emit CreateMarket(id, marketParams);

        // Lets a stateful IRM initialize its per-market state. The IRM is governance-allowlisted. The returned rate
        // is ignored on purpose: no time has elapsed, so there is no interest to apply.
        // slither-disable-next-line unused-return
        IIrm(marketParams.irm).borrowRate(marketParams, m); // forge-lint: disable-line(unused-return)
    }

    // ------------------------------------------------------------------------------------------------------------
    // Supply side
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    // slither-disable-next-line reentrancy-no-eth
    function supply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        Market storage m = _market[id];
        require(m.lastUpdate != 0, MarketNotCreated(id));
        require(_exactlyOneZero(assets, shares), InconsistentInput(assets, shares));
        require(onBehalf != address(0), ZeroAddress());

        _lock(id);
        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsUp(m.totalSupplyAssets, m.totalSupplyShares);

        _position[id][onBehalf].supplyShares += shares;
        m.totalSupplyShares = (uint256(m.totalSupplyShares) + shares).toUint128();
        m.totalSupplyAssets = (uint256(m.totalSupplyAssets) + assets).toUint128();

        emit Supply(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) ISupplyCallback(msg.sender).onSupply(assets, data);
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        _unlock(id);

        return (assets, shares);
    }

    /// @inheritdoc ILendingEngine
    // slither-disable-next-line reentrancy-no-eth
    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        Market storage m = _market[id];
        require(m.lastUpdate != 0, MarketNotCreated(id));
        require(_exactlyOneZero(assets, shares), InconsistentInput(assets, shares));
        require(receiver != address(0), ZeroAddress());
        require(_isSenderAuthorized(onBehalf), Unauthorized(msg.sender, onBehalf));

        _lock(id);
        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(m.totalSupplyAssets, m.totalSupplyShares);
        else assets = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);

        Position storage p = _position[id][onBehalf];
        require(shares <= p.supplyShares, InsufficientBalance(p.supplyShares, shares));
        p.supplyShares -= shares;
        m.totalSupplyShares -= shares.toUint128();
        m.totalSupplyAssets -= assets.toUint128();
        require(
            m.totalBorrowAssets <= m.totalSupplyAssets, InsufficientLiquidity(m.totalBorrowAssets, m.totalSupplyAssets)
        );

        emit Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);
        _unlock(id);

        return (assets, shares);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Borrow side
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    // slither-disable-next-line reentrancy-no-eth
    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        Market storage m = _market[id];
        require(m.lastUpdate != 0, MarketNotCreated(id));
        require(_exactlyOneZero(assets, shares), InconsistentInput(assets, shares));
        require(receiver != address(0), ZeroAddress());
        require(_isSenderAuthorized(onBehalf), Unauthorized(msg.sender, onBehalf));

        _lock(id);
        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
        else assets = shares.toAssetsDown(m.totalBorrowAssets, m.totalBorrowShares);

        Position storage p = _position[id][onBehalf];
        p.borrowShares = (uint256(p.borrowShares) + shares).toUint128();
        m.totalBorrowShares = (uint256(m.totalBorrowShares) + shares).toUint128();
        m.totalBorrowAssets = (uint256(m.totalBorrowAssets) + assets).toUint128();

        _requireHealthy(marketParams, m, p);
        require(
            m.totalBorrowAssets <= m.totalSupplyAssets, InsufficientLiquidity(m.totalBorrowAssets, m.totalSupplyAssets)
        );

        emit Borrow(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);
        _unlock(id);

        return (assets, shares);
    }

    /// @inheritdoc ILendingEngine
    // slither-disable-next-line reentrancy-no-eth
    function repay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        Market storage m = _market[id];
        require(m.lastUpdate != 0, MarketNotCreated(id));
        require(_exactlyOneZero(assets, shares), InconsistentInput(assets, shares));
        require(onBehalf != address(0), ZeroAddress());

        _lock(id);
        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
        else assets = shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        Position storage p = _position[id][onBehalf];
        require(shares <= p.borrowShares, RepayExceedsDebt(shares, p.borrowShares));
        p.borrowShares -= shares.toUint128();
        m.totalBorrowShares -= shares.toUint128();
        // The last repayer can pay a few wei more than the rounded-down total because each repayment rounds up.
        m.totalBorrowAssets = uint256(m.totalBorrowAssets).zeroFloorSub(assets).toUint128();

        emit Repay(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IRepayCallback(msg.sender).onRepay(assets, data);
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        _unlock(id);

        return (assets, shares);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Collateral
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    function supplyCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
    {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, MarketNotCreated(id));
        require(assets != 0, ZeroAmount());
        require(onBehalf != address(0), ZeroAddress());

        // No accrual: posting collateral cannot make any position less healthy, so interest can wait.
        _lock(id);

        Position storage p = _position[id][onBehalf];
        p.collateral = (uint256(p.collateral) + assets).toUint128();

        emit SupplyCollateral(id, msg.sender, onBehalf, assets);

        if (data.length > 0) ISupplyCollateralCallback(msg.sender).onSupplyCollateral(assets, data);
        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
        _unlock(id);
    }

    /// @inheritdoc ILendingEngine
    // slither-disable-next-line reentrancy-no-eth
    function withdrawCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        Id id = marketParams.id();
        Market storage m = _market[id];
        require(m.lastUpdate != 0, MarketNotCreated(id));
        require(assets != 0, ZeroAmount());
        require(receiver != address(0), ZeroAddress());
        require(_isSenderAuthorized(onBehalf), Unauthorized(msg.sender, onBehalf));

        _lock(id);
        _accrueInterest(marketParams, id);

        Position storage p = _position[id][onBehalf];
        require(assets <= p.collateral, InsufficientBalance(p.collateral, assets));
        p.collateral -= assets.toUint128();

        _requireHealthy(marketParams, m, p);

        emit WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
        _unlock(id);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Liquidation
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    // slither-disable-next-line reentrancy-no-eth
    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, MarketNotCreated(id));
        require(_exactlyOneZero(seizedAssets, repaidShares), InconsistentInput(seizedAssets, repaidShares));

        _lock(id);
        _accrueInterest(marketParams, id);

        LiquidationState memory s = _settleLiquidation(marketParams, id, borrower, seizedAssets, repaidShares);

        emit Liquidate(
            id,
            msg.sender,
            borrower,
            s.repaidAssets,
            s.repaidShares,
            s.seizedAssets,
            s.badDebtAssets,
            s.badDebtShares,
            s.health,
            s.bonus
        );

        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, s.seizedAssets);
        if (data.length > 0) ILiquidateCallback(msg.sender).onLiquidate(s.repaidAssets, data);
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), s.repaidAssets);
        _unlock(id);

        return (s.seizedAssets, s.repaidAssets);
    }

    /// @dev Prices the liquidation, applies it to storage and, for a closeout that leaves debt behind, writes the
    ///      residual debt off. Performs no token transfers.
    ///
    ///      A request that covers the whole position closes it (see `_priceClose`). Any other request is partial: it
    ///      may neither lower the health factor nor exhaust the collateral while debt remains, so it cannot realize
    ///      bad debt.
    function _settleLiquidation(
        MarketParams calldata marketParams,
        Id id,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal returns (LiquidationState memory s) {
        Market storage m = _market[id];
        Position storage p = _position[id][borrower];
        uint256 collateral = p.collateral;
        uint256 borrowShares = p.borrowShares;
        uint256 debt = _assessLiquidation(s, marketParams, m, collateral, borrowShares);

        // Asking for at least the whole position (e.g. `type(uint256).max`) means "close it": the amounts are taken
        // from the current state, so a dust deposit or repayment sent in front of the call cannot make it revert.
        bool close = seizedAssets > 0 ? seizedAssets >= collateral : repaidShares >= borrowShares;
        if (close) {
            _priceClose(s, m, collateral, borrowShares, debt);
        } else if (seizedAssets > 0) {
            s.seizedAssets = seizedAssets;
            s.repaidShares = LiquidationMath.repaidSharesForSeizure(
                seizedAssets, s.price, WAD + s.bonus, m.totalBorrowAssets, m.totalBorrowShares
            );
            require(s.repaidShares <= borrowShares, RepayExceedsDebt(s.repaidShares, borrowShares));
        } else {
            s.repaidShares = repaidShares;
            s.seizedAssets = LiquidationMath.seizureForRepaidShares(
                repaidShares, s.price, WAD + s.bonus, m.totalBorrowAssets, m.totalBorrowShares
            );
            require(s.seizedAssets <= collateral, SeizeExceedsCollateral(s.seizedAssets, collateral));
        }
        s.repaidAssets = s.repaidShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);

        p.borrowShares = (borrowShares - s.repaidShares).toUint128();
        m.totalBorrowShares -= s.repaidShares.toUint128();
        m.totalBorrowAssets = uint256(m.totalBorrowAssets).zeroFloorSub(s.repaidAssets).toUint128();
        p.collateral = (collateral - s.seizedAssets).toUint128();

        if (!close) _requireHealthNotLowered(s, marketParams, m, p);
        else if (p.borrowShares != 0) _writeOffBadDebt(s, m, p);
    }

    /// @dev Reads the oracle, requires the position to be unhealthy and sets the price, health factor and scheduled
    ///      bonus of `s`. Returns the position's debt, rounded up.
    function _assessLiquidation(
        LiquidationState memory s,
        MarketParams calldata marketParams,
        Market storage m,
        uint256 collateral,
        uint256 borrowShares
    ) internal view returns (uint256 debt) {
        s.price = IOracle(marketParams.oracle).price();
        require(s.price != 0, ZeroPrice());

        uint256 maxBorrowAssets = LiquidationMath.maxBorrow(collateral, s.price, marketParams.lltv);
        debt = borrowShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        s.health = LiquidationMath.healthFactor(maxBorrowAssets, debt);
        require(maxBorrowAssets < debt, HealthyPosition(s.health));

        LiquidationConfig memory cfg = _liquidationConfig[marketParams.lltv];
        s.bonus = LiquidationMath.liquidationBonus(s.health, cfg.maxBonus, cfg.bonusSlope);
    }

    /// @dev Partial liquidation: the health factor may not go down, and the collateral may not run out while debt
    ///      remains (that would be a closeout priced as a partial, and it would leave a zombie position).
    function _requireHealthNotLowered(
        LiquidationState memory s,
        MarketParams calldata marketParams,
        Market storage m,
        Position storage p
    ) internal view {
        uint256 healthAfter = LiquidationMath.healthFactor(
            LiquidationMath.maxBorrow(p.collateral, s.price, marketParams.lltv),
            uint256(p.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares)
        );
        require(
            healthAfter >= s.health && (p.collateral != 0 || p.borrowShares == 0),
            HealthDecreased(s.health, healthAfter)
        );
    }

    /// @dev Only an under-water closeout leaves debt behind, and it has taken all the collateral: the residual debt
    ///      can never be repaid by liquidation, so it is written off against this market's suppliers now. Other
    ///      markets are untouched (isolation).
    function _writeOffBadDebt(LiquidationState memory s, Market storage m, Position storage p) internal {
        s.badDebtShares = p.borrowShares;
        s.badDebtAssets =
            MathLib.min(m.totalBorrowAssets, s.badDebtShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares));
        m.totalBorrowAssets -= s.badDebtAssets.toUint128();
        m.totalSupplyAssets = uint256(m.totalSupplyAssets).zeroFloorSub(s.badDebtAssets).toUint128();
        m.totalBorrowShares -= s.badDebtShares.toUint128();
        p.borrowShares = 0;
    }

    /// @dev Prices a close of the whole position, in one of three regimes:
    ///      1. The collateral covers debt plus the scheduled bonus: repay every share, seize what that buys, and the
    ///         borrower keeps the rest.
    ///      2. The collateral covers the debt but not the bonus: repay every share and seize all collateral. The
    ///         liquidator's bonus is capped at the borrower's equity, so suppliers take no loss on a position that is
    ///         not under water (and a borrower cannot close their own position for less than its debt).
    ///      3. The collateral is worth less than the debt: seize all of it at the scheduled bonus. The shortfall is
    ///         bad debt, written off by the caller.
    function _priceClose(
        LiquidationState memory s,
        Market storage m,
        uint256 collateral,
        uint256 borrowShares,
        uint256 debt
    ) internal view {
        s.repaidShares = borrowShares;
        s.seizedAssets = LiquidationMath.seizureForRepaidShares(
            borrowShares, s.price, WAD + s.bonus, m.totalBorrowAssets, m.totalBorrowShares
        );
        if (s.seizedAssets <= collateral) return;

        s.seizedAssets = collateral;
        uint256 value = LiquidationMath.collateralValue(collateral, s.price);
        if (value >= debt) {
            s.bonus = LiquidationMath.equityCappedBonus(s.bonus, value, debt);
        } else {
            s.repaidShares = MathLib.min(
                LiquidationMath.repaidSharesForSeizure(
                    collateral, s.price, WAD + s.bonus, m.totalBorrowAssets, m.totalBorrowShares
                ),
                borrowShares
            );
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Flash loans
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    /// @dev Not bound to a market and therefore not locked: the callback may operate on any market, which is what
    ///      makes flash-loan-funded liquidations possible. Repayment is enforced by the final `transferFrom`.
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, ZeroAmount());

        emit FlashLoan(msg.sender, token, assets);

        IERC20(token).safeTransfer(msg.sender, assets);
        IFlashLoanCallback(msg.sender).onFlashLoan(assets, data);
        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Interest
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    function accrueInterest(MarketParams calldata marketParams) external {
        Id id = marketParams.id();
        require(_market[id].lastUpdate != 0, MarketNotCreated(id));
        _lock(id);
        _accrueInterest(marketParams, id);
        _unlock(id);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Authorization
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
        emit SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    /// @inheritdoc ILendingEngine
    function setAuthorizationWithSig(Authorization calldata authorization, bytes calldata signature) external {
        require(block.timestamp <= authorization.deadline, SignatureExpired(authorization.deadline, block.timestamp));
        uint256 expectedNonce = nonce[authorization.authorizer];
        require(authorization.nonce == expectedNonce, InvalidNonce(expectedNonce, authorization.nonce));

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization)));
        require(
            SignatureChecker.isValidSignatureNowCalldata(authorization.authorizer, digest, signature),
            InvalidSignature(authorization.authorizer)
        );

        nonce[authorization.authorizer] = expectedNonce + 1;
        emit IncrementNonce(msg.sender, authorization.authorizer, expectedNonce);

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;
        emit SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ILendingEngine
    function market(Id id) external view returns (Market memory) {
        return _market[id];
    }

    /// @inheritdoc ILendingEngine
    function position(Id id, address user) external view returns (Position memory) {
        return _position[id][user];
    }

    /// @inheritdoc ILendingEngine
    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _idToMarketParams[id];
    }

    /// @inheritdoc ILendingEngine
    function liquidationConfig(uint256 lltv) external view returns (LiquidationConfig memory) {
        return _liquidationConfig[lltv];
    }

    /// @inheritdoc ILendingEngine
    function isMarketLocked(Id id) external view returns (bool) {
        return _lockSlot(id).tload();
    }

    /// @inheritdoc ILendingEngine
    function expectedMarketBalances(MarketParams calldata marketParams)
        public
        view
        returns (uint256, uint256, uint256, uint256)
    {
        Id id = marketParams.id();
        Market memory m = _market[id];
        require(m.lastUpdate != 0, MarketNotCreated(id));
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed != 0 && m.totalBorrowAssets != 0) {
            uint256 rate = IIrm(marketParams.irm).borrowRateView(marketParams, m);
            uint256 interest = uint256(m.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(elapsed));
            m.totalBorrowAssets += interest.toUint128();
            m.totalSupplyAssets += interest.toUint128();
            if (m.fee != 0) {
                uint256 feeAmount = interest.wMulDown(m.fee);
                m.totalSupplyShares += feeAmount.toSharesDown(m.totalSupplyAssets - feeAmount, m.totalSupplyShares)
                    .toUint128();
            }
        }
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares);
    }

    /// @inheritdoc ILendingEngine
    /// @dev (Slither triage) `debt == 0` distinguishes "no debt" (infinite health) from a real ratio; it is not a
    ///      balance equality an attacker can game.
    // slither-disable-next-line incorrect-equality
    function healthFactor(MarketParams calldata marketParams, address borrower) external view returns (uint256) {
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) = expectedMarketBalances(marketParams);
        Position memory p = _position[marketParams.id()][borrower];
        uint256 debt = uint256(p.borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        if (debt == 0) return type(uint256).max;
        uint256 price = IOracle(marketParams.oracle).price();
        return LiquidationMath.healthFactor(LiquidationMath.maxBorrow(p.collateral, price, marketParams.lltv), debt);
    }

    /// @inheritdoc ILendingEngine
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Applies interest since the last update. The IRM sees the pre-accrual state.
    ///      (Slither triage) `elapsed == 0` is the "already accrued in this block" fast path, not a manipulable
    ///      equality. The IRM call precedes the state writes by necessity (the rate is an input); it runs under the
    ///      market lock and the IRM is governance-allowlisted, so it cannot re-enter this market.
    // slither-disable-next-line incorrect-equality,reentrancy-no-eth
    function _accrueInterest(MarketParams calldata marketParams, Id id) internal {
        Market storage m = _market[id];
        uint256 elapsed = block.timestamp - m.lastUpdate;
        if (elapsed == 0) return;

        uint256 rate = IIrm(marketParams.irm).borrowRate(marketParams, m);
        uint256 interest = uint256(m.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(elapsed));
        m.totalBorrowAssets = (uint256(m.totalBorrowAssets) + interest).toUint128();
        m.totalSupplyAssets = (uint256(m.totalSupplyAssets) + interest).toUint128();

        uint256 feeShares = 0;
        if (m.fee != 0) {
            uint256 feeAmount = interest.wMulDown(m.fee);
            // The fee is a share of the interest just added to supply, so it is priced against the supply
            // before the fee (as if the fee recipient supplied `feeAmount` at the pre-fee share price).
            feeShares = feeAmount.toSharesDown(m.totalSupplyAssets - feeAmount, m.totalSupplyShares);
            _position[id][feeRecipient].supplyShares += feeShares;
            m.totalSupplyShares = (uint256(m.totalSupplyShares) + feeShares).toUint128();
        }

        m.lastUpdate = block.timestamp.toUint128();
        emit AccrueInterest(id, rate, interest, feeShares);
    }

    /// @dev Reverts unless the position's debt fits within the borrowing capacity of its collateral.
    function _requireHealthy(MarketParams calldata marketParams, Market storage m, Position storage p) internal view {
        if (p.borrowShares == 0) return;
        uint256 debt = uint256(p.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
        uint256 price = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = LiquidationMath.maxBorrow(p.collateral, price, marketParams.lltv);
        require(debt <= maxBorrow, InsufficientCollateral(debt, maxBorrow));
    }

    /// @dev Whether `msg.sender` may act for `onBehalf`.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /// @dev True iff exactly one argument is zero.
    function _exactlyOneZero(uint256 x, uint256 y) internal pure returns (bool) {
        return (x == 0) != (y == 0);
    }

    /// @dev Enters market `id`, reverting if an operation on it is already in progress.
    function _lock(Id id) internal {
        TransientSlot.BooleanSlot slot = _lockSlot(id);
        require(!slot.tload(), MarketLocked(id));
        slot.tstore(true);
    }

    /// @dev Leaves market `id`.
    function _unlock(Id id) internal {
        _lockSlot(id).tstore(false);
    }

    /// @dev Transient slot holding the lock of market `id`.
    function _lockSlot(Id id) internal pure returns (TransientSlot.BooleanSlot) {
        return MARKET_LOCK_SLOT.deriveMapping(Id.unwrap(id)).asBoolean();
    }
}
