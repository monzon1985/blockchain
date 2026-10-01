// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CumulativeMerkleDistributor} from "../src/CumulativeMerkleDistributor.sol";
import {Script} from "forge-std/Script.sol";

/// @title Deploy
/// @notice Deploys a `CumulativeMerkleDistributor` with three distinct roles. Keystore-based, no raw keys:
///
///         DISTRIBUTOR_OWNER=0x... DISTRIBUTOR_UPDATER=0x... DISTRIBUTOR_GUARDIAN=0x... \
///           forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --account <keystore-name> --broadcast
///
///         The local demo (`npm run demo` in tree-builder/) runs this exact script against anvil with `--unlocked`.
/// @dev The contract itself accepts a zero updater or guardian (a deliberately disabled role). A deployment script is
///      where a typo becomes a live misconfiguration, so this one refuses zero addresses and shared roles outright.
contract Deploy is Script {
    /// @notice A role address is zero.
    /// @param role Name of the role ("owner", "updater" or "guardian").
    error ZeroRoleAddress(string role);

    /// @notice Two roles were given the same address, which would defeat the separation of duties.
    /// @param account The shared address.
    error SharedRole(address account);

    /// @notice The deployed contract does not report the roles and the empty state it was constructed with.
    /// @param distributor The deployed contract.
    error PostDeployCheckFailed(address distributor);

    /// @notice Reads the roles from the environment and deploys.
    /// @return distributor The deployed distributor.
    function run() external returns (CumulativeMerkleDistributor distributor) {
        return deploy(
            vm.envAddress("DISTRIBUTOR_OWNER"),
            vm.envAddress("DISTRIBUTOR_UPDATER"),
            vm.envAddress("DISTRIBUTOR_GUARDIAN")
        );
    }

    /// @notice Validates the roles, deploys the distributor from the broadcasting account and checks the result.
    /// @param owner Owner (sets the updater and the guardian; two-step transfer). Ideally a multisig or a timelock.
    /// @param updater Hot key or service that proposes roots.
    /// @param guardian Independent account that can veto a pending root.
    /// @return distributor The deployed distributor.
    function deploy(address owner, address updater, address guardian)
        public
        returns (CumulativeMerkleDistributor distributor)
    {
        require(owner != address(0), ZeroRoleAddress("owner"));
        require(updater != address(0), ZeroRoleAddress("updater"));
        require(guardian != address(0), ZeroRoleAddress("guardian"));
        require(owner != updater && owner != guardian, SharedRole(owner));
        require(updater != guardian, SharedRole(updater));

        vm.startBroadcast();
        distributor = new CumulativeMerkleDistributor(owner, updater, guardian);
        vm.stopBroadcast();

        require(
            distributor.owner() == owner && distributor.updater() == updater && distributor.guardian() == guardian
                && distributor.root() == bytes32(0) && distributor.epoch() == 0,
            PostDeployCheckFailed(address(distributor))
        );
    }
}
