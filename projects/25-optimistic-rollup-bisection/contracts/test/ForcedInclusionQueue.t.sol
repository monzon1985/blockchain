// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ForcedInclusionQueue} from "../src/ForcedInclusionQueue.sol";
import {IForcedInclusionQueue} from "../src/interfaces/IForcedInclusionQueue.sol";
import {Record} from "../src/lib/Types.sol";
import {RollupSpec} from "../src/lib/RollupSpec.sol";

contract ForcedInclusionQueueTest is Test {
    ForcedInclusionQueue internal queue;
    address internal bridgeAddr = makeAddr("bridge");
    address internal user = makeAddr("user");

    function setUp() public {
        queue = new ForcedInclusionQueue(bridgeAddr, 10);
    }

    function _record(uint256 kind, address from, address to, uint256 amount) internal pure returns (Record memory) {
        return Record({
            kind: kind,
            from: uint256(uint160(from)),
            to: uint256(uint160(to)),
            amount: amount,
            nonce: 0,
            v: 0,
            r: 0,
            s: 0
        });
    }

    function test_enqueue_emitsAndChainsAccumulator() public {
        Record memory r0 = _record(RollupSpec.KIND_DEPOSIT, user, user, 1 ether);
        bytes32 acc0 = keccak256(abi.encode(bytes32(0), keccak256(abi.encode(r0))));
        vm.expectEmit(address(queue));
        emit IForcedInclusionQueue.MessageEnqueued(0, r0, uint64(vm.getBlockNumber()), acc0);
        vm.prank(bridgeAddr);
        assertEq(queue.enqueueDeposit(user, user, 1 ether), 0);

        vm.roll(vm.getBlockNumber() + 3);
        Record memory r1 = _record(RollupSpec.KIND_FORCED_TRANSFER, user, address(7), 5);
        vm.prank(user);
        assertEq(queue.forceTransfer(address(7), 5), 1);
        Record memory r2 = _record(RollupSpec.KIND_FORCED_WITHDRAWAL, user, address(8), 6);
        vm.prank(user);
        assertEq(queue.forceWithdrawal(address(8), 6), 2);

        bytes32 acc1 = keccak256(abi.encode(acc0, queue.recordHash(r1)));
        bytes32 acc2 = keccak256(abi.encode(acc1, queue.recordHash(r2)));
        assertEq(queue.length(), 3);
        assertEq(queue.accumulatorBefore(0), bytes32(0));
        assertEq(queue.accumulatorBefore(1), acc0);
        assertEq(queue.accumulatorBefore(3), acc2);
        assertEq(queue.enqueuedAt(1), vm.getBlockNumber());
        assertEq(queue.deadline(1), vm.getBlockNumber() + 10);
    }

    function test_overdueStrictlyAfterDeadline() public {
        vm.prank(user);
        queue.forceTransfer(address(1), 1);
        uint256 dl = queue.deadline(0);
        vm.roll(dl);
        assertFalse(queue.isOverdue(0));
        vm.roll(dl + 1);
        assertTrue(queue.isOverdue(0));
    }

    function test_revert_onlyBridgeDeposits() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IForcedInclusionQueue.OnlyBridge.selector, user));
        queue.enqueueDeposit(user, user, 1);
    }

    function test_revert_indexOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(IForcedInclusionQueue.IndexOutOfRange.selector, 1, 0));
        queue.accumulatorBefore(1);
        vm.expectRevert(abi.encodeWithSelector(IForcedInclusionQueue.IndexOutOfRange.selector, 0, 0));
        queue.enqueuedAt(0);
        vm.expectRevert(abi.encodeWithSelector(IForcedInclusionQueue.IndexOutOfRange.selector, 0, 0));
        queue.isOverdue(0);
    }

    function test_revert_zeroConstructorParameters() public {
        vm.expectRevert(IForcedInclusionQueue.ZeroParameter.selector);
        new ForcedInclusionQueue(address(0), 10);
        vm.expectRevert(IForcedInclusionQueue.ZeroParameter.selector);
        new ForcedInclusionQueue(bridgeAddr, 0);
    }

    function testFuzz_accumulatorIsAHashChain(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 20));
        bytes32 acc;
        for (uint256 i = 0; i < n; ++i) {
            address to = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            uint256 amount = uint256(keccak256(abi.encode(i, seed)));
            vm.prank(user);
            queue.forceTransfer(to, amount);
            acc = keccak256(
                abi.encode(acc, keccak256(abi.encode(_record(RollupSpec.KIND_FORCED_TRANSFER, user, to, amount))))
            );
            assertEq(queue.accumulatorBefore(i + 1), acc);
        }
    }
}
