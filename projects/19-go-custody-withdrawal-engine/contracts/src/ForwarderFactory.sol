// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin-contracts/proxy/Clones.sol";
import {DepositForwarder} from "./DepositForwarder.sol";

/// @title ForwarderFactory
/// @notice Deploys per-user deposit forwarders at CREATE2 addresses and flushes them to the hot
///         wallet in batches. A user's deposit address is known before anything is deployed:
///         `forwarderAddress(keccak256(bytes(userId)))`, so the exchange can hand it out at signup
///         and only pay for deployment when the first deposit is swept.
/// @dev Every forwarder is an ERC-1167 clone of a single {DepositForwarder} implementation created
///      in the constructor. The owner (the custody engine's sweeper key) is the only caller of the
///      mutating functions, but a compromised owner cannot redirect funds: every flush pays the
///      immutable `DESTINATION`. The factory keeps no state besides ownership, so external token
///      calls cannot reenter into anything that matters (see README, "Security considerations").
contract ForwarderFactory is Ownable2Step {
    /// @notice The {DepositForwarder} implementation every clone delegates to.
    address public immutable IMPLEMENTATION;

    /// @notice The hot wallet that receives every flushed balance, fixed at deployment.
    address payable public immutable DESTINATION;

    /// @notice Emitted the first time the forwarder for `salt` is deployed.
    /// @param salt The CREATE2 salt, `keccak256(bytes(userId))` by convention.
    /// @param forwarder The address of the new clone.
    event ForwarderDeployed(bytes32 indexed salt, address indexed forwarder);

    /// @notice Emitted once per batch flush.
    /// @param token The ERC-20 token that was flushed, or `address(0)` for the native currency.
    /// @param forwarders The number of salts in the batch (duplicates included).
    /// @param total The total amount moved to `DESTINATION` by the batch.
    event BatchFlushed(address indexed token, uint256 forwarders, uint256 total);

    /// @notice The destination passed to the constructor was the zero address.
    error ZeroDestination();

    /// @notice A batch operation was called with no salts.
    error EmptyBatch();

    /// @notice Ownership can only be transferred, never renounced: without an owner, deposits
    ///         sitting in forwarders could never be flushed again.
    error OwnershipCannotBeRenounced();

    /// @notice Deploys the shared forwarder implementation for `destination`.
    /// @param destination The hot wallet that will receive every flushed balance.
    /// @param initialOwner The sweeper key allowed to deploy and flush forwarders.
    constructor(address payable destination, address initialOwner) Ownable(initialOwner) {
        require(destination != address(0), ZeroDestination());
        IMPLEMENTATION = address(new DepositForwarder(destination));
        DESTINATION = destination;
    }

    /// @notice The CREATE2 salt used for `userId`.
    /// @param userId The exchange-side user identifier.
    /// @return The salt, `keccak256(bytes(userId))`.
    function saltFor(string calldata userId) external pure returns (bytes32) {
        return keccak256(bytes(userId));
    }

    /// @notice The deposit address for `salt`, whether or not it has been deployed yet.
    /// @param salt The CREATE2 salt.
    /// @return The address of the ERC-1167 clone for `salt`.
    function forwarderAddress(bytes32 salt) public view returns (address) {
        return Clones.predictDeterministicAddress(IMPLEMENTATION, salt);
    }

    /// @notice Whether the forwarder for `salt` has been deployed.
    /// @param salt The CREATE2 salt.
    /// @return True when the clone has code.
    function isDeployed(bytes32 salt) external view returns (bool) {
        return forwarderAddress(salt).code.length != 0;
    }

    /// @notice Deploys the forwarder for `salt` if it does not exist yet.
    /// @param salt The CREATE2 salt.
    /// @return forwarder The forwarder address (deployed now or earlier).
    function deploy(bytes32 salt) external onlyOwner returns (address forwarder) {
        forwarder = _deployIfNeeded(salt);
    }

    // Triage (Slither calls-loop, reentrancy-events; forge-lint equivalents below): batching
    // external calls is the purpose of both batch functions, only the owner can call them, and
    // forwarders only ever pay the immutable DESTINATION. See README, "Static analysis".
    // slither-disable-start calls-loop,reentrancy-events

    /// @notice Deploys (when needed) and flushes every forwarder in `salts` for `token`.
    /// @dev One transaction sweeps a whole batch, which is what makes counterfactual deposit
    ///      addresses cheap to operate. Duplicate salts are harmless: the second flush of the same
    ///      forwarder finds a zero balance.
    /// @param salts The CREATE2 salts of the forwarders to flush.
    /// @param token The ERC-20 token to flush.
    /// @return total The total amount moved to `DESTINATION`.
    function flushMany(bytes32[] calldata salts, IERC20 token)
        external
        onlyOwner
        returns (uint256 total)
    {
        uint256 len = salts.length;
        require(len != 0, EmptyBatch());
        for (uint256 i; i < len; ++i) {
            // Batching is the point of this function; the owner bounds the batch size and a
            // reverting token only reverts the owner's own sweep (see README, lint triage).
            // forge-lint: disable-next-line(calls-loop)
            total += DepositForwarder(_deployIfNeeded(salts[i])).flush(token);
        }
        // The total is only known after the calls. Reentry cannot forge this log: only the owner
        // can call flushMany, and forwarders only ever pay DESTINATION.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BatchFlushed(address(token), len, total);
    }

    /// @notice Deploys (when needed) and flushes the native balance of every forwarder in `salts`.
    /// @dev Recovery path for ETH sent to a deposit address before its forwarder existed.
    /// @param salts The CREATE2 salts of the forwarders to flush.
    /// @return total The total amount of wei moved to `DESTINATION`.
    function flushNativeMany(bytes32[] calldata salts) external onlyOwner returns (uint256 total) {
        uint256 len = salts.length;
        require(len != 0, EmptyBatch());
        for (uint256 i; i < len; ++i) {
            // Same justification as flushMany.
            // forge-lint: disable-next-line(calls-loop)
            total += DepositForwarder(_deployIfNeeded(salts[i])).flushNative();
        }
        // Same justification as flushMany.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BatchFlushed(address(0), len, total);
    }

    // slither-disable-end calls-loop,reentrancy-events

    /// @notice Always reverts: the factory must keep an owner so deposits can always be flushed.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @dev Deploys the clone for `salt` unless it already has code, and returns its address.
    function _deployIfNeeded(bytes32 salt) private returns (address forwarder) {
        forwarder = forwarderAddress(salt);
        if (forwarder.code.length == 0) {
            forwarder = Clones.cloneDeterministic(IMPLEMENTATION, salt);
            // The "external call" is the CREATE2 of a 45-byte clone that runs no constructor code.
            // forge-lint: disable-next-line(reentrancy-events)
            emit ForwarderDeployed(salt, forwarder);
        }
    }
}
