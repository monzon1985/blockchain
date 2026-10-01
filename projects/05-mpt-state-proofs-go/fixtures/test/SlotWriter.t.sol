// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SlotWriter} from "../src/SlotWriter.sol";

/// @notice The subset of Foundry's cheatcode interface these tests use, declared here so the
///         fixture project needs no dependency.
interface Vm {
    function load(address target, bytes32 slot) external view returns (bytes32 data);
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData)
        external;
}

/// @notice Unit tests for the SlotWriter fixture: the values the Go integration tests
///         recompute off-chain must be exactly what the contract stores.
contract SlotWriterTest {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    SlotWriter internal writer;

    event SlotWritten(bytes32 indexed slot, bytes32 value);
    event SlotsCleared(uint256 indexed seed, uint256 from, uint256 to);

    function setUp() public {
        writer = new SlotWriter();
    }

    function test_SlotAndValueFormulas() public view {
        bytes32 slot = writer.slotOf(7, 3);
        require(slot == keccak256(abi.encode(uint256(7), uint256(3))), "slot formula");
        bytes32 value = writer.valueOf(slot, 3);
        require(uint256(value) == uint256(keccak256(abi.encode(slot))) >> 24, "value formula");
        // Index 31 keeps a single byte; index 32 wraps around to a full word.
        require(uint256(writer.valueOf(slot, 31)) < 256, "one byte at i = 31");
        require(writer.valueOf(slot, 32) == keccak256(abi.encode(slot)), "full word at i = 32");
    }

    function test_WriteStoresEveryEntry() public {
        writer.write(42, 64);
        for (uint256 i; i < 64; ++i) {
            bytes32 slot = writer.slotOf(42, i);
            bytes32 stored = VM.load(address(writer), slot);
            require(stored == writer.valueOf(slot, i), "stored value");
            require(stored != bytes32(0), "values are never zero");
        }
        require(VM.load(address(writer), writer.slotOf(42, 64)) == bytes32(0), "entry 64 untouched");
    }

    function test_WriteEmitsSlotWritten() public {
        bytes32 slot = writer.slotOf(1, 0);
        VM.expectEmit(true, false, false, true);
        emit SlotWritten(slot, writer.valueOf(slot, 0));
        writer.write(1, 1);
    }

    function test_ClearZeroesTheRange() public {
        writer.write(5, 10);
        VM.expectEmit(true, false, false, true);
        emit SlotsCleared(5, 2, 6);
        writer.clear(5, 2, 6);
        for (uint256 i; i < 10; ++i) {
            bytes32 stored = VM.load(address(writer), writer.slotOf(5, i));
            require((stored == bytes32(0)) == (i >= 2 && i < 6), "only [2, 6) is cleared");
        }
    }

    function test_RevertWhen_WriteBatchTooLarge() public {
        VM.expectRevert(abi.encodeWithSelector(SlotWriter.BatchTooLarge.selector, 257));
        writer.write(1, 257);
    }

    function test_RevertWhen_ClearRangeEmpty() public {
        VM.expectRevert(abi.encodeWithSelector(SlotWriter.EmptyRange.selector, 3, 3));
        writer.clear(1, 3, 3);
    }

    function test_RevertWhen_ClearRangeInverted() public {
        VM.expectRevert(abi.encodeWithSelector(SlotWriter.EmptyRange.selector, 4, 2));
        writer.clear(1, 4, 2);
    }

    function test_RevertWhen_ClearBatchTooLarge() public {
        VM.expectRevert(abi.encodeWithSelector(SlotWriter.BatchTooLarge.selector, 300));
        writer.clear(1, 0, 300);
    }

    function testFuzz_ValueIsNeverZero(bytes32 slot, uint256 i) public view {
        require(writer.valueOf(slot, i) != bytes32(0), "non-zero");
    }
}
