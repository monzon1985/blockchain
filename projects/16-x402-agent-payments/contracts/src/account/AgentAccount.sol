// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {AccountERC7579} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579.sol";
import {CallType, ERC7579Utils, Mode} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {AbstractSigner} from "@openzeppelin/contracts/utils/cryptography/signers/AbstractSigner.sol";
import {SignerECDSA} from "@openzeppelin/contracts/utils/cryptography/signers/SignerECDSA.sol";
import {ERC7739} from "@openzeppelin/contracts/utils/cryptography/signers/draft-ERC7739.sol";

/// @title AgentAccount
/// @notice ERC-7579 modular smart account for an autonomous agent. A human principal (the ECDSA `signer`) owns the
///         funds and administers the account; the agent itself only holds a session key registered in the
///         {BudgetExecutor} module and can therefore spend only within the module's on-chain policy.
/// @dev Built from OpenZeppelin `Account` + `AccountERC7579` + `SignerECDSA` + `ERC7739`, deployed as ERC-1167
///      clones by {AgentAccountFactory}. Deviations from the stock composition:
///      - Delegatecall execution mode is rejected for every caller (owner, EntryPoint and executor modules). An
///        executor that asked for delegatecall could otherwise rewrite the account's storage, including its module
///        set, and escape any policy.
///      - The owner EOA may call the `onlyEntryPointOrSelf` functions directly. The local stack has no ERC-4337
///        bundler, so this is how the principal installs modules, edits the policy and withdraws. It grants the
///        owner nothing it could not already do through a UserOperation.
///      - ERC-1271 checks try the ERC-7739 nested typed-data path first (replay-safe owner signatures), then
///        installed validator modules.
contract AgentAccount is Account, AccountERC7579, SignerECDSA, ERC7739, Initializable {
    /// @notice Emitted once, when a clone is initialized.
    /// @param owner The ECDSA signer that controls the account.
    /// @param executor The executor module installed at creation.
    event AgentAccountInitialized(address indexed owner, address indexed executor);

    /// @notice Delegatecall execution mode is disabled on this account.
    error DelegatecallDisabled();

    /// @notice The owner must be a non-zero address.
    error ZeroOwner();

    /// @dev The implementation is never used directly: its signer stays zero and initialization is disabled.
    constructor() EIP712("AgentAccount", "1") SignerECDSA(address(0)) {
        _disableInitializers();
    }

    /// @notice Initializes a clone: sets the owner and installs the budget executor with its policy.
    /// @param owner ECDSA signer that controls the account.
    /// @param executor The executor module (a {BudgetExecutor}).
    /// @param executorInitData `onInstall` payload for the executor.
    function initialize(address owner, address executor, bytes calldata executorInitData) external initializer {
        require(owner != address(0), ZeroOwner());
        _setSigner(owner);
        _installModule(MODULE_TYPE_EXECUTOR, executor, executorInitData);
        emit AgentAccountInitialized(owner, executor);
    }

    /// @notice ERC-7579 account identifier.
    /// @return `vendor.account.semver` identifier.
    function accountId() public pure override returns (string memory) {
        return "x402-local.AgentAccount.v1.0.0";
    }

    /// @notice Same as OpenZeppelin's, minus delegatecall mode.
    /// @param encodedMode ERC-7579 execution mode.
    /// @return Whether the mode is supported.
    function supportsExecutionMode(bytes32 encodedMode) public view override returns (bool) {
        // slither-disable-next-line unused-return (only the call type matters here)
        (CallType callType,,,) = ERC7579Utils.decodeMode(Mode.wrap(encodedMode));
        return !(callType == ERC7579Utils.CALLTYPE_DELEGATECALL) && super.supportsExecutionMode(encodedMode);
    }

    /// @notice ERC-1271: ERC-7739 nested signature from the owner first, then installed validator modules.
    /// @param hash The digest that was signed.
    /// @param signature The signature payload.
    /// @return The ERC-1271 magic value, or `0xffffffff`.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        public
        view
        override(AccountERC7579, ERC7739)
        returns (bytes4)
    {
        bytes4 magic = ERC7739.isValidSignature(hash, signature);
        return magic == bytes4(0xffffffff) ? AccountERC7579.isValidSignature(hash, signature) : magic;
    }

    /// @dev Rejects delegatecall mode, then defers to OpenZeppelin's single/batch execution.
    function _execute(Mode mode, bytes calldata executionCalldata) internal override returns (bytes[] memory) {
        // slither-disable-next-line unused-return (only the call type matters here)
        (CallType callType,,,) = ERC7579Utils.decodeMode(mode);
        require(!(callType == ERC7579Utils.CALLTYPE_DELEGATECALL), DelegatecallDisabled());
        return super._execute(mode, executionCalldata);
    }

    /// @dev The owner EOA is accepted alongside the EntryPoint and the account itself.
    function _checkEntryPointOrSelf() internal view override {
        if (msg.sender == signer()) return;
        super._checkEntryPointOrSelf();
    }

    /// @dev UserOperations signed by the owner are valid when no validator module is selected.
    function _validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, bytes calldata signature)
        internal
        override(Account, AccountERC7579)
        returns (uint256)
    {
        return super._validateUserOp(userOp, userOpHash, signature);
    }

    /// @dev Raw ECDSA validation against the owner (used by ERC-7739 and UserOperation validation).
    // slither-disable-next-line dead-code (reached through virtual dispatch from ERC7739 and Account)
    function _rawSignatureValidation(bytes32 hash, bytes calldata signature)
        internal
        view
        override(AbstractSigner, AccountERC7579, SignerECDSA)
        returns (bool)
    {
        return SignerECDSA._rawSignatureValidation(hash, signature);
    }
}
