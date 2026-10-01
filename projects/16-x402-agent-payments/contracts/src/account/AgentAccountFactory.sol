// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "./AgentAccount.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title AgentAccountFactory
/// @notice Deploys {AgentAccount} clones at deterministic addresses, each with the {BudgetExecutor} pre-installed.
/// @dev The CREATE2 salt commits to the owner *and* the full policy payload. Without that, anyone could front-run a
///      counterfactual deployment with the right owner but their own session key or payee list, and then spend the
///      funds the owner sent to the predicted address. Nothing in the salted payload can expire: the executor does not
///      check the session expiry at install time, so an address funded counterfactually stays deployable (and its
///      owner can withdraw) after the session has expired.
contract AgentAccountFactory {
    /// @notice Clone implementation (initialization disabled).
    address public immutable ACCOUNT_IMPLEMENTATION;

    /// @notice Budget executor installed in every account.
    address public immutable BUDGET_EXECUTOR;

    /// @notice Emitted when a new account is deployed.
    /// @param account The new account.
    /// @param owner Its owner.
    /// @param salt The CREATE2 salt used.
    event AccountCreated(address indexed account, address indexed owner, bytes32 salt);

    /// @notice The budget executor address must be non-zero.
    error ZeroExecutor();

    /// @param budgetExecutor The {BudgetExecutor} to pre-install.
    constructor(address budgetExecutor) {
        require(budgetExecutor != address(0), ZeroExecutor());
        ACCOUNT_IMPLEMENTATION = address(new AgentAccount());
        BUDGET_EXECUTOR = budgetExecutor;
    }

    /// @notice Deploys (or returns the existing) account for `owner` with `policyInitData`.
    /// @param owner Account owner (ECDSA signer).
    /// @param policyInitData `abi.encode(BudgetExecutor.Policy, address[] payees)`.
    /// @param userSalt Extra salt so one owner can hold several accounts with the same policy.
    /// @return account The account address.
    function createAccount(address owner, bytes calldata policyInitData, bytes32 userSalt)
        external
        returns (address account)
    {
        bytes32 salt = accountSalt(owner, policyInitData, userSalt);
        account = Clones.predictDeterministicAddress(ACCOUNT_IMPLEMENTATION, salt);
        if (account.code.length == 0) {
            account = Clones.cloneDeterministic(ACCOUNT_IMPLEMENTATION, salt);
            emit AccountCreated(account, owner, salt);
            AgentAccount(payable(account)).initialize(owner, BUDGET_EXECUTOR, policyInitData);
        }
    }

    /// @notice Counterfactual address of an account.
    /// @param owner Account owner.
    /// @param policyInitData Executor install payload.
    /// @param userSalt Extra salt.
    /// @return The address {createAccount} deploys to.
    function predictAccount(address owner, bytes calldata policyInitData, bytes32 userSalt)
        external
        view
        returns (address)
    {
        return Clones.predictDeterministicAddress(ACCOUNT_IMPLEMENTATION, accountSalt(owner, policyInitData, userSalt));
    }

    /// @notice CREATE2 salt binding owner, policy and user salt.
    /// @param owner Account owner.
    /// @param policyInitData Executor install payload.
    /// @param userSalt Extra salt.
    /// @return The salt.
    function accountSalt(address owner, bytes calldata policyInitData, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, keccak256(policyInitData), userSalt));
    }
}
