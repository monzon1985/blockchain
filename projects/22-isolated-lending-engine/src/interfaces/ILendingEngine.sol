// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Morpho Blue by Morpho Labs (https://github.com/morpho-org/morpho-blue, src/interfaces/IMorpho.sol,
// GPL-2.0-or-later): the MarketParams, Market, Position and Authorization types and the shape of the supply, borrow,
// collateral, flash-loan and authorization entry points and events. Modified for this project in 2026 (liquidation
// schedule, health guard, closeout rules, per-market lock); see the README's License section.
pragma solidity 0.8.37;

/// @notice Market identifier: `keccak256(abi.encode(MarketParams))`.
type Id is bytes32;

/// @notice Immutable definition of an isolated market. Its hash is the market id.
/// @param loanToken Token supplied by lenders and borrowed by borrowers.
/// @param collateralToken Token posted by borrowers; never lent out.
/// @param oracle `IOracle` quoting collateral in loan units (1e36 scale).
/// @param irm Governance-allowlisted interest rate model.
/// @param lltv Liquidation loan-to-value (WAD); governance-allowlisted together with its liquidation config.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Mutable accounting of one market. Assets are in loan-token base units.
/// @dev Packed into three storage slots.
struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

/// @notice A user's position in one market.
/// @dev Packed into two storage slots.
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice Reverse-Dutch liquidation schedule bound to an allowlisted LLTV.
/// @dev `bonus = min(maxBonus, bonusSlope * (1 - healthFactor))`, all WAD-scaled. Immutable once enabled.
/// @param maxBonus Cap on the liquidation bonus (e.g. 0.05e18 = 5 %).
/// @param bonusSlope Bonus paid per unit of health deficit (e.g. 1e18 = 1 % bonus per 1 % deficit).
/// @param enabled Whether the LLTV is allowlisted.
struct LiquidationConfig {
    uint96 maxBonus;
    uint96 bonusSlope;
    bool enabled;
}

/// @notice EIP-712 message that lets `authorized` manage `authorizer`'s positions.
/// @param authorizer The account granting (or revoking) the authorization.
/// @param authorized The position manager.
/// @param isAuthorized New authorization status.
/// @param nonce Must equal the authorizer's current nonce.
/// @param deadline Timestamp after which the signature is void.
struct Authorization {
    address authorizer;
    address authorized;
    bool isAuthorized;
    uint256 nonce;
    uint256 deadline;
}

/// @title ILendingEngine
/// @notice Isolated-market lending singleton: permissionless markets, share-based accounting, reverse-Dutch
///         liquidations with per-market bad-debt socialization, fee-free flash loans and EIP-712 delegation.
interface ILendingEngine {
    // ------------------------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------------------------

    /// @notice A market was created.
    /// @param id The market id.
    /// @param marketParams The market definition hashed into `id`.
    event CreateMarket(Id indexed id, MarketParams marketParams);

    /// @notice Loan tokens were supplied.
    /// @param id The market id.
    /// @param caller The account that paid.
    /// @param onBehalf The account credited with supply shares.
    /// @param assets Loan tokens supplied.
    /// @param shares Supply shares minted.
    event Supply(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);

