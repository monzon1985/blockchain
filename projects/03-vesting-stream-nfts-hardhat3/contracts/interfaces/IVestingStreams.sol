// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CreateParams, Milestone, Shape, Status, Stream} from "../types/StreamTypes.sol";
import {IStreamRenderer} from "./IStreamRenderer.sol";

/// @title IVestingStreams
/// @notice Token vesting streams represented as ERC-721 NFTs. Owning the NFT is owning the right to withdraw.
interface IVestingStreams is IERC4906 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A stream was created and its NFT minted to `recipient`.
    /// @param streamId Id of the stream and of its NFT.
    /// @param sender Account that funded the stream.
    /// @param recipient First owner of the NFT.
    /// @param token Streamed token.
    /// @param shape Unlock curve.
    /// @param depositAmount Tokens escrowed.
    /// @param startTime Vesting start.
    /// @param endTime Time at which everything has vested.
    /// @param cancelable Whether the sender can cancel.
    event StreamCreated(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        IERC20 token,
        Shape shape,
        uint128 depositAmount,
        uint40 startTime,
        uint40 endTime,
        bool cancelable
    );

    /// @notice Vested tokens were paid out.
    /// @param streamId The stream.
    /// @param caller NFT owner or approved operator that triggered the withdrawal.
    /// @param to Receiver of the tokens.
    /// @param amount Tokens paid out.
    event Withdrawn(uint256 indexed streamId, address indexed caller, address indexed to, uint128 amount);

    /// @notice The sender canceled a stream and got the unvested part back.
    /// @param streamId The stream.
    /// @param sender The sender, who received `refunded`.
    /// @param recipient NFT owner at the time of the cancellation.
    /// @param refunded Unvested tokens returned to the sender.
    /// @param withdrawable Vested tokens that remain withdrawable by the NFT owner.
    event Canceled(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint128 refunded,
        uint128 withdrawable
    );

    /// @notice The sender permanently gave up the right to cancel.
    /// @param streamId The stream.
    event CancelabilityRenounced(uint256 indexed streamId);

    /// @notice The `IStreamRecipient` hook of a contract recipient reverted or ran out of gas. The cancellation
    /// went through regardless.
    /// @param streamId The canceled stream.
    /// @param recipient The contract whose hook failed.
    event RecipientHookFailed(uint256 indexed streamId, address indexed recipient);

    /// @notice The metadata renderer was replaced.
    /// @param previousRenderer Old renderer.
    /// @param newRenderer New renderer.
    event RendererUpdated(IStreamRenderer indexed previousRenderer, IStreamRenderer indexed newRenderer);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The NFT recipient is the zero address or this contract (which could never withdraw).
    /// @param recipient Rejected recipient.
    error InvalidRecipient(address recipient);

    /// @notice Withdrawals cannot target the zero address or this contract.
    /// @param to Rejected receiver.
    error InvalidWithdrawalTarget(address to);

    /// @notice A stream must escrow at least one base unit.
    error ZeroDepositAmount();

    /// @notice `startTime` must be non-zero.
    error ZeroStartTime();

    /// @notice A stream must finish vesting in the future, otherwise it is a plain transfer.
    /// @param endTime Requested end time.
    /// @param currentTime `block.timestamp`.
    error EndTimeNotInFuture(uint40 endTime, uint256 currentTime);

    /// @notice Linear schedules need `start < end` and, if set, `start < cliff < end`.
    /// @param startTime Requested start.
    /// @param cliffTime Requested cliff (zero = none).
    /// @param endTime Requested end.
    error InvalidLinearSchedule(uint40 startTime, uint40 cliffTime, uint40 endTime);

    /// @notice A `LinearCliff` stream was given milestones.
    /// @param count Number of milestones supplied.
    error UnexpectedMilestones(uint256 count);

    /// @notice A milestone stream was given a cliff or an explicit end time (the end is the last milestone).
    /// @param cliffTime Supplied cliff.
    /// @param endTime Supplied end.
    error UnexpectedLinearFields(uint40 cliffTime, uint40 endTime);

    /// @notice Milestone count outside `1..MAX_TRANCHES` (tranched) or `1..MAX_SEGMENTS` (segmented).
    /// @param shape Requested shape.
    /// @param count Supplied count.
    /// @param maxCount Maximum for the shape.
    error MilestoneCountOutOfRange(Shape shape, uint256 count, uint256 maxCount);

    /// @notice Milestone timestamps must be strictly increasing and strictly after `startTime`.
    /// @param index Offending milestone.
    /// @param previousTimestamp `startTime` for index 0, otherwise the previous milestone's timestamp.
    /// @param timestamp Offending timestamp.
    error MilestoneNotAfterPrevious(uint256 index, uint40 previousTimestamp, uint40 timestamp);

    /// @notice The deposit of a milestone stream must equal the sum of its milestone amounts.
    /// @param depositAmount Supplied deposit.
    /// @param milestoneSum Sum of milestone amounts.
    error DepositMismatch(uint128 depositAmount, uint256 milestoneSum);

    /// @notice `createBatch` needs at least one stream.
    error EmptyBatch();

    /// @notice The token did not deliver exactly the requested amount (fee-on-transfer, rebasing or otherwise
    /// non-standard token).
    /// @param token The rejected token.
    /// @param expected Amount requested with `transferFrom`.
    /// @param received Actual increase of this contract's balance.
    error UnsupportedToken(IERC20 token, uint256 expected, uint256 received);

    /// @notice No stream with this id was ever created.
    /// @param streamId Unknown id.
    error StreamNotFound(uint256 streamId);

    /// @notice Only the stream's sender can cancel or renounce cancelability.
    /// @param streamId The stream.
    /// @param caller The rejected caller.
    error NotStreamSender(uint256 streamId, address caller);

    /// @notice Only the NFT owner or an approved operator can withdraw.
    /// @param streamId The stream.
    /// @param caller The rejected caller.
    error NotAuthorizedToWithdraw(uint256 streamId, address caller);

    /// @notice The stream was created non-cancelable, its cancelability was renounced, or it is already canceled.
    /// @param streamId The stream.
    error StreamNotCancelable(uint256 streamId);

    /// @notice Everything has vested already, so there is nothing to cancel.
    /// @param streamId The stream.
    error StreamSettled(uint256 streamId);

    /// @notice Withdrawal amounts must be non-zero.
    /// @param streamId The stream.
    error ZeroWithdrawAmount(uint256 streamId);

    /// @notice The requested amount is larger than what has vested and not yet been withdrawn.
    /// @param streamId The stream.
    /// @param requested Requested amount.
    /// @param withdrawable Currently withdrawable amount.
    error WithdrawAmountExceedsWithdrawable(uint256 streamId, uint128 requested, uint128 withdrawable);

    /// @notice `withdrawMax` found nothing to withdraw.
    /// @param streamId The stream.
    error NothingToWithdraw(uint256 streamId);

    /// @notice Cancelling a stream held by a contract needs enough gas to give the recipient hook its full stipend.
    /// @param gasLeft Gas available before the hook call.
    /// @param gasRequired Minimum gas needed.
    error InsufficientGasForHook(uint256 gasLeft, uint256 gasRequired);

    /// @notice The renderer must be a deployed contract.
    /// @param renderer Rejected renderer.
    error InvalidRenderer(address renderer);

    /*//////////////////////////////////////////////////////////////
                            STATE-CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates one stream funded by `msg.sender`.
    /// @param token Token to stream. Fee-on-transfer and rebasing tokens are rejected.
    /// @param params Stream parameters.
    /// @return streamId Id of the new stream and NFT.
    function create(IERC20 token, CreateParams calldata params) external returns (uint256 streamId);

    /// @notice Creates several streams of the same token with a single `transferFrom` of the total deposit.
    /// @param token Token to stream. Fee-on-transfer and rebasing tokens are rejected.
    /// @param params Parameters of each stream.
    /// @return streamIds Ids of the new streams, in input order.
    function createBatch(IERC20 token, CreateParams[] calldata params) external returns (uint256[] memory streamIds);

    /// @notice Withdraws `amount` vested tokens of `streamId` to `to`.
    /// @param streamId The stream.
    /// @param to Receiver of the tokens.
    /// @param amount Tokens to withdraw, at most {withdrawableAmountOf}.
    function withdraw(uint256 streamId, address to, uint128 amount) external;

    /// @notice Withdraws everything currently withdrawable from `streamId` to `to`.
    /// @param streamId The stream.
    /// @param to Receiver of the tokens.
    /// @return amount Tokens withdrawn.
    function withdrawMax(uint256 streamId, address to) external returns (uint128 amount);

    /// @notice Cancels a stream: the unvested part goes back to the sender, the vested part stays withdrawable.
    /// @param streamId The stream.
    /// @return refunded Tokens returned to the sender.
    function cancel(uint256 streamId) external returns (uint128 refunded);

    /// @notice Irreversibly removes the sender's ability to cancel `streamId`.
    /// @param streamId The stream.
    function renounceCancelability(uint256 streamId) external;

    /// @notice Replaces the metadata renderer. Owner only; cannot affect balances or withdrawal rights.
    /// @param newRenderer The new renderer contract.
    function setRenderer(IStreamRenderer newRenderer) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas forwarded to `IStreamRecipient.onStreamCanceled`.
    /// @return The stipend.
    function RECIPIENT_HOOK_GAS() external view returns (uint256);

    /// @notice Maximum number of tranches of a `Tranched` stream.
    /// @return The limit.
    function MAX_TRANCHES() external view returns (uint256);

    /// @notice Maximum number of segments of a `Segmented` stream.
    /// @return The limit.
    function MAX_SEGMENTS() external view returns (uint256);

    /// @notice Id that the next created stream will get. Ids start at 1.
    /// @return The next id.
    function nextStreamId() external view returns (uint256);

    /// @notice Current metadata renderer.
    /// @return The renderer.
    function renderer() external view returns (IStreamRenderer);

    /// @notice Stored state of a stream.
    /// @param streamId The stream.
    /// @return The stream.
    function getStream(uint256 streamId) external view returns (Stream memory);

    /// @notice Tranches or segments of a stream (empty for `LinearCliff`).
    /// @param streamId The stream.
    /// @return The milestones.
    function getMilestones(uint256 streamId) external view returns (Milestone[] memory);

    /// @notice Amount the schedule vests at `timestamp`, ignoring any cancellation.
    /// @param streamId The stream.
    /// @param timestamp Evaluation time.
    /// @return The scheduled amount.
    function scheduledAmountAt(uint256 streamId, uint40 timestamp) external view returns (uint128);

    /// @notice Amount vested so far; frozen at the moment of cancellation for canceled streams.
    /// @param streamId The stream.
    /// @return The streamed amount.
    function streamedAmountOf(uint256 streamId) external view returns (uint128);

    /// @notice Streamed amount not yet withdrawn.
    /// @param streamId The stream.
    /// @return The withdrawable amount.
    function withdrawableAmountOf(uint256 streamId) external view returns (uint128);

    /// @notice Amount the sender would get back by canceling now (zero if the stream cannot be canceled).
    /// @param streamId The stream.
    /// @return The refundable amount.
    function refundableAmountOf(uint256 streamId) external view returns (uint128);

    /// @notice Lifecycle status of a stream.
    /// @param streamId The stream.
    /// @return The status.
    function statusOf(uint256 streamId) external view returns (Status);
}
