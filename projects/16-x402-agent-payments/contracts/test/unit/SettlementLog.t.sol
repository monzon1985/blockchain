// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISettlementLog} from "../../src/interfaces/ISettlementLog.sol";
import {ResourceBinding} from "../../src/settlement/ResourceBinding.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {Fixture} from "../utils/Fixture.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Exposes `_transferOwnership` to simulate a post-seal ownership bug.
contract SettlementLogHarness is SettlementLog {
    constructor(address asset_, address owner_) SettlementLog(asset_, owner_) {}

    function forceOwner(address newOwner) external {
        _transferOwnership(newOwner);
    }
}

/// @notice Unit tests for the settlement router, including the adversarial-facilitator cases: whatever the relayer
///         changes in the payer's authorization, the settlement reverts and no receipt is created.
contract SettlementLogTest is Fixture {
    bytes32 internal constant SALT = keccak256("salt");

    function setUp() public override {
        super.setUp();
        _mint(payer, 100 * ONE);
    }

    function test_Wiring() public view {
        assertEq(settlement.asset(), address(token));
        assertTrue(settlement.isSealed());
        assertEq(settlement.owner(), address(0));
        assertTrue(settlement.isRecorder(address(executor)));
        assertTrue(settlement.isRecorder(address(escrow)));
    }

    function test_SettleExact_RecordsReceipt() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        bytes32 expectedId =
            settlement.receiptIdFor(address(settlement), ISettlementLog.Scheme.Exact, payer, auth.nonce);

        vm.expectEmit(address(settlement));
        emit SettlementLog.ReceiptRecorded(expectedId, ISettlementLog.Scheme.Exact, payer, payee, ONE, RESOURCE);
        vm.prank(relayer);
        bytes32 receiptId = settlement.settleExact(auth, RESOURCE, SALT, sig);

        assertEq(receiptId, expectedId);
        ISettlementLog.Receipt memory r = settlement.receiptOf(receiptId);
        assertEq(r.payer, payer);
        assertEq(r.payee, payee);
        assertEq(r.amount, ONE);
        assertEq(r.resourceHash, RESOURCE);
        assertEq(uint8(r.scheme), uint8(ISettlementLog.Scheme.Exact));
        assertEq(r.settledAt, block.timestamp);
        assertEq(token.balanceOf(payee), ONE);
        assertEq(token.balanceOf(payer), 99 * ONE);
        assertEq(settlement.receiptCount(), 1);
    }

    function test_ExactNonceView_MatchesLibrary() public view {
        assertEq(settlement.exactNonce(RESOURCE, SALT), ResourceBinding.exactNonce(RESOURCE, SALT));
        assertEq(uint64(uint256(settlement.exactNonce(RESOURCE, SALT))), 0, "sequence bits are zero");
    }

    // ------------------------------------------------------------------ adversarial facilitator

    function test_RevertWhen_FacilitatorChangesAmount() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        auth.value = 2 * ONE;
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        settlement.settleExact(auth, RESOURCE, SALT, sig);
        assertEq(settlement.receiptCount(), 0);
    }

    function test_RevertWhen_FacilitatorChangesPayee() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        auth.to = relayer;
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        settlement.settleExact(auth, RESOURCE, SALT, sig);
    }

    function test_RevertWhen_FacilitatorChangesResource() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        bytes32 expected = ResourceBinding.exactNonce(OTHER_RESOURCE, SALT);
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.ResourceBindingMismatch.selector, auth.nonce, expected));
        settlement.settleExact(auth, OTHER_RESOURCE, SALT, sig);
    }

    function test_RevertWhen_FacilitatorForgesNonceForOtherResource() public {
        // Re-deriving the nonce for another resource invalidates the payer's signature.
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        auth.nonce = ResourceBinding.exactNonce(OTHER_RESOURCE, SALT);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        settlement.settleExact(auth, OTHER_RESOURCE, SALT, sig);
    }

    function test_RevertWhen_FacilitatorChangesSalt() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        bytes32 otherSalt = keccak256("other");
        bytes32 expected = ResourceBinding.exactNonce(RESOURCE, otherSalt);
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.ResourceBindingMismatch.selector, auth.nonce, expected));
        settlement.settleExact(auth, RESOURCE, otherSalt, sig);
    }

    function test_RevertWhen_Replayed() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        bytes32 id = settlement.settleExact(auth, RESOURCE, SALT, sig);
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.ReceiptAlreadyRecorded.selector, id));
        settlement.settleExact(auth, RESOURCE, SALT, sig);
    }

    function test_RevertWhen_Expired() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        vm.warp(auth.validBefore);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3009.ERC3009InvalidAuthorizationTime.selector, auth.validAfter, auth.validBefore)
        );
        settlement.settleExact(auth, RESOURCE, SALT, sig);
    }

    function test_RevertWhen_InsufficientBalance() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, 1000 * ONE, RESOURCE, SALT);
        vm.expectRevert();
        settlement.settleExact(auth, RESOURCE, SALT, sig);
        assertEq(settlement.receiptCount(), 0);
    }

    function test_RevertWhen_ZeroAmount() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, 0, RESOURCE, SALT);
        vm.expectRevert(SettlementLog.ZeroAmount.selector);
        settlement.settleExact(auth, RESOURCE, SALT, sig);
    }

    function test_RevertWhen_SelfPayment() public {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payer, ONE, RESOURCE, SALT);
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.SelfPayment.selector, payer));
        settlement.settleExact(auth, RESOURCE, SALT, sig);
    }

    function test_RevertWhen_DirectTokenCallFrontRunsThenLogSettles() public {
        // A relayer can bypass the log and call the token directly: the payee is still paid exactly what was signed,
        // but no receipt exists and the log refuses the consumed authorization afterwards.
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        token.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, sig
        );
        assertEq(token.balanceOf(payee), ONE);
        vm.expectRevert();
        settlement.settleExact(auth, RESOURCE, SALT, sig);
        assertEq(settlement.receiptCount(), 0);
    }

    // ------------------------------------------------------------------ recorders and sealing

    function test_RevertWhen_RecordByNonRecorder() public {
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.NotRecorder.selector, relayer));
        vm.prank(relayer);
        settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payee, ONE, RESOURCE, bytes32(0));
    }

    function test_RecordReceiptChecks() public {
        vm.startPrank(address(executor));
        vm.expectRevert(SettlementLog.ZeroAmount.selector);
        settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payee, 0, RESOURCE, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.SelfPayment.selector, payer));
        settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payer, ONE, RESOURCE, bytes32(0));
        uint256 tooBig = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, tooBig));
        settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payee, tooBig, RESOURCE, bytes32(0));
        bytes32 id = settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payee, ONE, RESOURCE, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SettlementLog.ReceiptAlreadyRecorded.selector, id));
        settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payee, ONE, RESOURCE, bytes32(0));
        vm.stopPrank();
    }

    function test_ReceiptIdsAreScopedByRecorder() public {
        vm.prank(address(executor));
        bytes32 a = settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payee, ONE, RESOURCE, bytes32(0));
        vm.prank(address(escrow));
        bytes32 b = settlement.recordReceipt(ISettlementLog.Scheme.BudgetExec, payer, payee, ONE, RESOURCE, bytes32(0));
        assertTrue(a != b);
    }

    function test_UnsealedLifecycle() public {
        SettlementLog fresh = new SettlementLog(address(token), deployer);
        assertFalse(fresh.isSealed());

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, relayer));
        vm.prank(relayer);
        fresh.setRecorder(relayer, true);

        vm.startPrank(deployer);
        vm.expectRevert(SettlementLog.ZeroAddress.selector);
        fresh.setRecorder(address(0), true);

        vm.expectEmit(address(fresh));
        emit SettlementLog.RecorderSet(relayer, true);
        fresh.setRecorder(relayer, true);
        fresh.setRecorder(relayer, false);
        assertFalse(fresh.isRecorder(relayer));

        vm.expectRevert(SettlementLog.RenounceDisabled.selector);
        fresh.renounceOwnership();

        vm.expectEmit(address(fresh));
        emit SettlementLog.Sealed(deployer);
        fresh.seal();
        vm.stopPrank();

        assertTrue(fresh.isSealed());
        assertEq(fresh.owner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        vm.prank(deployer);
        fresh.setRecorder(relayer, true);
    }

    function test_SetRecorderAfterSealRevertsForOwnerRestoredByNobody() public {
        // After sealing nobody owns the log, so even the original deployer cannot touch the recorder set.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        vm.prank(deployer);
        settlement.setRecorder(relayer, true);
    }

    function test_SetRecorderStillRefusedIfOwnershipWereEverRestored() public {
        // Defense in depth: sealing renounces ownership, so `AlreadySealed` is unreachable through the public API.
        // A harness that restores an owner after sealing (a hypothetical future bug) still cannot add a recorder.
        SettlementLogHarness harness = new SettlementLogHarness(address(token), deployer);
        vm.startPrank(deployer);
        harness.seal();
        harness.forceOwner(deployer);
        vm.expectRevert(SettlementLog.AlreadySealed.selector);
        harness.setRecorder(relayer, true);
        vm.stopPrank();
    }

    function test_RevertWhen_ConstructedWithZeroAsset() public {
        vm.expectRevert(SettlementLog.ZeroAddress.selector);
        new SettlementLog(address(0), deployer);
    }

    function test_SealTwiceIsImpossible() public {
        SettlementLog fresh = new SettlementLog(address(token), deployer);
        vm.prank(deployer);
        fresh.seal();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        vm.prank(deployer);
        fresh.seal();
    }

    // ------------------------------------------------------------------ fuzz

    /// @notice Any resource other than the signed one is rejected, whatever the salt the relayer claims.
    function testFuzz_RevertWhen_ResourceDiffers(bytes32 otherResource, bytes32 claimedSalt) public {
        vm.assume(otherResource != RESOURCE);
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, ONE, RESOURCE, SALT);
        vm.expectRevert();
        settlement.settleExact(auth, otherResource, claimedSalt, sig);
        assertEq(settlement.receiptCount(), 0);
        assertEq(token.balanceOf(payee), 0);
    }

    /// @notice Settling moves exactly the signed value and records it verbatim.
    function testFuzz_SettleExact(uint256 value, bytes32 resourceHash, bytes32 salt) public {
        value = bound(value, 1, 100 * ONE);
        bytes32 id = _settleExact(value, resourceHash, salt);
        ISettlementLog.Receipt memory r = settlement.receiptOf(id);
        assertEq(r.amount, value);
        assertEq(r.resourceHash, resourceHash);
        assertEq(token.balanceOf(payee), value);
        assertEq(token.balanceOf(payer), 100 * ONE - value);
    }

    /// @notice Resource-bound nonces always have a zero sequence and a non-zero key in practice.
    function testFuzz_ExactNonceLayout(bytes32 resourceHash, bytes32 salt) public pure {
        bytes32 nonce = ResourceBinding.exactNonce(resourceHash, salt);
        assertEq(uint64(uint256(nonce)), 0);
        assertEq(
            nonce, bytes32(uint256(keccak256(abi.encode(ResourceBinding.EXACT_TAG, resourceHash, salt))) >> 64 << 64)
        );
    }
}