    /// @notice Loan tokens were withdrawn.
    /// @param id The market id.
    /// @param caller The account that initiated the withdrawal (owner or authorized manager).
    /// @param onBehalf The account whose supply shares were burned.
    /// @param receiver The recipient of the tokens.
    /// @param assets Loan tokens withdrawn.
    /// @param shares Supply shares burned.
    event Withdraw(
        Id indexed id,
        address caller,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    /// @notice Loan tokens were borrowed.
    /// @param id The market id.
    /// @param caller The account that initiated the borrow (owner or authorized manager).
    /// @param onBehalf The account whose debt increased.
    /// @param receiver The recipient of the tokens.
    /// @param assets Loan tokens borrowed.
    /// @param shares Borrow shares minted.
    event Borrow(
        Id indexed id,
        address caller,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    /// @notice Debt was repaid.
    /// @param id The market id.
    /// @param caller The account that paid.
    /// @param onBehalf The account whose debt decreased.
    /// @param assets Loan tokens repaid.
    /// @param shares Borrow shares burned.
    event Repay(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);

    /// @notice Collateral was posted.
    /// @param id The market id.
    /// @param caller The account that paid.
    /// @param onBehalf The account credited with the collateral.
    /// @param assets Collateral tokens posted.
    event SupplyCollateral(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets);

    /// @notice Collateral was withdrawn.
    /// @param id The market id.
    /// @param caller The account that initiated the withdrawal (owner or authorized manager).
    /// @param onBehalf The account whose collateral decreased.
    /// @param receiver The recipient of the tokens.
    /// @param assets Collateral tokens withdrawn.
    event WithdrawCollateral(
        Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets
    );

    /// @notice An unhealthy position was liquidated.
    /// @param id The market id.
    /// @param caller The liquidator.
    /// @param borrower The liquidated account.
    /// @param repaidAssets Loan tokens paid by the liquidator.
    /// @param repaidShares Borrow shares burned from the borrower.
    /// @param seizedAssets Collateral transferred to the liquidator.
    /// @param badDebtAssets Debt written off against the market's suppliers (0 unless the collateral ran out).
    /// @param badDebtShares Borrow shares written off with `badDebtAssets`.
    /// @param healthFactor Health factor (WAD) of the position before the liquidation.
    /// @param bonus Liquidation bonus (WAD) applied: the reverse-Dutch schedule's, except in a closeout whose
    ///        collateral covers the debt but not debt plus the scheduled bonus, where it is capped at the borrower's
    ///        remaining equity `collateralValue / debt - 1`.
    event Liquidate(
        Id indexed id,
        address indexed caller,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets,
        uint256 badDebtAssets,
        uint256 badDebtShares,
        uint256 healthFactor,
        uint256 bonus
    );

    /// @notice A flash loan was executed.
    /// @param caller The borrower of the flash loan (and callback target).
    /// @param token The token lent.
    /// @param assets The amount lent and returned.
    event FlashLoan(address indexed caller, address indexed token, uint256 assets);

    /// @notice Interest was accrued on a market.
    /// @param id The market id.
    /// @param borrowRate Average borrow rate per second (WAD) returned by the IRM.
    /// @param interest Loan tokens added to both total borrow and total supply.
    /// @param feeShares Supply shares minted to the fee recipient.
    event AccrueInterest(Id indexed id, uint256 borrowRate, uint256 interest, uint256 feeShares);

    /// @notice A position manager authorization changed.
    /// @param caller The account that submitted the change (the authorizer or a relayer of its signature).
    /// @param authorizer The account whose positions are managed.
    /// @param authorized The manager.
    /// @param isAuthorized The new status.
    event SetAuthorization(
        address indexed caller, address indexed authorizer, address indexed authorized, bool isAuthorized
    );

    /// @notice A signature nonce was consumed.
    /// @param caller The relayer that submitted the signature.
    /// @param authorizer The signer whose nonce was consumed.
    /// @param usedNonce The consumed nonce.
    event IncrementNonce(address indexed caller, address indexed authorizer, uint256 usedNonce);

    /// @notice An interest rate model was allowlisted.
    /// @param irm The model.
    event EnableIrm(address indexed irm);

    /// @notice An LLTV was allowlisted together with its liquidation schedule.
    /// @param lltv The liquidation loan-to-value (WAD).
    /// @param maxBonus The bonus cap (WAD).
    /// @param bonusSlope The bonus per unit of health deficit (WAD).
    event EnableLltv(uint256 lltv, uint256 maxBonus, uint256 bonusSlope);

    /// @notice The protocol fee of a market changed.
    /// @param id The market id.
    /// @param newFee The new fee (WAD fraction of interest).
    event SetFee(Id indexed id, uint256 newFee);

    /// @notice The fee recipient changed.
    /// @param newFeeRecipient The new recipient of fee shares.
    event SetFeeRecipient(address indexed newFeeRecipient);

    // ------------------------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------------------------

    /// @notice A required address argument was zero.
    error ZeroAddress();
    /// @notice The amount argument was zero.
    error ZeroAmount();
    /// @notice Exactly one of `assets` and `shares` (or `seizedAssets` and `repaidShares`) must be non-zero.
    /// @param assets The assets-denominated input.
    /// @param shares The shares-denominated input.
    error InconsistentInput(uint256 assets, uint256 shares);
    /// @notice The interest rate model is not allowlisted.
    /// @param irm The rejected model.
    error IrmNotEnabled(address irm);
    /// @notice The interest rate model is already allowlisted.
    /// @param irm The model.
    error IrmAlreadyEnabled(address irm);
    /// @notice The LLTV is not allowlisted.
    /// @param lltv The rejected LLTV.
    error LltvNotEnabled(uint256 lltv);
    /// @notice The LLTV is already allowlisted; its liquidation schedule is immutable.
    /// @param lltv The LLTV.
    error LltvAlreadyEnabled(uint256 lltv);
    /// @notice The liquidation schedule is outside the safe envelope.
    /// @param lltv The LLTV.
    /// @param maxBonus The proposed bonus cap.
    /// @param bonusSlope The proposed slope.
    error InvalidLiquidationConfig(uint256 lltv, uint256 maxBonus, uint256 bonusSlope);
    /// @notice A market with these parameters already exists.
    /// @param id The existing market id.
    error MarketAlreadyCreated(Id id);
    /// @notice No market with this id exists.
    /// @param id The unknown market id.
    error MarketNotCreated(Id id);
    /// @notice The loan and collateral tokens must differ.
    /// @param token The token passed for both roles.
    error SameTokens(address token);
    /// @notice The market is locked by an operation in progress (same-market reentrancy).
    /// @param id The locked market.
    error MarketLocked(Id id);
    /// @notice `msg.sender` may not manage `onBehalf`'s position.
    /// @param caller The rejected caller.
    /// @param onBehalf The position owner.
    error Unauthorized(address caller, address onBehalf);
    /// @notice The operation would leave the position with more debt than its collateral allows.
    /// @param debt The position's debt after the operation (rounded up).
    /// @param maxBorrow The borrowing capacity of its collateral (rounded down).
    error InsufficientCollateral(uint256 debt, uint256 maxBorrow);
    /// @notice The account holds fewer supply shares or collateral than the operation removes.
    /// @param available The balance held.
    /// @param requested The amount the operation needs.
    error InsufficientBalance(uint256 available, uint256 requested);
    /// @notice The market would lend out more than it holds.
    /// @param totalBorrowAssets Total borrows after the operation.
    /// @param totalSupplyAssets Total supply after the operation.
    error InsufficientLiquidity(uint256 totalBorrowAssets, uint256 totalSupplyAssets);
    /// @notice The oracle returned a zero price, which would let collateral be seized for free.
    error ZeroPrice();
    /// @notice The position is healthy and cannot be liquidated.
    /// @param healthFactor The position's health factor (WAD, >= 1e18).
    error HealthyPosition(uint256 healthFactor);
    /// @notice A partial liquidation would lower the position's health factor (exhausting the collateral while debt
    ///         remains counts as lowering it to zero); close the position instead.
    /// @param healthBefore Health factor before the liquidation (WAD).
    /// @param healthAfter Health factor the liquidation would leave (WAD).
    error HealthDecreased(uint256 healthBefore, uint256 healthAfter);
    /// @notice A partial seizure would repay more shares than the borrower owes; close the position instead.
    /// @param repaidShares Shares the liquidation would burn.
    /// @param borrowShares Shares the borrower owes.
    error RepayExceedsDebt(uint256 repaidShares, uint256 borrowShares);
    /// @notice A partial repayment would seize more collateral than the borrower posted; close the position instead.
    /// @param seizedAssets Collateral the liquidation would seize.
    /// @param collateral Collateral the borrower posted.
    error SeizeExceedsCollateral(uint256 seizedAssets, uint256 collateral);
    /// @notice The fee exceeds `MAX_FEE`.
    /// @param fee The rejected fee.
    error MaxFeeExceeded(uint256 fee);
    /// @notice The fee is already set to this value.
    /// @param fee The current fee.
    error FeeAlreadySet(uint256 fee);
    /// @notice The fee recipient is already set to this value.
    /// @param feeRecipient The current recipient.
    error FeeRecipientAlreadySet(address feeRecipient);
    /// @notice The authorization signature expired.
    /// @param deadline The signed deadline.
    /// @param timestamp The current block timestamp.
    error SignatureExpired(uint256 deadline, uint256 timestamp);
    /// @notice The authorization nonce does not match.
    /// @param expected The authorizer's current nonce.
    /// @param provided The nonce in the message.
    error InvalidNonce(uint256 expected, uint256 provided);
    /// @notice The signature does not belong to the authorizer (EOA or ERC-1271 wallet).
    /// @param authorizer The expected signer.
    error InvalidSignature(address authorizer);

    // ------------------------------------------------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Allowlists an interest rate model for new markets.
    /// @param irm The model.
    function enableIrm(address irm) external;

    /// @notice Allowlists an LLTV and binds its immutable reverse-Dutch liquidation schedule.
    /// @param lltv Liquidation loan-to-value (WAD, strictly between 0 and 1e18).
    /// @param maxBonus Bonus cap (WAD); must satisfy `lltv * (1 + maxBonus) < 1`.
    /// @param bonusSlope Bonus per unit of health deficit (WAD).
    function enableLltv(uint256 lltv, uint256 maxBonus, uint256 bonusSlope) external;

    /// @notice Sets the share of interest routed to the fee recipient on one market (accrues first).
    /// @param marketParams The market.
    /// @param newFee The new fee (WAD, at most `MAX_FEE`).
    function setFee(MarketParams calldata marketParams, uint256 newFee) external;

    /// @notice Sets the account credited with fee shares.
    /// @param newFeeRecipient The new recipient.
    function setFeeRecipient(address newFeeRecipient) external;

    // ------------------------------------------------------------------------------------------------------------
    // Markets
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Permissionlessly creates a market from allowlisted components.
    /// @param marketParams The market definition.
    /// @return id The new market id.
    function createMarket(MarketParams calldata marketParams) external returns (Id id);

    /// @notice Supplies loan tokens; pass exactly one of `assets` or `shares`.
    /// @param marketParams The market.
    /// @param assets Loan tokens to supply (rounded against the supplier when converting to shares).
    /// @param shares Supply shares to mint (the assets owed are rounded up).
    /// @param onBehalf The account credited with the shares.
    /// @param data Callback payload; empty skips `onSupply`.
    /// @return assetsSupplied Loan tokens pulled.
    /// @return sharesSupplied Supply shares minted.
    function supply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @notice Withdraws loan tokens; pass exactly one of `assets` or `shares`.
    /// @param marketParams The market.
    /// @param assets Loan tokens to withdraw (shares burned are rounded up).
    /// @param shares Supply shares to burn (assets paid out are rounded down).
    /// @param onBehalf The position owner; `msg.sender` must be it or an authorized manager.
    /// @param receiver The recipient of the tokens.
    /// @return assetsWithdrawn Loan tokens sent.
    /// @return sharesWithdrawn Supply shares burned.
    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    /// @notice Borrows loan tokens against collateral; pass exactly one of `assets` or `shares`.
    /// @param marketParams The market.
    /// @param assets Loan tokens to borrow (debt shares minted are rounded up).
    /// @param shares Debt shares to mint (assets received are rounded down).
    /// @param onBehalf The position owner; `msg.sender` must be it or an authorized manager.
    /// @param receiver The recipient of the tokens.
    /// @return assetsBorrowed Loan tokens sent.
    /// @return sharesBorrowed Debt shares minted.
    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /// @notice Repays debt; pass exactly one of `assets` or `shares`.
    /// @param marketParams The market.
    /// @param assets Loan tokens to repay (debt shares burned are rounded down).
    /// @param shares Debt shares to burn (assets owed are rounded up).
    /// @param onBehalf The account whose debt decreases.
    /// @param data Callback payload; empty skips `onRepay`.
    /// @return assetsRepaid Loan tokens pulled.
    /// @return sharesRepaid Debt shares burned.
    function repay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Posts collateral.
    /// @param marketParams The market.
    /// @param assets Collateral tokens to post.
    /// @param onBehalf The account credited.
    /// @param data Callback payload; empty skips `onSupplyCollateral`.
    function supplyCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external;

    /// @notice Withdraws collateral; the position must stay healthy.
    /// @param marketParams The market.
    /// @param assets Collateral tokens to withdraw.
    /// @param onBehalf The position owner; `msg.sender` must be it or an authorized manager.
    /// @param receiver The recipient of the tokens.
    function withdrawCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    /// @notice Liquidates an unhealthy position; pass exactly one of `seizedAssets` or `repaidShares`.
    /// @dev A request that covers the whole position (`seizedAssets >= collateral` or `repaidShares >= borrowShares`,
    ///      for example `type(uint256).max`) closes it, so a dust deposit or repayment sent in front of it cannot make
    ///      it revert. A close repays the whole debt at the scheduled bonus when the collateral covers debt plus
    ///      bonus (the borrower keeps the rest); repays the whole debt for all the collateral when the collateral
    ///      covers the debt but not the bonus (the bonus is capped at the borrower's equity, so suppliers lose
    ///      nothing); and otherwise seizes all collateral at the scheduled bonus and writes the residual debt off
    ///      against this market's suppliers. Any smaller request is a partial liquidation: it must not lower the
    ///      health factor or exhaust the collateral.
    /// @param marketParams The market.
    /// @param borrower The position to liquidate.
    /// @param seizedAssets Collateral to seize (repaid shares derived, rounded up); at least the posted collateral
    ///        closes the position.
    /// @param repaidShares Debt shares to repay (seized collateral derived, rounded down); at least the owed shares
    ///        close the position.
    /// @param data Callback payload; empty skips `onLiquidate`.
    /// @return seized Collateral sent to the liquidator.
    /// @return repaidAssets Loan tokens pulled from the liquidator.
    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256 seized, uint256 repaidAssets);

    /// @notice Lends `assets` of any token the engine holds, fee-free, for the duration of the callback.
    /// @param token The token to borrow.
    /// @param assets The amount to borrow.
    /// @param data Payload forwarded to `onFlashLoan`.
    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    /// @notice Accrues interest on a market.
    /// @param marketParams The market.
    function accrueInterest(MarketParams calldata marketParams) external;

    // ------------------------------------------------------------------------------------------------------------
    // Authorization
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Grants or revokes a position manager.
    /// @param authorized The manager.
    /// @param newIsAuthorized The new status.
    function setAuthorization(address authorized, bool newIsAuthorized) external;

    /// @notice Grants or revokes a position manager with an EIP-712 signature (EOA or ERC-1271).
    /// @param authorization The signed message.
    /// @param signature The authorizer's signature over the EIP-712 digest.
    function setAuthorizationWithSig(Authorization calldata authorization, bytes calldata signature) external;

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Market accounting at the last accrual.
    /// @param id The market id.
    /// @return The market struct.
    function market(Id id) external view returns (Market memory);

    /// @notice A user's position.
    /// @param id The market id.
    /// @param user The account.
    /// @return The position struct.
    function position(Id id, address user) external view returns (Position memory);

    /// @notice The parameters hashed into `id`.
    /// @param id The market id.
    /// @return The market parameters (zeroed if the market does not exist).
    function idToMarketParams(Id id) external view returns (MarketParams memory);

    /// @notice Liquidation schedule bound to an LLTV.
    /// @param lltv The LLTV.
    /// @return The config (with `enabled == false` if the LLTV is not allowlisted).
    function liquidationConfig(uint256 lltv) external view returns (LiquidationConfig memory);

    /// @notice Whether an interest rate model is allowlisted.
    /// @param irm The model.
    /// @return True if allowlisted.
    function isIrmEnabled(address irm) external view returns (bool);

    /// @notice Whether `authorized` may manage `authorizer`'s positions.
    /// @param authorizer The position owner.
    /// @param authorized The manager.
    /// @return True if authorized.
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    /// @notice Next EIP-712 authorization nonce of `authorizer`.
    /// @param authorizer The account.
    /// @return The nonce.
    function nonce(address authorizer) external view returns (uint256);

    /// @notice Recipient of fee shares.
    /// @return The fee recipient.
    function feeRecipient() external view returns (address);

    /// @notice Whether a market is locked by an in-flight operation (only observable from a callback).
    /// @param id The market id.
    /// @return True while an operation on `id` is executing.
    function isMarketLocked(Id id) external view returns (bool);

    /// @notice Market totals as they would be after accruing interest now.
    /// @param marketParams The market.
    /// @return totalSupplyAssets Expected total supply.
    /// @return totalSupplyShares Expected total supply shares (including fee shares).
    /// @return totalBorrowAssets Expected total borrow.
    /// @return totalBorrowShares Total borrow shares (unchanged by accrual).
    function expectedMarketBalances(MarketParams calldata marketParams)
        external
        view
        returns (
            uint256 totalSupplyAssets,
            uint256 totalSupplyShares,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares
        );

    /// @notice Health factor of a position with interest accrued to now and the current oracle price.
    /// @param marketParams The market.
    /// @param borrower The account.
    /// @return The health factor (WAD); `type(uint256).max` when the position has no debt.
    function healthFactor(MarketParams calldata marketParams, address borrower) external view returns (uint256);

    /// @notice EIP-712 domain separator used by `setAuthorizationWithSig`.
    /// @return The domain separator for the current chain.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
