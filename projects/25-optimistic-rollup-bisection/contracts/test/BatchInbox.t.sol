// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {SystemFixture} from "./utils/SystemFixture.sol";
import {BatchInbox} from "../src/BatchInbox.sol";
import {IBatchInbox} from "../src/interfaces/IBatchInbox.sol";
import {IForcedInclusionQueue} from "../src/interfaces/IForcedInclusionQueue.sol";
import {Record} from "../src/lib/Types.sol";
import {RollupSpec} from "../src/lib/RollupSpec.sol";

contract BatchInboxTest is SystemFixture {
    address internal user = makeAddr("user");

    function setUp() public override {
        super.setUp();
        vm.deal(user, 100 ether);
    }

    function _deposit(uint256 amount) internal returns (Record memory r) {
        vm.prank(user);
        bridge.deposit{value: amount}(user);
        r = Record({
            kind: RollupSpec.KIND_DEPOSIT,
            from: uint256(uint160(user)),
            to: uint256(uint160(user)),
            amount: amount,
            nonce: 0,
            v: 0,
            r: 0,
            s: 0
        });
    }

    function _forced(uint256 amount) internal returns (Record memory r) {
        vm.prank(user);
        queue.forceTransfer(address(0xbeef), amount);
        r = Record({
            kind: RollupSpec.KIND_FORCED_TRANSFER,
            from: uint256(uint160(user)),
            to: uint256(uint160(address(0xbeef))),
            amount: amount,
            nonce: 0,
            v: 0,
            r: 0,
            s: 0
        });
    }

    function _one(Record memory r) internal pure returns (Record[] memory a) {
        a = new Record[](1);
        a[0] = r;
    }

    function _tx(uint256 seed) internal pure returns (bytes memory) {
        return abi.encode(
            Record({
                kind: RollupSpec.KIND_TRANSFER, from: seed, to: seed + 1, amount: seed + 2, nonce: 0, v: 27, r: 1, s: 2
            })
        );
    }

    function test_submitBatch_commitsToTheExactTape() public {
        Record memory dep = _deposit(1 ether);
        bytes memory txData = bytes.concat(_tx(1), _tx(2));
        bytes memory tape = bytes.concat(bytes32(uint256(1)), abi.encode(dep), txData);

        vm.expectEmit(address(inbox));
        emit IBatchInbox.BatchAppended(1, keccak256(tape), uint32(tape.length / 32), 0, 1, false, txData);
        vm.prank(sequencer);
        assertEq(inbox.submitBatch(txData, _one(dep)), 1);

        IBatchInbox.Batch memory b = inbox.batch(1);
        assertEq(b.tapeHash, keccak256(tape));
        assertEq(b.tapeSize, 1 + 8 + 16);
        assertEq(b.queueStart, 0);
        assertEq(b.queueEnd, 1);
        assertEq(b.l1Block, vm.getBlockNumber());
        assertFalse(b.forced);
        assertEq(inbox.queueCursor(), 1);
        assertEq(inbox.batchCount(), 1);
    }

    function test_emptyBatchTapeIsTheHeaderWord() public {
        _postEmptyBatch();
        assertEq(inbox.batch(1).tapeHash, keccak256(abi.encode(uint256(0))));
        assertEq(inbox.batch(1).tapeSize, 1);
    }

    function test_forcedInclusion_sequencerCannotSkipOverdueMessages() public {
        Record memory f = _forced(5);
        // Within the window the sequencer may still leave it out.
        vm.roll(vm.getBlockNumber() + INCLUSION_WINDOW);
        _postEmptyBatch();
        // One block later the message is overdue: an empty batch is refused...
        vm.roll(vm.getBlockNumber() + 1);
        uint256 dl = queue.deadline(0);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.ForcedInclusionViolated.selector, 0, dl));
        inbox.submitBatch("", new Record[](0));
        // ...and a batch that carries it is accepted.
        vm.prank(sequencer);
        inbox.submitBatch("", _one(f));
        assertEq(inbox.queueCursor(), 1);
    }

    function test_forceBatch_escapeHatch() public {
        Record memory f = _forced(5);
        vm.expectRevert(IBatchInbox.NothingOverdue.selector);
        inbox.forceBatch(_one(f));

        vm.roll(vm.getBlockNumber() + INCLUSION_WINDOW + 1);
        // Leaving the overdue message out of a forced batch is not allowed either.
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.ForcedInclusionViolated.selector, 0, queue.deadline(0)));
        inbox.forceBatch(new Record[](0));

        vm.prank(user);
        uint256 epoch = inbox.forceBatch(_one(f));
        IBatchInbox.Batch memory b = inbox.batch(epoch);
        assertTrue(b.forced);
        assertEq(b.tapeHash, keccak256(bytes.concat(bytes32(uint256(1)), abi.encode(f))));
        vm.expectRevert(IBatchInbox.NothingOverdue.selector);
        inbox.forceBatch(new Record[](0));
    }

    function test_forcedInclusion_capAllowsBacklog() public {
        uint256 n = inbox.MAX_QUEUE_PER_BATCH() + 1;
        Record[] memory all = new Record[](n);
        for (uint256 i = 0; i < n; ++i) {
            all[i] = _forced(i);
        }
        vm.roll(vm.getBlockNumber() + INCLUSION_WINDOW + 1);
        Record[] memory first = new Record[](n - 1);
        for (uint256 i = 0; i < n - 1; ++i) {
            first[i] = all[i];
        }
        vm.prank(sequencer);
        inbox.submitBatch("", first); // full batch: the 33rd overdue message may wait
        uint256 dl = queue.deadline(n - 1);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.ForcedInclusionViolated.selector, n - 1, dl));
        inbox.submitBatch("", new Record[](0));
        inbox.forceBatch(_one(all[n - 1]));
        assertEq(inbox.queueCursor(), n);
    }

    function test_revert_onlySequencer() public {
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.OnlySequencer.selector, address(this)));
        inbox.submitBatch("", new Record[](0));
    }

    function test_revert_invalidTxData() public {
        vm.startPrank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.InvalidTxData.selector, 32));
        inbox.submitBatch(new bytes(32), new Record[](0));
        uint256 tooLong = (inbox.MAX_SEQUENCED_TXS() + 1) * RollupSpec.RECORD_BYTES;
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.InvalidTxData.selector, tooLong));
        inbox.submitBatch(new bytes(tooLong), new Record[](0));
        vm.stopPrank();
    }

    function test_revert_tooManyQueueRecords() public {
        uint256 max = inbox.MAX_QUEUE_PER_BATCH();
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.TooManyQueueRecords.selector, max + 1, max));
        inbox.submitBatch("", new Record[](max + 1));
    }

    function test_revert_queueRangeOutOfBounds() public {
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.QueueRangeOutOfBounds.selector, 1, 0));
        inbox.submitBatch("", new Record[](1));
    }

    function test_revert_queueRecordsMismatch() public {
        Record memory dep = _deposit(1 ether);
        dep.amount = 2 ether; // lie about the deposit
        bytes32 computed = keccak256(abi.encode(bytes32(0), keccak256(abi.encode(dep))));
        bytes32 expected = queue.accumulatorBefore(1);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.QueueRecordsMismatch.selector, expected, computed));
        inbox.submitBatch("", _one(dep));
    }

    function test_setSequencer_ownerOnly() public {
        address next = makeAddr("next");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        inbox.setSequencer(next);
        vm.prank(owner);
        vm.expectRevert(IBatchInbox.ZeroParameter.selector);
        inbox.setSequencer(address(0));
        vm.expectEmit(address(inbox));
        emit IBatchInbox.SequencerUpdated(sequencer, next);
        vm.prank(owner);
        inbox.setSequencer(next);
        assertEq(inbox.sequencer(), next);
    }

    function test_ownershipIsTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        inbox.transferOwnership(newOwner);
        assertEq(inbox.owner(), owner);
        vm.prank(newOwner);
        inbox.acceptOwnership();
        assertEq(inbox.owner(), newOwner);
    }

    function test_revert_unknownEpoch() public {
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.UnknownEpoch.selector, 0));
        inbox.batch(0);
        vm.expectRevert(abi.encodeWithSelector(IBatchInbox.UnknownEpoch.selector, 1));
        inbox.batch(1);
    }

    function test_revert_constructorZeroParameters() public {
        vm.expectRevert(IBatchInbox.ZeroParameter.selector);
        new BatchInbox(IForcedInclusionQueue(address(0)), owner, sequencer);
        vm.expectRevert(IBatchInbox.ZeroParameter.selector);
        new BatchInbox(queue, owner, address(0));
    }

    function testFuzz_tapeHashMatchesReference(uint8 nQueue, uint8 nTx, uint256 seed) public {
        nQueue = uint8(bound(nQueue, 0, inbox.MAX_QUEUE_PER_BATCH()));
        nTx = uint8(bound(nTx, 0, inbox.MAX_SEQUENCED_TXS()));
        seed = bound(seed, 0, type(uint128).max);
        Record[] memory recs = new Record[](nQueue);
        bytes memory encodedRecs;
        for (uint256 i = 0; i < nQueue; ++i) {
            recs[i] = _deposit(1 + (seed % 1000) + i);
            encodedRecs = bytes.concat(encodedRecs, abi.encode(recs[i]));
        }
        bytes memory txData;
        for (uint256 i = 0; i < nTx; ++i) {
            txData = bytes.concat(txData, _tx(seed + i));
        }
        vm.prank(sequencer);
        uint256 epoch = inbox.submitBatch(txData, recs);
        bytes memory tape = bytes.concat(bytes32(uint256(nQueue)), encodedRecs, txData);
        assertEq(inbox.batch(epoch).tapeHash, keccak256(tape));
        assertEq(inbox.batch(epoch).tapeSize, tape.length / 32);
    }
}
