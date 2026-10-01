// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import {MilestoneCodec} from "../libraries/MilestoneCodec.sol";
import {Milestone} from "../types/StreamTypes.sol";

/// @notice Gas benchmark only: stores the same milestones either in one storage slot each (the naive layout) or
/// packed into an SSTORE2 data contract (the layout `VestingStreams` uses), so `npm run gas:check` can report the
/// measured difference.
contract MilestoneStorageBench {
    mapping(uint256 id => Milestone[]) internal _slots;
    mapping(uint256 id => address) internal _pointers;
    uint256 public nextId = 1;

    function storeInSlots(Milestone[] calldata milestones) external {
        Milestone[] storage stored = _slots[nextId++];
        for (uint256 i; i < milestones.length; ++i) {
            stored.push(milestones[i]);
        }
    }

    function storeViaSstore2(Milestone[] calldata milestones) external {
        _pointers[nextId++] = SSTORE2.write(MilestoneCodec.encode(milestones));
    }

    function sumFromSlots(uint256 id) external view returns (uint256 sum) {
        Milestone[] storage stored = _slots[id];
        for (uint256 i; i < stored.length; ++i) {
            sum += stored[i].amount;
        }
    }

    function sumViaSstore2(uint256 id) external view returns (uint256 sum) {
        Milestone[] memory loaded = MilestoneCodec.decode(SSTORE2.read(_pointers[id]));
        for (uint256 i; i < loaded.length; ++i) {
            sum += loaded[i].amount;
        }
    }
}
