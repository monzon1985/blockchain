// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {StreamRenderer} from "../../../contracts/StreamRenderer.sol";
import {VestingStreams} from "../../../contracts/VestingStreams.sol";
import {IVestingStreams} from "../../../contracts/interfaces/IVestingStreams.sol";
import {MockERC20} from "../../../contracts/mocks/MockERC20.sol";
import {CreateParams, Milestone, Shape, Status, Stream} from "../../../contracts/types/StreamTypes.sol";

/// @notice Shared fixture: a fresh protocol, an 18-decimal token funded to `sender`, and parameter builders.
abstract contract BaseTest is Test {
    /// @dev 2026-03-01T00:00:00Z; tests start one day earlier.
    uint40 internal constant T0 = 1_772_323_200;
    uint40 internal constant DAY = 1 days;
    uint40 internal constant MONTH = 30 days;
    uint256 internal constant E18 = 1e18;

    VestingStreams internal vesting;
    StreamRenderer internal renderer;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal sender = makeAddr("sender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal eve = makeAddr("eve");

    function setUp() public virtual {
        vm.warp(T0 - DAY);
        renderer = new StreamRenderer();
        vesting = new VestingStreams(renderer, owner);
        token = new MockERC20("Mock Token", "MOCK", 18);
        token.mint(sender, 1e36);
        vm.prank(sender);
        token.approve(address(vesting), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              PARAM BUILDERS
    //////////////////////////////////////////////////////////////*/

    function _linear(address recipient, uint128 deposit, uint40 start, uint40 cliff, uint40 end)
        internal
        pure
        returns (CreateParams memory params)
    {
        params.recipient = recipient;
        params.shape = Shape.LinearCliff;
        params.cancelable = true;
        params.startTime = start;
        params.cliffTime = cliff;
        params.endTime = end;
        params.depositAmount = deposit;
    }

    function _withMilestones(address recipient, Shape shape, uint40 start, Milestone[] memory milestones)
        internal
        pure
        returns (CreateParams memory params)
    {
        params.recipient = recipient;
        params.shape = shape;
        params.cancelable = true;
        params.startTime = start;
        params.milestones = milestones;
        uint256 sum;
        for (uint256 i; i < milestones.length; ++i) {
            sum += milestones[i].amount;
        }
        params.depositAmount = uint128(sum);
    }

    /// @dev `count` milestones of `amount` each, one every `step` seconds after `start`.
    function _even(uint256 count, uint128 amount, uint40 start, uint40 step)
        internal
        pure
        returns (Milestone[] memory m)
    {
        m = new Milestone[](count);
        for (uint256 i; i < count; ++i) {
            m[i] = Milestone({amount: amount, timestamp: start + step * uint40(i + 1)});
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ACTIONS
    //////////////////////////////////////////////////////////////*/

    function _create(CreateParams memory params) internal returns (uint256 streamId) {
        vm.prank(sender);
        streamId = vesting.create(token, params);
    }

    /// @dev 1,200 tokens from T0 to T0 + 12 months with a 3-month cliff, to `alice`.
    function _createDefaultLinear() internal returns (uint256) {
        return _create(_linear(alice, uint128(1200 * E18), T0, T0 + 3 * MONTH, T0 + 12 * MONTH));
    }

    /// @dev 12 monthly tranches of 100 tokens from T0, to `alice`.
    function _createDefaultTranched() internal returns (uint256) {
        return _create(_withMilestones(alice, Shape.Tranched, T0, _even(12, uint128(100 * E18), T0, MONTH)));
    }

    /// @dev Ramp 1,000 over 2 months, plateau 2 months, then 3,000 over 6 months, to `alice`.
    function _createDefaultSegmented() internal returns (uint256) {
        Milestone[] memory m = new Milestone[](3);
        m[0] = Milestone({amount: uint128(1000 * E18), timestamp: T0 + 2 * MONTH});
        m[1] = Milestone({amount: 0, timestamp: T0 + 4 * MONTH});
        m[2] = Milestone({amount: uint128(3000 * E18), timestamp: T0 + 10 * MONTH});
        return _create(_withMilestones(alice, Shape.Segmented, T0, m));
    }

    function _err(bytes4 selector, uint256 streamId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, streamId);
    }
}
