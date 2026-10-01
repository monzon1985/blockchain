// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IStreamRecipient} from "../interfaces/IStreamRecipient.sol";
import {IVestingStreams} from "../interfaces/IVestingStreams.sol";
import {ITokenReceiver} from "./HookedToken.sol";

/// @notice Records every hook call and the gas it was given, packed into three slots so the bookkeeping fits
/// comfortably inside the 100k stipend.
contract RecordingRecipient is IStreamRecipient {
    address public lastSender;
    uint32 public calls;
    uint64 public gasAtEntry;
    uint128 public lastRefunded;
    uint128 public lastWithdrawable;
    uint256 public lastStreamId;

    function onStreamCanceled(uint256 streamId, address sender, uint128 refunded, uint128 withdrawable) external {
        uint256 gasLeft = gasleft();
        lastSender = sender;
        calls += 1;
        gasAtEntry = uint64(gasLeft);
        lastRefunded = refunded;
        lastWithdrawable = withdrawable;
        lastStreamId = streamId;
    }

    function withdrawMax(IVestingStreams streams, uint256 streamId, address to) external returns (uint128) {
        return streams.withdrawMax(streamId, to);
    }
}

/// @notice Hook that always reverts with a reason string.
contract RevertingRecipient is IStreamRecipient {
    function onStreamCanceled(uint256, address, uint128, uint128) external pure {
        revert("hook says no");
    }
}

/// @notice Hook that burns every unit of gas it receives.
contract GasGuzzlerRecipient is IStreamRecipient {
    uint256 public counter;

    function onStreamCanceled(uint256, address, uint128, uint128) external {
        while (true) {
            ++counter;
        }
    }
}

/// @notice Hook that reverts with 150 kB of revert data, trying to make the caller pay to copy it.
contract ReturnBombRecipient is IStreamRecipient {
    function onStreamCanceled(uint256, address, uint128, uint128) external pure {
        assembly ("memory-safe") {
            revert(0, 150000)
        }
    }
}

/// @notice Contract that tries to re-enter the vesting contract from the cancel hook and from token callbacks, and
/// counts how many re-entrant calls succeeded. Used as NFT owner and/or as stream sender.
contract ReentrantActor is IStreamRecipient, ITokenReceiver {
    IVestingStreams public immutable streams;
    uint256 public targetStreamId;
    uint256 public attempts;
    uint256 public successes;

    constructor(IVestingStreams streams_) {
        streams = streams_;
    }

    function setTarget(uint256 streamId) external {
        targetStreamId = streamId;
    }

    function onStreamCanceled(uint256, address, uint128, uint128) external {
        _reenter();
    }

    function onTokenReceived(address, uint256) external {
        _reenter();
    }

    /// @notice Lets tests drive the actor as a normal account.
    function execute(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function _reenter() private {
        uint256 id = targetStreamId;
        if (id == 0) return;
        ++attempts;
        try streams.withdrawMax(id, address(this)) {
            ++successes;
        } catch {}
        try streams.cancel(id) {
            ++successes;
        } catch {}
    }
}
