// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {Errors} from "@openzeppelin-contracts/utils/Errors.sol";
import {SystemFixture} from "./utils/SystemFixture.sol";
import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {IOutputOracle} from "../src/interfaces/IOutputOracle.sol";
import {IForcedInclusionQueue} from "../src/interfaces/IForcedInclusionQueue.sol";
import {SmtProof} from "../src/lib/Types.sol";
import {RollupSpec} from "../src/lib/RollupSpec.sol";
import {VmBuilder} from "./utils/VmBuilder.sol";

/// @dev Re-enters `finalizeWithdrawal` from its payout, for the withdrawal being paid or another one. With `swallow`
///      set it catches the nested revert (recording its data), so the outer payout can complete.
contract ReentrantRecipient {
    Bridge internal immutable BRIDGE;
    uint64 internal epoch;
    uint256 internal reenterId;
    uint256 internal amount;
    SmtProof internal proof;
    bool internal swallow;
    bytes public nestedRevert;
    uint256 public payouts;

    constructor(Bridge bridge) {
        BRIDGE = bridge;
    }

    function arm(uint64 epoch_, uint256 reenterId_, uint256 amount_, SmtProof calldata proof_, bool swallow_) external {
        (epoch, reenterId, amount, proof, swallow) = (epoch_, reenterId_, amount_, proof_, swallow_);
    }

    receive() external payable {
        payouts += 1;
        if (!swallow) {
            BRIDGE.finalizeWithdrawal(epoch, reenterId, address(this), amount, proof);
            return;
        }
        try BRIDGE.finalizeWithdrawal(epoch, reenterId, address(this), amount, proof) {}
        catch (bytes memory data) {
            nestedRevert = data;
        }
    }
}

