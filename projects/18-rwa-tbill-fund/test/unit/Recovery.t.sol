// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {IERC7943Fungible} from "../../src/interfaces/IERC7943Fungible.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {FundVault} from "../../src/vault/FundVault.sol";
import {FundFixture} from "../utils/FundFixture.sol";

contract RecoveryTest is FundFixture {
    bytes32 internal constant CASE = keccak256("TA-CASE-0042");

    function setUp() public override {
        super.setUp();
        _seed(alice, 1000 * USDC);
        _bind(alice2, ID_ALICE); // new wallet after re-verification (compliance officer)
    }

    function _initiate() internal {
        vm.prank(transferAgent);
        share.initiateRecovery(alice, alice2, CASE);
    }

    function _initiateAndWait() internal {
        _initiate();
        vm.warp(block.timestamp + share.RECOVERY_DELAY());
    }

    // ---------------------------------------------------------------- initiate

    function test_initiate_schedulesAndFreezesLostWallet() public {
        uint64 eta = uint64(block.timestamp + 2 days);
        vm.expectEmit(address(share));
        emit FundShareToken.RecoveryInitiated(alice, alice2, ID_ALICE, eta, CASE);
        _initiate();
        (address successor, uint64 storedEta, bytes32 caseRef) = share.pendingRecovery(alice);
        assertEq(successor, alice2);
        assertEq(storedEta, eta);
        assertEq(caseRef, CASE);

        assertFalse(share.canSend(alice));
        assertFalse(share.canReceive(alice));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotSend.selector, alice));
        share.transfer(bob, 1);
    }

    function test_initiate_argumentValidation() public {
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidRecovery.selector, address(0), alice2));
        share.initiateRecovery(address(0), alice2, CASE);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidRecovery.selector, alice, address(0)));
        share.initiateRecovery(alice, address(0), CASE);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidRecovery.selector, alice, alice));
        share.initiateRecovery(alice, alice, CASE);
        vm.stopPrank();
    }

    function test_initiate_revertsWhenAlreadyPending() public {
        _initiate();
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.RecoveryAlreadyPending.selector, alice));
        share.initiateRecovery(alice, alice2, CASE);
    }

    function test_initiate_revertsForOtherIdentity() public {
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.RecoveryIdentityMismatch.selector, alice, bob, ID_ALICE));
        share.initiateRecovery(alice, bob, CASE);
    }

    function test_initiate_revertsForUnknownLostWallet() public {
        address ghost = makeAddr("ghost");
        vm.prank(transferAgent);
        vm.expectRevert(
            abi.encodeWithSelector(FundShareToken.RecoveryIdentityMismatch.selector, ghost, alice2, bytes32(0))
        );
        share.initiateRecovery(ghost, alice2, CASE);
    }

    function test_initiate_revertsWhenSuccessorNotEligible() public {
        vm.prank(complianceOfficer);
        registry.removeClaim(ID_ALICE, 1);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, alice2));
        share.initiateRecovery(alice, alice2, CASE);
    }

    function test_initiate_revertsForRetiredWallet() public {
        _initiateAndWait();
        vm.prank(transferAgent);
        share.executeRecovery(alice);
        address alice3 = makeAddr("alice3");
        _bind(alice3, ID_ALICE);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.WalletRetired.selector, alice));
        share.initiateRecovery(alice, alice3, CASE);
    }

    function test_initiate_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        share.initiateRecovery(alice, alice2, CASE);
    }

    // ---------------------------------------------------------------- cancel / veto

    function test_cancel_byTransferAgent() public {
        _initiate();
        vm.expectEmit(address(share));
        emit FundShareToken.RecoveryCancelled(alice, alice2, transferAgent);
        vm.prank(transferAgent);
        share.cancelRecovery(alice);
        assertTrue(share.canSend(alice));
    }

    function test_veto_byLostWalletProvesControl() public {
        _initiate();
        vm.expectEmit(address(share));
        emit FundShareToken.RecoveryCancelled(alice, alice2, alice);
        vm.prank(alice);
        share.vetoRecovery();
        vm.warp(block.timestamp + 3 days);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NoPendingRecovery.selector, alice));
        share.executeRecovery(alice);
    }

    function test_cancelAndVeto_revertWithoutPending() public {
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NoPendingRecovery.selector, alice));
        share.cancelRecovery(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NoPendingRecovery.selector, bob));
        share.vetoRecovery();
    }

    // ---------------------------------------------------------------- execute

    function test_execute_revertsBeforeTimelockExact() public {
        _initiate();
        (, uint64 eta,) = share.pendingRecovery(alice);
        vm.warp(eta - 1);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.RecoveryTimelocked.selector, alice, eta));
        share.executeRecovery(alice);
    }

    function test_execute_revertsWithoutPending() public {
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.NoPendingRecovery.selector, alice));
        share.executeRecovery(alice);
    }

    function test_execute_revalidatesIdentityBinding() public {
        _initiateAndWait();
        vm.startPrank(complianceOfficer);
        registry.unregisterWallet(alice2);
        registry.registerWallet(alice2, ID_BOB);
        vm.stopPrank();
        vm.startPrank(transferAgent);
        vm.expectRevert(
            abi.encodeWithSelector(FundShareToken.RecoveryIdentityMismatch.selector, alice, alice2, ID_ALICE)
        );
        share.executeRecovery(alice);
        vm.stopPrank();
    }

    function test_execute_revertsIfSuccessorLostEligibilityDuringDelay() public {
        _initiateAndWait();
        vm.prank(complianceOfficer);
        registry.removeClaim(ID_ALICE, 2);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, alice2));
        share.executeRecovery(alice);
    }

    function test_execute_movesBalanceFreezeAndLockAndRetires() public {
        _subscribe(alice, 100 * USDC); // fresh lock of 100
        vm.prank(complianceOfficer);
        share.setFrozenTokens(alice, 250 * USDC);
        _initiateAndWait();
        uint256 holdersBefore = engine.holderCount(US);

        vm.expectEmit(address(share));
        emit IERC7943Fungible.Frozen(alice, 0);
        vm.expectEmit(address(share));
        emit IERC7943Fungible.Frozen(alice2, 250 * USDC);
        vm.expectEmit(address(share));
        emit FundShareToken.RecoveryExecuted(alice, alice2, 1100 * USDC, 250 * USDC, CASE);
        vm.prank(transferAgent);
        uint256 moved = share.executeRecovery(alice);

        assertEq(moved, 1100 * USDC);
        assertEq(share.balanceOf(alice), 0);
        assertEq(share.balanceOf(alice2), 1100 * USDC);
        assertEq(share.getFrozenTokens(alice2), 250 * USDC);
        assertEq(share.getFrozenTokens(alice), 0);
        assertEq(engine.holderCount(US), holdersBefore, "same investor: holder count unchanged");
        assertEq(engine.investorBalance(ID_ALICE), 1100 * USDC);
        assertEq(share.successorOf(alice), alice2);
        assertEq(share.currentWalletOf(alice), alice2);
        assertEq(share.currentWalletOf(bob), bob);

        assertFalse(share.canReceive(alice), "retired forever");
        _seed(bob, 10 * USDC);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, alice));
        share.transfer(alice, 1);
    }

    function test_execute_movesActiveLockToSuccessor() public {
        vm.prank(complianceOfficer);
        lockup.setLockupPeriod(30 days);
        _subscribe(alice, 100 * USDC);
        _initiateAndWait();
        vm.prank(transferAgent);
        share.executeRecovery(alice);
        assertEq(lockup.lockedBalanceOf(alice), 0);
        assertEq(lockup.lockedBalanceOf(alice2), 100 * USDC);
    }

    function test_execute_withZeroBalanceStillRetires() public {
        address empty = makeAddr("empty");
        address empty2 = makeAddr("empty2");
        _bind(empty, ID_CAROL);
        _bind(empty2, ID_CAROL);
        vm.startPrank(transferAgent);
        share.initiateRecovery(empty, empty2, CASE);
        vm.warp(block.timestamp + 2 days);
        assertEq(share.executeRecovery(empty), 0);
        vm.stopPrank();
        assertEq(share.successorOf(empty), empty2);
    }

    function test_successorClaimsPendingVaultRequestsOfLostWallet() public {
        _requestDeposit(alice, 500 * USDC);
        _closeAndSettle(NAV_ONE);
        _initiateAndWait();
        vm.prank(transferAgent);
        share.executeRecovery(alice);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, alice));
        vault.deposit(500 * USDC, stranger, alice);

        vm.prank(alice2);
        uint256 shares = vault.deposit(500 * USDC, alice2, alice);
        assertEq(shares, 500 * USDC);
        assertEq(share.balanceOf(alice2), 1500 * USDC);
    }

    function test_currentWalletOf_boundedChain() public {
        address current = alice;
        for (uint256 i; i < share.MAX_SUCCESSION_DEPTH() + 1; ++i) {
            address next = makeAddr(string.concat("aliceWallet", vm.toString(i)));
            _bind(next, ID_ALICE);
            vm.startPrank(transferAgent);
            share.initiateRecovery(current, next, CASE);
            vm.warp(block.timestamp + 2 days);
            share.executeRecovery(current);
            vm.stopPrank();
            current = next;
        }
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.SuccessionTooDeep.selector, alice));
        share.currentWalletOf(alice);
        address second = makeAddr("aliceWallet0");
        assertEq(share.currentWalletOf(second), current);
    }

    // ---------------------------------------------------------------- separation of duties and cooldowns

    /// @dev Regression (review finding): the transfer agent used to hold wallet binding as well, so it could bind
    ///      a wallet it controls to any holder's identity and recover the whole position to it. Binding is now
    ///      a compliance-officer power, so the transfer agent alone cannot complete a recovery to its own wallet.
    function test_regression_transferAgentAloneCannotRecoverToAWalletItBinds() public {
        address agentWallet = makeAddr("agentWallet");
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        registry.registerWallet(agentWallet, ID_ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(FundShareToken.RecoveryIdentityMismatch.selector, alice, agentWallet, ID_ALICE)
        );
        share.initiateRecovery(alice, agentWallet, CASE);
        vm.stopPrank();
        assertEq(share.balanceOf(alice), 1000 * USDC);
        assertTrue(share.canSend(alice), "no pending recovery locks alice out");
    }

    function test_veto_startsCooldownAgainstReinitiation() public {
        _initiate();
        vm.prank(alice);
        share.vetoRecovery();
        uint64 until = uint64(block.timestamp + share.RECOVERY_COOLDOWN());
        assertEq(share.recoveryCooldownUntil(alice), until);
        assertTrue(share.canSend(alice), "the veto lifts the recovery lock immediately");

        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.RecoveryCoolingDown.selector, alice, until));
        share.initiateRecovery(alice, alice2, CASE);
        vm.warp(until - 1);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.RecoveryCoolingDown.selector, alice, until));
        share.initiateRecovery(alice, alice2, CASE);
        vm.warp(until);
        _initiate();
        (address successor,,) = share.pendingRecovery(alice);
        assertEq(successor, alice2);
    }

    function test_cancel_startsCooldownToo() public {
        _initiate();
        vm.prank(transferAgent);
        share.cancelRecovery(alice);
        uint64 until = uint64(block.timestamp + share.RECOVERY_COOLDOWN());
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.RecoveryCoolingDown.selector, alice, until));
        share.initiateRecovery(alice, alice2, CASE);
    }

    /// @dev A thief holding the key can veto every recovery. Fallback: the compliance officer freezes and
    ///      unbinds the stolen wallet, the fund administrator issues a lawful order, the transfer agent executes it.
    function test_stolenKeyFallback_lawfulOrderMovesThePosition() public {
        _initiate();
        vm.prank(alice); // the thief, who holds alice's key
        share.vetoRecovery();

        vm.startPrank(complianceOfficer);
        share.setFrozenTokens(alice, type(uint256).max);
        registry.unregisterWallet(alice);
        vm.stopPrank();
        assertFalse(share.canSend(alice));

        bytes32 order = keccak256("order:stolen-key");
        _issueOrder(order, alice, alice2, 1000 * USDC);
        vm.prank(transferAgent);
        share.forcedTransfer(alice, alice2, 1000 * USDC, order);
        assertEq(share.balanceOf(alice), 0);
        assertEq(share.balanceOf(alice2), 1000 * USDC);
        assertEq(engine.investorBalance(ID_ALICE), 1000 * USDC, "same investor, position intact");
    }

    // ---------------------------------------------------------------- vault claims follow the succession

    function _settledRedemption(uint256 shares) internal {
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        _closeAndSettle(NAV_ONE);
    }

    /// @dev Regression (review finding): a retired wallet, and any operator it approved, could still claim its
    ///      settled redemption ahead of the successor and send the proceeds anywhere eligible.
    function test_regression_retiredWalletAndItsOperatorsCannotClaim() public {
        vm.prank(alice);
        vault.setOperator(stranger, true);
        _settledRedemption(1000 * USDC);
        _initiateAndWait();
        vm.prank(transferAgent);
        share.executeRecovery(alice);
        assertEq(share.currentWalletOf(alice), alice2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, alice, alice));
        vault.redeem(1000 * USDC, bob, alice);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, alice));
        vault.redeem(1000 * USDC, bob, alice);

        assertEq(vault.maxRedeem(alice), 1000 * USDC, "still claimable by the successor");
        vm.prank(alice2);
        assertEq(vault.redeem(1000 * USDC, alice2, alice), 1000 * USDC);
        assertEq(usdc.balanceOf(alice2), 1000 * USDC);
        assertEq(usdc.balanceOf(bob), 0);
    }

    function test_successorOperatorsMayClaimForTheRetiredController() public {
        _settledRedemption(400 * USDC);
        _initiateAndWait();
        vm.prank(transferAgent);
        share.executeRecovery(alice);
        vm.prank(alice2);
        vault.setOperator(stranger, true);
        vm.prank(stranger);
        vault.withdraw(400 * USDC, alice2, alice);
        assertEq(usdc.balanceOf(alice2), 400 * USDC);
    }

    /// @dev The retired controller itself can never be minted to; what matters is whether its successor can.
    function test_convertUnclaimableDeposit_isJudgedForTheSuccessorWallet() public {
        _requestDeposit(alice, 500 * USDC);
        _closeAndSettle(NAV_ONE);
        _initiateAndWait();
        vm.prank(transferAgent);
        share.executeRecovery(alice);
        vm.prank(alice2);
        vm.expectRevert(abi.encodeWithSelector(FundVault.DepositStillClaimable.selector, alice, 500 * USDC));
        vault.convertUnclaimableDeposit(alice);
    }

    function test_claimsWaitWhileARecoveryIsPending() public {
        _settledRedemption(1000 * USDC);
        _initiate();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ControllerRecoveryPending.selector, alice, alice));
        vault.redeem(1000 * USDC, alice, alice);
        vm.prank(alice2);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ControllerRecoveryPending.selector, alice, alice));
        vault.redeem(1000 * USDC, alice2, alice);

        vm.prank(alice);
        share.vetoRecovery(); // the key was not lost after all
        vm.prank(alice);
        assertEq(vault.redeem(1000 * USDC, alice, alice), 1000 * USDC);
    }
}
