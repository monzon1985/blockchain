// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {QuartetAssembly} from "../src/assembly/QuartetAssembly.sol";
import {YulBytecode} from "../src/generated/YulBytecode.sol";
import {IQuartetToken} from "../src/interfaces/IQuartetToken.sol";
import {QuartetSolidity} from "../src/solidity/QuartetSolidity.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title DeployQuartet
/// @notice Deploys the four implementations side by side and prints their addresses and code sizes.
/// @dev No private key is ever read by this script. The broadcaster comes from forge's wallet flags:
///        simulation only:  forge script script/DeployQuartet.s.sol
///        local anvil:      forge script script/DeployQuartet.s.sol --rpc-url <url> --broadcast \
///                            --unlocked --sender <an anvil account>
///        any network:      forge script script/DeployQuartet.s.sol --rpc-url <url> --broadcast \
///                            --account <keystore name> --sender <address>
///      Optional environment: QUARTET_HOLDER (default: the broadcaster), QUARTET_SUPPLY (default 1e24).
contract DeployQuartet is Script {
    /// @notice Deploys Solidity, inline assembly, Yul and Vyper tokens with the same holder and supply.
    /// @return tokens The four token addresses, in that order.
    function run() external returns (IQuartetToken[4] memory tokens) {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        address holder = vm.envOr("QUARTET_HOLDER", broadcaster);
        uint256 supply = vm.envOr("QUARTET_SUPPLY", uint256(1_000_000e18));

        tokens[0] = IQuartetToken(address(new QuartetSolidity(holder, supply)));
        tokens[1] = IQuartetToken(address(new QuartetAssembly(holder, supply)));
        bytes memory initcode = bytes.concat(YulBytecode.CREATION, abi.encode(holder, supply));
        address yul;
        // Memory-safe: reads the initcode in place.
        assembly ("memory-safe") {
            yul := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(yul != address(0), "Yul deployment failed");
        tokens[2] = IQuartetToken(yul);
        tokens[3] = IQuartetToken(vm.deployCode("QuartetVyper.vy:QuartetVyper", abi.encode(holder, supply)));
        vm.stopBroadcast();

        string[4] memory names = ["Solidity", "Assembly", "Yul", "Vyper"];
        for (uint256 i; i < 4; ++i) {
            require(tokens[i].balanceOf(holder) == supply, "holder did not receive the supply");
            console.log(
                "%s: %s (%s bytes of runtime code)", names[i], address(tokens[i]), address(tokens[i]).code.length
            );
        }
    }
}