contract BridgeTest is SystemFixture {
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public override {
        super.setUp();
        vm.deal(user, 100 ether);
        vm.prank(user);
        bridge.deposit{value: 10 ether}(user);
    }

    /// @dev Finalizes epoch 1 with `stateRoot` (the oracle trusts it once the window passes undisputed).
    function _finalizeWith(bytes32 stateRoot) internal {
        _postEmptyBatch();
        _propose(proposer, 1, stateRoot);
        vm.warp(vm.getBlockTimestamp() + CHALLENGE_WINDOW);
        oracle.finalize(1);
    }

    function _emptyProof() internal pure returns (SmtProof memory p) {
        p.siblings = new bytes32[](0);
    }

    function test_deposit_entersTheQueue() public {
        vm.expectEmit(address(bridge));
        emit IBridge.DepositInitiated(user, address(0xabc), 1 ether, 1);
        vm.prank(user);
        assertEq(bridge.deposit{value: 1 ether}(address(0xabc)), 1);
        assertEq(queue.length(), 2);
        assertEq(address(bridge).balance, 11 ether);
    }

    function test_revert_zeroDeposit() public {
        vm.expectRevert(IBridge.ZeroDeposit.selector);
        bridge.deposit(user);
    }

    function test_finalizeWithdrawal_singleLeaf() public {
        bytes32 root =
            VmBuilder.singleLeafRoot(RollupSpec.withdrawalKey(0), RollupSpec.withdrawalValue(recipient, 3 ether));
        _finalizeWith(root);
        vm.expectEmit(address(bridge));
        emit IBridge.WithdrawalFinalized(0, recipient, 3 ether, 1);
        bridge.finalizeWithdrawal(1, 0, recipient, 3 ether, _emptyProof());
        assertEq(recipient.balance, 3 ether);
        assertTrue(bridge.finalized(0));

        vm.expectRevert(abi.encodeWithSelector(IBridge.AlreadyFinalized.selector, 0));
        bridge.finalizeWithdrawal(1, 0, recipient, 3 ether, _emptyProof());
    }

    function test_finalizeWithdrawal_twoLeafTree() public {
        (bytes32 root, uint256 bitmap, bytes32[] memory siblings) = VmBuilder.twoLeaves(
            RollupSpec.withdrawalKey(7),
            RollupSpec.withdrawalValue(recipient, 1 ether),
            keccak256("some balance key"),
            bytes32(uint256(123))
        );
        _finalizeWith(root);
        bridge.finalizeWithdrawal(1, 7, recipient, 1 ether, SmtProof({bitmap: bitmap, siblings: siblings}));
        assertEq(recipient.balance, 1 ether);
    }

    function test_revert_invalidProof() public {
        bytes32 root =
            VmBuilder.singleLeafRoot(RollupSpec.withdrawalKey(0), RollupSpec.withdrawalValue(recipient, 3 ether));
        _finalizeWith(root);
        bytes32 computed =
            VmBuilder.singleLeafRoot(RollupSpec.withdrawalKey(0), RollupSpec.withdrawalValue(recipient, 4 ether));
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidWithdrawalProof.selector, root, computed));
        bridge.finalizeWithdrawal(1, 0, recipient, 4 ether, _emptyProof());
    }

    function test_revert_notFinalized() public {
        _postEmptyBatch();
        _propose(proposer, 1, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IOutputOracle.NotFinalized.selector, 1));
        bridge.finalizeWithdrawal(1, 0, recipient, 1, _emptyProof());
    }

    function test_revert_insufficientBridgeBalance() public {
        bytes32 root =
            VmBuilder.singleLeafRoot(RollupSpec.withdrawalKey(0), RollupSpec.withdrawalValue(recipient, 50 ether));
        _finalizeWith(root);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 10 ether, 50 ether));
        bridge.finalizeWithdrawal(1, 0, recipient, 50 ether, _emptyProof());
    }

    /// @dev Re-entering with the same id and proof while the first payout is in flight: the nested call reverts and
    ///      the recipient is paid exactly once; afterwards the id is spent.
    function test_reentrantRecipientCannotDoubleWithdraw() public {
        ReentrantRecipient evil = new ReentrantRecipient(bridge);
        bytes32 root =
            VmBuilder.singleLeafRoot(RollupSpec.withdrawalKey(0), RollupSpec.withdrawalValue(address(evil), 1 ether));
        _finalizeWith(root);
        evil.arm(1, 0, 1 ether, _emptyProof(), true);

        bridge.finalizeWithdrawal(1, 0, address(evil), 1 ether, _emptyProof());
        assertEq(address(evil).balance, 1 ether, "paid exactly once");
        assertEq(evil.payouts(), 1);
        assertEq(
            evil.nestedRevert(), abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertTrue(bridge.finalized(0));

        vm.expectRevert(abi.encodeWithSelector(IBridge.AlreadyFinalized.selector, 0));
        bridge.finalizeWithdrawal(1, 0, address(evil), 1 ether, _emptyProof());
        assertEq(address(evil).balance, 1 ether);
    }

    /// @dev Same-id re-entry whose revert propagates: the whole withdrawal reverts, nothing is paid or spent.
    function test_reentrantRecipientSameIdRevertUndoesThePayout() public {
        ReentrantRecipient evil = new ReentrantRecipient(bridge);
        bytes32 root =
            VmBuilder.singleLeafRoot(RollupSpec.withdrawalKey(0), RollupSpec.withdrawalValue(address(evil), 1 ether));
        _finalizeWith(root);
        evil.arm(1, 0, 1 ether, _emptyProof(), false);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        bridge.finalizeWithdrawal(1, 0, address(evil), 1 ether, _emptyProof());
        assertEq(address(evil).balance, 0);
        assertFalse(bridge.finalized(0));
    }

    /// @dev The guard also blocks a nested payout of a different, legitimate withdrawal while one is being paid.
    function test_reentrancyGuardBlocksNestedWithdrawalOfAnotherId() public {
        ReentrantRecipient evil = new ReentrantRecipient(bridge);
        (bytes32 root, uint256 bitmap, bytes32[] memory siblings) = VmBuilder.twoLeaves(
            RollupSpec.withdrawalKey(0),
            RollupSpec.withdrawalValue(address(evil), 1 ether),
            RollupSpec.withdrawalKey(1),
            RollupSpec.withdrawalValue(address(evil), 1 ether)
        );
        _finalizeWith(root);
        (,, bytes32[] memory siblings1) = VmBuilder.twoLeaves(
            RollupSpec.withdrawalKey(1),
            RollupSpec.withdrawalValue(address(evil), 1 ether),
            RollupSpec.withdrawalKey(0),
            RollupSpec.withdrawalValue(address(evil), 1 ether)
        );
        evil.arm(1, 1, 1 ether, SmtProof({bitmap: bitmap, siblings: siblings1}), false);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        bridge.finalizeWithdrawal(1, 0, address(evil), 1 ether, SmtProof({bitmap: bitmap, siblings: siblings}));
        assertFalse(bridge.finalized(0));
    }

    function test_revert_constructorZeroParameters() public {
        vm.expectRevert(IBridge.ZeroParameter.selector);
        new Bridge(IForcedInclusionQueue(address(0)), oracle);
        vm.expectRevert(IBridge.ZeroParameter.selector);
        new Bridge(queue, IOutputOracle(address(0)));
    }
}
