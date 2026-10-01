// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {IERC20Errors} from "@openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin-contracts/utils/introspection/IERC165.sol";
import {IERC7540Deposit, IERC7540Operator, IERC7540Redeem} from "../../src/interfaces/IERC7540.sol";
import {IERC7575} from "../../src/interfaces/IERC7575.sol";
import {IERC7943Fungible} from "../../src/interfaces/IERC7943Fungible.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {FundVault} from "../../src/vault/FundVault.sol";
import {FundFixture} from "../utils/FundFixture.sol";

contract FundVaultTest is FundFixture {
    address internal unverified = makeAddr("unverified");

    // ---------------------------------------------------------------- construction and ERC-165

    function test_constructor_rejectsZeroNav() public {
        vm.expectRevert(FundVault.InvalidNav.selector);
        new FundVault(usdc, share, address(manager), 0);
    }

    function test_metadataAndInterfaces() public view {
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.share(), address(share));
        assertEq(vault.currentEpoch(), 1);
        assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5));
        assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65));
        assertEq(type(IERC7540Deposit).interfaceId, bytes4(0xce3bbe50));
        assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4));
        assertTrue(vault.supportsInterface(0x2f0a18c5));
        assertTrue(vault.supportsInterface(0xe3bc4e65));
        assertTrue(vault.supportsInterface(0xce3bbe50));
        assertTrue(vault.supportsInterface(0x620ee8e4));
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }

    function test_previewsRevert() public {
        vm.expectRevert(FundVault.AsyncFlow.selector);
        vault.previewDeposit(1);
        vm.expectRevert(FundVault.AsyncFlow.selector);
        vault.previewMint(1);
        vm.expectRevert(FundVault.AsyncFlow.selector);
        vault.previewWithdraw(1);
        vm.expectRevert(FundVault.AsyncFlow.selector);
        vault.previewRedeem(1);
    }

    // ---------------------------------------------------------------- operators

    function test_setOperator() public {
        vm.expectEmit(address(vault));
        emit IERC7540Operator.OperatorSet(alice, stranger, true);
        vm.prank(alice);
        assertTrue(vault.setOperator(stranger, true));
        assertTrue(vault.isOperator(alice, stranger));
        vm.prank(alice);
        vault.setOperator(stranger, false);
        assertFalse(vault.isOperator(alice, stranger));
    }

    function test_setOperator_rejectsSelf() public {
        vm.prank(alice);
        vm.expectRevert(FundVault.SelfOperator.selector);
        vault.setOperator(alice, true);
    }

    // ---------------------------------------------------------------- deposit requests

    function test_requestDeposit_locksAssetsAndEmits() public {
        _fund(alice, 100 * USDC);
        vm.expectEmit(address(vault));
        emit IERC7540Deposit.DepositRequest(alice, alice, 0, alice, 100 * USDC);
        vm.prank(alice);
        assertEq(vault.requestDeposit(100 * USDC, alice, alice), 0);
        assertEq(usdc.balanceOf(address(vault)), 100 * USDC);
        assertEq(vault.pendingDepositRequest(0, alice), 100 * USDC);
        assertEq(vault.claimableDepositRequest(0, alice), 0);
        assertEq(vault.totalPendingDepositAssets(), 100 * USDC);
        assertEq(vault.getEpoch(1).depositAssets, 100 * USDC);
    }

    function test_requestDeposit_byOperatorForOtherController() public {
        _fund(alice, 100 * USDC);
        vm.prank(alice);
        vault.setOperator(stranger, true);
        vm.prank(stranger);
        vault.requestDeposit(100 * USDC, bob, alice);
        assertEq(vault.pendingDepositRequest(0, bob), 100 * USDC);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_requestDeposit_revertsForUnauthorizedCaller() public {
        _fund(alice, 100 * USDC);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, alice));
        vault.requestDeposit(100 * USDC, stranger, alice);
    }

    function test_requestDeposit_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.requestDeposit(0, alice, alice);
    }

    function test_requestDeposit_revertsForIneligibleController() public {
        _fund(alice, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ControllerNotEligible.selector, unverified));
        vault.requestDeposit(100 * USDC, unverified, alice);
    }

    function test_requestDeposit_mergesWithinEpochAndSplitsAcrossEpochs() public {
        _requestDeposit(alice, 100 * USDC);
        _requestDeposit(alice, 50 * USDC);
        assertEq(vault.pendingDepositRequest(0, alice), 150 * USDC);
        _close();
        _requestDeposit(alice, 30 * USDC); // epoch 2 while epoch 1 awaits settlement
        assertEq(vault.pendingDepositRequest(0, alice), 180 * USDC);
        _postAndSettle(NAV_ONE);
        assertEq(vault.pendingDepositRequest(0, alice), 30 * USDC);
        assertEq(vault.claimableDepositRequest(0, alice), 150 * USDC);
        assertEq(vault.maxMint(alice), 150 * USDC);

        _requestDeposit(alice, 20 * USDC); // folds epoch 1 into claimable, reuses the slot
        assertEq(vault.pendingDepositRequest(0, alice), 50 * USDC);
        assertEq(vault.claimableDepositRequest(0, alice), 150 * USDC);
        _closeAndSettle(NAV_ONE);
        assertEq(vault.claimableDepositRequest(0, alice), 200 * USDC);
        assertEq(vault.pendingDepositRequest(0, alice), 0);
    }

    function test_requestViews_unknownRequestIdIsEmpty() public {
        _requestDeposit(alice, 100 * USDC);
        assertEq(vault.pendingDepositRequest(1, alice), 0);
        assertEq(vault.claimableDepositRequest(1, alice), 0);
        assertEq(vault.pendingRedeemRequest(1, alice), 0);
        assertEq(vault.claimableRedeemRequest(1, alice), 0);
    }

    // ---------------------------------------------------------------- deposit claims

    function test_deposit_partialClaimsSumExactly() public {
        _requestDeposit(alice, 100 * USDC);
        _closeAndSettle(1.02e18);
        uint256 total = vault.maxMint(alice);
        assertEq(total, 98_039_215); // floor(100e6 / 1.02)

        vm.startPrank(alice);
        uint256 s1 = vault.deposit(33 * USDC, alice, alice);
        uint256 s2 = vault.deposit(33 * USDC, alice, alice);
        uint256 s3 = vault.deposit(34 * USDC, alice, alice);
        vm.stopPrank();
        assertEq(s1 + s2 + s3, total);
        assertEq(s1, 32_352_940); // floor(33e6 * 98_039_215 / 100e6)
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.totalClaimableDepositShares(), 0);
    }

    function test_mint_roundsAssetsUpAndFinalClaimTakesRemainder() public {
        _requestDeposit(alice, 100 * USDC);
        _closeAndSettle(1.02e18);
        vm.startPrank(alice);
        uint256 assets = vault.mint(10 * USDC, alice, alice);
        assertEq(assets, 10_200_001); // ceil(10e6 * 100e6 / 98_039_215)
        uint256 rest = vault.maxMint(alice);
        uint256 lastAssets = vault.mint(rest, alice, alice);
        vm.stopPrank();
        assertEq(assets + lastAssets, 100 * USDC);
        assertEq(share.balanceOf(alice), 98_039_215);
    }

    function test_depositAndMint_twoArgOverloadsUseCallerAsController() public {
        _requestDeposit(alice, 100 * USDC);
        _closeAndSettle(NAV_ONE);
        vm.startPrank(alice);
        vault.deposit(40 * USDC, alice);
        vault.mint(60 * USDC, alice);
        vm.stopPrank();
        assertEq(share.balanceOf(alice), 100 * USDC);
    }

    function test_deposit_byOperatorToOtherReceiver() public {
        _requestDeposit(alice, 100 * USDC);
        _closeAndSettle(NAV_ONE);
        vm.prank(alice);
        vault.setOperator(stranger, true);
        vm.expectEmit(address(vault));
        emit IERC7575.Deposit(alice, bob, 100 * USDC, 100 * USDC);
        vm.prank(stranger);
        vault.deposit(100 * USDC, bob, alice);
        assertEq(share.balanceOf(bob), 100 * USDC);
    }

    function test_deposit_revertsForUnauthorized() public {
        _requestDeposit(alice, 100 * USDC);
        _closeAndSettle(NAV_ONE);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, alice));
        vault.deposit(1, stranger, alice);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, alice));
        vault.mint(1, stranger, alice);
    }

    function test_deposit_revertsOnZeroOrExcess() public {
        _requestDeposit(alice, 100 * USDC);
        _closeAndSettle(NAV_ONE);
        vm.startPrank(alice);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.deposit(0, alice, alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ExceedsClaimable.selector, 100 * USDC + 1, 100 * USDC));
        vault.deposit(100 * USDC + 1, alice, alice);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.mint(0, alice, alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ExceedsClaimable.selector, 100 * USDC + 1, 100 * USDC));
        vault.mint(100 * USDC + 1, alice, alice);
        vm.stopPrank();
    }

    function test_deposit_revertsBeforeSettlement() public {
        _requestDeposit(alice, 100 * USDC);
        _close();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ExceedsClaimable.selector, 1, 0));
        vault.deposit(1, alice, alice);
    }

    function test_deposit_claimToIneligibleReceiverFailsCompliance() public {
        _requestDeposit(alice, 100 * USDC);
        _closeAndSettle(NAV_ONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, unverified));
        vault.deposit(100 * USDC, unverified, alice);
    }

    // ---------------------------------------------------------------- redemption requests and claims

    function test_requestRedeem_burnsSharesAndEmits() public {
        _seed(alice, 100 * USDC);
        vm.expectEmit(address(vault));
        emit IERC7540Redeem.RedeemRequest(alice, alice, 0, alice, 40 * USDC);
        vm.prank(alice);
        assertEq(vault.requestRedeem(40 * USDC, alice, alice), 0);
        assertEq(share.balanceOf(alice), 60 * USDC);
        assertEq(vault.pendingRedeemRequest(0, alice), 40 * USDC);
        assertEq(vault.totalPendingRedeemShares(), 40 * USDC);
        assertEq(vault.outstandingShares(), 100 * USDC);
    }

    function test_requestRedeem_viaAllowance() public {
        _seed(alice, 100 * USDC);
        vm.prank(alice);
        share.approve(stranger, 30 * USDC);
        vm.prank(stranger);
        vault.requestRedeem(30 * USDC, alice, alice);
        assertEq(share.allowance(alice, stranger), 0);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, uint256(1))
        );
        vault.requestRedeem(1, alice, alice);
    }

    function test_requestRedeem_viaOperatorNeedsNoAllowance() public {
        _seed(alice, 100 * USDC);
        vm.prank(alice);
        vault.setOperator(stranger, true);
        vm.prank(stranger);
        vault.requestRedeem(100 * USDC, bob, alice);
        assertEq(vault.pendingRedeemRequest(0, bob), 100 * USDC);
    }

    function test_requestRedeem_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.requestRedeem(0, alice, alice);
    }

    function test_redeem_paysAtEpochNav() public {
        _seed(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(100 * USDC, alice, alice);
        usdc.mint(address(vault), 2 * USDC); // yield realised into the vault
        _closeAndSettle(1.015e18);
        assertEq(vault.maxRedeem(alice), 100 * USDC);
        assertEq(vault.maxWithdraw(alice), 101_500_000);
        assertEq(vault.claimableRedeemRequest(0, alice), 100 * USDC);

        vm.expectEmit(address(vault));
        emit IERC7575.Withdraw(alice, alice, alice, 50_750_000, 50 * USDC);
        vm.prank(alice);
        assertEq(vault.redeem(50 * USDC, alice, alice), 50_750_000);
        vm.prank(alice);
        assertEq(vault.withdraw(50_750_000, alice, alice), 50 * USDC);
        assertEq(usdc.balanceOf(alice), 101_500_000);
        assertEq(vault.totalReservedRedeemAssets(), 0);
    }

    function test_withdraw_roundsSharesUp() public {
        _seed(alice, 3);
        vm.prank(alice);
        vault.requestRedeem(3, alice, alice);
        usdc.mint(address(vault), 1);
        _closeAndSettle(1.02e18); // 3 shares -> floor(3.06) = 3 assets
        vm.startPrank(alice);
        assertEq(vault.withdraw(1, alice, alice), 1, "ceil(1 * 3 / 3)");
        assertEq(vault.withdraw(2, alice, alice), 2);
        vm.stopPrank();
    }

    function test_redeem_revertsForIneligibleReceiver() public {
        _seed(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(100 * USDC, alice, alice);
        _closeAndSettle(NAV_ONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ReceiverNotEligible.selector, unverified));
        vault.redeem(100 * USDC, unverified, alice);
    }

    function test_redeemAndWithdraw_revertOnZeroExcessOrUnauthorized() public {
        _seed(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(100 * USDC, alice, alice);
        _closeAndSettle(NAV_ONE);
        vm.startPrank(alice);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.redeem(0, alice, alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ExceedsClaimable.selector, 100 * USDC + 1, 100 * USDC));
        vault.redeem(100 * USDC + 1, alice, alice);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.withdraw(0, alice, alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ExceedsClaimable.selector, 100 * USDC + 1, 100 * USDC));
        vault.withdraw(100 * USDC + 1, alice, alice);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, alice));
        vault.redeem(1, stranger, alice);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, alice));
        vault.withdraw(1, stranger, alice);
    }

    // ---------------------------------------------------------------- epochs and NAV

    function test_closeEpoch_emitsAndAdvances() public {
        _requestDeposit(alice, 7 * USDC);
        vm.expectEmit(address(vault));
        emit FundVault.EpochClosed(1, uint64(block.timestamp), 7 * USDC, 0);
        _close();
        assertEq(vault.currentEpoch(), 2);
        assertEq(vault.epochAwaitingSettlement(), 1);
        assertEq(vault.getEpoch(1).cutoff, block.timestamp);
    }

    function test_closeEpoch_revertsWhileSettlementPending() public {
        _close();
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(FundVault.SettlementPending.selector, uint256(1)));
        vault.closeEpoch();
    }

    function test_settleEpoch_revertsWithoutClosedEpoch() public {
        vm.prank(fundAdmin);
        vm.expectRevert(FundVault.NoEpochAwaitingSettlement.selector);
        vault.settleEpoch();
    }

    function test_settleEpoch_forwardPricingRejectsNavAtOrBeforeCutoff() public {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(navOracle);
        vault.postNav(NAV_ONE, uint64(block.timestamp));
        _close(); // cutoff == NAV timestamp
        vm.prank(fundAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                FundVault.NavPredatesCutoff.selector, uint64(block.timestamp), uint64(block.timestamp)
            )
        );
        vault.settleEpoch();
    }

    function test_settleEpoch_rejectsStaleNav() public {
        _close();
        vm.warp(block.timestamp + 1);
        vm.prank(navOracle);
        vault.postNav(NAV_ONE, uint64(block.timestamp));
        uint64 asOf = uint64(block.timestamp);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NavStale.selector, asOf, block.timestamp));
        vault.settleEpoch();
    }

    function test_settleEpoch_acceptsNavExactly24hOld() public {
        _close();
        vm.warp(block.timestamp + 1);
        vm.prank(navOracle);
        vault.postNav(NAV_ONE, uint64(block.timestamp));
        vm.warp(block.timestamp + 24 hours);
        vm.prank(fundAdmin);
        vault.settleEpoch();
    }

    function test_settleEpoch_requiresLiquidityForRedemptions() public {
        _seed(alice, 100 * USDC);
        vm.prank(fundAdmin);
        vault.deployToCustodian(100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(100 * USDC, alice, alice);
        _close();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(navOracle);
        vault.postNav(NAV_ONE, uint64(block.timestamp));
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(FundVault.InsufficientLiquidity.selector, 100 * USDC, uint256(0)));
        vault.settleEpoch();

        vm.prank(fundAdmin);
        vault.recallFromCustodian(100 * USDC);
        vm.prank(fundAdmin);
        vault.settleEpoch();
        assertEq(vault.totalReservedRedeemAssets(), 100 * USDC);
    }

    function test_settleEpoch_netsDepositsAgainstRedemptions() public {
        _seed(alice, 100 * USDC);
        vm.prank(fundAdmin);
        vault.deployToCustodian(100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(60 * USDC, alice, alice);
        _requestDeposit(bob, 60 * USDC); // same-epoch subscription funds the redemption
        _closeAndSettle(NAV_ONE);
        assertEq(vault.totalReservedRedeemAssets(), 60 * USDC);
        assertEq(vault.idleAssets(), 0);
    }

    function test_settleEpoch_emitsTotals() public {
        _requestDeposit(alice, 100 * USDC);
        _close();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(navOracle);
        vault.postNav(1.01e18, uint64(block.timestamp));
        vm.expectEmit(address(vault));
        emit FundVault.EpochSettled(1, 1.01e18, uint64(block.timestamp), 100 * USDC, 99_009_900, 0, 0);
        vm.prank(fundAdmin);
        vault.settleEpoch();
        FundVault.Epoch memory e = vault.getEpoch(1);
        assertEq(e.nav, 1.01e18);
        assertEq(e.depositShares, 99_009_900);
        assertEq(e.settledAt, block.timestamp);
    }

    function test_postNav_bandAndTimestampChecks() public {
        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(navOracle);
        vm.expectRevert(
            abi.encodeWithSelector(FundVault.NavChangeTooLarge.selector, uint256(1.0201e18), uint256(NAV_ONE))
        );
        vault.postNav(1.0201e18, uint64(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(FundVault.NavChangeTooLarge.selector, uint256(0.9799e18), uint256(NAV_ONE))
        );
        vault.postNav(0.9799e18, uint64(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(FundVault.InvalidNavTimestamp.selector, uint64(block.timestamp + 1), uint64(START))
        );
        vault.postNav(NAV_ONE, uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(FundVault.InvalidNavTimestamp.selector, uint64(START), uint64(START)));
        vault.postNav(NAV_ONE, uint64(START));

        vm.expectEmit(address(vault));
        emit FundVault.NavPosted(1.02e18, uint64(block.timestamp), navOracle);
        vault.postNav(1.02e18, uint64(block.timestamp)); // exactly +2 %
        vm.stopPrank();
        (uint128 nav, uint64 asOf) = vault.latestNav();
        assertEq(nav, 1.02e18);
        assertEq(asOf, block.timestamp);
    }

    function test_postNav_restrictedToOracle() public {
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        vault.postNav(NAV_ONE, uint64(block.timestamp));
    }

    function test_resetNavReference_escapesCircuitBreaker() public {
        _requestDeposit(alice, 100 * USDC);
        _close();
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(address(vault));
        emit FundVault.NavReferenceReset(0.9e18, uint64(block.timestamp));
        vault.resetNavReference(0.9e18, uint64(block.timestamp)); // governance: -10 % credit event
        vm.prank(fundAdmin);
        vault.settleEpoch();
        assertEq(vault.maxMint(alice), 111_111_111);
    }

    function test_resetNavReference_validation() public {
        vm.expectRevert(FundVault.InvalidNav.selector);
        vault.resetNavReference(0, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(FundVault.InvalidNavTimestamp.selector, uint64(START), uint64(START)));
        vault.resetNavReference(NAV_ONE, uint64(START));
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        vault.resetNavReference(NAV_ONE, uint64(block.timestamp));
    }

    // ---------------------------------------------------------------- rounding dust

    function test_depositDustReturnsToFundOnceEpochFullyFolded() public {
        _requestDeposit(alice, 1 * USDC);
        _requestDeposit(bob, 1 * USDC);
        _requestDeposit(carol, 1 * USDC);
        _closeAndSettle(1.013e18);
        // Aggregate floor(3e6/1.013) = 2_961_500; per investor floor(1e6/1.013) = 987_166 -> dust 2.
        assertEq(vault.totalClaimableDepositShares(), 2_961_500);
        vm.prank(alice);
        vault.deposit(1 * USDC, alice, alice);
        vm.prank(bob);
        vault.deposit(1 * USDC, bob, bob);
        vm.expectEmit(address(vault));
        emit FundVault.EpochDustReleased(1, 2, 0);
        vm.prank(carol);
        vault.deposit(1 * USDC, carol, carol);
        assertEq(vault.totalClaimableDepositShares(), 0);
        assertEq(vault.getEpoch(1).depositSharesUnfolded, 0);
    }

    function test_redeemDustReturnsToFundOnceEpochFullyFolded() public {
        _seed(alice, 1 * USDC);
        _seed(bob, 1 * USDC);
        _seed(carol, 1 * USDC);
        usdc.mint(address(vault), 1 * USDC);
        vm.prank(alice);
        vault.requestRedeem(333_333, alice, alice);
        vm.prank(bob);
        vault.requestRedeem(333_333, bob, bob);
        vm.prank(carol);
        vault.requestRedeem(333_334, carol, carol);
        _closeAndSettle(1.013e18);
        // Aggregate floor(1e6 * 1.013) = 1_013_000; individual floors 337_666 + 337_666 + 337_667 = 1_012_999.
        assertEq(vault.totalReservedRedeemAssets(), 1_013_000);
        vm.prank(alice);
        vault.redeem(333_333, alice, alice);
        vm.prank(bob);
        vault.redeem(333_333, bob, bob);
        uint256 epochId = vault.currentEpoch() - 1; // the three seeds used epochs 1-3
        vm.expectEmit(address(vault));
        emit FundVault.EpochDustReleased(epochId, 0, 1);
        vm.prank(carol);
        vault.redeem(333_334, carol, carol);
        assertEq(vault.totalReservedRedeemAssets(), 0);
    }

    // ---------------------------------------------------------------- custody

    function test_setCustodian_governanceOnlyAndNotWhileDeployed() public {
        _seed(alice, 100 * USDC);
        vm.prank(fundAdmin);
        vault.deployToCustodian(10 * USDC);
        vm.expectRevert(abi.encodeWithSelector(FundVault.CustodianHasAssets.selector, 10 * USDC));
        vault.setCustodian(stranger);
        vm.prank(fundAdmin);
        vault.recallFromCustodian(10 * USDC);
        vm.expectEmit(address(vault));
        emit FundVault.CustodianSet(stranger);
        vault.setCustodian(stranger);
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        vault.setCustodian(custodian);
    }

    function test_deployToCustodian_onlyIdleAssets() public {
        _seed(alice, 100 * USDC);
        _requestDeposit(bob, 50 * USDC); // pending: not deployable
        assertEq(vault.idleAssets(), 100 * USDC);
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ExceedsIdleAssets.selector, 100 * USDC + 1, 100 * USDC));
        vault.deployToCustodian(100 * USDC + 1);
        vm.expectEmit(address(vault));
        emit FundVault.AssetsDeployed(custodian, 100 * USDC, 100 * USDC);
        vm.prank(fundAdmin);
        vault.deployToCustodian(100 * USDC);
        assertEq(usdc.balanceOf(custodian), 100 * USDC);
        assertEq(vault.deployedAssets(), 100 * USDC);
    }

    function test_recallFromCustodian_splitsPrincipalAndYield() public {
        _seed(alice, 100 * USDC);
        vm.prank(fundAdmin);
        vault.deployToCustodian(100 * USDC);
        usdc.mint(custodian, 3 * USDC);
        vm.expectEmit(address(vault));
        emit FundVault.AssetsRecalled(custodian, 103 * USDC, 100 * USDC, 3 * USDC);
        vm.prank(fundAdmin);
        vault.recallFromCustodian(103 * USDC);
        assertEq(vault.deployedAssets(), 0);
    }

    function test_custody_requiresCustodian() public {
        vault.setCustodian(address(0));
        vm.startPrank(fundAdmin);
        vm.expectRevert(FundVault.NoCustodian.selector);
        vault.deployToCustodian(1);
        vm.expectRevert(FundVault.NoCustodian.selector);
        vault.recallFromCustodian(1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- views

    function test_conversionAndAumViews() public {
        _seed(alice, 100 * USDC);
        _requestDeposit(bob, 10 * USDC);
        _close();
        _postAndSettle(1.01e18);
        assertEq(vault.convertToAssets(100 * USDC), 101 * USDC);
        assertEq(vault.convertToShares(101 * USDC), 100 * USDC);
        // 100 minted + 9_900_990 settled-but-unminted.
        assertEq(vault.outstandingShares(), 100 * USDC + 9_900_990);
        assertEq(vault.totalAssets(), (100 * USDC + 9_900_990) * 101 / 100);
    }

    // ---------------------------------------------------------------- construction: decimals

    function test_constructor_rejectsDecimalsMismatch() public {
        FundShareToken share18 = new FundShareToken("x", "x", 18, address(manager), registry, engine, documents);
        vm.expectRevert(abi.encodeWithSelector(FundVault.DecimalsMismatch.selector, uint8(6), uint8(18)));
        new FundVault(usdc, share18, address(manager), NAV_ONE);
    }

    // ---------------------------------------------------------------- subscriptions refused by compliance

    /// @dev Regression (review finding): a subscription whose country was already full was accepted and
    ///      settled, then could never be claimed, and the investor's cash had no way out.
    function test_regression_subscriptionIntoAFullCountryIsRejectedUpFront() public {
        _seed(alice, 10 * USDC);
        _seed(bob, 10 * USDC);
        vm.prank(complianceOfficer);
        maxHolders.setCountryCap(US, 2);
        address newbie = makeAddr("newbie");
        _onboard(newbie, keccak256("identity:newbie"), US);
        _fund(newbie, 500 * USDC);
        vm.prank(newbie);
        vm.expectRevert(
            abi.encodeWithSelector(FundVault.SubscriptionNotAdmissible.selector, newbie, uint256(510_204_082))
        );
        vault.requestDeposit(500 * USDC, newbie, newbie);
        assertEq(usdc.balanceOf(newbie), 500 * USDC);
    }

    /// @dev The second half of the same finding: when the cap fills up after the request was accepted, the
    ///      controller turns the settled subscription into a redemption and gets its cash back at the next NAV.
    function test_regression_unclaimableSubscriptionConvertsIntoARedemption() public {
        _seed(alice, 10 * USDC);
        vm.prank(complianceOfficer);
        maxHolders.setCountryCap(US, 2);
        address newbie = makeAddr("newbie");
        _onboard(newbie, keccak256("identity:newbie"), US);
        _requestDeposit(newbie, 500 * USDC); // admissible: one US slot left
        vm.prank(alice);
        share.transfer(bob, 1); // bob takes the last US slot before the claim
        _closeAndSettle(NAV_ONE);
        assertEq(vault.maxDeposit(newbie), 500 * USDC);
        vm.prank(newbie);
        vm.expectRevert(); // ComplianceModuleRejected(maxHolders, Mint, ...)
        vault.deposit(500 * USDC, newbie, newbie);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NotAuthorized.selector, stranger, newbie));
        vault.convertUnclaimableDeposit(newbie);

        uint256 epochId = vault.currentEpoch();
        vm.expectEmit(address(vault));
        emit FundVault.UnclaimableDepositConverted(newbie, newbie, epochId, 500 * USDC, 500 * USDC);
        vm.prank(newbie);
        assertEq(vault.convertUnclaimableDeposit(newbie), 500 * USDC);
        assertEq(vault.maxDeposit(newbie), 0);
        assertEq(vault.maxMint(newbie), 0);
        assertEq(vault.pendingRedeemRequest(0, newbie), 500 * USDC);
        assertEq(vault.totalClaimableDepositShares(), 0);
        assertEq(vault.totalPendingRedeemShares(), 500 * USDC);
        assertEq(vault.outstandingShares(), share.totalSupply() + 500 * USDC, "still outstanding until settled");

        _closeAndSettle(1.001e18); // forward pricing: the next NAV, like any redemption
        vm.prank(newbie);
        assertEq(vault.redeem(500 * USDC, newbie, newbie), 500_500_000);
        assertEq(usdc.balanceOf(newbie), 500_500_000);
        assertEq(share.balanceOf(newbie), 0, "the shares were never minted");
    }

    function test_convertUnclaimableDeposit_onlyWhenComplianceRefusesTheMint() public {
        _requestDeposit(alice, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(FundVault.ZeroAmount.selector); // nothing settled yet
        vault.convertUnclaimableDeposit(alice);
        _closeAndSettle(NAV_ONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.DepositStillClaimable.selector, alice, 100 * USDC));
        vault.convertUnclaimableDeposit(alice);
    }

    // ---------------------------------------------------------------- redemption request validation

    /// @dev Regression (review finding): a zero controller could never claim, and its unfolded request kept the
    ///      epoch's rounding dust reserved forever.
    function test_regression_requestRedeemRejectsZeroController() public {
        _seed(alice, 10 * USDC);
        vm.prank(alice);
        vm.expectRevert(FundVault.InvalidController.selector);
        vault.requestRedeem(10 * USDC, address(0), alice);
    }

    // ---------------------------------------------------------------- custody write-down

    /// @dev Regression (review finding): after any custody loss `deployedAssets` could never return to zero, so
    ///      governance could never replace the custodian, precisely when that matters.
    function test_regression_custodianReplaceableAfterALoss() public {
        _seed(alice, 1000 * USDC);
        vm.prank(fundAdmin);
        vault.deployToCustodian(1000 * USDC);
        usdc.burn(custodian, 1); // a one-unit loss at the custodian
        vm.prank(fundAdmin);
        vault.recallFromCustodian(1000 * USDC - 1);
        assertEq(vault.deployedAssets(), 1);
        address newCustodian = makeAddr("newCustodian");
        vm.expectRevert(abi.encodeWithSelector(FundVault.CustodianHasAssets.selector, uint256(1)));
        vault.setCustodian(newCustodian);

        vm.expectEmit(address(vault));
        emit FundVault.CustodyWrittenDown(custodian, 1, 0);
        vault.writeDownCustody(1); // governance
        assertEq(vault.deployedAssets(), 0);
        vault.setCustodian(newCustodian);
        assertEq(vault.custodian(), newCustodian);
    }

    function test_writeDownCustody_validationAndRole() public {
        _seed(alice, 100 * USDC);
        vm.prank(fundAdmin);
        vault.deployToCustodian(100 * USDC);
        vm.expectRevert(abi.encodeWithSelector(FundVault.InvalidWriteDown.selector, 0, 100 * USDC));
        vault.writeDownCustody(0);
        vm.expectRevert(abi.encodeWithSelector(FundVault.InvalidWriteDown.selector, 100 * USDC + 1, 100 * USDC));
        vault.writeDownCustody(100 * USDC + 1);
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        vault.writeDownCustody(1);
        vault.writeDownCustody(40 * USDC);
        assertEq(vault.deployedAssets(), 60 * USDC);
    }

    // ---------------------------------------------------------------- NAV window

    function _emptyEpochAt(uint128 nav) internal {
        _close();
        vm.warp(block.timestamp + 1);
        vm.prank(navOracle);
        vault.postNav(nav, uint64(block.timestamp));
        vm.prank(fundAdmin);
        vault.settleEpoch();
    }

    /// @dev Regression (review finding): the 2 % band applied per epoch and epochs have no minimum length, so
    ///      40 empty epochs two seconds apart walked the NAV below 0.46. Now the move is capped per 24 h window.
    function test_regression_navCannotBeRatchetedByFastEpochs() public {
        _emptyEpochAt(0.98e18); // the first 2 % step is allowed
        for (uint256 i; i < 40; ++i) {
            (uint128 ref,) = vault.referenceNav();
            uint128 target = uint128((uint256(ref) * 98 + 99) / 100);
            _close();
            vm.warp(block.timestamp + 1);
            vm.prank(navOracle);
            vm.expectRevert(abi.encodeWithSelector(FundVault.NavWindowChangeTooLarge.selector, target, 1e18));
            vault.postNav(target, uint64(block.timestamp));
            // Settling at the last posted NAV (0.98) is still fine: the reference does not move further.
            vm.prank(navOracle);
            vault.postNav(0.98e18, uint64(block.timestamp));
            vm.prank(fundAdmin);
            vault.settleEpoch();
        }
        (uint128 nav,) = vault.referenceNav();
        assertEq(nav, 0.98e18);
    }

    function test_navWindow_rollsAfter24Hours() public {
        _emptyEpochAt(0.98e18);
        (uint128 anchor, uint64 openedAt) = vault.navWindowAnchor();
        assertEq(anchor, NAV_ONE);
        (uint256 minNav, uint256 maxNav) = vault.navBounds();
        assertEq(minNav, 0.98e18, "window floor");
        assertEq(maxNav, 0.9996e18, "reference ceiling: 0.98 + 2 % of 0.98");

        vm.warp(openedAt + 24 hours - 2);
        _close();
        vm.warp(block.timestamp + 1);
        vm.prank(navOracle);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NavWindowChangeTooLarge.selector, 0.97e18, 1e18));
        vault.postNav(0.97e18, uint64(block.timestamp));

        vm.warp(openedAt + 24 hours);
        (minNav,) = vault.navBounds();
        assertEq(minNav, 0.9604e18, "a new window anchors at the current reference");
        vm.prank(navOracle);
        vault.postNav(0.9604e18, uint64(block.timestamp));
        vm.expectEmit(address(vault));
        emit FundVault.NavWindowOpened(0.98e18, uint64(block.timestamp));
        vm.prank(fundAdmin);
        vault.settleEpoch();
        (anchor, openedAt) = vault.navWindowAnchor();
        assertEq(anchor, 0.98e18);
        assertEq(openedAt, block.timestamp);
        (uint128 nav,) = vault.referenceNav();
        assertEq(nav, 0.9604e18);
    }

    function test_navWindow_upwardMovesAreCappedToo() public {
        _emptyEpochAt(1.02e18);
        _close();
        vm.warp(block.timestamp + 1);
        vm.prank(navOracle);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NavWindowChangeTooLarge.selector, 1.0201e18, 1e18));
        vault.postNav(1.0201e18, uint64(block.timestamp));
    }

    function test_resetNavReference_reanchorsTheWindow() public {
        _emptyEpochAt(0.98e18);
        vm.warp(block.timestamp + 1);
        vault.resetNavReference(0.5e18, uint64(block.timestamp));
        (uint128 anchor, uint64 openedAt) = vault.navWindowAnchor();
        assertEq(anchor, 0.5e18);
        assertEq(openedAt, block.timestamp);
        (uint256 minNav, uint256 maxNav) = vault.navBounds();
        assertEq(minNav, 0.49e18);
        assertEq(maxNav, 0.51e18);
    }
}
