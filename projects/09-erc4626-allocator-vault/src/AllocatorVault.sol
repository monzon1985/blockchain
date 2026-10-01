// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IAllocatorVault} from "./interfaces/IAllocatorVault.sol";
import {VaultMath} from "./libraries/VaultMath.sol";

/// @title AllocatorVault
/// @notice A curated ERC-4626 meta-vault. Deposits land in an idle buffer; an allocator moves them into capped
///         ERC-4626 strategies; withdrawals pull from idle and then from strategies in withdraw-queue order.
/// @dev Economic hardening, each covered by a proof-of-concept test against a naive variant:
///      - Inflation / donation: 10**6 virtual shares (`DECIMALS_OFFSET = 6`) and donations are profit that unlocks
///        over `PROFIT_UNLOCK_PERIOD`, so they cannot move the price inside a transaction.
///      - Harvest sandwich: every profit (strategy yield, donation, re-listed strategy) is locked, and all locked
///        profit restarts a full 7-day linear unlock whenever new profit arrives, so no profit ever unlocks faster.
///      - First-mover loss escape: strategy positions are valued live on every entry point, so a loss is recognized
///        before anyone can exit at the stale price; a pending forced removal counts the position only for what can
///        be redeemed now, so its write-off reaches the price when it is announced, not when it executes.
///      - Impaired positions (a strategy whose views revert, or a pending forced removal that marks a position down):
///        the vault keeps working at the conservative price, books no profit or loss, and pauses deposits until the
///        impairment ends, so nobody can buy into a markdown that later reverses.
///      - Rounding extraction: every conversion rounds against the caller; deposits that would mint 0 shares revert.
///      Fees are minted as shares, the performance fee only above a high-water mark, both rounded down.
contract AllocatorVault is ERC4626, AccessManaged, ReentrancyGuardTransient, IAllocatorVault {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Decimals offset between shares and assets; also the exponent of the virtual shares.
    uint8 public constant DECIMALS_OFFSET = 6;

    /// @notice Virtual shares (and, implicitly, 1 virtual asset) added to every conversion.
    uint256 public constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET;

    /// @notice Delay before cap increases, strategy additions, fee increases and forced removals take effect.
    uint256 public constant TIMELOCK = 3 days;

    /// @notice Period over which newly observed profit is released into the share price.
    uint256 public constant PROFIT_UNLOCK_PERIOD = 7 days;

    /// @notice Maximum number of strategies; bounds the gas of every accrual.
    uint256 public constant MAX_STRATEGIES = 20;

    /// @notice Maximum performance fee (WAD): 50 % of the gain above the high-water mark.
    uint256 public constant MAX_PERFORMANCE_FEE = 0.5e18;

    /// @notice Maximum management fee (WAD per year): 5 % of total assets per year.
    uint256 public constant MAX_MANAGEMENT_FEE = 0.05e18;

    /// @notice Maximum value of the share-price growth limit (WAD per year): 100 % per year.
    uint256 public constant MAX_PRICE_GROWTH_LIMIT = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor parameters.
    /// @param asset The underlying asset.
    /// @param name ERC-20 name of the shares.
    /// @param symbol ERC-20 symbol of the shares.
    /// @param authority The AccessManager that enforces curator, allocator and guardian roles.
    /// @param feeRecipient Receiver of fee shares (may be zero only if both fees are zero).
    /// @param performanceFee Initial performance fee (WAD).
    /// @param managementFee Initial management fee (WAD per year).
    /// @param maxSharePriceGrowthPerYear Growth limit of `safeSharePrice` (WAD per year, non-zero).
    struct InitParams {
        IERC20 asset;
        string name;
        string symbol;
        address authority;
        address feeRecipient;
        uint256 performanceFee;
        uint256 managementFee;
        uint256 maxSharePriceGrowthPerYear;
    }

    /// @dev Everything an accrual reads, packed into one slot.
    /// @param lastAccrual Timestamp of the last accrual.
    /// @param unlockEnd Timestamp at which the locked profit is fully unlocked.
    /// @param performanceFee Performance fee (WAD).
    /// @param managementFee Management fee (WAD per year).
    struct Checkpoint {
        uint64 lastAccrual;
        uint64 unlockEnd;
        uint64 performanceFee;
        uint64 managementFee;
    }

    /// @dev Last rate-limited share price.
    /// @param price The price (RAY).
    /// @param updatedAt When it was recorded.
    struct SafePrice {
        uint192 price;
        uint64 updatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Growth limit of `safeSharePrice` (WAD per year, linear between checkpoints).
    uint256 public immutable maxSharePriceGrowthPerYear;

    /// @notice Booked gross assets: idle plus strategy assets observed by the last accrual that found no impaired
    ///         position, adjusted by deposits and withdrawals since.
    /// @dev The next unimpaired accrual compares the live gross assets against this value to detect profit or loss.
    uint256 public lastTotalAssets;

    /// @notice High-water mark: the highest share price (RAY, virtual shares included) ever recorded.
    /// @dev The performance fee is charged only on the part of a price increase above this mark.
    uint256 public highWaterMark;

    /// @notice Receiver of management- and performance-fee shares.
    address public feeRecipient;

    /// @dev Number of enabled strategies with a pending forced removal (packed with `feeRecipient`, which every
    ///      accrual reads anyway); lets the valuation skip each strategy's config while it is zero.
    uint96 internal _pendingRemovals;

    /// @dev Locked profit as of `_checkpoint.lastAccrual`; decays linearly until `_checkpoint.unlockEnd`.
    uint256 internal _lockedProfit;

    /// @dev Accrual timestamps and fee rates (one slot).
    Checkpoint internal _checkpoint;

    /// @dev Last rate-limited share price.
    SafePrice internal _safePrice;

    /// @dev Fee rates waiting out the timelock.
    PendingFees internal _pendingFees;

    /// @dev Configuration per strategy.
    mapping(IERC4626 strategy => StrategyConfig) internal _config;

    /// @dev Cap waiting out the timelock, per strategy.
    mapping(IERC4626 strategy => PendingValue) internal _pendingCap;

    /// @dev Enabled strategies in the order withdrawals pull liquidity from them.
    IERC4626[] internal _withdrawQueue;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys the vault with its initial fee configuration and share-price growth limit.
    /// @param params See `InitParams`.
    constructor(InitParams memory params)
        ERC4626(params.asset)
        ERC20(params.name, params.symbol)
        AccessManaged(params.authority)
    {
        if (address(params.asset) == address(0) || params.authority == address(0)) {
            revert ZeroAddress();
        }
        if (params.maxSharePriceGrowthPerYear == 0 || params.maxSharePriceGrowthPerYear > MAX_PRICE_GROWTH_LIMIT) {
            revert InvalidPriceGrowthLimit(params.maxSharePriceGrowthPerYear, MAX_PRICE_GROWTH_LIMIT);
        }
        _validateFees(params.performanceFee, params.managementFee, params.feeRecipient);

        maxSharePriceGrowthPerYear = params.maxSharePriceGrowthPerYear;
        feeRecipient = params.feeRecipient;
        _checkpoint = Checkpoint({
            lastAccrual: block.timestamp.toUint64(),
            unlockEnd: block.timestamp.toUint64(),
            performanceFee: params.performanceFee.toUint64(),
            managementFee: params.managementFee.toUint64()
        });
        uint256 initialPrice = VaultMath.sharePrice(0, 0, VIRTUAL_SHARES);
        highWaterMark = initialPrice;
        _safePrice = SafePrice({price: initialPrice.toUint192(), updatedAt: block.timestamp.toUint64()});

        emit SetFeeRecipient(msg.sender, params.feeRecipient);
        emit SetFees(msg.sender, params.performanceFee, params.managementFee);
    }

    /*//////////////////////////////////////////////////////////////
                         ERC-4626: STATE CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC4626
    /// @dev Accrues first, then mints `floor(assets * (supply + 1e6) / (totalAssets + 1))` shares. Reverts with
    ///      `ZeroShares` rather than taking assets for nothing, with `AssetTransferMismatch` for fee-on-transfer or
    ///      rebasing assets, and with `DepositsPausedWhileImpaired` while a strategy position is impaired.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        Accrual memory a = _accrueForDeposit();
        shares = _toShares(assets, a.totalSupply, a.totalAssets, Math.Rounding.Floor);
        // Zero check on a computed share amount, not an equality on a balance anyone can move.
        // slither-disable-next-line incorrect-equality
        if (shares == 0 && assets != 0) revert ZeroShares(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    /// @dev Accrues first, then pulls `ceil(shares * (totalAssets + 1) / (supply + 1e6))` assets. Paused while a
    ///      strategy position is impaired, like `deposit`.
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        Accrual memory a = _accrueForDeposit();
        assets = _toAssets(shares, a.totalSupply, a.totalAssets, Math.Rounding.Ceil);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IERC4626
    /// @dev Accrues first (so a pending loss is recognized before pricing), then burns
    ///      `ceil(assets * (supply + 1e6) / (totalAssets + 1))` shares.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        Accrual memory a = _accrue();
        shares = _toShares(assets, a.totalSupply, a.totalAssets, Math.Rounding.Ceil);
        uint256 ownerShares = balanceOf(owner);
        if (shares > ownerShares) {
            revert ERC4626ExceededMaxWithdraw(
                owner, assets, _toAssets(ownerShares, a.totalSupply, a.totalAssets, Math.Rounding.Floor)
            );
        }
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @inheritdoc IERC4626
    /// @dev Accrues first, then pays `floor(shares * (totalAssets + 1) / (supply + 1e6))` assets.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        Accrual memory a = _accrue();
        uint256 ownerShares = balanceOf(owner);
        if (shares > ownerShares) revert ERC4626ExceededMaxRedeem(owner, shares, ownerShares);
        assets = _toAssets(shares, a.totalSupply, a.totalAssets, Math.Rounding.Floor);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                             ERC-4626: VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC4626
    /// @dev Idle plus the counted strategy value, minus the profit that is still locked (the conservative price of
    ///      `_previewAccrual` while a position is impaired). Never reverts because of a strategy; reverts when read from
    ///      inside a vault call (read-only reentrancy).
    function totalAssets() public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        return _previewAccrual().totalAssets;
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets)
        public
        view
        override(ERC4626, IERC4626)
        nonReentrantView
        returns (uint256)
    {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares)
        public
        view
        override(ERC4626, IERC4626)
        nonReentrantView
        returns (uint256)
    {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets)
        public
        view
        override(ERC4626, IERC4626)
        nonReentrantView
        returns (uint256)
    {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev 0 while a strategy position is impaired (deposits are paused), unlimited otherwise.
    function maxDeposit(address) public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        return _depositsPaused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @dev 0 while a strategy position is impaired (deposits are paused), unlimited otherwise.
    function maxMint(address) public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        return _depositsPaused() ? 0 : type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @dev The owner's assets, capped by what idle and the strategies can deliver right now.
    function maxWithdraw(address owner) public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        Accrual memory a = _previewAccrual();
        uint256 ownerAssets = _toAssets(balanceOf(owner), a.totalSupply, a.totalAssets, Math.Rounding.Floor);
        return FixedPointMathLib.min(ownerAssets, _availableLiquidity());
    }

    /// @inheritdoc IERC4626
    /// @dev The owner's shares, capped by the shares whose redemption the available liquidity can cover. Compared in
    ///      asset space first: liquidity can include a large still-locked donation, and converting it to shares
    ///      against the (smaller) unlocked `totalAssets` could overflow, while this view must never revert.
    function maxRedeem(address owner) public view override(ERC4626, IERC4626) nonReentrantView returns (uint256) {
        Accrual memory a = _previewAccrual();
        uint256 ownerShares = balanceOf(owner);
        uint256 liquidity = _availableLiquidity();
        if (_toAssets(ownerShares, a.totalSupply, a.totalAssets, Math.Rounding.Floor) <= liquidity) return ownerShares;
        // Here liquidity < the owner's assets <= totalAssets, so the conversion cannot overflow and is < ownerShares.
        return _toShares(liquidity, a.totalSupply, a.totalAssets, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                                KEEPER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAllocatorVault
    function accrue() external nonReentrant {
        _accrue();
    }

    /*//////////////////////////////////////////////////////////////
                                CURATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAllocatorVault
    function submitCap(IERC4626 strategy, uint256 newCap) external restricted {
        StrategyConfig memory cfg = _config[strategy];
        if (!cfg.enabled) _validateStrategy(strategy);
        if (newCap == cfg.cap) revert CapAlreadySet(strategy, newCap);

        if (newCap < cfg.cap) {
            // Lowering a cap only restricts the allocator: effective at once, and it cancels any pending increase.
            _clearPendingCap(strategy);
            _setCap(strategy, newCap);
            return;
        }

        if (cfg.removableAt != 0) revert RemovalPending(strategy);
        uint256 pendingValidAt = _pendingCap[strategy].validAt;
        if (pendingValidAt != 0) revert AlreadyPending(pendingValidAt);

        uint256 validAt = block.timestamp + TIMELOCK;
        _pendingCap[strategy] = PendingValue({value: newCap.toUint184(), validAt: validAt.toUint64()});
        emit SubmitCap(msg.sender, strategy, newCap, validAt);
    }

    /// @inheritdoc IAllocatorVault
    /// @dev Accrues first, so profit and loss up to now are booked at the full valuation, then redeems everything the
    ///      strategy lets the vault redeem. From then on the rest of the position counts as 0 (see `_strategyValue`),
    ///      so the write-off is priced in at once and no later change in the strategy's liquidity (borrowers repaying,
    ///      or a flash-loaned deposit into the strategy) can lift the price an exit is paid at.
    function submitStrategyRemoval(IERC4626 strategy) external nonReentrant restricted {
        StrategyConfig memory cfg = _config[strategy];
        if (!cfg.enabled) revert StrategyNotEnabled(strategy);
        if (cfg.cap != 0) revert CapNotZero(strategy, cfg.cap);
        if (cfg.removableAt != 0) revert AlreadyPending(cfg.removableAt);
        uint256 pendingValidAt = _pendingCap[strategy].validAt;
        if (pendingValidAt != 0) revert AlreadyPending(pendingValidAt);

        _accrue();
        uint256 removableAt = block.timestamp + TIMELOCK;
        _config[strategy].removableAt = removableAt.toUint64();
        ++_pendingRemovals;
        emit SubmitStrategyRemoval(msg.sender, strategy, removableAt);
        _redeemRedeemable(strategy);
    }

    /// @inheritdoc IAllocatorVault
    function removeStrategy(IERC4626 strategy) external nonReentrant restricted {
        StrategyConfig memory cfg = _config[strategy];
        if (!cfg.enabled) revert StrategyNotEnabled(strategy);
        if (cfg.cap != 0) revert CapNotZero(strategy, cfg.cap);

        _accrue();
        uint256 recovered = _redeemRedeemable(strategy);

        // Whatever is left (at the strategy's own `previewRedeem`) is written off. That needs a forced removal that
        // waited out its timelock. So does a position the strategy cannot value at all; `remaining` then stays 0, the
        // value it was already counted at.
        uint256 remaining = 0;
        (bool valued, uint256 shares) = _tryView(strategy.balanceOf, address(this));
        if (valued && shares != 0) (valued, remaining) = _tryView(strategy.previewRedeem, shares);
        if (!valued || remaining != 0) {
            if (cfg.removableAt == 0) revert StrategyHasAssets(strategy, remaining);
            if (block.timestamp < cfg.removableAt) revert TimelockNotElapsed(cfg.removableAt, block.timestamp);
        }

        if (cfg.removableAt != 0) --_pendingRemovals;
        delete _config[strategy];
        _clearPendingCap(strategy); // a pending re-raise of the removed strategy's cap is void
        _removeFromWithdrawQueue(strategy);
        emit StrategyRemoved(msg.sender, strategy, recovered, remaining);

        // Realize the write-off (and any redemption rounding) as a loss in this same transaction.
        _accrue();
    }

    /// @inheritdoc IAllocatorVault
    function submitFees(uint256 newPerformanceFee, uint256 newManagementFee) external nonReentrant restricted {
        _validateFees(newPerformanceFee, newManagementFee, feeRecipient);
        Checkpoint memory c = _checkpoint;
        if (newPerformanceFee == c.performanceFee && newManagementFee == c.managementFee) revert FeesAlreadySet();

        if (newPerformanceFee <= c.performanceFee && newManagementFee <= c.managementFee) {
            // Pure decrease: charge what is owed at the old rates, then switch. A pending increase is void.
            _accrue();
            if (_pendingFees.validAt != 0) {
                delete _pendingFees;
                emit RevokePendingFees(msg.sender);
            }
            _setFees(newPerformanceFee, newManagementFee);
            return;
        }

        uint256 pendingValidAt = _pendingFees.validAt;
        if (pendingValidAt != 0) revert AlreadyPending(pendingValidAt);
        uint256 validAt = block.timestamp + TIMELOCK;
        _pendingFees = PendingFees({
            performanceFee: newPerformanceFee.toUint64(),
            managementFee: newManagementFee.toUint64(),
            validAt: validAt.toUint64()
        });
        emit SubmitFees(msg.sender, newPerformanceFee, newManagementFee, validAt);
    }

    // Zero is allowed on purpose (and checked in the body): it is only accepted while both fees are zero.
    // forge-lint: disable-next-item(missing-zero-check)
    /// @inheritdoc IAllocatorVault
    function setFeeRecipient(address newFeeRecipient) external nonReentrant restricted {
        if (newFeeRecipient == feeRecipient) revert FeeRecipientAlreadySet(newFeeRecipient);
        Checkpoint memory c = _checkpoint;
        if (newFeeRecipient == address(0) && (c.performanceFee != 0 || c.managementFee != 0)) {
            revert ZeroFeeRecipient();
        }
        _accrue();
        feeRecipient = newFeeRecipient;
        emit SetFeeRecipient(msg.sender, newFeeRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                               ALLOCATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAllocatorVault
    function reallocate(Allocation[] calldata allocations) external nonReentrant restricted {
        _accrue();
        IERC20 token = IERC20(asset());
        uint256 length = allocations.length;
        for (uint256 i; i < length; ++i) {
            IERC4626 strategy = allocations[i].strategy;
            uint256 target = allocations[i].assets;
            StrategyConfig memory cfg = _config[strategy];
            if (!cfg.enabled) revert StrategyNotEnabled(strategy);

            // Read fresh for every allocation, and only used to size this allocation's own move (a balance read
            // inside a `nonReentrant` function, so no reentrant call can change it before it is used).
            // slither-disable-next-line reentrancy-balance
            uint256 shares = strategy.balanceOf(address(this));
            // Zero check on the vault's own share count: no strategy is asked to value an empty position.
            // slither-disable-next-line incorrect-equality
            uint256 current = shares == 0 ? 0 : strategy.previewRedeem(shares);

            if (target < current) {
                if (target == 0) {
                    uint256 received = _redeemAllFromStrategy(token, strategy, shares);
                    emit Deallocate(msg.sender, strategy, received, shares);
                } else {
                    uint256 amount = current - target;
                    uint256 burned = _withdrawFromStrategy(token, strategy, amount);
                    emit Deallocate(msg.sender, strategy, amount, burned);
                }
            } else if (target > current) {
                // Fresh read, after any earlier move of this call; used before this allocation's own external call.
                // slither-disable-next-line reentrancy-balance
                uint256 idle = token.balanceOf(address(this));
                uint256 amount = target == type(uint256).max ? idle : target - current;
                // Skips an empty move; a computed amount, not a balance anyone can move.
                // slither-disable-next-line incorrect-equality
                if (amount == 0) continue;
                if (amount > idle) revert InsufficientIdle(amount, idle);
                if (current + amount > cfg.cap) revert CapExceeded(strategy, current + amount, cfg.cap);
                token.forceApprove(address(strategy), amount);
                uint256 minted = strategy.deposit(amount, address(this));
                emit Allocate(msg.sender, strategy, amount, minted);
            }
        }
    }

    /// @inheritdoc IAllocatorVault
    function setWithdrawQueue(IERC4626[] calldata newWithdrawQueue) external restricted {
        uint256 length = _withdrawQueue.length;
        if (newWithdrawQueue.length != length) revert WithdrawQueueLengthMismatch(length, newWithdrawQueue.length);
        // Enabled strategies are exactly the current queue, so `length` distinct enabled entries are a permutation.
        for (uint256 i; i < length; ++i) {
            IERC4626 strategy = newWithdrawQueue[i];
            if (!_config[strategy].enabled) revert StrategyNotEnabled(strategy);
            for (uint256 j; j < i; ++j) {
                if (address(newWithdrawQueue[j]) == address(strategy)) revert DuplicateStrategy(strategy);
            }
        }
        _withdrawQueue = newWithdrawQueue;
        emit SetWithdrawQueue(msg.sender, newWithdrawQueue);
    }

    /*//////////////////////////////////////////////////////////////
                               GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAllocatorVault
    function revokePendingCap(IERC4626 strategy) external restricted {
        if (_pendingCap[strategy].validAt == 0) revert NoPendingValue();
        delete _pendingCap[strategy];
        emit RevokePendingCap(msg.sender, strategy);
    }

    /// @inheritdoc IAllocatorVault
    /// @dev The position counts at its full `previewRedeem` value again; if that ends an impairment, the next accrual
    ///      books profit and loss as usual.
    function revokePendingRemoval(IERC4626 strategy) external restricted {
        StrategyConfig storage cfg = _config[strategy];
        if (cfg.removableAt == 0) revert NoPendingValue();
        cfg.removableAt = 0;
        --_pendingRemovals;
        emit RevokePendingRemoval(msg.sender, strategy);
    }

    /// @inheritdoc IAllocatorVault
    function revokePendingFees() external restricted {
        if (_pendingFees.validAt == 0) revert NoPendingValue();
        delete _pendingFees;
        emit RevokePendingFees(msg.sender);
    }

    /// @inheritdoc IAllocatorVault
    /// @dev Idempotent on purpose: an emergency transaction must not fail because the cap is already zero.
    function zeroCap(IERC4626 strategy) external restricted {
        if (!_config[strategy].enabled) revert StrategyNotEnabled(strategy);
        _clearPendingCap(strategy);
        _setCap(strategy, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          TIMELOCK EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAllocatorVault
    function acceptCap(IERC4626 strategy) external {
        PendingValue memory pending = _pendingCap[strategy];
        _checkTimelock(pending.validAt);
        delete _pendingCap[strategy];
        // If the vault already holds shares of a (re-)listed strategy, their value shows up as profit at the next
        // accrual and is unlocked over PROFIT_UNLOCK_PERIOD like any other profit.
        _setCap(strategy, pending.value);
    }

    /// @inheritdoc IAllocatorVault
    function acceptFees() external nonReentrant {
        PendingFees memory pending = _pendingFees;
        _checkTimelock(pending.validAt);
        _validateFees(pending.performanceFee, pending.managementFee, feeRecipient);
        delete _pendingFees;
        _accrue();
        _setFees(pending.performanceFee, pending.managementFee);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAllocatorVault
    function previewAccrual() external view nonReentrantView returns (Accrual memory) {
        return _previewAccrual();
    }

    /// @inheritdoc IAllocatorVault
    function sharePrice() external view nonReentrantView returns (uint256) {
        return _previewAccrual().sharePrice;
    }

    /// @inheritdoc IAllocatorVault
    function safeSharePrice() public view nonReentrantView returns (uint256) {
        Accrual memory a = _previewAccrual();
        uint256 ceiling = _ceiling(_safeCheckpoint(address(a.impairedStrategy) != address(0)));
        return FixedPointMathLib.min(a.sharePrice, ceiling);
    }

    /// @inheritdoc IAllocatorVault
    function safeConvertToAssets(uint256 shares) external view returns (uint256 assets) {
        return FixedPointMathLib.fullMulDiv(shares, safeSharePrice(), VaultMath.RAY);
    }

    /// @inheritdoc IAllocatorVault
    function withdrawQueueLength() external view returns (uint256) {
        return _withdrawQueue.length;
    }

    /// @inheritdoc IAllocatorVault
    function withdrawQueue(uint256 index) external view returns (IERC4626) {
        return _withdrawQueue[index];
    }

    /// @inheritdoc IAllocatorVault
    function config(IERC4626 strategy) external view returns (StrategyConfig memory) {
        return _config[strategy];
    }

    /// @inheritdoc IAllocatorVault
    function pendingCap(IERC4626 strategy) external view returns (PendingValue memory) {
        return _pendingCap[strategy];
    }

    /// @inheritdoc IAllocatorVault
    function pendingFees() external view returns (PendingFees memory) {
        return _pendingFees;
    }

    /// @inheritdoc IAllocatorVault
    function strategyAssets(IERC4626 strategy) external view nonReentrantView returns (uint256 value) {
        (value,) = _strategyValue(strategy);
    }

    /// @inheritdoc IAllocatorVault
    function availableLiquidity() external view nonReentrantView returns (uint256) {
        return _availableLiquidity();
    }

    /// @notice Current performance fee (WAD).
    /// @return The fee.
    function performanceFee() external view returns (uint256) {
        return _checkpoint.performanceFee;
    }

    /// @notice Current management fee (WAD per year).
    /// @return The fee.
    function managementFee() external view returns (uint256) {
        return _checkpoint.managementFee;
    }

    /// @notice Timestamp of the last accrual.
    /// @return The timestamp.
    function lastAccrual() external view returns (uint256) {
        return _checkpoint.lastAccrual;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL: ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Computes the accrual at `block.timestamp` without writing it. Shared by every view and by `_accrue`, so
    ///      previews and executions use exactly the same numbers.
    function _previewAccrual() internal view returns (Accrual memory a) {
        Checkpoint memory c = _checkpoint;
        (a.grossAssets, a.impairedStrategy) = _grossAssets();

        uint256 locked = VaultMath.lockedProfitAt(_lockedProfit, c.lastAccrual, c.unlockEnd, block.timestamp);
        uint256 unlockEnd = c.unlockEnd;
        uint256 last = lastTotalAssets;
        if (address(a.impairedStrategy) != address(0)) {
            // Impaired: book nothing, because the markdown may reverse (a paused strategy resumes, a forced removal is
            // revoked or its borrowers repay). Price at the lower of the counted value and the booked value net of
            // locked profit, which is exactly where booking the markdown as a loss would leave it, so whoever exits
            // now gets no more than those who stay. `locked <= last` always holds (see invariant I2).
            a.totalAssets = FixedPointMathLib.min(a.grossAssets, last - locked);
        } else {
            if (a.grossAssets > last) {
                // Profit (strategy yield, donation, re-listed strategy): locked, then released linearly.
                a.profit = a.grossAssets - last;
                (locked, unlockEnd) = VaultMath.lockProfit(locked, a.profit, block.timestamp, PROFIT_UNLOCK_PERIOD);
            } else if (a.grossAssets < last) {
                // Loss: recognized now. It first cancels profit that has not reached the share price yet.
                a.loss = last - a.grossAssets;
                a.lossAbsorbed = FixedPointMathLib.min(a.loss, locked);
                locked -= a.lossAbsorbed;
            }
            // `locked <= grossAssets`: see invariant I2 in the README.
            a.totalAssets = a.grossAssets - locked;
        }
        a.lockedProfit = locked;
        a.unlockEnd = unlockEnd;

        uint256 supply = totalSupply();
        if (supply != 0 && feeRecipient != address(0)) {
            uint256 managementAssets =
                VaultMath.managementFeeAssets(a.totalAssets, c.managementFee, block.timestamp - c.lastAccrual);
            a.managementFeeShares = VaultMath.feeShares(managementAssets, supply + VIRTUAL_SHARES, a.totalAssets);
            supply += a.managementFeeShares;

            uint256 priceBeforePerformanceFee = VaultMath.sharePrice(a.totalAssets, supply, VIRTUAL_SHARES);
            uint256 performanceAssets =
                VaultMath.performanceFeeAssets(priceBeforePerformanceFee, highWaterMark, supply, c.performanceFee);
            a.performanceFeeShares = VaultMath.feeShares(performanceAssets, supply + VIRTUAL_SHARES, a.totalAssets);
            supply += a.performanceFeeShares;
        }
        a.totalSupply = supply;
        a.sharePrice = VaultMath.sharePrice(a.totalAssets, supply, VIRTUAL_SHARES);
        a.highWaterMark = FixedPointMathLib.max(highWaterMark, a.sharePrice);
    }

    /// @dev Writes the accrual: records gross assets and the unlock schedule, mints fee shares, raises the high-water
    ///      mark and checkpoints the rate-limited price. While a position is impaired the booked gross assets and the
    ///      safe-price checkpoint are left alone (see `_previewAccrual`). Returns the accrual every conversion must use
    ///      afterwards.
    function _accrue() internal returns (Accrual memory a) {
        a = _previewAccrual();
        bool impaired = address(a.impairedStrategy) != address(0);
        SafePrice memory checkpoint = _safeCheckpoint(impaired); // reads `lastAccrual`, so before it is overwritten

        if (!impaired) lastTotalAssets = a.grossAssets;
        _lockedProfit = a.lockedProfit;
        Checkpoint storage c = _checkpoint;
        c.lastAccrual = block.timestamp.toUint64();
        c.unlockEnd = a.unlockEnd.toUint64();
        highWaterMark = a.highWaterMark;

        uint256 feeShares = a.managementFeeShares + a.performanceFeeShares;
        if (feeShares != 0) _mint(feeRecipient, feeShares);

        // Re-anchor the rate limiter only while it does not bind: while the price is at or above the ceiling the old
        // checkpoint is kept, so the ceiling keeps growing linearly from it however often anyone accrues (re-anchoring
        // at the ceiling on every accrual would compound the limit). A conservative impaired price is not a reliable
        // anchor either: while a position is impaired the checkpoint keeps its price and only its clock is moved on.
        uint256 ceiling = _ceiling(checkpoint);
        if (impaired) {
            _safePrice = checkpoint;
            emit PnLDeferred(a.impairedStrategy, a.grossAssets, lastTotalAssets);
        } else if (a.sharePrice < ceiling) {
            _anchorSafePrice(FixedPointMathLib.min(a.sharePrice, ceiling));
        }

        if (a.profit != 0) emit ProfitLocked(a.profit, a.lockedProfit, a.unlockEnd);
        if (a.loss != 0) emit LossRealized(a.loss, a.lossAbsorbed);
        emit Accrue(
            a.grossAssets,
            a.totalAssets,
            a.lockedProfit,
            a.unlockEnd,
            a.managementFeeShares,
            a.performanceFeeShares,
            a.highWaterMark
        );
    }

    /// @dev `_accrue` for the deposit paths: new money must not buy into a markdown that may reverse.
    function _accrueForDeposit() internal returns (Accrual memory a) {
        a = _accrue();
        if (address(a.impairedStrategy) != address(0)) revert DepositsPausedWhileImpaired(a.impairedStrategy);
    }

    /// @dev Whether a strategy position is impaired, which pauses deposits.
    function _depositsPaused() internal view returns (bool) {
        (, IERC4626 impaired) = _grossAssets();
        return address(impaired) != address(0);
    }

    /// @dev Idle balance plus the counted value of every enabled strategy position, and the first impaired one.
    function _grossAssets() internal view returns (uint256 gross, IERC4626 impairedStrategy) {
        gross = IERC20(asset()).balanceOf(address(this));
        uint256 length = _withdrawQueue.length;
        for (uint256 i; i < length; ++i) {
            IERC4626 strategy = _withdrawQueue[i];
            (uint256 value, bool impaired) = _strategyValue(strategy);
            gross += value;
            if (impaired && address(impairedStrategy) == address(0)) impairedStrategy = strategy;
        }
    }

    /// @dev Value at which the vault counts its position in `strategy`, and whether that position is impaired:
    ///      - normally its `previewRedeem` value (which rounds down and includes any exit fee, so it never over-states
    ///        what the vault could get back);
    ///      - 0, impaired, while a forced removal is pending: everything redeemable was redeemed when the removal was
    ///        announced, and the rest is about to be written off. Counting it at anything the strategy reports live
    ///        (`maxRedeem` included) would let a holder lift that value for one transaction, by depositing flash-loaned
    ///        liquidity into the strategy, and exit at the pre-write-off price;
    ///      - 0, impaired, if any of these views reverts (for example a paused strategy, which EIP-4626 allows).
    function _strategyValue(IERC4626 strategy) internal view returns (uint256 value, bool impaired) {
        (bool ok, uint256 shares) = _tryView(strategy.balanceOf, address(this));
        if (ok && shares != 0) (ok, value) = _tryView(strategy.previewRedeem, shares);
        // A view that reverted, or a non-empty position whose forced removal is pending: counted as 0, impaired.
        impaired = !ok || (value != 0 && _removalPending(strategy));
        if (impaired) value = 0;
    }

    /// @dev Whether a forced removal of `strategy` is pending (the counter skips the config read while none is).
    function _removalPending(IERC4626 strategy) internal view returns (bool) {
        return _pendingRemovals != 0 && _config[strategy].removableAt != 0;
    }

    /// @dev Idle plus every strategy's `maxWithdraw` for the vault (0 for a strategy whose `maxWithdraw` reverts).
    function _availableLiquidity() internal view returns (uint256 liquidity) {
        liquidity = IERC20(asset()).balanceOf(address(this));
        uint256 length = _withdrawQueue.length;
        for (uint256 i; i < length; ++i) {
            (, uint256 withdrawable) = _tryView(_withdrawQueue[i].maxWithdraw, address(this));
            liquidity += withdrawable;
        }
    }

    /// @dev Calls a strategy view that takes an address. Returns `(false, 0)` if it reverts; see `_revertIfOutOfGas`.
    function _tryView(function(address) external view returns (uint256) view_, address arg)
        internal
        view
        returns (bool ok, uint256 result)
    {
        uint256 gasBefore = gasleft();
        try view_(arg) returns (uint256 value) {
            ok = true;
            result = value;
        } catch {
            _revertIfOutOfGas(IERC4626(view_.address), gasBefore);
        }
    }

    /// @dev Calls a strategy view that takes an amount. Returns `(false, 0)` if it reverts; see `_revertIfOutOfGas`.
    function _tryView(function(uint256) external view returns (uint256) view_, uint256 arg)
        internal
        view
        returns (bool ok, uint256 result)
    {
        uint256 gasBefore = gasleft();
        try view_(arg) returns (uint256 value) {
            ok = true;
            result = value;
        } catch {
            _revertIfOutOfGas(IERC4626(view_.address), gasBefore);
        }
    }

    /// @dev A strategy call that ran out of gas, at any depth inside the strategy, comes back with at most a few
    ///      64ths of the gas available before it (EIP-150). Counting it as a failing strategy would let a caller fake
    ///      an impairment by under-funding the transaction, so a failure only counts as genuine when more than a
    ///      quarter of that gas is left; otherwise the whole call reverts. A genuine failure can always be reached by
    ///      supplying more gas.
    function _revertIfOutOfGas(IERC4626 strategy, uint256 gasBefore) internal view {
        if (gasleft() <= gasBefore / 4) revert StrategyCallOutOfGas(strategy);
    }

    /// @dev The rate limiter's checkpoint as of now. Its clock does not run while a position is impaired: the time since
    ///      the last accrual is added to `updatedAt`, so the ceiling stays where it was. No headroom builds up behind a
    ///      conservative price, the ceiling does not drop, and nothing compounds (the price is unchanged).
    ///      `updatedAt <= lastAccrual`, so the result is never in the future.
    function _safeCheckpoint(bool impaired) internal view returns (SafePrice memory checkpoint) {
        checkpoint = _safePrice;
        if (impaired) checkpoint.updatedAt += (block.timestamp - _checkpoint.lastAccrual).toUint64();
    }

    /// @dev Moves the rate limiter's checkpoint to `price`, now.
    function _anchorSafePrice(uint256 price) internal {
        _safePrice = SafePrice({price: price.toUint192(), updatedAt: block.timestamp.toUint64()});
    }

    /// @dev The rate limiter's ceiling now: `checkpoint` grown linearly at `maxSharePriceGrowthPerYear`.
    function _ceiling(SafePrice memory checkpoint) internal view returns (uint256) {
        return
            VaultMath.priceCeiling(checkpoint.price, maxSharePriceGrowthPerYear, block.timestamp - checkpoint.updatedAt);
    }

    /// @dev `assets * (supply + 1e6) / (totalAssets + 1)` with explicit totals and rounding.
    function _toShares(uint256 assets, uint256 supply, uint256 totalAssets_, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return rounding == Math.Rounding.Ceil
            ? FixedPointMathLib.fullMulDivUp(assets, supply + VIRTUAL_SHARES, totalAssets_ + 1)
            : FixedPointMathLib.fullMulDiv(assets, supply + VIRTUAL_SHARES, totalAssets_ + 1);
    }

    /// @dev `shares * (totalAssets + 1) / (supply + 1e6)` with explicit totals and rounding.
    function _toAssets(uint256 shares, uint256 supply, uint256 totalAssets_, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return rounding == Math.Rounding.Ceil
            ? FixedPointMathLib.fullMulDivUp(shares, totalAssets_ + 1, supply + VIRTUAL_SHARES)
            : FixedPointMathLib.fullMulDiv(shares, totalAssets_ + 1, supply + VIRTUAL_SHARES);
    }

    /// @dev Used by the inherited ERC-4626 views; prices against the accrued (not the stored) totals.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        Accrual memory a = _previewAccrual();
        return _toShares(assets, a.totalSupply, a.totalAssets, rounding);
    }

    /// @dev Used by the inherited ERC-4626 views; prices against the accrued (not the stored) totals.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        Accrual memory a = _previewAccrual();
        return _toAssets(shares, a.totalSupply, a.totalAssets, rounding);
    }

    /// @dev 6: shares have 6 more decimals than the asset and every conversion adds 1e6 virtual shares.
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL: TOKEN MOVEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Pulls `assets` and checks the balance moved by exactly that much, so fee-on-transfer and rebasing assets
    ///      can never mint shares for assets the vault did not receive.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        IERC20 token = IERC20(asset());
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(caller, address(this), assets);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != assets) revert AssetTransferMismatch(assets, received);

        lastTotalAssets += assets;
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Burns first, books the outflow, then sources liquidity (idle, then the withdraw queue) and pays out.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);
        lastTotalAssets -= assets;

        _pullLiquidity(assets);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Makes sure at least `assets` are idle, withdrawing from strategies in withdraw-queue order.
    function _pullLiquidity(uint256 assets) internal {
        IERC20 token = IERC20(asset());
        // `needed` is decremented by what each strategy actually delivered (`_withdrawFromStrategy` reverts on a short
        // delivery), and the function is only reached from `nonReentrant` entry points.
        // slither-disable-next-line reentrancy-balance
        uint256 idle = token.balanceOf(address(this));
        if (idle >= assets) return;

        uint256 needed = assets - idle;
        uint256 length = _withdrawQueue.length;
        for (uint256 i = 0; i < length && needed != 0; ++i) {
            IERC4626 strategy = _withdrawQueue[i];
            (, uint256 withdrawable) = _tryView(strategy.maxWithdraw, address(this));
            uint256 amount = FixedPointMathLib.min(needed, withdrawable);
            // Skips a strategy with nothing to give; a computed amount, not a balance anyone can move.
            // slither-disable-next-line incorrect-equality
            if (amount == 0) continue;
            _withdrawFromStrategy(token, strategy, amount);
            needed -= amount;
        }
        if (needed != 0) revert InsufficientLiquidity(assets, assets - needed);
    }

    /// @dev Withdraws exactly `assets` from `strategy`, reverting if the strategy delivers less. A short delivery
    ///      paid out of other depositors' idle assets would let the withdrawer escape a loss.
    function _withdrawFromStrategy(IERC20 token, IERC4626 strategy, uint256 assets) internal returns (uint256 shares) {
        // Balance delta around exactly one external call; the after-read is fresh (reached only via `nonReentrant`).
        // slither-disable-next-line reentrancy-balance
        uint256 balanceBefore = token.balanceOf(address(this));
        shares = strategy.withdraw(assets, address(this), address(this));
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received < assets) revert StrategyUnderDelivered(strategy, assets, received);
    }

    // Triaged in docs/STATIC_ANALYSIS.md: the `redeem` return value is ignored on purpose (see the body).
    // slither-disable-start unused-return
    /// @dev Forced deallocation: redeems everything `strategy` lets the vault redeem right now and returns what actually
    ///      arrived. A strategy whose `maxRedeem` or `redeem` reverts contributes nothing (its position can then only be
    ///      written off). Reached only from `nonReentrant` entry points.
    function _redeemRedeemable(IERC4626 strategy) internal returns (uint256 recovered) {
        (bool ok, uint256 redeemable) = _tryView(strategy.maxRedeem, address(this));
        if (ok && redeemable != 0) {
            IERC20 token = IERC20(asset());
            uint256 balanceBefore = token.balanceOf(address(this));
            uint256 gasBefore = gasleft();
            // The strategy's claimed return is ignored on purpose: the vault books what actually arrived (and a
            // removal writes off the rest).
            // forge-lint: disable-next-line(unused-return, reentrancy-no-eth)
            try strategy.redeem(redeemable, address(this), address(this)) {}
            catch {
                _revertIfOutOfGas(strategy, gasBefore);
            }
            recovered = token.balanceOf(address(this)) - balanceBefore;
            if (recovered != 0) emit Deallocate(msg.sender, strategy, recovered, redeemable);
        }
    }

    // slither-disable-end unused-return

    /// @dev Redeems all `shares` from `strategy`, reverting if it delivers less than its own `redeem` return value.
    function _redeemAllFromStrategy(IERC20 token, IERC4626 strategy, uint256 shares)
        internal
        returns (uint256 received)
    {
        // Balance delta around exactly one external call; the after-read is fresh (reached only via `nonReentrant`).
        // slither-disable-next-line reentrancy-balance
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 claimed = strategy.redeem(shares, address(this), address(this));
        received = token.balanceOf(address(this)) - balanceBefore;
        if (received < claimed) revert StrategyUnderDelivered(strategy, claimed, received);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL: CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Sets a cap, enabling (and queueing) the strategy on its first non-zero cap.
    function _setCap(IERC4626 strategy, uint256 newCap) internal {
        StrategyConfig storage cfg = _config[strategy];
        if (newCap != 0 && !cfg.enabled) {
            if (_withdrawQueue.length >= MAX_STRATEGIES) revert MaxStrategiesExceeded(MAX_STRATEGIES);
            cfg.enabled = true;
            _withdrawQueue.push(strategy);
            emit StrategyAdded(strategy);
        }
        cfg.cap = newCap.toUint184();
        emit SetCap(msg.sender, strategy, newCap);
    }

    /// @dev Drops a pending cap, if there is one, and says so (monitors track pending values by their events).
    function _clearPendingCap(IERC4626 strategy) internal {
        // 0 is the "nothing pending" sentinel of a timestamp field, not a balance.
        // slither-disable-next-line incorrect-equality
        if (_pendingCap[strategy].validAt == 0) return;
        delete _pendingCap[strategy];
        emit RevokePendingCap(msg.sender, strategy);
    }

    /// @dev Sets fee rates (already validated).
    function _setFees(uint256 newPerformanceFee, uint256 newManagementFee) internal {
        Checkpoint storage c = _checkpoint;
        c.performanceFee = newPerformanceFee.toUint64();
        c.managementFee = newManagementFee.toUint64();
        emit SetFees(msg.sender, newPerformanceFee, newManagementFee);
    }

    /// @dev Removes `strategy` from the withdraw queue, preserving the order of the others.
    function _removeFromWithdrawQueue(IERC4626 strategy) internal {
        uint256 length = _withdrawQueue.length;
        uint256 index = 0;
        while (address(_withdrawQueue[index]) != address(strategy)) ++index;
        for (uint256 i = index + 1; i < length; ++i) {
            _withdrawQueue[i - 1] = _withdrawQueue[i];
        }
        _withdrawQueue.pop();
    }

    /// @dev Reverts unless `validAt` is set and has passed.
    function _checkTimelock(uint256 validAt) internal view {
        // 0 is the "nothing pending" sentinel of a timestamp field, not a balance.
        // slither-disable-next-line incorrect-equality
        if (validAt == 0) revert NoPendingValue();
        if (block.timestamp < validAt) revert TimelockNotElapsed(validAt, block.timestamp);
    }

    /// @dev Reverts unless `strategy` is a contract, not this vault, and an ERC-4626 vault over the same asset.
    function _validateStrategy(IERC4626 strategy) internal view {
        if (address(strategy).code.length == 0 || address(strategy) == address(this)) {
            revert InvalidStrategy(address(strategy));
        }
        if (strategy.asset() != asset()) revert InvalidStrategy(address(strategy));
    }

    /// @dev Reverts if a fee is above its maximum, or non-zero fees have no recipient.
    function _validateFees(uint256 newPerformanceFee, uint256 newManagementFee, address recipient) internal pure {
        if (newPerformanceFee > MAX_PERFORMANCE_FEE) revert FeeTooHigh(newPerformanceFee, MAX_PERFORMANCE_FEE);
        if (newManagementFee > MAX_MANAGEMENT_FEE) revert FeeTooHigh(newManagementFee, MAX_MANAGEMENT_FEE);
        if ((newPerformanceFee != 0 || newManagementFee != 0) && recipient == address(0)) revert ZeroFeeRecipient();
    }
}
