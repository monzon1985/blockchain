// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {IVolatilityFeeHook} from "../src/interfaces/IVolatilityFeeHook.sol";

/// @notice Shared deployment logic: mines a CREATE2 salt with HookMiner against the deterministic deployer
/// (0x4e59b448...) so the hook's address encodes exactly its permissions, then deploys through it.
abstract contract HookDeployment is Script {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function _deployHook(IPoolManager manager, address owner, IVolatilityFeeHook.FeeConfig memory config)
        internal
        returns (VolatilityFeeHook hook)
    {
        bytes memory args = abi.encode(manager, owner, config);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(VolatilityFeeHook).creationCode, args);
        console2.log("Mined hook address:", predicted);

        vm.broadcast();
        hook = new VolatilityFeeHook{salt: salt}(manager, owner, config);
        require(address(hook) == predicted, "deployed address differs from the mined address");
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "permission bits mismatch");
    }
}
