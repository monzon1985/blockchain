// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {VestingStreams} from "../../../contracts/VestingStreams.sol";
import {FeeOnTransferToken} from "../../../contracts/mocks/FeeOnTransferToken.sol";
import {HookedToken} from "../../../contracts/mocks/HookedToken.sol";
import {MockERC20} from "../../../contracts/mocks/MockERC20.sol";
import {NoReturnToken} from "../../../contracts/mocks/NoReturnToken.sol";
import {GasGuzzlerRecipient, ReentrantActor, RevertingRecipient} from "../../../contracts/mocks/RecipientMocks.sol";
import {ShareRebasingToken} from "../../../contracts/mocks/ShareRebasingToken.sol";
import {CreateParams, Milestone, Shape, Stream} from "../../../contracts/types/StreamTypes.sol";

/// @notice Drives `VestingStreams` through random sequences of create / createBatch / withdraw / cancel /
/// renounce / NFT transfer / operator withdrawal / donation / time warps, with adversarial tokens (no-return-value,
/// transfer-callback) and adversarial actors (re-entrant contract, reverting and gas-burning hooks). Every token
/// movement is measured with balance deltas and accumulated in ghost variables, independently of the contract's
/// own accounting.
contract VestingHandler is Test {
    VestingStreams public immutable vesting;
    ReentrantActor public immutable reentrant;

    /// @notice Tokens streams can be created with: 18-dec standard, 6-dec no-return (USDT-like), callback token.
    address[] public tokens;
    FeeOnTransferToken public immutable feeToken;
    ShareRebasingToken public immutable rebasingToken;

    /// @notice EOAs plus hostile contracts; all can send, receive and own streams.
    address[] public actors;

    uint256[] public streamIds;

    // Ghost accounting, measured from actual balance changes.
    mapping(uint256 streamId => uint256) public ghostDeposited;
    mapping(uint256 streamId => uint256) public ghostWithdrawn;
    mapping(uint256 streamId => uint256) public ghostRefunded;
    mapping(uint256 streamId => uint128) public ghostLastStreamed;
    mapping(address token => uint256) public ghostDonated;

    // Violation counters: every one of these must stay zero.
    uint256 public ghostMonotonicityViolations;
    uint256 public ghostShortDeliveryAccepted;
    uint256 public ghostUnauthorizedWithdrawals;
    uint256 public ghostBalanceDeltaMismatches;

    /// @notice How often each action ran to completion, for debugging a campaign (`calls("cancel")`, ...).
    /// With `failOnRevert: true` in every test profile, an action that reverts fails the campaign instead.
    mapping(bytes32 action => uint256) public calls;

    constructor(VestingStreams vesting_) {
        vesting = vesting_;
        reentrant = new ReentrantActor(vesting_);
        tokens.push(address(new MockERC20("Standard", "STD", 18)));
        tokens.push(address(new NoReturnToken()));
        tokens.push(address(new HookedToken()));
        feeToken = new FeeOnTransferToken(30);
        rebasingToken = new ShareRebasingToken();
        rebasingToken.mint(address(this), 1e30);
        rebasingToken.rebase(1); // share price no longer 1:1, so most transfers lose a wei to rounding

        actors.push(makeAddr("actorA"));
        actors.push(makeAddr("actorB"));
        actors.push(makeAddr("actorC"));
        actors.push(address(reentrant));
        actors.push(address(new RevertingRecipient()));
        actors.push(address(new GasGuzzlerRecipient()));
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function create(uint256 seed, uint256 tokenSeed, uint128 amount, uint40 timing) external checkMonotonic {
        address sender = _actor(seed);
        IERC20 token = IERC20(tokens[tokenSeed % tokens.length]);
        CreateParams memory p = _params(seed, amount, timing);
        _fund(token, sender, p.depositAmount);

        uint256 before = token.balanceOf(address(vesting));
        vm.prank(sender);
        uint256 id = vesting.create(token, p);
        _recordCreation(token, id, p.depositAmount, before);
        calls["create"]++;
    }

    function createBatch(uint256 seed, uint256 tokenSeed, uint128 amount, uint40 timing, uint8 size)
        external
        checkMonotonic
    {
        address sender = _actor(seed);
        IERC20 token = IERC20(tokens[tokenSeed % tokens.length]);
        CreateParams[] memory batch = new CreateParams[](bound(size, 1, 4));
        uint256 total;
        for (uint256 i; i < batch.length; ++i) {
            batch[i] = _params(uint256(keccak256(abi.encode(seed, i))), amount, timing);
            total += batch[i].depositAmount;
        }
        _fund(token, sender, total);

        uint256 before = token.balanceOf(address(vesting));
        vm.prank(sender);
        uint256[] memory ids = vesting.createBatch(token, batch);
        if (token.balanceOf(address(vesting)) - before != total) ghostShortDeliveryAccepted++;
        for (uint256 i; i < ids.length; ++i) {
            streamIds.push(ids[i]);
            ghostDeposited[ids[i]] = batch[i].depositAmount;
        }
        calls["createBatch"]++;
    }

    /// Attempts to stream a fee-on-transfer or a rebasing token from the current state. Short deliveries must always
    /// be rejected. The attempt runs inside a snapshot, so an exact (accepted) transfer never becomes a tracked stream
    /// of a token whose balances drift later. `vm.revertToState` also rolls back this handler's own storage, so the
    /// outcome is kept in local variables across the revert and only recorded afterwards.
    function createWithUnsupportedToken(uint256 seed, uint128 amount, uint40 timing, bool rebasing) external {
        address sender = _actor(seed);
        CreateParams memory p = _params(seed, amount, timing);
        IERC20 token = rebasing ? IERC20(address(rebasingToken)) : IERC20(address(feeToken));
        uint256 snapshot = vm.snapshotState();
        if (rebasing) {
            rebasingToken.transfer(sender, p.depositAmount + 10);
        } else {
            feeToken.mint(sender, p.depositAmount);
        }
        vm.prank(sender);
        token.approve(address(vesting), type(uint256).max);
        uint256 before = token.balanceOf(address(vesting));
        bool accepted;
        bool shortDelivery;
        vm.prank(sender);
        try vesting.create(token, p) {
            accepted = true;
            shortDelivery = token.balanceOf(address(vesting)) - before != p.depositAmount;
        } catch {}
        vm.revertToState(snapshot);
        if (shortDelivery) ghostShortDeliveryAccepted++;
        calls[accepted ? bytes32("unsupported: exact, accepted") : bytes32("unsupported: rejected")]++;
    }

    function withdraw(uint256 streamSeed, uint128 amount, uint256 toSeed) external checkMonotonic {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[streamSeed % streamIds.length];
        uint128 withdrawable = vesting.withdrawableAmountOf(id);
        if (withdrawable == 0) return;
        amount = uint128(bound(amount, 1, withdrawable));
        address to = _actor(toSeed);
        _withdrawAs(vesting.ownerOf(id), id, to, amount, false);
        calls["withdraw"]++;
    }

    function withdrawMax(uint256 streamSeed, uint256 toSeed) external checkMonotonic {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[streamSeed % streamIds.length];
        if (vesting.withdrawableAmountOf(id) == 0) return;
        _withdrawAs(vesting.ownerOf(id), id, _actor(toSeed), 0, true);
        calls["withdrawMax"]++;
    }

    function operatorWithdraw(uint256 streamSeed, uint256 operatorSeed, bool forAll) external checkMonotonic {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[streamSeed % streamIds.length];
        address holder = vesting.ownerOf(id);
        address operator = _actor(operatorSeed);
        if (operator == holder || vesting.withdrawableAmountOf(id) == 0) return;
        vm.prank(holder);
        if (forAll) vesting.setApprovalForAll(operator, true);
        else vesting.approve(operator, id);
        _withdrawAs(operator, id, operator, 0, true);
        vm.prank(holder);
        if (forAll) vesting.setApprovalForAll(operator, false);
        else vesting.approve(address(0), id);
        calls["operatorWithdraw"]++;
    }

    /// Anyone who is neither the owner nor approved must fail to withdraw.
    function strangerWithdraw(uint256 streamSeed, uint256 strangerSeed) external checkMonotonic {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[streamSeed % streamIds.length];
        address stranger = _actor(strangerSeed);
        address holder = vesting.ownerOf(id);
        if (stranger == holder || vesting.isApprovedForAll(holder, stranger) || vesting.getApproved(id) == stranger) {
            return;
        }
        vm.prank(stranger);
        try vesting.withdrawMax(id, stranger) {
            ghostUnauthorizedWithdrawals++;
        } catch {}
        calls["strangerWithdraw"]++;
    }

    function cancel(uint256 streamSeed) external checkMonotonic {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[streamSeed % streamIds.length];
        Stream memory s = vesting.getStream(id);
        if (!s.cancelable || vesting.refundableAmountOf(id) == 0) return;
        uint256 before = _balance(s.token, s.sender);
        uint256 vestingBefore = _balance(s.token, address(vesting));
        vm.prank(s.sender);
        uint128 refunded = vesting.cancel(id);
        uint256 received = _balance(s.token, s.sender) - before;
        if (received != refunded || vestingBefore - _balance(s.token, address(vesting)) != refunded) {
            ghostBalanceDeltaMismatches++;
        }
        ghostRefunded[id] += received;
        calls["cancel"]++;
    }

    function renounce(uint256 streamSeed) external checkMonotonic {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[streamSeed % streamIds.length];
        Stream memory s = vesting.getStream(id);
        if (!s.cancelable) return;
        vm.prank(s.sender);
        vesting.renounceCancelability(id);
        calls["renounce"]++;
    }

    function transferNft(uint256 streamSeed, uint256 toSeed) external checkMonotonic {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[streamSeed % streamIds.length];
        address holder = vesting.ownerOf(id);
        vm.prank(holder);
        vesting.transferFrom(holder, _actor(toSeed), id);
        calls["transferNft"]++;
    }

    /// Arms the re-entrant actor against a random stream: its token callbacks and cancel hook will try to
    /// withdraw from and cancel that stream in the middle of other operations.
    function armReentrancy(uint256 streamSeed) external {
        if (streamIds.length == 0) return;
        reentrant.setTarget(streamIds[streamSeed % streamIds.length]);
        calls["armReentrancy"]++;
    }

    /// Plain transfers to the contract are not attributed to any stream and must stay untouched.
    function donate(uint256 tokenSeed, uint96 amount) external {
        address token = tokens[tokenSeed % tokens.length];
        uint256 before = IERC20(token).balanceOf(address(vesting));
        _mint(token, address(vesting), amount);
        ghostDonated[token] += IERC20(token).balanceOf(address(vesting)) - before;
        calls["donate"]++;
    }

    function warp(uint32 seconds_) external checkMonotonic {
        vm.warp(block.timestamp + bound(seconds_, 1, 120 days));
        calls["warp"]++;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function streamCount() external view returns (uint256) {
        return streamIds.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Records the streamed amount of every stream after the action and flags any decrease. Time only moves
    /// forward in this handler, so the streamed amount must never go down, cancellation included.
    modifier checkMonotonic() {
        _;
        for (uint256 i; i < streamIds.length; ++i) {
            uint256 id = streamIds[i];
            uint128 current = vesting.streamedAmountOf(id);
            if (current < ghostLastStreamed[id]) ghostMonotonicityViolations++;
            ghostLastStreamed[id] = current;
        }
    }

    function _withdrawAs(address caller, uint256 id, address to, uint128 amount, bool max) internal {
        IERC20 token = vesting.getStream(id).token;
        uint256 before = _balance(token, to);
        uint256 vestingBefore = _balance(token, address(vesting));
        vm.prank(caller);
        if (max) amount = vesting.withdrawMax(id, to);
        else vesting.withdraw(id, to, amount);
        uint256 received = _balance(token, to) - before;
        if (received != amount || vestingBefore - _balance(token, address(vesting)) != amount) {
            ghostBalanceDeltaMismatches++;
        }
        ghostWithdrawn[id] += received;
    }

    function _recordCreation(IERC20 token, uint256 id, uint128 deposit, uint256 before) internal {
        uint256 received = token.balanceOf(address(vesting)) - before;
        if (received != deposit) ghostShortDeliveryAccepted++;
        streamIds.push(id);
        ghostDeposited[id] = received;
    }

    /// @dev Random valid parameters for any shape, starting within ±30 days of now, lasting up to two years.
    function _params(uint256 seed, uint128 amount, uint40 timing) internal view returns (CreateParams memory p) {
        uint256 r = uint256(keccak256(abi.encode(seed, amount, timing)));
        p.recipient = _actor(r >> 8);
        p.shape = Shape(r % 3);
        p.cancelable = (r >> 16) % 4 != 0;
        p.startTime = uint40(block.timestamp - 30 days + bound(timing, 0, 60 days));
        uint40 duration = uint40(bound(r >> 32, 31 days, 730 days));
        uint128 deposit = uint128(bound(amount, 1, 1e27));
        if (p.shape == Shape.LinearCliff) {
            p.endTime = p.startTime + duration;
            p.cliffTime = (r >> 72) % 2 == 0 ? 0 : p.startTime + uint40(bound(r >> 80, 1, duration - 1));
            p.depositAmount = deposit;
        } else {
            uint256 n = bound(r >> 96, 1, p.shape == Shape.Tranched ? 32 : 16);
            p.milestones = new Milestone[](n);
            uint40 step = duration / uint40(n);
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                uint128 part =
                    (r >> (104 + i)) % 5 == 0 ? 0 : uint128(bound(uint256(keccak256(abi.encode(r, i))), 1, deposit));
                p.milestones[i] = Milestone({amount: part, timestamp: p.startTime + step * uint40(i + 1)});
                sum += part;
            }
            if (sum == 0) {
                p.milestones[n - 1].amount = 1;
                sum = 1;
            }
            p.depositAmount = uint128(sum);
        }
    }

    function _fund(IERC20 token, address who, uint256 amount) internal {
        _mint(address(token), who, amount);
        vm.prank(who);
        // NoReturnToken's approve returns nothing: call it through the low-level interface.
        (bool ok,) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, address(vesting), type(uint256).max));
        require(ok, "approve failed");
    }

    function _mint(address token, address to, uint256 amount) internal {
        MockERC20(token).mint(to, amount); // all three stream tokens expose `mint(address,uint256)`
    }

    function _balance(IERC20 token, address who) internal view returns (uint256) {
        return token.balanceOf(who);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}
