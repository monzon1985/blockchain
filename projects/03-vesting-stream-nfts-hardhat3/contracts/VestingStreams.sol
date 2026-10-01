// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import {IStreamRecipient} from "./interfaces/IStreamRecipient.sol";
import {IStreamRenderer} from "./interfaces/IStreamRenderer.sol";
import {IVestingStreams} from "./interfaces/IVestingStreams.sol";
import {MilestoneCodec} from "./libraries/MilestoneCodec.sol";
import {StreamMath} from "./libraries/StreamMath.sol";
import {CreateParams, Milestone, Shape, Status, Stream} from "./types/StreamTypes.sol";

/// @title VestingStreams
/// @notice Escrows ERC-20 tokens and releases them along a linear-cliff, tranched or piecewise-linear schedule.
/// Every stream is an ERC-721: whoever owns (or is approved for) the NFT can withdraw what has vested.
/// @dev Value conservation per stream: `depositAmount == withdrawnAmount + refundedAmount + (tokens still held)`,
/// and the sum of tokens still held over all streams of a token never exceeds this contract's balance of it.
/// Both are enforced by the stateful invariant suite in `test/solidity/invariant/`.
/// The owner can only replace the metadata renderer; it has no power over escrowed tokens.
contract VestingStreams is IVestingStreams, ERC721, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVestingStreams
    uint256 public constant override RECIPIENT_HOOK_GAS = 100_000;

    /// @inheritdoc IVestingStreams
    uint256 public constant override MAX_TRANCHES = 32;

    /// @inheritdoc IVestingStreams
    uint256 public constant override MAX_SEGMENTS = 16;

    /// @notice Gas kept aside, on top of the 64/63-scaled stipend, for the hook call itself (address access,
    /// calldata encoding, memory expansion), so that the hook is guaranteed to receive its full stipend.
    uint256 internal constant HOOK_CALL_OVERHEAD = 5000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVestingStreams
    uint256 public override nextStreamId = 1;

    /// @inheritdoc IVestingStreams
    IStreamRenderer public override renderer;

    /// @notice Stream state by id.
    mapping(uint256 streamId => Stream) internal _streams;

    /// @notice SSTORE2 data contract holding the packed milestones of a `Tranched` or `Segmented` stream.
    mapping(uint256 streamId => address pointer) internal _milestonePointers;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param initialRenderer Metadata renderer.
    /// @param initialOwner Account allowed to replace the renderer (two-step transferable).
    constructor(IStreamRenderer initialRenderer, address initialOwner)
        ERC721("Vesting Streams", "VEST")
        Ownable(initialOwner)
    {
        _setRenderer(initialRenderer);
    }

    /*//////////////////////////////////////////////////////////////
                               CREATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVestingStreams
    function create(IERC20 token, CreateParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 streamId)
    {
        uint128 depositAmount = _validate(params);
        uint256 balanceBefore = token.balanceOf(address(this));
        streamId = nextStreamId++;
        _store(token, params, streamId);
        _pullExact(token, depositAmount, balanceBefore);
    }

    /// @inheritdoc IVestingStreams
    function createBatch(IERC20 token, CreateParams[] calldata params)
        external
        override
        nonReentrant
        returns (uint256[] memory streamIds)
    {
        uint256 count = params.length;
        if (count == 0) revert EmptyBatch();

        uint256 total = 0;
        for (uint256 i; i < count; ++i) {
            total += _validate(params[i]);
        }

        uint256 balanceBefore = token.balanceOf(address(this));
        // Ids are allocated once for the whole batch instead of incrementing the counter per stream.
        uint256 firstId = nextStreamId;
        nextStreamId = firstId + count;
        streamIds = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            streamIds[i] = firstId + i;
            _store(token, params[i], firstId + i);
        }
        _pullExact(token, total, balanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVestingStreams
    function withdraw(uint256 streamId, address to, uint128 amount) external override nonReentrant {
        Stream storage stream = _authorizeWithdrawal(streamId, to);
        if (amount == 0) revert ZeroWithdrawAmount(streamId);
        uint128 withdrawable = _streamedAmount(stream, streamId) - stream.withdrawnAmount;
        if (amount > withdrawable) revert WithdrawAmountExceedsWithdrawable(streamId, amount, withdrawable);
        _payOut(stream, streamId, to, amount);
    }

    /// @inheritdoc IVestingStreams
    function withdrawMax(uint256 streamId, address to) external override nonReentrant returns (uint128 amount) {
        Stream storage stream = _authorizeWithdrawal(streamId, to);
        amount = _streamedAmount(stream, streamId) - stream.withdrawnAmount;
        // Zero check on a computed amount, not on a manipulable balance.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert NothingToWithdraw(streamId);
        _payOut(stream, streamId, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             SENDER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVestingStreams
    function cancel(uint256 streamId) external override nonReentrant returns (uint128 refunded) {
        Stream storage stream = _requireStream(streamId);
        if (msg.sender != stream.sender) revert NotStreamSender(streamId, msg.sender);
        if (!stream.cancelable) revert StreamNotCancelable(streamId);

        uint128 depositAmount = stream.depositAmount;
        uint128 streamed = _scheduledAmount(stream, streamId, _now());
        // Exact comparison of two computed amounts, not of a token balance: the curve returns exactly the deposit
        // once everything has vested.
        // slither-disable-next-line incorrect-equality
        if (streamed == depositAmount) revert StreamSettled(streamId);

        // `streamed < depositAmount`, so the refund is strictly positive and `canceled` <=> `refundedAmount > 0`.
        refunded = depositAmount - streamed;
        uint128 withdrawable = streamed - stream.withdrawnAmount;
        stream.cancelable = false;
        stream.canceled = true;
        stream.canceledAt = _now();
        stream.refundedAmount = refunded;

        address recipient = _ownerOf(streamId);
        emit Canceled(streamId, msg.sender, recipient, refunded, withdrawable);
        emit MetadataUpdate(streamId);

        stream.token.safeTransfer(msg.sender, refunded);
        _notifyRecipient(streamId, recipient, refunded, withdrawable);
    }

    /// @inheritdoc IVestingStreams
    function renounceCancelability(uint256 streamId) external override nonReentrant {
        Stream storage stream = _requireStream(streamId);
        if (msg.sender != stream.sender) revert NotStreamSender(streamId, msg.sender);
        if (!stream.cancelable) revert StreamNotCancelable(streamId);
        stream.cancelable = false;
        emit CancelabilityRenounced(streamId);
        emit MetadataUpdate(streamId);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVestingStreams
    function setRenderer(IStreamRenderer newRenderer) external override onlyOwner {
        _setRenderer(newRenderer);
        uint256 lastId = nextStreamId - 1;
        if (lastId != 0) emit BatchMetadataUpdate(1, lastId);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVestingStreams
    function getStream(uint256 streamId) external view override returns (Stream memory) {
        return _requireStream(streamId);
    }

    /// @inheritdoc IVestingStreams
    function getMilestones(uint256 streamId) external view override returns (Milestone[] memory milestones) {
        Stream storage stream = _requireStream(streamId);
        if (stream.shape != Shape.LinearCliff) milestones = _loadMilestones(streamId);
    }

    /// @inheritdoc IVestingStreams
    function scheduledAmountAt(uint256 streamId, uint40 timestamp) external view override returns (uint128) {
        return _scheduledAmount(_requireStream(streamId), streamId, timestamp);
    }

    /// @inheritdoc IVestingStreams
    function streamedAmountOf(uint256 streamId) external view override returns (uint128) {
        return _streamedAmount(_requireStream(streamId), streamId);
    }

    /// @inheritdoc IVestingStreams
    function withdrawableAmountOf(uint256 streamId) external view override returns (uint128) {
        Stream storage stream = _requireStream(streamId);
        return _streamedAmount(stream, streamId) - stream.withdrawnAmount;
    }

    /// @inheritdoc IVestingStreams
    function refundableAmountOf(uint256 streamId) external view override returns (uint128) {
        Stream storage stream = _requireStream(streamId);
        if (!stream.cancelable) return 0;
        return stream.depositAmount - _scheduledAmount(stream, streamId, _now());
    }

    /// @inheritdoc IVestingStreams
    function statusOf(uint256 streamId) external view override returns (Status) {
        Stream storage stream = _requireStream(streamId);
        uint128 depositAmount = stream.depositAmount;
        if (stream.withdrawnAmount + stream.refundedAmount == depositAmount) return Status.Depleted;
        if (stream.canceled) return Status.Canceled;
        if (_now() < stream.startTime) return Status.Pending;
        // Computed amount against the stored deposit: exact by construction of the curves.
        // slither-disable-next-line incorrect-equality
        if (_scheduledAmount(stream, streamId, _now()) == depositAmount) return Status.Settled;
        return Status.Streaming;
    }

    /// @notice Fully on-chain metadata, produced by the current {renderer}.
    /// @param streamId The stream.
    /// @return A `data:application/json;base64,` URI.
    function tokenURI(uint256 streamId) public view override returns (string memory) {
        _requireOwned(streamId);
        return renderer.tokenURI(this, streamId);
    }

    /// @notice ERC-165: ERC-721, ERC-721 Metadata, ERC-4906 and ERC-165 itself.
    /// @param interfaceId Interface identifier.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL: CREATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates one stream's parameters and returns its deposit. Pure checks plus `block.timestamp`.
    function _validate(CreateParams calldata params) private view returns (uint128) {
        if (params.recipient == address(0) || params.recipient == address(this)) {
            revert InvalidRecipient(params.recipient);
        }
        if (params.depositAmount == 0) revert ZeroDepositAmount();
        if (params.startTime == 0) revert ZeroStartTime();

        uint40 endTime;
        if (params.shape == Shape.LinearCliff) {
            if (params.milestones.length != 0) revert UnexpectedMilestones(params.milestones.length);
            (uint40 start, uint40 cliff, uint40 end) = (params.startTime, params.cliffTime, params.endTime);
            if (start >= end || (cliff != 0 && (cliff <= start || cliff >= end))) {
                revert InvalidLinearSchedule(start, cliff, end);
            }
            endTime = end;
        } else {
            endTime = _validateMilestones(params);
        }
        if (endTime <= block.timestamp) revert EndTimeNotInFuture(endTime, block.timestamp);
        return params.depositAmount;
    }

    /// @dev Checks count, ordering and sum of the milestones; returns the last timestamp (the stream's end).
    function _validateMilestones(CreateParams calldata params) private pure returns (uint40 previous) {
        if (params.cliffTime != 0 || params.endTime != 0) {
            revert UnexpectedLinearFields(params.cliffTime, params.endTime);
        }
        uint256 maxCount = params.shape == Shape.Tranched ? MAX_TRANCHES : MAX_SEGMENTS;
        uint256 count = params.milestones.length;
        if (count == 0 || count > maxCount) revert MilestoneCountOutOfRange(params.shape, count, maxCount);

        previous = params.startTime;
        uint256 sum = 0;
        for (uint256 i; i < count; ++i) {
            Milestone calldata milestone = params.milestones[i];
            if (milestone.timestamp <= previous) revert MilestoneNotAfterPrevious(i, previous, milestone.timestamp);
            previous = milestone.timestamp;
            // At most 32 terms below 2^128 each: the uint256 sum cannot overflow.
            sum += milestone.amount;
        }
        if (sum != params.depositAmount) revert DepositMismatch(params.depositAmount, sum);
    }

    /// @dev Writes a validated stream under the pre-allocated `streamId`, stores its milestones and mints the NFT.
    /// No external calls: `_mint` does not invoke `onERC721Received`, so a contract recipient cannot block or
    /// re-enter the creation.
    function _store(IERC20 token, CreateParams calldata params, uint256 streamId) private {
        Shape shape = params.shape;
        uint256 count = params.milestones.length;
        uint40 endTime = shape == Shape.LinearCliff ? params.endTime : params.milestones[count - 1].timestamp;

        _streams[streamId] = Stream({
            sender: msg.sender,
            startTime: params.startTime,
            endTime: endTime,
            shape: shape,
            cancelable: params.cancelable,
            token: token,
            cliffTime: params.cliffTime,
            canceled: false,
            canceledAt: 0,
            // Bounded by MAX_TRANCHES (32) in `_validateMilestones`.
            milestoneCount: uint8(count),
            depositAmount: params.depositAmount,
            withdrawnAmount: 0,
            refundedAmount: 0
        });
        if (shape != Shape.LinearCliff) {
            _milestonePointers[streamId] = SSTORE2.write(MilestoneCodec.encode(params.milestones));
        }

        _mint(params.recipient, streamId);
        emit StreamCreated(
            streamId,
            msg.sender,
            params.recipient,
            token,
            shape,
            params.depositAmount,
            params.startTime,
            endTime,
            params.cancelable
        );
        emit MetadataUpdate(streamId);
    }

    /// @dev Pulls `amount` from the caller and requires this contract's balance to grow by exactly `amount`.
    /// Rejects fee-on-transfer tokens and tokens whose balances drift during a transfer (e.g. share-based
    /// rebasing tokens that lose a wei to rounding).
    function _pullExact(IERC20 token, uint256 amount, uint256 balanceBefore) private {
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert UnsupportedToken(token, amount, received);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL: WITHDRAW/CANCEL
    //////////////////////////////////////////////////////////////*/

    /// @dev Checks existence, caller authorization (owner or ERC-721 approved) and the withdrawal target.
    function _authorizeWithdrawal(uint256 streamId, address to) private view returns (Stream storage stream) {
        stream = _requireStream(streamId);
        if (!_isAuthorized(_ownerOf(streamId), msg.sender, streamId)) {
            revert NotAuthorizedToWithdraw(streamId, msg.sender);
        }
        if (to == address(0) || to == address(this)) revert InvalidWithdrawalTarget(to);
    }

    /// @dev Effects then interaction: the withdrawn counter is updated before the token transfer.
    function _payOut(Stream storage stream, uint256 streamId, address to, uint128 amount) private {
        // Cannot overflow: `withdrawnAmount + amount <= streamed <= depositAmount < 2^128`.
        stream.withdrawnAmount += amount;
        emit Withdrawn(streamId, msg.sender, to, amount);
        emit MetadataUpdate(streamId);
        stream.token.safeTransfer(to, amount);
    }

    /// @dev Calls the optional `IStreamRecipient` hook of a contract recipient with exactly `RECIPIENT_HOOK_GAS`.
    /// The caller must provide enough gas for the full stipend (otherwise the sender could starve the hook on
    /// purpose, EIP-150 style); a hook that reverts or runs out of gas within its stipend is ignored. `catch {}`
    /// without a parameter does not copy revert data, so a return-data bomb costs the caller nothing.
    function _notifyRecipient(uint256 streamId, address recipient, uint128 refunded, uint128 withdrawable) private {
        if (recipient.code.length == 0) return;
        uint256 gasRequired = (RECIPIENT_HOOK_GAS * 64) / 63 + HOOK_CALL_OVERHEAD;
        if (gasleft() < gasRequired) revert InsufficientGasForHook(gasleft(), gasRequired);
        try IStreamRecipient(recipient).onStreamCanceled{gas: RECIPIENT_HOOK_GAS}(
            streamId, msg.sender, refunded, withdrawable
        ) {}
        catch {
            emit RecipientHookFailed(streamId, recipient);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL: SCHEDULE
    //////////////////////////////////////////////////////////////*/

    /// @dev Streamed amount: the schedule value now, or the value frozen at cancellation.
    function _streamedAmount(Stream storage stream, uint256 streamId) private view returns (uint128) {
        if (stream.canceled) return stream.depositAmount - stream.refundedAmount;
        return _scheduledAmount(stream, streamId, _now());
    }

    /// @dev Schedule value at `t`, ignoring cancellation. Milestone streams skip the SSTORE2 read outside
    /// `(startTime, endTime)`: every milestone is strictly after the start, and the milestones sum to the deposit.
    function _scheduledAmount(Stream storage stream, uint256 streamId, uint40 t) private view returns (uint128) {
        Shape shape = stream.shape;
        if (shape == Shape.LinearCliff) {
            return StreamMath.linear(stream.depositAmount, stream.startTime, stream.cliffTime, stream.endTime, t);
        }
        if (t >= stream.endTime) return stream.depositAmount;
        uint40 startTime = stream.startTime;
        if (t <= startTime) return 0;
        Milestone[] memory milestones = _loadMilestones(streamId);
        return
            shape == Shape.Tranched
                ? StreamMath.tranched(milestones, t)
                : StreamMath.segmented(milestones, startTime, t);
    }

    /// @dev Reads and unpacks the milestones of a `Tranched` or `Segmented` stream.
    function _loadMilestones(uint256 streamId) private view returns (Milestone[] memory) {
        return MilestoneCodec.decode(SSTORE2.read(_milestonePointers[streamId]));
    }

    /// @dev Returns the stream or reverts with `StreamNotFound`. `sender` is never zero for a created stream.
    function _requireStream(uint256 streamId) private view returns (Stream storage stream) {
        stream = _streams[streamId];
        if (stream.sender == address(0)) revert StreamNotFound(streamId);
    }

    /// @dev `block.timestamp` as uint40, which holds Unix time until the year 36812.
    function _now() private view returns (uint40) {
        return uint40(block.timestamp);
    }

    /// @dev Sets the renderer after checking it is a contract.
    function _setRenderer(IStreamRenderer newRenderer) private {
        if (address(newRenderer).code.length == 0) revert InvalidRenderer(address(newRenderer));
        emit RendererUpdated(renderer, newRenderer);
        renderer = newRenderer;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL: ERC-721
    //////////////////////////////////////////////////////////////*/

    /// @dev Blocks transfers of stream NFTs to this contract, which could never withdraw them.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(this)) revert InvalidRecipient(to);
        return super._update(to, tokenId, auth);
    }
}
