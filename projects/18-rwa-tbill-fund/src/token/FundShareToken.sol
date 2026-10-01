// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin-contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {IComplianceEngine, TransferKind} from "../interfaces/ICompliance.sol";
import {IERC1643} from "../interfaces/IERC1643.sol";
import {IERC7575Share} from "../interfaces/IERC7575.sol";
import {IERC7943Fungible} from "../interfaces/IERC7943Fungible.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title FundShareToken
/// @notice Permissioned share of a demo tokenized T-bill fund (technical demonstration, not a real offering).
///         ERC-20 with the ERC-7943 enforcement surface, ERC-7575 share-side vault lookup, and lost-wallet
///         recovery behind a two-day timelock.
/// @dev Single choke point: OpenZeppelin's ERC-20 routes every balance change through `_update`, which is
///      overridden to call `_checkedUpdate`; forced transfers and recoveries call `_checkedUpdate` directly.
///      `_checkedUpdate` enforces eligibility and freezes for its movement kind and always calls
///      `compliance.transferred` before touching balances, so no code path moves shares without compliance.
///      Forced transfers may bypass freezes and the sender's eligibility, never the recipient's.
///      Separation of duties: the transfer agent executes referenced forced transfers, but only within a
///      `LawfulOrder` record that the fund administrator issued for a specific (from, to, maximum amount,
///      expiry) and that is consumed as it is used; it executes recoveries, but only to a successor wallet that
///      the compliance officer bound to the same identity (wallet binding is not a transfer-agent power).
contract FundShareToken is ERC20, AccessManaged, ReentrancyGuardTransient, IFundShareToken, IERC7575Share {
    /// @dev Pending lost-wallet recovery.
    struct RecoveryRequest {
        address successor;
        uint64 eta;
        bytes32 caseRef;
    }

    /// @notice A lawful order (court or regulator) authorising referenced forced transfers.
    /// @param from Only account that may be debited.
    /// @param expiresAt End of validity (exclusive).
    /// @param to Only account that may be credited.
    /// @param remaining Amount still authorised; decremented by every execution.
    /// @param documentHash Content hash of the order document, read from the ERC-1643 registry at issuance.
    struct LawfulOrder {
        address from;
        uint64 expiresAt;
        address to;
        uint256 remaining;
        bytes32 documentHash;
    }

    /// @notice Timelock between initiating and executing a recovery.
    uint256 public constant RECOVERY_DELAY = 2 days;
    /// @notice After a cancel or a veto, no new recovery of the same wallet may start for this long, so a
    ///         transfer agent cannot keep a holder locked out by re-initiating recoveries back to back.
    uint256 public constant RECOVERY_COOLDOWN = 7 days;
    /// @notice Maximum succession chain followed by `currentWalletOf`.
    uint256 public constant MAX_SUCCESSION_DEPTH = 16;

    /// @notice Identity registry deciding account-level eligibility.
    IIdentityRegistry public immutable identityRegistry;
    /// @notice Compliance engine every movement is reported to.
    IComplianceEngine public immutable compliance;
    /// @notice ERC-1643 registry where the documents behind lawful orders are anchored.
    IERC1643 public immutable documents;

    /// @dev Share decimals (matches the settlement asset so NAV is a plain WAD ratio).
    uint8 private immutable _decimals;

    /// @inheritdoc IFundShareToken
    mapping(address lost => RecoveryRequest) public pendingRecovery;
    /// @notice Successor of each recovered (retired) wallet; zero if never recovered.
    mapping(address lost => address successor) public successorOf;
    /// @notice Earliest time a new recovery of each wallet may be initiated (set by cancels and vetoes).
    mapping(address lost => uint64 until) public recoveryCooldownUntil;
    /// @notice Lawful orders by id. Ids are single-use: an issued id can never be issued again.
    mapping(bytes32 orderId => LawfulOrder) public lawfulOrders;

    /// @dev ERC-7943 absolute frozen amounts.
    mapping(address account => uint256 amount) private _frozen;
    /// @dev ERC-7575 asset -> vault lookup.
    mapping(address asset => address vault) private _vaults;

    /// @notice Emitted when a recovery of `lost` to `successor` is scheduled.
    /// @param lost Lost wallet (frozen for sending and receiving until the recovery ends).
    /// @param successor New wallet of the same identity.
    /// @param identity Investor identity.
    /// @param eta Earliest execution time.
    /// @param caseRef Off-chain case reference.
    event RecoveryInitiated(
        address indexed lost, address indexed successor, bytes32 indexed identity, uint64 eta, bytes32 caseRef
    );
    /// @notice Emitted when a pending recovery is cancelled by the transfer agent or vetoed by the lost wallet.
    /// @param lost Lost wallet.
    /// @param successor Successor that was scheduled.
    /// @param by Caller.
    event RecoveryCancelled(address indexed lost, address indexed successor, address indexed by);
    /// @notice Emitted when a recovery executes.
    /// @param lost Retired wallet.
    /// @param successor Wallet now holding the position.
    /// @param amount Shares moved.
    /// @param frozenMoved Frozen amount carried over.
    /// @param caseRef Off-chain case reference.
    event RecoveryExecuted(
        address indexed lost, address indexed successor, uint256 amount, uint256 frozenMoved, bytes32 caseRef
    );
    /// @notice Emitted when the fund administrator issues a lawful order.
    /// @param orderId Order id.
    /// @param from Account that may be debited.
    /// @param to Account that may be credited.
    /// @param maxAmount Amount authorised in total.
    /// @param expiresAt End of validity.
    /// @param documentKey ERC-1643 key of the order document.
    /// @param documentHash Content hash of the order document.
    event LawfulOrderIssued(
        bytes32 indexed orderId,
        address indexed from,
        address indexed to,
        uint256 maxAmount,
        uint64 expiresAt,
        bytes32 documentKey,
        bytes32 documentHash
    );
    /// @notice Emitted when the fund administrator revokes what is left of a lawful order.
    /// @param orderId Order id.
    /// @param remaining Amount that was still authorised.
    event LawfulOrderRevoked(bytes32 indexed orderId, uint256 remaining);
    /// @notice Emitted by a referenced forced transfer.
    /// @param lawfulOrder Order id.
    /// @param documentHash Content hash of the order document.
    /// @param from Account debited.
    /// @param to Account credited.
    /// @param amount Amount moved.
    /// @param remaining Amount the order still authorises afterwards.
    event LawfulOrderEnforced(
        bytes32 indexed lawfulOrder,
        bytes32 documentHash,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 remaining
    );

    /// @notice The document backing a lawful order is not anchored in the document registry.
    error LawfulOrderNotAnchored(bytes32 documentKey);
    /// @notice Zero id, zero or identical parties, zero amount, or an expiry that is not in the future.
    error InvalidLawfulOrder(bytes32 orderId);
    /// @notice The order id was already issued (ids are single-use).
    error LawfulOrderExists(bytes32 orderId);
    /// @notice No lawful order with this id.
    error UnknownLawfulOrder(bytes32 orderId);
    /// @notice The forced transfer's parties differ from the ones named in the order.
    error LawfulOrderMismatch(bytes32 orderId, address from, address to);
    /// @notice The order has expired.
    error LawfulOrderExpired(bytes32 orderId, uint64 expiresAt);
    /// @notice The amount exceeds what the order still authorises.
    error LawfulOrderExceeded(bytes32 orderId, uint256 amount, uint256 remaining);
    /// @notice A recovery of `lost` was cancelled or vetoed recently.
    error RecoveryCoolingDown(address lost, uint64 until);
    /// @notice Forced transfer with identical sender and recipient.
    error ForcedTransferToSelf(address account);
    /// @notice Zero or identical wallets in a recovery.
    error InvalidRecovery(address lost, address successor);
    /// @notice The wallet was already recovered and is retired.
    error WalletRetired(address wallet);
    /// @notice A recovery for `lost` is already pending.
    error RecoveryAlreadyPending(address lost);
    /// @notice No recovery pending for `lost`.
    error NoPendingRecovery(address lost);
    /// @notice The timelock has not elapsed.
    error RecoveryTimelocked(address lost, uint64 eta);
    /// @notice `successor` is not bound to the identity of `lost`.
    error RecoveryIdentityMismatch(address lost, address successor, bytes32 identity);
    /// @notice The succession chain is longer than `MAX_SUCCESSION_DEPTH`.
    error SuccessionTooDeep(address account);

    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param decimals_ Decimals (equal to the settlement asset's).
    /// @param initialAuthority AccessManager.
    /// @param registry Identity registry.
    /// @param engine Compliance engine.
    /// @param documentRegistry ERC-1643 document registry.
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address initialAuthority,
        IIdentityRegistry registry,
        IComplianceEngine engine,
        IERC1643 documentRegistry
    ) ERC20(name_, symbol_) AccessManaged(initialAuthority) {
        _decimals = decimals_;
        identityRegistry = registry;
        compliance = engine;
        documents = documentRegistry;
    }

    // ---------------------------------------------------------------------------------------------
    // Vault: issuance and redemption
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IFundShareToken
    function mint(address to, uint256 amount) external restricted {
        _mint(to, amount);
    }

    /// @inheritdoc IFundShareToken
    function burnForRedemption(address owner, address spender, uint256 amount) external restricted {
        if (spender != address(0)) _spendAllowance(owner, spender, amount);
        _burn(owner, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-7943 enforcement
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7943Fungible
    function setFrozenTokens(address account, uint256 amount) external restricted returns (bool result) {
        _frozen[account] = amount;
        emit Frozen(account, amount);
        return true;
    }

    /// @inheritdoc IERC7943Fungible
    /// @dev Reference-less entry point kept for ERC-7943 interoperability. The deployment maps this selector to
    ///      governance (ADMIN) only; the transfer agent uses the overload that executes a lawful order.
    function forcedTransfer(address from, address to, uint256 amount) external restricted returns (bool result) {
        _forcedTransfer(from, to, amount);
        return true;
    }

    /// @notice Issues a lawful order: authorises forced transfers from `from` to `to` of at most `maxAmount`
    ///         in total until `expiresAt`. The order document must already be anchored in the ERC-1643
    ///         registry under `documentKey`; its content hash is recorded with the order.
    /// @dev Fund administrator only (deployment wiring). The transfer agent executes the order but cannot widen
    ///      it: the parties are fixed, every execution consumes the authorised amount, and ids are single-use.
    /// @param orderId Order id (non-zero, never issued before).
    /// @param from Account that may be debited.
    /// @param to Account that may be credited.
    /// @param maxAmount Total amount authorised.
    /// @param expiresAt End of validity (exclusive), in the future.
    /// @param documentKey ERC-1643 key of the anchored order document.
    function issueLawfulOrder(
        bytes32 orderId,
        address from,
        address to,
        uint256 maxAmount,
        uint64 expiresAt,
        bytes32 documentKey
    ) external restricted {
        require(
            orderId != bytes32(0) && from != address(0) && to != address(0) && from != to && maxAmount != 0
                && expiresAt > block.timestamp,
            InvalidLawfulOrder(orderId)
        );
        require(lawfulOrders[orderId].from == address(0), LawfulOrderExists(orderId));
        // Only the content hash matters here; the URI and timestamp are informational.
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return)
        (, bytes32 documentHash,) = documents.getDocument(documentKey);
        // slither-disable-end unused-return
        require(documentHash != bytes32(0), LawfulOrderNotAnchored(documentKey));
        lawfulOrders[orderId] =
            LawfulOrder({from: from, expiresAt: expiresAt, to: to, remaining: maxAmount, documentHash: documentHash});
        emit LawfulOrderIssued(orderId, from, to, maxAmount, expiresAt, documentKey, documentHash);
    }

    /// @notice Revokes whatever a lawful order still authorises (e.g. the order was set aside on appeal).
    /// @param orderId Order id.
    function revokeLawfulOrder(bytes32 orderId) external restricted {
        LawfulOrder storage order = lawfulOrders[orderId];
        require(order.from != address(0), UnknownLawfulOrder(orderId));
        uint256 remaining = order.remaining;
        order.remaining = 0;
        emit LawfulOrderRevoked(orderId, remaining);
    }

    /// @notice Forced transfer executing a lawful order issued by the fund administrator.
    /// @param from Account debited (may be frozen or ineligible); must be the order's `from`.
    /// @param to Account credited (must be eligible; recipient-side modules apply); must be the order's `to`.
    /// @param amount Amount; at most what the order still authorises, which it consumes.
    /// @param lawfulOrder Order id.
    /// @return result True on success.
    function forcedTransfer(address from, address to, uint256 amount, bytes32 lawfulOrder)
        external
        restricted
        returns (bool result)
    {
        LawfulOrder storage order = lawfulOrders[lawfulOrder];
        require(order.from != address(0), UnknownLawfulOrder(lawfulOrder));
        require(order.from == from && order.to == to, LawfulOrderMismatch(lawfulOrder, from, to));
        uint64 expiresAt = order.expiresAt;
        require(block.timestamp < expiresAt, LawfulOrderExpired(lawfulOrder, expiresAt));
        uint256 remaining = order.remaining;
        require(amount <= remaining, LawfulOrderExceeded(lawfulOrder, amount, remaining));
        remaining -= amount;
        order.remaining = remaining;
        _forcedTransfer(from, to, amount);
        emit LawfulOrderEnforced(lawfulOrder, order.documentHash, from, to, amount, remaining);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Lost-wallet recovery
    // ---------------------------------------------------------------------------------------------

    /// @notice Schedules the recovery of `lost` to `successor`, a verified wallet that the compliance officer
    ///         bound to the same identity. `lost` can neither send nor receive while the recovery is pending.
    /// @param lost Lost wallet.
    /// @param successor Replacement wallet.
    /// @param caseRef Off-chain case reference for the audit trail.
    function initiateRecovery(address lost, address successor, bytes32 caseRef) external restricted {
        require(lost != address(0) && successor != address(0) && lost != successor, InvalidRecovery(lost, successor));
        require(successorOf[lost] == address(0), WalletRetired(lost));
        require(pendingRecovery[lost].successor == address(0), RecoveryAlreadyPending(lost));
        uint64 cooldownUntil = recoveryCooldownUntil[lost];
        require(block.timestamp >= cooldownUntil, RecoveryCoolingDown(lost, cooldownUntil));
        bytes32 identity = compliance.resolveIdentity(lost);
        require(
            identity != bytes32(0) && identityRegistry.identityOf(successor) == identity,
            RecoveryIdentityMismatch(lost, successor, identity)
        );
        require(_isEligible(successor), ERC7943CannotReceive(successor));

        uint64 eta = SafeCast.toUint64(block.timestamp + RECOVERY_DELAY);
        pendingRecovery[lost] = RecoveryRequest({successor: successor, eta: eta, caseRef: caseRef});
        emit RecoveryInitiated(lost, successor, identity, eta, caseRef);
    }

    /// @notice Cancels a pending recovery (transfer agent). Starts the `RECOVERY_COOLDOWN` for `lost`.
    /// @param lost Lost wallet.
    function cancelRecovery(address lost) external restricted {
        _cancelRecovery(lost);
    }

    /// @notice Vetoes a pending recovery of `msg.sender`: proof that the key is not lost. Starts the
    ///         `RECOVERY_COOLDOWN`, during which no new recovery of the wallet can be initiated.
    function vetoRecovery() external {
        _cancelRecovery(msg.sender);
    }

    /// @notice Executes a matured recovery: moves the whole balance and frozen amount of `lost` to the
    ///         successor through the compliance engine and retires `lost` permanently.
    /// @param lost Lost wallet.
    /// @return amount Shares moved.
    function executeRecovery(address lost) external restricted returns (uint256 amount) {
        RecoveryRequest memory request = pendingRecovery[lost];
        require(request.successor != address(0), NoPendingRecovery(lost));
        require(block.timestamp >= request.eta, RecoveryTimelocked(lost, request.eta));
        bytes32 identity = compliance.resolveIdentity(lost);
        require(
            identityRegistry.identityOf(request.successor) == identity,
            RecoveryIdentityMismatch(lost, request.successor, identity)
        );

        delete pendingRecovery[lost];
        successorOf[lost] = request.successor;

        uint256 frozen = _frozen[lost];
        if (frozen != 0) {
            _frozen[lost] = 0;
            emit Frozen(lost, 0);
            uint256 successorFrozen = _frozen[request.successor] + frozen;
            _frozen[request.successor] = successorFrozen;
            emit Frozen(request.successor, successorFrozen);
        }

        amount = balanceOf(lost);
        _checkedUpdate(TransferKind.Recovery, lost, request.successor, amount);
        emit ForcedTransfer(lost, request.successor, amount);
        emit RecoveryExecuted(lost, request.successor, amount, frozen, request.caseRef);
    }

    // ---------------------------------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the ERC-7575 vault serving `asset`.
    /// @param asset Asset.
    /// @param vault_ Vault (zero to unset).
    function setVault(address asset, address vault_) external restricted {
        _vaults[asset] = vault_;
        emit VaultUpdate(asset, vault_);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IERC7575Share
    function vault(address asset) external view returns (address) {
        return _vaults[asset];
    }

    /// @inheritdoc IERC7943Fungible
    function canSend(address account) public view returns (bool allowed) {
        return _isEligible(account);
    }

    /// @inheritdoc IERC7943Fungible
    function canReceive(address account) public view returns (bool allowed) {
        return _isEligible(account);
    }

    /// @notice Legacy ERC-7943 draft predicate: whether `account` may both send and receive.
    /// @param account Account.
    /// @return allowed True if eligible.
    function canTransact(address account) external view returns (bool allowed) {
        return _isEligible(account);
    }

    /// @inheritdoc IERC7943Fungible
    function getFrozenTokens(address account) external view returns (uint256 amount) {
        return _frozen[account];
    }

    /// @inheritdoc IERC7943Fungible
    function canTransfer(address from, address to, uint256 amount) external view returns (bool allowed) {
        if (!_isEligible(from) || !_isEligible(to)) return false;
        uint256 frozen = _frozen[from];
        if (frozen != 0 && amount > _unfrozen(from, balanceOf(from))) return false;
        return _modulesAllow(TransferKind.Transfer, from, to, amount);
    }

    /// @inheritdoc IFundShareToken
    function canMint(address to, uint256 amount) external view returns (bool allowed) {
        return _isEligible(to) && _modulesAllow(TransferKind.Mint, address(0), to, amount);
    }

    /// @inheritdoc IFundShareToken
    function currentWalletOf(address account) external view returns (address wallet) {
        wallet = account;
        // Up to MAX_SUCCESSION_DEPTH hops are followed; the extra iteration confirms the end of the chain.
        for (uint256 hops; hops <= MAX_SUCCESSION_DEPTH; ++hops) {
            address next = successorOf[wallet];
            if (next == address(0)) return wallet;
            wallet = next;
        }
        revert SuccessionTooDeep(account);
    }

    /// @notice ERC-165: ERC-20, ERC-7943 (fungible), ERC-7575 share, ERC-165.
    /// @param interfaceId Interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC7943Fungible).interfaceId || interfaceId == type(IERC7575Share).interfaceId
            || interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Every ERC-20 balance change (transfer, transferFrom, mint, burn) lands here.
    function _update(address from, address to, uint256 value) internal override {
        TransferKind kind;
        if (from == address(0)) kind = TransferKind.Mint;
        else if (to == address(0)) kind = TransferKind.Burn;
        else kind = TransferKind.Transfer;
        _checkedUpdate(kind, from, to, value);
    }

    /// @dev The only function that calls `ERC20._update`. Sender-side checks apply to user-initiated debits
    ///      (Transfer, Burn); recipient eligibility applies to every credit, forced ones included. The transient
    ///      guard makes a (governance-approved but misbehaving) module unable to re-enter a movement while the
    ///      engine is still judging it, because balances are only written after the engine returns.
    function _checkedUpdate(TransferKind kind, address from, address to, uint256 value) private nonReentrant {
        if (kind == TransferKind.Transfer || kind == TransferKind.Burn) {
            require(_isEligible(from), ERC7943CannotSend(from));
            uint256 balance = balanceOf(from);
            require(balance >= value, ERC20InsufficientBalance(from, balance, value));
            uint256 unfrozen = _unfrozen(from, balance);
            require(value <= unfrozen, ERC7943InsufficientUnfrozenBalance(from, value, unfrozen));
        }
        if (kind != TransferKind.Burn) require(_isEligible(to), ERC7943CannotReceive(to));
        // Re-entry into this function is blocked by `nonReentrant`; the engine and its modules are governed.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        compliance.transferred(kind, from, to, value);
        super._update(from, to, value);
    }

    function _forcedTransfer(address from, address to, uint256 amount) private {
        require(from != address(0), ERC20InvalidSender(address(0)));
        require(to != address(0), ERC20InvalidReceiver(address(0)));
        require(from != to, ForcedTransferToSelf(from));
        uint256 balance = balanceOf(from);
        require(balance >= amount, ERC20InsufficientBalance(from, balance, amount));

        uint256 unfrozen = _unfrozen(from, balance);
        if (amount > unfrozen) {
            // amount - unfrozen <= balance - unfrozen <= frozen, so this cannot underflow.
            uint256 newFrozen = _frozen[from] - (amount - unfrozen);
            _frozen[from] = newFrozen;
            emit Frozen(from, newFrozen);
        }
        _checkedUpdate(TransferKind.Forced, from, to, amount);
        emit ForcedTransfer(from, to, amount);
    }

    function _cancelRecovery(address lost) private {
        address successor = pendingRecovery[lost].successor;
        require(successor != address(0), NoPendingRecovery(lost));
        delete pendingRecovery[lost];
        recoveryCooldownUntil[lost] = SafeCast.toUint64(block.timestamp + RECOVERY_COOLDOWN);
        emit RecoveryCancelled(lost, successor, msg.sender);
    }

    /// @dev Never reverts: a reverting module counts as a rejection. The rejecting module is irrelevant here.
    function _modulesAllow(TransferKind kind, address from, address to, uint256 amount) private view returns (bool) {
        // slither-disable-next-line unused-return
        try compliance.checkTransfer(kind, from, to, amount) returns (bool ok, address) {
            return ok;
        } catch {
            return false;
        }
    }

    function _unfrozen(address account, uint256 balance) private view returns (uint256) {
        uint256 frozen = _frozen[account];
        return balance > frozen ? balance - frozen : 0;
    }

    function _isEligible(address account) private view returns (bool) {
        return account != address(0) && successorOf[account] == address(0)
            && pendingRecovery[account].successor == address(0) && identityRegistry.isVerified(account);
    }
}
