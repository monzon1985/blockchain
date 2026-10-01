// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IAllocatorVault
/// @notice A curated ERC-4626 meta-vault that allocates one asset across capped ERC-4626 strategies.
/// @dev Roles (curator, allocator, guardian) are enforced by an OpenZeppelin AccessManager through the
///      `restricted` modifier; see `VaultRoles` for the selector-to-role wiring.
interface IAllocatorVault is IERC4626 {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Configuration of one strategy.
    /// @param cap Maximum assets the allocator may place in the strategy, measured with its own `previewRedeem`.
    /// @param enabled True while the strategy is part of the withdraw queue and of `totalAssets`.
    /// @param removableAt Timestamp after which a strategy that still holds assets may be force-removed (0 = none).
    struct StrategyConfig {
        uint184 cap;
        bool enabled;
        uint64 removableAt;
    }

    /// @notice A value waiting out the timelock.
    /// @param value The submitted value.
    /// @param validAt Timestamp from which the value can be accepted (0 = nothing pending).
    struct PendingValue {
        uint184 value;
        uint64 validAt;
    }

    /// @notice Fee rates waiting out the timelock.
    /// @param performanceFee Submitted performance fee (WAD fraction of the gain above the high-water mark).
    /// @param managementFee Submitted management fee (WAD fraction of total assets per year).
    /// @param validAt Timestamp from which the fees can be accepted (0 = nothing pending).
    struct PendingFees {
        uint64 performanceFee;
        uint64 managementFee;
        uint64 validAt;
    }

    /// @notice One target of an allocator `reallocate` call.
    /// @param strategy The strategy to move assets into or out of.
    /// @param assets The target position in assets. `type(uint256).max` supplies all idle assets; 0 redeems all shares.
    struct Allocation {
        IERC4626 strategy;
        uint256 assets;
    }

    /// @notice Everything an accrual computes, returned by `previewAccrual` so keepers and integrators can inspect it.
    /// @param grossAssets Idle assets plus the counted value of every enabled strategy position: its `previewRedeem`
    ///        value; 0 while a forced removal is pending (what was redeemable was redeemed when it was announced) or
    ///        if its valuation reverts.
    /// @param lockedProfit Profit not yet reflected in the share price.
    /// @param unlockEnd Timestamp at which `lockedProfit` is fully unlocked.
    /// @param totalAssets The assets backing the shares: `grossAssets - lockedProfit`, or the impaired-case value
    ///        described under `impairedStrategy`.
    /// @param totalSupply Share supply including the fee shares the accrual mints.
    /// @param managementFeeShares Shares minted to the fee recipient for the management fee.
    /// @param performanceFeeShares Shares minted to the fee recipient for the performance fee.
    /// @param highWaterMark Share price (RAY, virtual shares included) after the accrual.
    /// @param sharePrice Share price (RAY, virtual shares included) after the accrual.
    /// @param profit Newly observed profit that was added to `lockedProfit`.
    /// @param loss Newly observed loss.
    /// @param lossAbsorbed Part of `loss` absorbed by profit that was still locked (never reached the share price).
    /// @param impairedStrategy First strategy in the withdraw queue whose position is impaired (its valuation reverts,
    ///        or a pending forced removal counts a non-empty position as 0); zero if none. While one is set,
    ///        profit and loss are not booked, `totalAssets` is the lower of `grossAssets` and the booked gross assets
    ///        net of locked profit, and deposits are paused.
    struct Accrual {
        uint256 grossAssets;
        uint256 lockedProfit;
        uint256 unlockEnd;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 managementFeeShares;
        uint256 performanceFeeShares;
        uint256 highWaterMark;
        uint256 sharePrice;
        uint256 profit;
        uint256 loss;
        uint256 lossAbsorbed;
        IERC4626 impairedStrategy;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every accrual.
    /// @param grossAssets Idle plus strategy assets observed by the accrual.
    /// @param totalAssets Assets backing the shares after the accrual.
    /// @param lockedProfit Profit still locked after the accrual.
    /// @param unlockEnd Timestamp at which the locked profit is fully unlocked.
    /// @param managementFeeShares Management-fee shares minted to the fee recipient.
    /// @param performanceFeeShares Performance-fee shares minted to the fee recipient.
    /// @param highWaterMark High-water mark (RAY share price) after the accrual.
    event Accrue(
        uint256 grossAssets,
        uint256 totalAssets,
        uint256 lockedProfit,
        uint256 unlockEnd,
        uint256 managementFeeShares,
        uint256 performanceFeeShares,
        uint256 highWaterMark
    );

