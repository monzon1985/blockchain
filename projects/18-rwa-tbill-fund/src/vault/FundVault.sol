// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin-contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {IERC7540Deposit, IERC7540Operator, IERC7540Redeem} from "../interfaces/IERC7540.sol";
import {IERC7575} from "../interfaces/IERC7575.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";

/// @title FundVault
/// @notice ERC-7540 asynchronous subscription / redemption vault with an ERC-7575 external share, settled per
///         epoch at an oracle-posted NAV (forward pricing). Technical demonstration, not a real fund.
/// @dev Lifecycle of an epoch `e`:
///        1. Open: `requestDeposit` locks assets, `requestRedeem` burns shares (through compliance).
///        2. `closeEpoch`: the cutoff is stamped; new requests go to `e + 1`.
///        3. The NAV oracle posts a NAV observed strictly after the cutoff (no stale-price arbitrage), within
///           +/- 2 % of the previous epoch's NAV and within +/- 2 % of the NAV that anchors the current 24 h
///           window (so a fast succession of epochs cannot walk the price further than 2 % per window).
///        4. `settleEpoch`: the NAV must be at most 24 h old. Deposits convert at `floor(assets / nav)`,
///           redemptions at `floor(shares * nav)`, and the vault must hold enough liquidity for every
///           reserved redemption plus the still-pending deposits.
///      Each controller's claim is computed from its own request and the epoch NAV only, so claim order cannot
///      move value between investors, and all rounding favours the remaining holders. Per-controller requests
///      use two slots indexed by epoch parity: at most one closed-but-unsettled epoch plus the open one exist,
///      and settled slots are folded into the claimable balance lazily on the controller's next interaction.
///      Rounding dust of an epoch is released back to the fund once every request of the epoch was folded.
///      Subscriptions are pre-checked against the compliance modules at request time; a settled subscription
///      that compliance still refuses to mint (e.g. its country filled up meanwhile) can be turned into a
///      redemption request by its controller (`convertUnclaimableDeposit`), so investor cash is never stranded.
///      Claims follow lost-wallet recoveries: only the latest wallet of the succession chain (or its operators)
///      may claim for a recovered controller, and nobody may claim while a recovery of that wallet is pending.
contract FundVault is
    AccessManaged,
    ReentrancyGuardTransient,
    IERC7540Operator,
    IERC7540Deposit,
    IERC7540Redeem,
    IERC7575,
    IERC165
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev Pending request slot: amount (assets for deposits, shares for redemptions) and its epoch.
    struct Slot {
        uint128 amount;
        uint64 epoch;
    }

    /// @dev Per-controller request state.
    struct Account {
        Slot[2] deposit;
        Slot[2] redeem;
        uint128 claimableDepositAssets;
        uint128 claimableDepositShares;
        uint128 claimableRedeemShares;
        uint128 claimableRedeemAssets;
    }

    /// @notice Per-epoch totals.
    /// @param cutoff Close time (0 while open).
    /// @param settledAt Settlement time (0 until settled).
    /// @param nav NAV per share used for settlement (WAD).
    /// @param depositAssets Assets requested for deposit in the epoch.
    /// @param redeemShares Shares requested for redemption in the epoch.
    /// @param depositShares Shares issued for the epoch's deposits, `floor(depositAssets / nav)`.
    /// @param redeemAssets Assets reserved for the epoch's redemptions, `floor(redeemShares * nav)`.
    /// @param depositAssetsUnfolded Deposit assets not yet folded into controllers' claimable balances.
    /// @param depositSharesUnfolded Issued shares not yet folded.
    /// @param redeemSharesUnfolded Redeemed shares not yet folded.
    /// @param redeemAssetsUnfolded Reserved assets not yet folded.
    struct Epoch {
        uint64 cutoff;
        uint64 settledAt;
        uint128 nav;
        uint128 depositAssets;
        uint128 redeemShares;
        uint128 depositShares;
        uint128 redeemAssets;
        uint128 depositAssetsUnfolded;
        uint128 depositSharesUnfolded;
        uint128 redeemSharesUnfolded;
        uint128 redeemAssetsUnfolded;
    }

    /// @notice A NAV observation.
    /// @param nav Assets per share, WAD-scaled (1e18 = 1 asset unit per share unit).
    /// @param asOf Valuation time.
    struct NavPoint {
        uint128 nav;
        uint64 asOf;
    }

    /// @notice Fixed-point scale of NAV values.
    uint256 public constant WAD = 1e18;
    /// @notice Maximum age of the NAV used to settle an epoch.
    uint256 public constant MAX_NAV_STALENESS = 24 hours;
    /// @notice Maximum NAV move between consecutive epochs, and within one `NAV_WINDOW`, in basis points.
    uint256 public constant MAX_NAV_CHANGE_BPS = 200;
    /// @notice Length of the window over which cumulative NAV moves are capped.
    uint256 public constant NAV_WINDOW = 24 hours;
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @dev Settlement asset (USDC-like, no transfer fees).
    IERC20 private immutable _asset;
    /// @dev Share token issued by this vault.
    IFundShareToken private immutable _share;

    /// @notice Epoch currently accepting requests (starts at 1).
    uint64 public currentEpoch = 1;
    /// @notice Closed epoch awaiting settlement (0 if none).
    uint64 public epochAwaitingSettlement;

    /// @notice Latest NAV posted by the oracle.
    NavPoint public latestNav;
    /// @notice NAV the next settlement is compared against (previous epoch's NAV, or a governance reset).
    NavPoint public referenceNav;
    /// @notice Anchor of the current NAV window: `nav` is the reference NAV when the window opened and `asOf`
    ///         the time it opened. Once `NAV_WINDOW` has elapsed the next settlement opens a new window anchored
    ///         at the then-current reference NAV.
    NavPoint public navWindowAnchor;

    /// @notice Assets in unsettled deposit requests (held by the vault).
    uint256 public totalPendingDepositAssets;
    /// @notice Shares burned by unsettled redemption requests (still economically outstanding).
    uint256 public totalPendingRedeemShares;
    /// @notice Settled but not yet minted deposit shares.
    uint256 public totalClaimableDepositShares;
    /// @notice Settled but not yet paid redemption assets (reserved liquidity).
    uint256 public totalReservedRedeemAssets;

    /// @notice Off-chain custody account holding T-bill positions.
    address public custodian;
    /// @notice Principal currently deployed with the custodian.
    uint256 public deployedAssets;

    /// @inheritdoc IERC7540Operator
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    /// @dev Epoch data.
    mapping(uint256 epochId => Epoch) private _epochs;
    /// @dev Controller data.
    mapping(address controller => Account) private _accounts;

    /// @notice Emitted when an epoch is closed.
    /// @param epochId Closed epoch.
    /// @param cutoff Close time.
    /// @param depositAssets Assets requested in the epoch.
    /// @param redeemShares Shares requested in the epoch.
    event EpochClosed(uint256 indexed epochId, uint64 cutoff, uint256 depositAssets, uint256 redeemShares);
    /// @notice Emitted when an epoch is settled.
    /// @param epochId Settled epoch.
    /// @param nav NAV used.
    /// @param navAsOf Valuation time of the NAV.
    /// @param depositAssets Assets converted.
    /// @param depositShares Shares issued.
    /// @param redeemShares Shares redeemed.
    /// @param redeemAssets Assets reserved.
    event EpochSettled(
        uint256 indexed epochId,
        uint256 nav,
        uint64 navAsOf,
        uint256 depositAssets,
        uint256 depositShares,
        uint256 redeemShares,
        uint256 redeemAssets
    );
    /// @notice Emitted when the oracle posts a NAV.
    /// @param nav NAV (WAD).
    /// @param asOf Valuation time.
    /// @param oracle Poster.
    event NavPosted(uint256 nav, uint64 asOf, address indexed oracle);
    /// @notice Emitted when governance re-anchors the NAV reference (moves beyond the circuit breaker); the NAV
    ///         window restarts at the new NAV.
    /// @param nav New reference NAV.
    /// @param asOf Valuation time.
    event NavReferenceReset(uint256 nav, uint64 asOf);
    /// @notice Emitted when a settlement opens a new 24 h NAV window.
    /// @param anchorNav NAV every price in the new window must stay within `MAX_NAV_CHANGE_BPS` of.
    /// @param openedAt Start of the window.
    event NavWindowOpened(uint256 anchorNav, uint64 openedAt);
    /// @notice Emitted when rounding dust of an epoch returns to the fund.
    /// @param epochId Epoch.
    /// @param dustShares Issued-but-unallocated shares cancelled.
    /// @param dustAssets Reserved-but-unallocated assets released.
    event EpochDustReleased(uint256 indexed epochId, uint256 dustShares, uint256 dustAssets);
    /// @notice Emitted when the custodian changes.
    /// @param custodian New custodian.
    event CustodianSet(address indexed custodian);
    /// @notice Emitted when idle assets are sent to the custodian.
    /// @param custodian Custodian.
    /// @param assets Amount.
    /// @param deployedAssets Principal deployed afterwards.
    event AssetsDeployed(address indexed custodian, uint256 assets, uint256 deployedAssets);
    /// @notice Emitted when assets are pulled back from the custodian.
    /// @param custodian Custodian.
    /// @param assets Amount.
    /// @param principal Part counted as returned principal.
    /// @param yield Part above deployed principal.
    event AssetsRecalled(address indexed custodian, uint256 assets, uint256 principal, uint256 yield);
    /// @notice Emitted when governance writes off deployed principal the custodian will not return.
    /// @param custodian Custodian the principal was deployed with.
    /// @param assets Principal written off.
    /// @param deployedAssets Principal still deployed afterwards.
    event CustodyWrittenDown(address indexed custodian, uint256 assets, uint256 deployedAssets);
    /// @notice Emitted when a settled subscription that compliance refuses to mint becomes a redemption request.
    /// @param controller Controller of the subscription.
    /// @param sender Caller (controller, operator or successor wallet).
    /// @param epochId Epoch the redemption request joins.
    /// @param assets Subscription assets the shares were issued for.
    /// @param shares Shares moved from claimable deposits to the redemption request.
    event UnclaimableDepositConverted(
        address indexed controller, address indexed sender, uint256 indexed epochId, uint256 assets, uint256 shares
    );

    /// @notice Caller may not act for `account`.
    error NotAuthorized(address caller, address account);
    /// @notice Zero amount.
    error ZeroAmount();
    /// @notice Controller is not eligible to hold shares.
    error ControllerNotEligible(address controller);
    /// @notice A compliance module (holder caps, investor cap, ...) would refuse to mint the controller's
    ///         subscription, estimated at the lowest NAV the circuit breaker allows.
    error SubscriptionNotAdmissible(address controller, uint256 estimatedShares);
    /// @notice The controller's settled subscription can still be minted; only unclaimable ones convert.
    error DepositStillClaimable(address controller, uint256 shares);
    /// @notice Zero controller.
    error InvalidController();
    /// @notice A recovery of the controller's current wallet is pending; claims wait until it ends.
    error ControllerRecoveryPending(address controller, address wallet);
    /// @notice Share and settlement asset decimals differ (NAV is a plain WAD ratio of base units).
    error DecimalsMismatch(uint8 assetDecimals, uint8 shareDecimals);
    /// @notice Redemption proceeds may only be paid to eligible wallets.
    error ReceiverNotEligible(address receiver);
    /// @notice Amount exceeds the claimable balance.
    error ExceedsClaimable(uint256 requested, uint256 claimable);
    /// @notice Preview functions are undefined for asynchronous flows.
    error AsyncFlow();
    /// @notice An operator cannot be the controller itself.
    error SelfOperator();
    /// @notice A closed epoch is still awaiting settlement.
    error SettlementPending(uint256 epochId);
    /// @notice No closed epoch to settle.
    error NoEpochAwaitingSettlement();
    /// @notice NAV observation is not strictly after the epoch cutoff (forward pricing).
    error NavPredatesCutoff(uint64 asOf, uint64 cutoff);
    /// @notice NAV is older than `MAX_NAV_STALENESS`.
    error NavStale(uint64 asOf, uint256 nowTs);
    /// @notice NAV moves more than `MAX_NAV_CHANGE_BPS` from the reference.
    error NavChangeTooLarge(uint256 nav, uint256 referenceNav);
    /// @notice NAV moves more than `MAX_NAV_CHANGE_BPS` from the anchor of the current `NAV_WINDOW`.
    error NavWindowChangeTooLarge(uint256 nav, uint256 anchorNav);
    /// @notice NAV timestamp in the future or not newer than the latest.
    error InvalidNavTimestamp(uint64 asOf, uint64 latestAsOf);
    /// @notice Zero NAV.
    error InvalidNav();
    /// @notice Vault cannot cover reserved redemptions plus pending deposits.
    error InsufficientLiquidity(uint256 required, uint256 available);
    /// @notice Amount exceeds idle (unreserved) assets.
    error ExceedsIdleAssets(uint256 requested, uint256 idle);
    /// @notice No custodian configured.
    error NoCustodian();
    /// @notice Custodian cannot change while principal is deployed.
    error CustodianHasAssets(uint256 deployedAssets);
    /// @notice Zero write-down, or more than the deployed principal.
    error InvalidWriteDown(uint256 assets, uint256 deployedAssets);

    /// @param asset_ Settlement asset.
    /// @param share_ Share token (same decimals as `asset_`).
    /// @param initialAuthority AccessManager.
    /// @param initialNav Initial NAV per share (WAD).
    constructor(IERC20 asset_, IFundShareToken share_, address initialAuthority, uint128 initialNav)
        AccessManaged(initialAuthority)
    {
        require(initialNav != 0, InvalidNav());
        uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
        uint8 shareDecimals = IERC20Metadata(address(share_)).decimals();
        require(assetDecimals == shareDecimals, DecimalsMismatch(assetDecimals, shareDecimals));
        _asset = asset_;
        _share = share_;
        NavPoint memory point = NavPoint({nav: initialNav, asOf: block.timestamp.toUint64()});
        latestNav = point;
        referenceNav = point;
        navWindowAnchor = point;
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-7540 operators
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) external returns (bool) {
        require(operator != msg.sender, SelfOperator());
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Deposit
    /// @dev Besides eligibility, the controller's whole unminted position (claimable shares plus pending and new
    ///      assets converted at the lowest NAV the circuit breaker allows) must pass every compliance module as a
    ///      mint, so a subscription that a holder cap or the investor cap would refuse is rejected before any
    ///      cash moves. Caps can still fill up before the claim: see `convertUnclaimableDeposit`.
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        require(owner == msg.sender || isOperator[owner][msg.sender], NotAuthorized(msg.sender, owner));
        require(assets != 0, ZeroAmount());
        uint256 estimate = _maxSharesIssuable(controller, assets);
        if (!_share.canMint(controller, estimate)) {
            // `canMint` covers eligibility too; tell the two failure modes apart only on the error path.
            require(_share.canReceive(controller), ControllerNotEligible(controller));
            revert SubscriptionNotAdmissible(controller, estimate);
        }

        uint64 epochId = currentEpoch;
        Account storage account = _accounts[controller];
        _fold(account);
        Slot storage slot = account.deposit[epochId & 1];
        slot.amount += assets.toUint128();
        slot.epoch = epochId;
        _epochs[epochId].depositAssets += assets.toUint128();
        totalPendingDepositAssets += assets;

        // `owner` is msg.sender or approved msg.sender as its ERC-7540 operator (checked above).
        // slither-disable-start arbitrary-send-erc20
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        _asset.safeTransferFrom(owner, address(this), assets);
        // slither-disable-end arbitrary-send-erc20
        emit DepositRequest(controller, owner, 0, msg.sender, assets);
        return 0;
    }

    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        require(shares != 0, ZeroAmount());
        // A zero controller could never claim, and its unfolded request would pin the epoch's dust forever.
        require(controller != address(0), InvalidController());
        address spender = owner == msg.sender || isOperator[owner][msg.sender] ? address(0) : msg.sender;

        _addRedeemRequest(_accounts[controller], shares);

        // Burn through the compliance path: sender eligibility, freezes and the lockup all apply.
        _share.burnForRedemption(owner, spender, shares);
        emit RedeemRequest(controller, owner, 0, msg.sender, shares);
        return 0;
    }

    /// @notice Turns the controller's settled-but-unclaimed subscription into a redemption request of the open
    ///         epoch, when compliance would refuse to mint it to the controller's current wallet (for example its
    ///         country reached its holder cap, or the investor cap would be exceeded, after the request was
    ///         accepted). The shares never get minted; they are redeemed at the next settlement NAV like any other
    ///         redemption (forward pricing), so the investor's cash is not stranded and no other holder is diluted.
    /// @param controller Controller of the subscription (caller: controller, its operator, or its successor).
    /// @return shares Shares moved from claimable deposits to the redemption request.
    function convertUnclaimableDeposit(address controller) external nonReentrant returns (uint256 shares) {
        _checkController(controller);
        Account storage account = _accounts[controller];
        _fold(account);
        shares = account.claimableDepositShares;
        uint256 assets = account.claimableDepositAssets;
        require(shares != 0, ZeroAmount());
        // Judged for the wallet that would receive the mint (the last successor if the controller was recovered).
        require(!_share.canMint(_share.currentWalletOf(controller), shares), DepositStillClaimable(controller, shares));

        account.claimableDepositAssets = 0;
        account.claimableDepositShares = 0;
        totalClaimableDepositShares -= shares;
        uint64 epochId = _addRedeemRequest(account, shares);
        emit UnclaimableDepositConverted(controller, msg.sender, epochId, assets, shares);
    }

    // ---------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Deposit
    function deposit(uint256 assets, address receiver, address controller)
        public
        nonReentrant
        returns (uint256 shares)
    {
        _checkController(controller);
        Account storage account = _accounts[controller];
        _fold(account);
        uint256 claimableAssets = account.claimableDepositAssets;
        uint256 claimableShares = account.claimableDepositShares;
        require(assets != 0, ZeroAmount());
        require(assets <= claimableAssets, ExceedsClaimable(assets, claimableAssets));

        shares = assets == claimableAssets
            ? claimableShares
            : Math.mulDiv(assets, claimableShares, claimableAssets, Math.Rounding.Floor);
        _consumeDeposit(account, assets, shares);
        _share.mint(receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        return deposit(assets, receiver, msg.sender);
    }

    /// @inheritdoc IERC7540Deposit
    function mint(uint256 shares, address receiver, address controller) public nonReentrant returns (uint256 assets) {
        _checkController(controller);
        Account storage account = _accounts[controller];
        _fold(account);
        uint256 claimableAssets = account.claimableDepositAssets;
        uint256 claimableShares = account.claimableDepositShares;
        require(shares != 0, ZeroAmount());
        require(shares <= claimableShares, ExceedsClaimable(shares, claimableShares));

        assets = shares == claimableShares
            ? claimableAssets
            : Math.mulDiv(shares, claimableAssets, claimableShares, Math.Rounding.Ceil);
        _consumeDeposit(account, assets, shares);
        _share.mint(receiver, shares);
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        return mint(shares, receiver, msg.sender);
    }

    /// @inheritdoc IERC7575
    function redeem(uint256 shares, address receiver, address controller)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _checkController(controller);
        Account storage account = _accounts[controller];
        _fold(account);
        uint256 claimableShares = account.claimableRedeemShares;
        uint256 claimableAssets = account.claimableRedeemAssets;
        require(shares != 0, ZeroAmount());
        require(shares <= claimableShares, ExceedsClaimable(shares, claimableShares));

        assets = shares == claimableShares
            ? claimableAssets
            : Math.mulDiv(shares, claimableAssets, claimableShares, Math.Rounding.Floor);
        _payRedemption(account, controller, receiver, assets, shares);
    }

    /// @inheritdoc IERC7575
    function withdraw(uint256 assets, address receiver, address controller)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _checkController(controller);
        Account storage account = _accounts[controller];
        _fold(account);
        uint256 claimableShares = account.claimableRedeemShares;
        uint256 claimableAssets = account.claimableRedeemAssets;
        require(assets != 0, ZeroAmount());
        require(assets <= claimableAssets, ExceedsClaimable(assets, claimableAssets));

        shares = assets == claimableAssets
            ? claimableShares
            : Math.mulDiv(assets, claimableShares, claimableAssets, Math.Rounding.Ceil);
        _payRedemption(account, controller, receiver, assets, shares);
    }

    // ---------------------------------------------------------------------------------------------
    // Fund administration
    // ---------------------------------------------------------------------------------------------

    /// @notice Closes the open epoch: stamps the cutoff and opens the next one.
    function closeEpoch() external restricted {
        uint64 awaiting = epochAwaitingSettlement;
        require(awaiting == 0, SettlementPending(awaiting));
        uint64 epochId = currentEpoch;
        Epoch storage epoch = _epochs[epochId];
        epoch.cutoff = block.timestamp.toUint64();
        epochAwaitingSettlement = epochId;
        currentEpoch = epochId + 1;
        emit EpochClosed(epochId, epoch.cutoff, epoch.depositAssets, epoch.redeemShares);
    }

    /// @notice Settles the closed epoch at the latest posted NAV.
    function settleEpoch() external restricted {
        uint64 epochId = epochAwaitingSettlement;
        require(epochId != 0, NoEpochAwaitingSettlement());
        Epoch storage epoch = _epochs[epochId];
        NavPoint memory nav = latestNav;
        require(nav.asOf > epoch.cutoff, NavPredatesCutoff(nav.asOf, epoch.cutoff));
        require(block.timestamp - nav.asOf <= MAX_NAV_STALENESS, NavStale(nav.asOf, block.timestamp));
        _checkNavBand(nav.nav);

        uint256 depositAssets = epoch.depositAssets;
        uint256 redeemShares = epoch.redeemShares;
        uint256 depositShares = Math.mulDiv(depositAssets, WAD, nav.nav, Math.Rounding.Floor);
        uint256 redeemAssets = Math.mulDiv(redeemShares, nav.nav, WAD, Math.Rounding.Floor);

        epoch.settledAt = block.timestamp.toUint64();
        epoch.nav = nav.nav;
        epoch.depositShares = depositShares.toUint128();
        epoch.redeemAssets = redeemAssets.toUint128();
        epoch.depositAssetsUnfolded = depositAssets.toUint128();
        epoch.depositSharesUnfolded = depositShares.toUint128();
        epoch.redeemSharesUnfolded = redeemShares.toUint128();
        epoch.redeemAssetsUnfolded = redeemAssets.toUint128();

        totalPendingDepositAssets -= depositAssets;
        totalPendingRedeemShares -= redeemShares;
        totalClaimableDepositShares += depositShares;
        totalReservedRedeemAssets += redeemAssets;

        uint256 required = totalPendingDepositAssets + totalReservedRedeemAssets;
        uint256 available = _asset.balanceOf(address(this));
        require(available >= required, InsufficientLiquidity(required, available));

        // A window that has run its course is replaced by one anchored at the reference this NAV was checked
        // against (`_windowAnchorNav` already used it as the anchor).
        if (block.timestamp >= navWindowAnchor.asOf + NAV_WINDOW) {
            NavPoint memory anchor = NavPoint({nav: referenceNav.nav, asOf: block.timestamp.toUint64()});
            navWindowAnchor = anchor;
            emit NavWindowOpened(anchor.nav, anchor.asOf);
        }
        referenceNav = nav;
        epochAwaitingSettlement = 0;
        emit EpochSettled(epochId, nav.nav, nav.asOf, depositAssets, depositShares, redeemShares, redeemAssets);
    }

    /// @notice Posts a NAV observation.
    /// @param nav NAV per share (WAD), within +/- `MAX_NAV_CHANGE_BPS` of the reference NAV and of the current
    ///        window's anchor (see `navBounds`).
    /// @param asOf Valuation time: not in the future and strictly newer than the latest observation.
    function postNav(uint128 nav, uint64 asOf) external restricted {
        _checkNavTimestamp(asOf);
        _checkNavBand(nav);
        latestNav = NavPoint({nav: nav, asOf: asOf});
        emit NavPosted(nav, asOf, msg.sender);
    }

    /// @notice Governance escape hatch for NAV moves beyond the circuit breaker (e.g. a credit event):
    ///         re-anchors the reference, the latest NAV and the NAV window.
    /// @param nav New NAV (WAD).
    /// @param asOf Valuation time.
    function resetNavReference(uint128 nav, uint64 asOf) external restricted {
        require(nav != 0, InvalidNav());
        _checkNavTimestamp(asOf);
        NavPoint memory point = NavPoint({nav: nav, asOf: asOf});
        latestNav = point;
        referenceNav = point;
        navWindowAnchor = NavPoint({nav: nav, asOf: block.timestamp.toUint64()});
        emit NavReferenceReset(nav, asOf);
    }

    /// @notice Sets the custodian (zero disables custody moves). Only while no principal is deployed.
    /// @param newCustodian Custodian address.
    // slither-disable-start missing-zero-check
    // forge-lint: disable-next-line(missing-zero-check)
    function setCustodian(address newCustodian) external restricted {
        require(deployedAssets == 0, CustodianHasAssets(deployedAssets));
        custodian = newCustodian;
        emit CustodianSet(newCustodian);
    }

    // slither-disable-end missing-zero-check

    /// @notice Sends idle assets (not pending, not reserved) to the custodian to buy T-bills.
    /// @param assets Amount.
    function deployToCustodian(uint256 assets) external nonReentrant restricted {
        address to = custodian;
        require(to != address(0), NoCustodian());
        uint256 idle = idleAssets();
        require(assets <= idle, ExceedsIdleAssets(assets, idle));
        deployedAssets += assets;
        _asset.safeTransfer(to, assets);
        emit AssetsDeployed(to, assets, deployedAssets);
    }

    /// @notice Pulls assets back from the custodian (which must have approved the vault). Anything above
    ///         the deployed principal is reported as realised yield.
    /// @param assets Amount.
    function recallFromCustodian(uint256 assets) external nonReentrant restricted {
        address from = custodian;
        require(from != address(0), NoCustodian());
        uint256 principal = Math.min(assets, deployedAssets);
        deployedAssets -= principal;
        // `from` is the governance-appointed custodian, which pre-approves the vault; restricted to FUND_ADMIN.
        // slither-disable-start arbitrary-send-erc20
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        _asset.safeTransferFrom(from, address(this), assets);
        // slither-disable-end arbitrary-send-erc20
        emit AssetsRecalled(from, assets, principal, assets - principal);
    }

    /// @notice Writes off deployed principal that the custodian will not return (a custody loss, a fee, an
    ///         insolvent or compromised custodian). Bookkeeping only: the loss reaches the share price through
    ///         the NAV. It lets governance bring `deployedAssets` back to what is recoverable, which is what
    ///         `setCustodian` requires before the custodian can be replaced.
    /// @param assets Principal to write off (at most `deployedAssets`).
    function writeDownCustody(uint256 assets) external restricted {
        uint256 deployed = deployedAssets;
        require(assets != 0 && assets <= deployed, InvalidWriteDown(assets, deployed));
        uint256 remaining = deployed - assets;
        deployedAssets = remaining;
        emit CustodyWrittenDown(custodian, assets, remaining);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IERC7575
    function share() external view returns (address) {
        return address(_share);
    }

    /// @notice Shares that exist economically: minted supply, settled-but-unminted shares, and shares
    ///         burned by redemption requests that are not settled yet.
    /// @return Outstanding shares.
    function outstandingShares() public view returns (uint256) {
        return _share.totalSupply() + totalClaimableDepositShares + totalPendingRedeemShares;
    }

    /// @inheritdoc IERC7575
    function totalAssets() external view returns (uint256) {
        return convertToAssets(outstandingShares());
    }

    /// @notice Vault balance that is neither pending deposits nor reserved for redemptions.
    /// @return Idle assets.
    function idleAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this)) - totalPendingDepositAssets - totalReservedRedeemAssets;
    }

    /// @notice Range of NAVs `postNav` and `settleEpoch` accept right now: the intersection of
    ///         +/- `MAX_NAV_CHANGE_BPS` around the reference NAV and around the current window's anchor.
    /// @return minNav Lowest acceptable NAV (WAD).
    /// @return maxNav Highest acceptable NAV (WAD).
    function navBounds() public view returns (uint256 minNav, uint256 maxNav) {
        (minNav, maxNav) = _band(referenceNav.nav);
        (uint256 windowMin, uint256 windowMax) = _band(_windowAnchorNav());
        if (windowMin > minNav) minNav = windowMin;
        if (windowMax < maxNav) maxNav = windowMax;
    }

    /// @inheritdoc IERC7575
    function convertToShares(uint256 assets) external view returns (uint256) {
        return Math.mulDiv(assets, WAD, referenceNav.nav, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC7575
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, referenceNav.nav, WAD, Math.Rounding.Floor);
    }

    /// @notice Epoch data.
    /// @param epochId Epoch.
    /// @return The epoch record.
    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pending) {
        if (requestId != 0) return 0;
        (pending,) = _depositView(controller);
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 claimable) {
        if (requestId != 0) return 0;
        (, claimable) = _depositView(controller);
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pending) {
        if (requestId != 0) return 0;
        (pending,,) = _redeemView(controller);
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 claimable) {
        if (requestId != 0) return 0;
        (, claimable,) = _redeemView(controller);
    }

    /// @inheritdoc IERC7575
    function maxDeposit(address controller) external view returns (uint256) {
        (, uint256 claimable) = _depositView(controller);
        return claimable;
    }

    /// @inheritdoc IERC7575
    function maxMint(address controller) public view returns (uint256 shares) {
        Account storage account = _accounts[controller];
        shares = account.claimableDepositShares;
        for (uint256 i; i < 2; ++i) {
            Slot memory slot = account.deposit[i];
            Epoch storage epoch = _epochs[slot.epoch];
            if (slot.amount != 0 && epoch.settledAt != 0) {
                shares += Math.mulDiv(slot.amount, WAD, epoch.nav, Math.Rounding.Floor);
            }
        }
    }

    /// @inheritdoc IERC7575
    function maxWithdraw(address controller) external view returns (uint256) {
        (,, uint256 assets) = _redeemView(controller);
        return assets;
    }

    /// @inheritdoc IERC7575
    function maxRedeem(address controller) external view returns (uint256) {
        (, uint256 shares,) = _redeemView(controller);
        return shares;
    }

    /// @inheritdoc IERC7575
    function previewDeposit(uint256) external pure returns (uint256) {
        revert AsyncFlow();
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256) external pure returns (uint256) {
        revert AsyncFlow();
    }

    /// @inheritdoc IERC7575
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert AsyncFlow();
    }

    /// @inheritdoc IERC7575
    function previewRedeem(uint256) external pure returns (uint256) {
        revert AsyncFlow();
    }

    /// @notice ERC-165: ERC-7575 vault, ERC-7540 operator / async deposit / async redeem, ERC-165.
    /// @param interfaceId Interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC7575).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Claims for `controller` may be made by the wallet that currently represents it (the controller
    ///      itself, or the last successor if it was recovered) or by that wallet's operators. A retired wallet
    ///      and the operators it approved lose every right on recovery, and nobody may claim while a recovery
    ///      of the current wallet is pending (the old key may be compromised; the successor is not confirmed).
    function _checkController(address controller) private view {
        address wallet = _share.currentWalletOf(controller);
        // Only whether a successor is scheduled matters; the ETA and case reference are informational.
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return)
        (address pendingSuccessor,,) = _share.pendingRecovery(wallet);
        // slither-disable-end unused-return
        require(pendingSuccessor == address(0), ControllerRecoveryPending(controller, wallet));
        require(msg.sender == wallet || isOperator[wallet][msg.sender], NotAuthorized(msg.sender, controller));
    }

    /// @dev Adds `shares` to the controller's redemption request of the open epoch and returns that epoch.
    function _addRedeemRequest(Account storage account, uint256 shares) private returns (uint64 epochId) {
        epochId = currentEpoch;
        _fold(account);
        Slot storage slot = account.redeem[epochId & 1];
        slot.amount += shares.toUint128();
        slot.epoch = epochId;
        _epochs[epochId].redeemShares += shares.toUint128();
        totalPendingRedeemShares += shares;
    }

    /// @dev Upper bound on the shares the controller could end up claiming if it adds `assets`: its claimable
    ///      shares plus every unsettled and new asset converted at the lowest NAV accepted right now.
    function _maxSharesIssuable(address controller, uint256 assets) private view returns (uint256) {
        (uint256 pendingAssets,) = _depositView(controller);
        (uint256 minNav,) = navBounds();
        return maxMint(controller) + Math.mulDiv(pendingAssets + assets, WAD, minNav, Math.Rounding.Ceil);
    }

    /// @dev Folds settled request slots of `account` into its claimable balances.
    function _fold(Account storage account) private {
        for (uint256 i; i < 2; ++i) {
            Slot storage slot = account.deposit[i];
            uint256 amount = slot.amount;
            if (amount != 0) {
                uint64 epochId = slot.epoch;
                Epoch storage epoch = _epochs[epochId];
                if (epoch.settledAt != 0) {
                    uint256 shares = Math.mulDiv(amount, WAD, epoch.nav, Math.Rounding.Floor);
                    account.claimableDepositAssets += amount.toUint128();
                    account.claimableDepositShares += shares.toUint128();
                    epoch.depositAssetsUnfolded -= amount.toUint128();
                    epoch.depositSharesUnfolded -= shares.toUint128();
                    delete account.deposit[i];
                    if (epoch.depositAssetsUnfolded == 0) _releaseDepositDust(epochId, epoch);
                }
            }
            slot = account.redeem[i];
            amount = slot.amount;
            if (amount != 0) {
                uint64 epochId = slot.epoch;
                Epoch storage epoch = _epochs[epochId];
                if (epoch.settledAt != 0) {
                    uint256 assets = Math.mulDiv(amount, epoch.nav, WAD, Math.Rounding.Floor);
                    account.claimableRedeemShares += amount.toUint128();
                    account.claimableRedeemAssets += assets.toUint128();
                    epoch.redeemSharesUnfolded -= amount.toUint128();
                    epoch.redeemAssetsUnfolded -= assets.toUint128();
                    delete account.redeem[i];
                    if (epoch.redeemSharesUnfolded == 0) _releaseRedeemDust(epochId, epoch);
                }
            }
        }
    }

    function _releaseDepositDust(uint256 epochId, Epoch storage epoch) private {
        uint256 dust = epoch.depositSharesUnfolded;
        if (dust == 0) return;
        epoch.depositSharesUnfolded = 0;
        totalClaimableDepositShares -= dust;
        emit EpochDustReleased(epochId, dust, 0);
    }

    function _releaseRedeemDust(uint256 epochId, Epoch storage epoch) private {
        uint256 dust = epoch.redeemAssetsUnfolded;
        if (dust == 0) return;
        epoch.redeemAssetsUnfolded = 0;
        totalReservedRedeemAssets -= dust;
        emit EpochDustReleased(epochId, 0, dust);
    }

    function _consumeDeposit(Account storage account, uint256 assets, uint256 shares) private {
        // Both values are bounded by the claimable balances they are subtracted from.
        account.claimableDepositAssets -= assets.toUint128();
        account.claimableDepositShares -= shares.toUint128();
        totalClaimableDepositShares -= shares;
    }

    function _payRedemption(
        Account storage account,
        address controller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) private {
        require(_share.canReceive(receiver), ReceiverNotEligible(receiver));
        account.claimableRedeemShares -= shares.toUint128();
        account.claimableRedeemAssets -= assets.toUint128();
        totalReservedRedeemAssets -= assets;
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _depositView(address controller) private view returns (uint256 pending, uint256 claimable) {
        Account storage account = _accounts[controller];
        claimable = account.claimableDepositAssets;
        for (uint256 i; i < 2; ++i) {
            Slot memory slot = account.deposit[i];
            if (_epochs[slot.epoch].settledAt != 0) claimable += slot.amount;
            else pending += slot.amount;
        }
    }

    function _redeemView(address controller)
        private
        view
        returns (uint256 pending, uint256 claimableShares, uint256 claimableAssets)
    {
        Account storage account = _accounts[controller];
        claimableShares = account.claimableRedeemShares;
        claimableAssets = account.claimableRedeemAssets;
        for (uint256 i; i < 2; ++i) {
            Slot memory slot = account.redeem[i];
            Epoch storage epoch = _epochs[slot.epoch];
            if (epoch.settledAt != 0) {
                claimableShares += slot.amount;
                claimableAssets += Math.mulDiv(slot.amount, epoch.nav, WAD, Math.Rounding.Floor);
            } else {
                pending += slot.amount;
            }
        }
    }

    function _checkNavTimestamp(uint64 asOf) private view {
        uint64 latestAsOf = latestNav.asOf;
        require(asOf <= block.timestamp && asOf > latestAsOf, InvalidNavTimestamp(asOf, latestAsOf));
    }

    function _checkNavBand(uint256 nav) private view {
        uint256 ref = referenceNav.nav;
        (uint256 minNav, uint256 maxNav) = _band(ref);
        require(nav >= minNav && nav <= maxNav, NavChangeTooLarge(nav, ref));
        uint256 anchor = _windowAnchorNav();
        (minNav, maxNav) = _band(anchor);
        require(nav >= minNav && nav <= maxNav, NavWindowChangeTooLarge(nav, anchor));
    }

    /// @dev Anchor the next NAV is checked against: the stored anchor while its window runs, else the
    ///      reference NAV (the settlement that next succeeds will open a new window anchored there).
    function _windowAnchorNav() private view returns (uint256) {
        NavPoint memory anchor = navWindowAnchor;
        return block.timestamp >= anchor.asOf + NAV_WINDOW ? referenceNav.nav : anchor.nav;
    }

    /// @dev `[nav - d, nav + d]` with `d = floor(nav * MAX_NAV_CHANGE_BPS / BPS)`, i.e. exactly the values
    ///      whose distance to `nav` is at most `MAX_NAV_CHANGE_BPS` basis points of `nav`.
    function _band(uint256 nav) private pure returns (uint256 minNav, uint256 maxNav) {
        uint256 d = nav * MAX_NAV_CHANGE_BPS / BPS;
        return (nav - d, nav + d);
    }
}
