// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IEntryPoint} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {PasskeyAccount} from "./PasskeyAccount.sol";
import {IPasskeyAccount} from "./interfaces/IPasskeyAccount.sol";

/// @title PasskeyAccountFactory
/// @author Passkey Smart Account contributors
/// @notice CREATE2 factory for ERC-1167 clones of {PasskeyAccount}, usable as an ERC-4337 `factory`.
/// @dev The CREATE2 salt commits to the full initialization parameters, and the clone is initialized in the same call
/// that deploys it. A front-runner can therefore only deploy the exact account the user asked for.
contract PasskeyAccountFactory {
    /// @notice The implementation every clone delegates to. Also usable as an EIP-7702 delegation target.
    // slither-disable-next-line naming-convention
    PasskeyAccount public immutable ACCOUNT_IMPLEMENTATION;

    /// @notice Emitted when a new account is deployed.
    /// @param account The deployed clone.
    /// @param qx X coordinate of the initial passkey.
    /// @param qy Y coordinate of the initial passkey.
    /// @param salt The user-chosen salt.
    event AccountCreated(address indexed account, bytes32 qx, bytes32 qy, bytes32 salt);

    /// @notice Deploys the implementation, bound to `entryPoint_` and to this factory.
    /// @param entryPoint_ The ERC-4337 EntryPoint the accounts trust.
    constructor(IEntryPoint entryPoint_) {
        ACCOUNT_IMPLEMENTATION = new PasskeyAccount(entryPoint_, address(this));
    }

    /// @notice Deploys and initializes an account, or returns it if it already exists.
    /// @dev Idempotent so that the EntryPoint's `initCode` flow and direct calls behave the same.
    /// @param params Passkey, guardians and threshold.
    /// @param salt User-chosen salt, to derive several accounts from the same parameters.
    /// @return account The account address.
    function createAccount(IPasskeyAccount.InitParams calldata params, bytes32 salt)
        external
        returns (address account)
    {
        bytes32 create2Salt = _create2Salt(params, salt);
        account = Clones.predictDeterministicAddress(address(ACCOUNT_IMPLEMENTATION), create2Salt);
        if (account.code.length == 0) {
            account = Clones.cloneDeterministic(address(ACCOUNT_IMPLEMENTATION), create2Salt);
            // Only the clone's own CREATE2 precedes the event; it is emitted before the external initialize call.
            // forge-lint: disable-next-line(reentrancy-events)
            emit AccountCreated(account, params.passkey.qx, params.passkey.qy, salt);
            PasskeyAccount(payable(account)).initialize(params);
        }
    }

    /// @notice Counterfactual address of the account `createAccount(params, salt)` deploys.
    /// @param params Passkey, guardians and threshold.
    /// @param salt User-chosen salt.
    /// @return The account address.
    function getAddress(IPasskeyAccount.InitParams calldata params, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(address(ACCOUNT_IMPLEMENTATION), _create2Salt(params, salt));
    }

    function _create2Salt(IPasskeyAccount.InitParams calldata params, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(params, salt));
    }
}