    /// @notice Emitted when an accrual observes new profit and locks it for linear unlocking.
    /// @param profit The newly observed profit.
    /// @param lockedProfit Total locked profit after adding `profit`.
    /// @param unlockEnd The new unlock end: one full `PROFIT_UNLOCK_PERIOD` from now, for all the locked profit.
    event ProfitLocked(uint256 profit, uint256 lockedProfit, uint256 unlockEnd);

    /// @notice Emitted when an accrual observes a loss. It is recognized in the same transaction.
    /// @param loss The loss observed.
    /// @param absorbedByLockedProfit Part of the loss cancelled against still-locked profit; the rest lowered the price.
    event LossRealized(uint256 loss, uint256 absorbedByLockedProfit);

    /// @notice Emitted by an accrual that could not book profit or loss because a strategy position is impaired.
    /// @param impairedStrategy The first impaired strategy in the withdraw queue.
    /// @param countedGrossAssets Gross assets with the impaired position at its counted (lower) value.
    /// @param bookedGrossAssets Gross assets booked by the last unimpaired accrual, adjusted by flows since.
    event PnLDeferred(IERC4626 indexed impairedStrategy, uint256 countedGrossAssets, uint256 bookedGrossAssets);

    /// @notice Emitted when the curator submits a cap increase (or a new strategy) that must wait out the timelock.
    /// @param caller The curator.
    /// @param strategy The strategy.
    /// @param cap The submitted cap.
    /// @param validAt Timestamp from which `acceptCap` succeeds.
    event SubmitCap(address indexed caller, IERC4626 indexed strategy, uint256 cap, uint256 validAt);

    /// @notice Emitted when a strategy cap takes effect.
    /// @param caller The account that made the cap effective.
    /// @param strategy The strategy.
    /// @param cap The new cap.
    event SetCap(address indexed caller, IERC4626 indexed strategy, uint256 cap);

    /// @notice Emitted when a strategy is enabled and appended to the withdraw queue.
    /// @param strategy The strategy.
    event StrategyAdded(IERC4626 indexed strategy);

    /// @notice Emitted when a pending cap is dropped: revoked by the guardian, or cleared by a cap decrease, a guardian
    ///         `zeroCap` or the removal of the strategy.
    /// @param caller The account whose call dropped it.
    /// @param strategy The strategy.
    event RevokePendingCap(address indexed caller, IERC4626 indexed strategy);

    /// @notice Emitted when the curator starts the timelock for force-removing a strategy that still holds assets.
    ///         From this moment the position counts only for what can be redeemed now.
    /// @param caller The curator.
    /// @param strategy The strategy.
    /// @param removableAt Timestamp from which the forced removal is allowed.
    event SubmitStrategyRemoval(address indexed caller, IERC4626 indexed strategy, uint256 removableAt);

    /// @notice Emitted when the guardian revokes a pending forced removal.
    /// @param caller The guardian.
    /// @param strategy The strategy.
    event RevokePendingRemoval(address indexed caller, IERC4626 indexed strategy);

    /// @notice Emitted when a strategy is removed from the vault.
    /// @param caller The curator.
    /// @param strategy The strategy.
    /// @param recoveredAssets Assets withdrawn from the strategy during removal.
    /// @param writtenOffAssets `previewRedeem` value left in the strategy that is no longer counted (realized as a
    ///        loss); 0 when the strategy cannot value it (it was already counted as 0).
    event StrategyRemoved(
        address indexed caller, IERC4626 indexed strategy, uint256 recoveredAssets, uint256 writtenOffAssets
    );

