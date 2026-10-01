// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {YulBytecode} from "../../src/generated/YulBytecode.sol";
import {QuartetBase} from "../utils/QuartetBase.sol";
import {Impl} from "../utils/RevertClassifier.sol";

/// @title YulBytecodeTest
/// @notice Integrity of the committed Yul bytecode. `scripts/build-yul.mjs --check` proves the constants
///         match what npm solc produces; these tests add that (1) forge's native solc build of the same
///         source is byte-identical, and (2) the deployed runtime is exactly the emitted runtime with the
///         four immutables filled in.
contract YulBytecodeTest is QuartetBase {
    function test_CommittedCreationCodeEqualsNativeSolcBuild() public view {
        // Yul artifacts have `"abi": null`, which vm.getCode rejects, so read the artifact JSON directly.
        string memory artifact = vm.readFile("out/QuartetYul.yul/QuartetYul.json");
        assertEq(YulBytecode.CREATION, vm.parseJsonBytes(artifact, ".bytecode.object"));
        assertEq(YulBytecode.RUNTIME, vm.parseJsonBytes(artifact, ".deployedBytecode.object"));
    }

    function test_DeployedRuntimeMatchesEmittedRuntimeOutsideImmutables() public {
        address token = address(_deploy(Impl.Yul, address(this), SUPPLY));
        bytes memory deployed = token.code;
        bytes memory emitted = YulBytecode.RUNTIME;
        assertEq(deployed.length, emitted.length);
        assertEq(deployed.length, YulBytecode.RUNTIME_SIZE);
        // Four PUSH32 immutables of 32 bytes each (several occurrences): every differing byte must lie in
        // a zero-filled placeholder of the emitted code.
        uint256 differing;
        for (uint256 i; i < deployed.length; ++i) {
            if (deployed[i] != emitted[i]) {
                assertEq(uint8(emitted[i]), 0, "difference outside an immutable placeholder");
                ++differing;
            }
        }
        assertGt(differing, 0);
    }
}
