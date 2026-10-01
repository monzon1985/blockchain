// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {DocumentRegistry} from "../../src/documents/DocumentRegistry.sol";
import {IERC1643} from "../../src/interfaces/IERC1643.sol";
import {FundFixture} from "../utils/FundFixture.sol";

contract DocumentRegistryTest is FundFixture {
    bytes32 internal constant PROSPECTUS = "prospectus";
    bytes32 internal constant NAV_POLICY = "nav-policy";
    bytes32 internal constant HASH_V1 = keccak256("prospectus v1");
    bytes32 internal constant HASH_V2 = keccak256("prospectus v2");

    function _set(bytes32 name, string memory uri, bytes32 hash) internal {
        vm.prank(fundAdmin);
        documents.setDocument(name, uri, hash);
    }

    function test_setDocument_storesAnchorsAndEmits() public {
        vm.expectEmit(address(documents));
        emit DocumentRegistry.HashAnchored(HASH_V1, PROSPECTUS, uint64(block.timestamp));
        vm.expectEmit(address(documents));
        emit IERC1643.DocumentUpdated(PROSPECTUS, "ipfs://v1", HASH_V1);
        _set(PROSPECTUS, "ipfs://v1", HASH_V1);

        (string memory uri, bytes32 hash, uint256 modified) = documents.getDocument(PROSPECTUS);
        assertEq(uri, "ipfs://v1");
        assertEq(hash, HASH_V1);
        assertEq(modified, block.timestamp);
        assertEq(documents.anchoredAt(HASH_V1), block.timestamp);
        assertTrue(documents.verifyDocument(PROSPECTUS, HASH_V1));
        assertEq(documents.getAllDocuments().length, 1);
    }

    function test_setDocument_replacementKeepsOriginalAnchor() public {
        _set(PROSPECTUS, "ipfs://v1", HASH_V1);
        uint256 firstAnchor = block.timestamp;
        vm.warp(block.timestamp + 30 days);
        _set(PROSPECTUS, "ipfs://v2", HASH_V2);
        _set(NAV_POLICY, "ipfs://nav", HASH_V1); // re-using a known hash does not re-anchor it
        assertEq(documents.anchoredAt(HASH_V1), firstAnchor);
        assertEq(documents.anchoredAt(HASH_V2), block.timestamp);
        assertFalse(documents.verifyDocument(PROSPECTUS, HASH_V1));
        assertTrue(documents.verifyDocument(PROSPECTUS, HASH_V2));
        assertEq(documents.getAllDocuments().length, 2);
    }

    function test_setDocument_validation() public {
        vm.startPrank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.InvalidDocument.selector, bytes32(0), HASH_V1));
        documents.setDocument(bytes32(0), "x", HASH_V1);
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.InvalidDocument.selector, PROSPECTUS, bytes32(0)));
        documents.setDocument(PROSPECTUS, "x", bytes32(0));
        vm.stopPrank();
    }

    function test_setDocument_restricted() public {
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        documents.setDocument(PROSPECTUS, "x", HASH_V1);
    }

    function test_setDocument_boundedCount() public {
        vm.startPrank(fundAdmin);
        for (uint256 i; i < documents.MAX_DOCUMENTS(); ++i) {
            documents.setDocument(bytes32(i + 1), "u", HASH_V1);
        }
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.TooManyDocuments.selector, uint256(256)));
        documents.setDocument(bytes32(uint256(10_000)), "u", HASH_V1);
        documents.setDocument(bytes32(uint256(1)), "u2", HASH_V2); // updating an existing one still works
        vm.stopPrank();
    }

    function test_removeDocument_swapsLastIntoHole() public {
        _set(PROSPECTUS, "ipfs://v1", HASH_V1);
        _set(NAV_POLICY, "ipfs://nav", HASH_V2);
        _set("kid", "ipfs://kid", keccak256("kid"));

        vm.expectEmit(address(documents));
        emit IERC1643.DocumentRemoved(PROSPECTUS, "ipfs://v1", HASH_V1);
        vm.prank(fundAdmin);
        documents.removeDocument(PROSPECTUS);

        bytes32[] memory names = documents.getAllDocuments();
        assertEq(names.length, 2);
        assertEq(names[0], bytes32("kid"));
        assertEq(names[1], NAV_POLICY);
        (, bytes32 hash,) = documents.getDocument(PROSPECTUS);
        assertEq(hash, bytes32(0));
        assertEq(documents.anchoredAt(HASH_V1), START, "anchor survives removal");

        vm.prank(fundAdmin);
        documents.removeDocument("kid"); // removing the new head, then the last element
        vm.prank(fundAdmin);
        documents.removeDocument(NAV_POLICY);
        assertEq(documents.getAllDocuments().length, 0);
    }

    function test_removeDocument_revertsWhenMissing() public {
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(DocumentRegistry.DocumentNotFound.selector, PROSPECTUS));
        documents.removeDocument(PROSPECTUS);
    }

    function test_verifyDocument_rejectsZeroHash() public view {
        assertFalse(documents.verifyDocument(PROSPECTUS, bytes32(0)));
    }
}