    /// @notice Emitted when idle assets are supplied to a strategy.
    /// @param caller The allocator.
    /// @param strategy The strategy.
    /// @param assets Assets supplied.
    /// @param shares Strategy shares received.
    event Allocate(address indexed caller, IERC4626 indexed strategy, uint256 assets, uint256 shares);

    /// @notice Emitted when assets are withdrawn from a strategy back to idle by the allocator.
    /// @param caller The allocator.
    /// @param strategy The strategy.
    /// @param assets Assets received.
    /// @param shares Strategy shares burned.
    event Deallocate(address indexed caller, IERC4626 indexed strategy, uint256 assets, uint256 shares);

    /// @notice Emitted when the allocator reorders the withdraw queue.
    /// @param caller The allocator.
    /// @param newWithdrawQueue The new order.
    event SetWithdrawQueue(address indexed caller, IERC4626[] newWithdrawQueue);

    /// @notice Emitted when the curator submits a fee increase that must wait out the timelock.
    /// @param caller The curator.
    /// @param performanceFee The submitted performance fee (WAD).
    /// @param managementFee The submitted management fee (WAD per year).
    /// @param validAt Timestamp from which `acceptFees` succeeds.
    event SubmitFees(address indexed caller, uint256 performanceFee, uint256 managementFee, uint256 validAt);

    /// @notice Emitted when fee rates take effect.
    /// @param caller The account that made the fees effective.
    /// @param performanceFee The performance fee (WAD).
    /// @param managementFee The management fee (WAD per year).
    event SetFees(address indexed caller, uint256 performanceFee, uint256 managementFee);

    /// @notice Emitted when pending fees are dropped: revoked by the guardian, or cleared by a fee decrease.
    /// @param caller The account whose call dropped them.
    event RevokePendingFees(address indexed caller);

    /// @notice Emitted when the fee recipient changes.
    /// @param caller The curator.
    /// @param feeRecipient The new fee recipient.
    event SetFeeRecipient(address indexed caller, address indexed feeRecipient);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice The strategy is not an ERC-4626 vault over the same asset (or is the vault itself).
    /// @param strategy The rejected strategy.
    error InvalidStrategy(address strategy);

    /// @notice The strategy is not enabled.
    /// @param strategy The strategy.
    error StrategyNotEnabled(IERC4626 strategy);

    /// @notice The submitted cap equals the current cap.
    /// @param strategy The strategy.
    /// @param cap The current cap.
    error CapAlreadySet(IERC4626 strategy, uint256 cap);

    /// @notice A value is already pending for this slot.
    /// @param validAt When the pending value becomes acceptable.
    error AlreadyPending(uint256 validAt);

    /// @notice There is no pending value to accept or revoke.
    error NoPendingValue();

    /// @notice The timelock has not elapsed yet.
    /// @param validAt When the pending value becomes acceptable.
    /// @param timestamp The current block timestamp.
    error TimelockNotElapsed(uint256 validAt, uint256 timestamp);

    /// @notice The withdraw queue is full.
    /// @param max The maximum number of strategies.
    error MaxStrategiesExceeded(uint256 max);

    /// @notice An allocation would exceed the strategy cap.
    /// @param strategy The strategy.
    /// @param allocation The position the allocation would create.
    /// @param cap The strategy cap.
    error CapExceeded(IERC4626 strategy, uint256 allocation, uint256 cap);

    /// @notice An allocation needs more idle assets than the vault holds.
    /// @param requested Assets requested.
    /// @param idle Idle assets available.
    error InsufficientIdle(uint256 requested, uint256 idle);

    /// @notice Idle plus withdrawable strategy liquidity cannot cover a withdrawal.
    /// @param requested Assets requested.
    /// @param available Assets the withdraw queue could provide.
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice A strategy returned fewer assets than it was asked to withdraw.
    /// @param strategy The strategy.
    /// @param requested Assets requested.
    /// @param received Assets actually received.
    error StrategyUnderDelivered(IERC4626 strategy, uint256 requested, uint256 received);

    /// @notice The vault received a different amount than it pulled from the depositor (fee-on-transfer or rebasing).
    /// @param expected Assets the vault pulled.
    /// @param received Assets the vault's balance increased by.
    error AssetTransferMismatch(uint256 expected, uint256 received);

