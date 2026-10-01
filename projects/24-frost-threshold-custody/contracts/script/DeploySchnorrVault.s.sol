// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";

import {SchnorrVault} from "../src/SchnorrVault.sol";

/// @notice Deploys a SchnorrVault for an existing FROST group.
/// @dev Template, exercised by DeployScriptTest and mirrored by the Rust end-to-end test.
///      Keystore-based, never a raw private key:
///
///      GROUP_KEY_X=0x... GROUP_KEY_PARITY=0 GUARDIAN=0x... ETH_DAILY_LIMIT=1000000000000000000 \
///      forge script script/DeploySchnorrVault.s.sol --rpc-url $RPC_URL --account deployer --broadcast
///
///      Only deploy for a group whose key shares are persisted somewhere and whose signers
///      are pinned to the deployed vault's address and chain id. The `frost-custody` CLI keeps
///      shares in process memory only: a vault deployed for a key printed by `frost-custody
///      demo` could never withdraw, rotate or replace its guardian, and anything deposited
///      would be locked for good.
contract DeploySchnorrVault is Script {
    /// @notice Deploys the vault with an ETH daily limit taken from the environment.
    /// @return vault The deployed vault.
    function run() external returns (SchnorrVault vault) {
        uint256 keyX = vm.envUint("GROUP_KEY_X");
        uint8 parity = uint8(vm.envUint("GROUP_KEY_PARITY"));
        address guardian = vm.envAddress("GUARDIAN");
        address[] memory tokens = new address[](1);
        uint256[] memory limits = new uint256[](1);
        limits[0] = vm.envUint("ETH_DAILY_LIMIT");
        vm.startBroadcast();
        vault = new SchnorrVault(keyX, parity, guardian, tokens, limits);
        vm.stopBroadcast();
    }
}
