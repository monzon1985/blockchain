// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";

import {HeaderStore} from "../../src/settlement/proof/HeaderStore.sol";
import {HeaderBuilder} from "../utils/HeaderBuilder.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";

contract HeaderStoreTest is IntentTestBase {
    bytes internal genesis;
    bytes internal child;

    function setUp() public override {
        super.setUp();
        genesis = HeaderBuilder.encode(bytes32(0), keccak256("state-10"), 10, 1_000);
        child = HeaderBuilder.encode(keccak256(genesis), keccak256("state-11"), 11, 1_012);
        vm.chainId(ORIGIN);
    }

    function test_submitHeader_storesParsedFields() public {
        vm.expectEmit(address(headers));
        emit HeaderStore.HeaderStored(DEST, 11, keccak256(child), keccak256("state-11"), 1_012, false);
        vm.prank(headerRelayer);
        headers.submitHeader(DEST, child);
        HeaderStore.StoredHeader memory stored = headers.header(DEST, 11);
        assertEq(stored.blockHash, keccak256(child));
        assertEq(stored.stateRoot, keccak256("state-11"));
        assertEq(stored.timestamp, 1_012);
        (bytes32 root, uint64 timestamp) = headers.stateRootAt(DEST, 11);
        assertEq(root, keccak256("state-11"));
        assertEq(timestamp, 1_012);
    }

    function test_submitHeader_isIdempotentButImmutable() public {
        vm.startPrank(headerRelayer);
        headers.submitHeader(DEST, child);
        headers.submitHeader(DEST, child); // same header: no-op
        bytes memory conflicting = HeaderBuilder.encode(keccak256(genesis), keccak256("forged"), 11, 1_012);
        vm.expectRevert(
            abi.encodeWithSelector(
                HeaderStore.HeaderConflict.selector, DEST, 11, keccak256(child), keccak256(conflicting)
            )
        );
        headers.submitHeader(DEST, conflicting);
        vm.stopPrank();
    }

    function test_submitHeader_isRestricted() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        headers.submitHeader(DEST, child);
    }

    function test_submitHeader_rejectsLocalChain() public {
        vm.prank(headerRelayer);
        vm.expectRevert(HeaderStore.LocalChain.selector);
        headers.submitHeader(ORIGIN, child);
    }

    function test_submitHeader_rejectsTimestampBeyond64Bits() public {
        bytes memory header = HeaderBuilder.encode(bytes32(0), bytes32(0), 1, uint256(type(uint64).max) + 1);
        vm.prank(headerRelayer);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, uint256(type(uint64).max) + 1)
        );
        headers.submitHeader(DEST, header);
    }

    function test_submitHeader_rejectsMalformedRlp() public {
        vm.prank(headerRelayer);
        vm.expectRevert();
        headers.submitHeader(DEST, hex"c3010203ff");
    }

    function test_stateRootAt_revertsForUnknownHeader() public {
        vm.expectRevert(abi.encodeWithSelector(HeaderStore.UnknownHeader.selector, DEST, 99));
        headers.stateRootAt(DEST, 99);
    }

    function test_submitAncestor_isPermissionlessThroughParentHash() public {
        vm.prank(headerRelayer);
        headers.submitHeader(DEST, child);
        vm.expectEmit(address(headers));
        emit HeaderStore.HeaderStored(DEST, 10, keccak256(genesis), keccak256("state-10"), 1_000, true);
        vm.prank(rival);
        headers.submitAncestor(DEST, 11, child, genesis);
        assertEq(headers.header(DEST, 10).blockHash, keccak256(genesis));
    }

    function test_submitAncestor_rejectsUnknownChild() public {
        vm.expectRevert(abi.encodeWithSelector(HeaderStore.UnknownHeader.selector, DEST, 11));
        headers.submitAncestor(DEST, 11, child, genesis);
    }

    function test_submitAncestor_rejectsWrongChildRlp() public {
        vm.prank(headerRelayer);
        headers.submitHeader(DEST, child);
        vm.expectRevert(
            abi.encodeWithSelector(HeaderStore.ChildHashMismatch.selector, keccak256(child), keccak256(genesis))
        );
        headers.submitAncestor(DEST, 11, genesis, genesis);
    }

    function test_submitAncestor_rejectsNonParent() public {
        vm.prank(headerRelayer);
        headers.submitHeader(DEST, child);
        bytes memory impostor = HeaderBuilder.encode(bytes32(0), keccak256("forged"), 10, 1_000);
        vm.expectRevert(
            abi.encodeWithSelector(HeaderStore.ParentHashMismatch.selector, keccak256(genesis), keccak256(impostor))
        );
        headers.submitAncestor(DEST, 11, child, impostor);
    }
}