    /// @notice A deposit of non-zero assets would mint zero shares.
    /// @param assets The deposited assets.
    error ZeroShares(uint256 assets);

    /// @notice Deposits are paused while a strategy position is impaired: new money must not buy into a markdown that
    ///         may reverse.
    /// @param strategy The first impaired strategy in the withdraw queue.
    error DepositsPausedWhileImpaired(IERC4626 strategy);

    /// @notice A call to a strategy ran out of gas. It is not treated as a failing strategy, so that under-funding a
    ///         transaction cannot fake an impairment; retry with more gas.
    /// @param strategy The strategy.
    error StrategyCallOutOfGas(IERC4626 strategy);

    /// @notice The strategy must have a zero cap for this action.
    /// @param strategy The strategy.
    /// @param cap Its current cap.
    error CapNotZero(IERC4626 strategy, uint256 cap);

    /// @notice A forced removal is pending for this strategy.
    /// @param strategy The strategy.
    error RemovalPending(IERC4626 strategy);

    /// @notice The strategy still holds value (or cannot value the vault's position) and no forced removal of it has
    ///         waited out the timelock.
    /// @param strategy The strategy.
    /// @param remainingAssets Value that would be written off (0 if the strategy cannot value the position).
    error StrategyHasAssets(IERC4626 strategy, uint256 remainingAssets);

    /// @notice A fee is above its maximum.
    /// @param fee The submitted fee.
    /// @param max The maximum.
    error FeeTooHigh(uint256 fee, uint256 max);

    /// @notice Fees cannot be non-zero without a fee recipient (and the recipient cannot be cleared while they are).
    error ZeroFeeRecipient();

    /// @notice The submitted fees equal the current fees.
    error FeesAlreadySet();

    /// @notice The submitted fee recipient is already the fee recipient.
    /// @param feeRecipient The current fee recipient.
    error FeeRecipientAlreadySet(address feeRecipient);

    /// @notice The new withdraw queue is not a permutation of the current one.
    /// @param expectedLength The current queue length.
    /// @param actualLength The submitted queue length.
    error WithdrawQueueLengthMismatch(uint256 expectedLength, uint256 actualLength);

    /// @notice A strategy appears twice in the submitted withdraw queue.
    /// @param strategy The duplicated strategy.
    error DuplicateStrategy(IERC4626 strategy);

    /// @notice The share-price growth limit passed at construction is out of range.
    /// @param value The submitted limit (WAD per year).
    /// @param max The maximum limit.
    error InvalidPriceGrowthLimit(uint256 value, uint256 max);

    /*//////////////////////////////////////////////////////////////
                               KEEPER
    //////////////////////////////////////////////////////////////*/

    /// @notice Accrues profit, losses and fees (a "harvest"). Permissionless: it cannot move the price unfairly
    ///         because profit is locked and unlocked linearly while losses are recognized at once.
    function accrue() external;

    /*//////////////////////////////////////////////////////////////
                               CURATOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Submits a new cap. Decreases apply immediately; increases and new strategies wait out `TIMELOCK`.
    /// @param strategy The strategy (must be an ERC-4626 vault over `asset()`).
    /// @param newCap The new cap in assets.
    function submitCap(IERC4626 strategy, uint256 newCap) external;

    /// @notice Starts the timelock after which a zero-cap strategy that still holds assets may be force-removed, and
    ///         redeems everything the strategy lets the vault redeem now. From then on the rest of the position counts
    ///         as 0, so the expected write-off reaches the share price at once instead of at the removal.
    /// @param strategy The strategy.
    function submitStrategyRemoval(IERC4626 strategy) external;

    /// @notice Removes a zero-cap strategy: redeems whatever it lets the vault redeem and writes off the rest.
    /// @dev Writing off value (or a position the strategy cannot value) requires a forced removal that has waited out
    ///      the timelock. Works even when the strategy's views revert.
    /// @param strategy The strategy.
    function removeStrategy(IERC4626 strategy) external;

    /// @notice Submits new fee rates. Decreases apply immediately; any increase waits out `TIMELOCK`.
    /// @param newPerformanceFee Performance fee (WAD), at most `MAX_PERFORMANCE_FEE`.
    /// @param newManagementFee Management fee (WAD per year), at most `MAX_MANAGEMENT_FEE`.
    function submitFees(uint256 newPerformanceFee, uint256 newManagementFee) external;

    /// @notice Sets the fee recipient. Fees accrued so far are minted to the previous recipient first.
    /// @param newFeeRecipient The new recipient.
    function setFeeRecipient(address newFeeRecipient) external;

    /*//////////////////////////////////////////////////////////////
                              ALLOCATOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Moves assets between idle and strategies, processing `allocations` in order.
    /// @param allocations Target positions.
    function reallocate(Allocation[] calldata allocations) external;

