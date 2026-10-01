// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployScriptTest is Test {
    function _params() internal returns (Deploy.Params memory) {
        return Deploy.Params({
            owner: makeAddr("owner"),
            sequencer: makeAddr("sequencer"),
            inclusionWindow: 10,
            proposerBond: 1 ether,
            challengerBond: 0.5 ether,
            challengeWindow: 3600,
            clock: 1800,
            maxDepth: 16,
            genesisStateRoot: bytes32(0),
            codeRoot: keccak256("program"),
            codeSize: 151
        });
    }

    function test_deployWiresEverything() public {
        Deploy script = new Deploy();
        Deploy.Params memory p = Deploy.Params({
            owner: makeAddr("owner"),
            sequencer: makeAddr("sequencer"),
            inclusionWindow: 10,
            proposerBond: 1 ether,
            challengerBond: 0.5 ether,
            challengeWindow: 3600,
            clock: 1800,
            maxDepth: 16,
            genesisStateRoot: bytes32(0),
            codeRoot: keccak256("program"),
            codeSize: 151
        });
        Deploy.Deployed memory d = script.deployWith(p, address(script));
        assertEq(address(d.inbox.QUEUE()), address(d.queue));
        assertEq(address(d.oracle.INBOX()), address(d.inbox));
        assertEq(address(d.game.ORACLE()), address(d.oracle));
        assertEq(address(d.game.VM()), address(d.osvm));
        assertEq(address(d.bridge.ORACLE()), address(d.oracle));
        assertEq(d.game.CODE_ROOT(), keccak256("program"));
        assertEq(d.game.MAX_DEPTH(), 16);
        assertEq(d.inbox.owner(), p.owner);
        assertEq(d.inbox.sequencer(), p.sequencer);
    }

    function test_paramsFromEnv() public {
        vm.setEnv("SEQUENCER", vm.toString(makeAddr("seq")));
        vm.setEnv("CODE_ROOT", vm.toString(keccak256("root")));
        vm.setEnv("CODE_SIZE", "151");
        Deploy script = new Deploy();
        Deploy.Params memory p = script.paramsFromEnv(address(this));
        assertEq(p.sequencer, makeAddr("seq"));
        assertEq(p.codeRoot, keccak256("root"));
        assertEq(p.codeSize, 151);
        assertEq(p.owner, address(this));
        assertEq(p.proposerBond, 1 ether);
        assertEq(p.maxDepth, 16);
        assertEq(p.genesisStateRoot, bytes32(0));
    }

    /// @dev The smallest allowed depth holds the worst-case trace and the next smaller one does not.
    function test_minDepthIsTheSmallestThatHoldsTheWorstCase() public {
        Deploy script = new Deploy();
        uint256 minDepth = script.MIN_MAX_DEPTH();
        assertGe(uint256(1) << minDepth, script.WORST_CASE_TRACE_STEPS());
        assertLt(uint256(1) << (minDepth - 1), script.WORST_CASE_TRACE_STEPS());
        assertEq(script.checkedDepth(minDepth), minDepth);
        assertEq(script.checkedDepth(script.MAX_MAX_DEPTH()), script.MAX_MAX_DEPTH());
    }

    /// @dev Depths that could not hold a full batch, or that the game would reject, never reach the constructor; a
    ///      value above 255 is rejected before it could wrap around when narrowed to uint8.
    function test_revert_depthOutOfRange() public {
        Deploy script = new Deploy();
        vm.expectRevert(abi.encodeWithSelector(Deploy.MaxDepthOutOfRange.selector, 13, 14, 40));
        script.checkedDepth(13);
        vm.expectRevert(abi.encodeWithSelector(Deploy.MaxDepthOutOfRange.selector, 41, 14, 40));
        script.checkedDepth(41);
        vm.expectRevert(abi.encodeWithSelector(Deploy.MaxDepthOutOfRange.selector, 270, 14, 40));
        script.checkedDepth(270);

        Deploy.Params memory p = _params();
        p.maxDepth = 8;
        vm.expectRevert(abi.encodeWithSelector(Deploy.MaxDepthOutOfRange.selector, 8, 14, 40));
        script.deployWith(p, address(script));
    }

    /// @dev The node derives from an empty genesis; any other root is refused at deployment.
    function test_revert_nonEmptyGenesis() public {
        Deploy script = new Deploy();
        Deploy.Params memory p = _params();
        p.genesisStateRoot = keccak256("some state");
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedGenesis.selector, p.genesisStateRoot));
        script.deployWith(p, address(script));
    }
}
