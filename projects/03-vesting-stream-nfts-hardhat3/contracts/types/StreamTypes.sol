// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The three unlock curves a stream can follow.
/// @dev `LinearCliff`: nothing is withdrawable before the cliff, then the amount grows linearly from `startTime`
/// to `endTime`. `Tranched`: step function, each tranche unlocks in full at its timestamp. `Segmented`:
/// piecewise-linear curve, each segment streams its amount linearly between the previous milestone and its own
/// timestamp.
enum Shape {
    LinearCliff,
    Tranched,
    Segmented
}

/// @notice Lifecycle of a stream, derived from its stored state and `block.timestamp`.
/// @dev `Pending`: before `startTime`. `Streaming`: between start and full vesting. `Settled`: everything has
/// vested but not everything was withdrawn. `Canceled`: canceled with an unwithdrawn balance left for the
/// recipient. `Depleted`: nothing is left in the contract for this stream.
enum Status {
    Pending,
    Streaming,
    Settled,
    Canceled,
    Depleted
}

/// @notice A tranche (for `Tranched`) or a segment end-point (for `Segmented`).
/// @param amount Tokens released by this milestone.
/// @param timestamp Unix time at which the milestone is fully vested.
struct Milestone {
    uint128 amount;
    uint40 timestamp;
}

/// @notice Arguments to create one stream. Fields that do not apply to the chosen shape must be zero.
/// @param recipient First owner of the stream NFT, i.e. the first holder of the withdrawal right.
/// @param shape Unlock curve.
/// @param cancelable Whether the sender may cancel and reclaim the unvested part.
/// @param startTime Time at which vesting starts. May be in the past (backdated grants).
/// @param cliffTime `LinearCliff` only: nothing is withdrawable before it. Zero means "no cliff".
/// @param endTime `LinearCliff` only: time at which everything has vested. Zero for the milestone shapes.
/// @param depositAmount Tokens escrowed. For the milestone shapes it must equal the sum of milestone amounts.
/// @param milestones `Tranched` (1..32) or `Segmented` (1..16) milestones with strictly increasing timestamps.
struct CreateParams {
    address recipient;
    Shape shape;
    bool cancelable;
    uint40 startTime;
    uint40 cliffTime;
    uint40 endTime;
    uint128 depositAmount;
    Milestone[] milestones;
}

/// @notice Stored state of a stream, packed into four storage slots.
/// @dev Slot 0: sender, startTime, endTime, shape, cancelable (256 bits). Slot 1: token, cliffTime, canceledAt,
/// milestoneCount, canceled (256 bits). Slot 2: depositAmount, withdrawnAmount. Slot 3: refundedAmount.
/// Milestones live in an SSTORE2 data contract referenced by a separate mapping.
/// @param sender Account that funded the stream and may cancel it.
/// @param startTime Vesting start.
/// @param endTime Time at which the whole deposit has vested (last milestone for the milestone shapes).
/// @param shape Unlock curve.
/// @param cancelable False once canceled, renounced, or if created non-cancelable.
/// @param token Streamed ERC-20.
/// @param cliffTime `LinearCliff` cliff (zero if none).
/// @param canceledAt Time of cancellation, zero if never canceled.
/// @param milestoneCount Number of milestones (zero for `LinearCliff`).
/// @param canceled True once the sender canceled the stream.
/// @param depositAmount Tokens escrowed at creation.
/// @param withdrawnAmount Tokens paid out to the NFT owner (or its chosen `to`) so far.
/// @param refundedAmount Tokens returned to the sender on cancel.
struct Stream {
    address sender;
    uint40 startTime;
    uint40 endTime;
    Shape shape;
    bool cancelable;
    IERC20 token;
    uint40 cliffTime;
    uint40 canceledAt;
    uint8 milestoneCount;
    bool canceled;
    uint128 depositAmount;
    uint128 withdrawnAmount;
    uint128 refundedAmount;
}