    /// @notice Reorders the withdraw queue.
    /// @param newWithdrawQueue A permutation of the current queue.
    function setWithdrawQueue(IERC4626[] calldata newWithdrawQueue) external;

    /*//////////////////////////////////////////////////////////////
                               GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Revokes a pending cap increase or strategy addition.
    /// @param strategy The strategy.
    function revokePendingCap(IERC4626 strategy) external;

    /// @notice Revokes a pending forced removal.
    /// @param strategy The strategy.
    function revokePendingRemoval(IERC4626 strategy) external;

    /// @notice Revokes pending fee increases.
    function revokePendingFees() external;

    /// @notice Sets a strategy cap to zero immediately and drops any pending cap for it.
    /// @param strategy The strategy.
    function zeroCap(IERC4626 strategy) external;

    /*//////////////////////////////////////////////////////////////
                           TIMELOCK EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Makes a pending cap effective once its timelock has elapsed. Permissionless.
    /// @param strategy The strategy.
    function acceptCap(IERC4626 strategy) external;

    /// @notice Makes pending fees effective once their timelock has elapsed. Permissionless.
    function acceptFees() external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The result of accruing now, without writing it.
    /// @return The accrual.
    function previewAccrual() external view returns (Accrual memory);

    /// @notice Share price after accrual: `(totalAssets + 1) * 1e27 / (totalSupply + 10**6)`.
    /// @return The price in RAY.
    function sharePrice() external view returns (uint256);

    /// @notice Share price whose growth is limited to `maxSharePriceGrowthPerYear`, linear from the last checkpoint at
    ///         which the limit did not bind; falls with the price at once.
    /// @return The rate-limited price in RAY.
    function safeSharePrice() external view returns (uint256);

    /// @notice `convertToAssets` priced with `safeSharePrice`, for integrators that use shares as collateral.
    /// @param shares Shares to value.
    /// @return assets Value in assets, rounded down.
    function safeConvertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Number of strategies in the withdraw queue.
    /// @return The queue length.
    function withdrawQueueLength() external view returns (uint256);

    /// @notice Strategy at `index` of the withdraw queue.
    /// @param index Queue index.
    /// @return The strategy.
    function withdrawQueue(uint256 index) external view returns (IERC4626);

    /// @notice Configuration of a strategy.
    /// @param strategy The strategy.
    /// @return The configuration.
    function config(IERC4626 strategy) external view returns (StrategyConfig memory);

    /// @notice Pending cap of a strategy.
    /// @param strategy The strategy.
    /// @return The pending cap.
    function pendingCap(IERC4626 strategy) external view returns (PendingValue memory);

    /// @notice Pending fee rates.
    /// @return The pending fees.
    function pendingFees() external view returns (PendingFees memory);

    /// @notice Value at which the vault counts its position in a strategy: its `previewRedeem` value; 0 while a forced
    ///         removal is pending or if the strategy's views revert.
    /// @param strategy The strategy.
    /// @return The counted position value in assets.
    function strategyAssets(IERC4626 strategy) external view returns (uint256);

    /// @notice Assets the withdraw queue can deliver right now: idle plus every strategy's `maxWithdraw` (0 for a
    ///         strategy whose `maxWithdraw` reverts).
    /// @return The available liquidity.
    function availableLiquidity() external view returns (uint256);
}
