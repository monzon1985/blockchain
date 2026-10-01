// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DIAMOND_STORAGE_LOCATION} from "../../src/diamond/libraries/LibDiamond.sol";
import {OWNERSHIP_STORAGE_LOCATION} from "../../src/diamond/libraries/LibOwnership.sol";
import {DIAMOND_REGISTRY_STORAGE_LOCATION} from "../../src/diamond/libraries/LibRegistryDiamond.sol";
import {REGISTRY_NAMESPACE_ID, REGISTRY_STORAGE_LOCATION} from "../../src/uups/RegistryNamespace.sol";
import {SubscriptionRegistryV3} from "../../src/uups/v3/SubscriptionRegistryV3.sol";
import {LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Cross-checks the `erc7201` builtin (Solidity 0.8.35+) against the ERC-7201 formula written out by
///         hand, against the value published in the EIP, and against the slots OpenZeppelin uses. The same values
///         are pinned a third time by `layout-diff`'s Rust unit tests, and the layout gate checks every accessor's
///         slot, OpenZeppelin's private constants included, by reading them from the compiled AST.
contract Erc7201FormulaTest is LabBase {
    /// @dev keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff)), exactly as in ERC-7201.
    function formula(bytes memory id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(uint256(keccak256(id)) - 1))) & ~uint256(0xff);
    }

    function test_eipExampleValue() public pure {
        // ERC-7201 "Rationale" example for the namespace id "example.main".
        assertEq(erc7201("example.main"), 0x183a6125c38840424c4a85fa12bab2ab606c4b6d0e7cc73c0c06ba5300eab500);
        assertEq(formula("example.main"), erc7201("example.main"));
    }

    function test_labNamespaces_builtinEqualsFormula() public pure {
        assertEq(REGISTRY_STORAGE_LOCATION, formula(bytes(REGISTRY_NAMESPACE_ID)));
        assertEq(DIAMOND_STORAGE_LOCATION, formula("upgradelab.storage.Diamond"));
        assertEq(OWNERSHIP_STORAGE_LOCATION, formula("upgradelab.storage.DiamondOwnership"));
        assertEq(DIAMOND_REGISTRY_STORAGE_LOCATION, formula("upgradelab.storage.DiamondRegistry"));
    }

    function test_labNamespaces_pinnedValues() public pure {
        // Pinned so an accidental edit of an id string cannot silently move a namespace.
        assertEq(REGISTRY_STORAGE_LOCATION, 0xb4bb17120a8e44106124fda25af4145500ca9108cc41e1baa7fd32e47222d800);
        assertEq(DIAMOND_STORAGE_LOCATION, 0x9d0b67c2da79ec3af17c43bb85ef3b6146c19eb61c4203de6bfaed592a4f0100);
        assertEq(OWNERSHIP_STORAGE_LOCATION, 0xae3a6b50b5fc26224cb55a9b0086ac3427c5c05685780b3dc3016495a458ad00);
        assertEq(DIAMOND_REGISTRY_STORAGE_LOCATION, 0xd98e97910f38ac455dd0f5c3a6749a71611cf333ff2249e8b62580866e5fba00);
    }

    function test_openZeppelinConstants_matchBuiltinAndFormula() public pure {
        // Literals copied by hand from the OpenZeppelin Contracts(-Upgradeable) 5.7.0 sources (the constants are
        // private, so no test can import them; `test_openZeppelinParentsWriteTheProbedSlots` observes the real ones).
        _check("openzeppelin.storage.Initializable", 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00);
        _check("openzeppelin.storage.Ownable", 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300);
        _check("openzeppelin.storage.Ownable2Step", 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00);
        _check("openzeppelin.storage.Pausable", 0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300);
        _check("openzeppelin.storage.AccessManaged", 0xf3177357ab46d8af007ab3fdb9af81da189e1068fefdc0073dca88a2cab40a00);
        _check(
            "openzeppelin.storage.ReentrancyGuard", 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00
        );
        assertEq(
            erc7201("openzeppelin.storage.Ownable"), 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300
        );
    }

    function _check(bytes memory id, uint256 ozConstant) private pure {
        assertEq(formula(id), ozConstant);
    }

    /// @notice Differential test of the compiler builtin that computes every lab location: for arbitrary ids
    ///         (evaluated at run time, not folded at compile time) `erc7201(id)` equals the formula written out by
    ///         hand, is 256-slot aligned, and is never the naive keccak256(id) slot of pre-ERC-7201 code.
    function testFuzz_builtinEqualsTheFormula(string calldata id) public pure {
        uint256 slot = erc7201(id);
        assertEq(slot, formula(bytes(id)));
        assertEq(slot & 0xff, 0);
        assertTrue(slot != uint256(keccak256(bytes(id))));
    }

    /// @notice The OpenZeppelin parents really write at the bases the probes assume (`erc7201("openzeppelin.storage.*")`):
    ///         observed with `vm.record` on a fresh V3 proxy, not compared with copied literals.
    function test_openZeppelinParentsWriteTheProbedSlots() public {
        AccessManager manager = new AccessManager(governance);
        MockERC20 token = _newToken();
        SubscriptionRegistryV3 impl = new SubscriptionRegistryV3();
        vm.record();
        address proxy = address(
            new ERC1967Proxy(
                address(impl),
                abi.encodeCall(SubscriptionRegistryV3.initialize, (owner, address(manager), token, treasury))
            )
        );
        (, bytes32[] memory writes) = vm.accesses(proxy);
        assertTrue(_contains(writes, bytes32(erc7201("openzeppelin.storage.Initializable"))), "Initializable");
        assertTrue(_contains(writes, bytes32(erc7201("openzeppelin.storage.Ownable"))), "Ownable");
        assertTrue(_contains(writes, bytes32(erc7201("openzeppelin.storage.AccessManaged"))), "AccessManaged");

        vm.record();
        vm.startPrank(owner);
        SubscriptionRegistryV3(proxy).pause();
        SubscriptionRegistryV3(proxy).transferOwnership(treasury);
        vm.stopPrank();
        (, writes) = vm.accesses(proxy);
        assertTrue(_contains(writes, bytes32(erc7201("openzeppelin.storage.Pausable"))), "Pausable");
        assertTrue(_contains(writes, bytes32(erc7201("openzeppelin.storage.Ownable2Step"))), "Ownable2Step");
    }

    function _contains(bytes32[] memory list, bytes32 item) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == item) return true;
        }
        return false;
    }
}
