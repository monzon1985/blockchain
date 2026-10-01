// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin-contracts/utils/introspection/IERC165.sol";
import {IERC7575Share} from "../../src/interfaces/IERC7575.sol";
import {IERC7943Fungible} from "../../src/interfaces/IERC7943Fungible.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {FundFixture} from "../utils/FundFixture.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";
import {ReentrantModule, RevertingModule} from "../mocks/Mocks.sol";

contract FundShareTokenTest is FundFixture {
    bytes32 internal constant ORDER = keccak256("order:2026-001");
    address internal unverified = makeAddr("unverified");

    function setUp() public override {
        super.setUp();
        _seed(alice, 1000 * USDC);
        _seed(bob, 1000 * USDC);
    }

    function _freeze(address account, uint256 amount) internal {
        vm.prank(complianceOfficer);
        share.setFrozenTokens(account, amount);
    }

    // ---------------------------------------------------------------- metadata and ERC-165

    function test_metadata() public view {
        assertEq(share.name(), "Demo T-Bill Fund Share");
        assertEq(share.symbol(), "dTBILL");
        assertEq(share.decimals(), 6);
        assertEq(address(share.identityRegistry()), address(registry));
        assertEq(address(share.compliance()), address(engine));
        assertEq(address(share.documents()), address(documents));
        assertEq(share.vault(address(usdc)), address(vault));
    }

    function test_interfaceIdsMatchTheErcs() public view {
        assertEq(type(IERC7943Fungible).interfaceId, bytes4(0x3edbb4c4));
        assertEq(type(IERC7575Share).interfaceId, bytes4(0xf815c03d));
        assertTrue(share.supportsInterface(0x3edbb4c4));
        assertTrue(share.supportsInterface(0xf815c03d));
        assertTrue(share.supportsInterface(type(IERC20).interfaceId));
        assertTrue(share.supportsInterface(type(IERC165).interfaceId));
        assertFalse(share.supportsInterface(0xffffffff));
    }

    function test_setVault_governanceOnly() public {
        vm.expectEmit(address(share));
        emit IERC7575Share.VaultUpdate(address(usdc), address(0));
        share.setVault(address(usdc), address(0));
        assertEq(share.vault(address(usdc)), address(0));

        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, fundAdmin));
        share.setVault(address(usdc), address(vault));
    }

    // ---------------------------------------------------------------- compliant transfers

    function test_transfer_betweenVerifiedInvestors() public {
        vm.prank(alice);
        assertTrue(share.transfer(carol, 250 * USDC));
        assertEq(share.balanceOf(carol), 250 * USDC);
        assertEq(engine.holderCount(DE), 1);
    }

    function test_transferFrom_spendsAllowance() public {
        vm.prank(alice);
        share.approve(stranger, 100 * USDC);
        vm.prank(stranger);
        share.transferFrom(alice, carol, 60 * USDC);
        assertEq(share.allowance(alice, stranger), 40 * USDC);
        assertEq(share.balanceOf(carol), 60 * USDC);
    }

    function test_transfer_revertsToUnverifiedRecipient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, unverified));
        share.transfer(unverified, 1);
    }

    function test_transfer_revertsEvenForZeroAmountToUnverified() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, unverified));
        share.transfer(unverified, 0);
    }

    function test_transfer_revertsFromSenderWithExpiredKyc() public {
        vm.prank(complianceOfficer);
        registry.removeClaim(ID_ALICE, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotSend.selector, alice));
        share.transfer(bob, 1);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000 * USDC, 1000 * USDC + 1)
        );
        share.transfer(bob, 1000 * USDC + 1);
    }

    function test_transfer_respectsPartialFreeze() public {
        _freeze(alice, 900 * USDC);
        vm.startPrank(alice);
        share.transfer(bob, 100 * USDC);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, alice, 1, 0)
        );
        share.transfer(bob, 1);
        vm.stopPrank();
    }

    function test_transfer_freezeAboveBalanceBlocksEverything() public {
        _freeze(alice, 5000 * USDC);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, alice, 1, 0)
        );
        share.transfer(bob, 1);
    }

    function test_freezeBlocksRedemptionRequests() public {
        _freeze(alice, 1000 * USDC);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC7943Fungible.ERC7943InsufficientUnfrozenBalance.selector, alice, 1, 0)
        );
        vault.requestRedeem(1, alice, alice);
    }

    // ---------------------------------------------------------------- ERC-7943 views

    function test_canSendCanReceive() public view {
        assertTrue(share.canSend(alice));
        assertTrue(share.canReceive(alice));
        assertTrue(share.canTransact(alice));
        assertFalse(share.canSend(unverified));
        assertFalse(share.canReceive(unverified));
        assertFalse(share.canTransact(unverified));
        assertFalse(share.canReceive(address(0)));
    }

    function test_canTransfer_matchesEnforcement() public {
        assertTrue(share.canTransfer(alice, bob, 10));
        assertFalse(share.canTransfer(alice, unverified, 10));
        assertFalse(share.canTransfer(unverified, alice, 10));
        _freeze(alice, 995 * USDC);
        assertTrue(share.canTransfer(alice, bob, 5 * USDC));
        assertFalse(share.canTransfer(alice, bob, 5 * USDC + 1));
    }

    function test_canTransfer_doesNotFailOnPlainBalanceShortfall() public view {
        assertTrue(share.canTransfer(alice, bob, 10_000 * USDC));
    }

    function test_canTransfer_neverRevertsWhenAModuleReverts() public {
        RevertingModule bad = new RevertingModule(address(engine));
        vm.prank(complianceOfficer);
        engine.addModule(address(bad));
        assertFalse(share.canTransfer(alice, bob, 1));
        vm.prank(alice);
        vm.expectRevert(bytes("boom"));
        share.transfer(bob, 1);
    }

    function test_canMint_eligibilityAndModules() public {
        assertTrue(share.canMint(alice, 1));
        assertFalse(share.canMint(unverified, 1), "ineligible recipient");
        vm.prank(complianceOfficer);
        maxHolders.setCountryCap(DE, 0);
        assertFalse(share.canMint(carol, 1), "a module rejects the new holder");
        vm.prank(complianceOfficer);
        investorCap.setMaxPerInvestor(1000 * USDC);
        assertTrue(share.canMint(alice, 0));
        assertFalse(share.canMint(alice, 1), "investor cap reached");
    }

    function test_canMint_neverRevertsWhenAModuleReverts() public {
        RevertingModule bad = new RevertingModule(address(engine));
        vm.prank(complianceOfficer);
        engine.addModule(address(bad));
        assertFalse(share.canMint(alice, 1));
    }

    function test_moduleCannotReenterAMovement() public {
        ReentrantModule bad = new ReentrantModule(address(engine), address(share));
        vm.prank(complianceOfficer);
        engine.addModule(address(bad));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        share.transfer(bob, 1);
    }

    // ---------------------------------------------------------------- freezes

    function test_setFrozenTokens_emitsAndMayExceedBalance() public {
        vm.expectEmit(address(share));
        emit IERC7943Fungible.Frozen(alice, 10_000 * USDC);
        vm.prank(complianceOfficer);
        assertTrue(share.setFrozenTokens(alice, 10_000 * USDC));
        assertEq(share.getFrozenTokens(alice), 10_000 * USDC);
    }

    function test_setFrozenTokens_restricted() public {
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        share.setFrozenTokens(alice, 1);
    }

    // ---------------------------------------------------------------- vault-only entry points

    function test_mintAndBurn_vaultOnly() public {
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        share.mint(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        share.burnForRedemption(alice, address(0), 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- lawful orders

    function test_issueLawfulOrder_storesAndEmits() public {
        vm.prank(fundAdmin);
        documents.setDocument(ORDER_DOC, "ipfs://bafy-order", keccak256("order pdf"));
        uint64 expiresAt = uint64(block.timestamp + 7 days);
        vm.expectEmit(address(share));
        emit FundShareToken.LawfulOrderIssued(
            ORDER, alice, bob, 300 * USDC, expiresAt, ORDER_DOC, keccak256("order pdf")
        );
        vm.prank(fundAdmin);
        share.issueLawfulOrder(ORDER, alice, bob, 300 * USDC, expiresAt, ORDER_DOC);
        (address from, uint64 storedExpiry, address to, uint256 remaining, bytes32 documentHash) =
            share.lawfulOrders(ORDER);
        assertEq(from, alice);
        assertEq(storedExpiry, expiresAt);
        assertEq(to, bob);
        assertEq(remaining, 300 * USDC);
        assertEq(documentHash, keccak256("order pdf"));
    }

    function test_issueLawfulOrder_validation() public {
        vm.startPrank(fundAdmin);
        documents.setDocument(ORDER_DOC, "ipfs://bafy-order", keccak256("order pdf"));
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidLawfulOrder.selector, bytes32(0)));
        share.issueLawfulOrder(bytes32(0), alice, bob, 1, expiry, ORDER_DOC);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidLawfulOrder.selector, ORDER));
        share.issueLawfulOrder(ORDER, address(0), bob, 1, expiry, ORDER_DOC);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidLawfulOrder.selector, ORDER));
        share.issueLawfulOrder(ORDER, alice, address(0), 1, expiry, ORDER_DOC);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidLawfulOrder.selector, ORDER));
        share.issueLawfulOrder(ORDER, alice, alice, 1, expiry, ORDER_DOC);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidLawfulOrder.selector, ORDER));
        share.issueLawfulOrder(ORDER, alice, bob, 0, expiry, ORDER_DOC);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InvalidLawfulOrder.selector, ORDER));
        share.issueLawfulOrder(ORDER, alice, bob, 1, uint64(block.timestamp), ORDER_DOC);
        bytes32 missing = "never-anchored";
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderNotAnchored.selector, missing));
        share.issueLawfulOrder(ORDER, alice, bob, 1, expiry, missing);

        share.issueLawfulOrder(ORDER, alice, bob, 1, expiry, ORDER_DOC);
        share.revokeLawfulOrder(ORDER);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderExists.selector, ORDER));
        share.issueLawfulOrder(ORDER, alice, bob, 1, expiry, ORDER_DOC); // ids are single-use, even once spent
        vm.stopPrank();
    }

    function test_lawfulOrders_fundAdminOnly() public {
        vm.prank(fundAdmin);
        documents.setDocument(ORDER_DOC, "ipfs://bafy-order", keccak256("order pdf"));
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        share.issueLawfulOrder(ORDER, alice, bob, 1, uint64(block.timestamp + 1 days), ORDER_DOC);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        share.revokeLawfulOrder(ORDER);
        vm.stopPrank();
    }

    function test_revokeLawfulOrder_emitsAndStopsExecution() public {
        _issueOrder(ORDER, alice, bob, 500 * USDC);
        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, 200 * USDC, ORDER);
        vm.expectEmit(address(share));
        emit FundShareToken.LawfulOrderRevoked(ORDER, 300 * USDC);
        vm.prank(fundAdmin);
        share.revokeLawfulOrder(ORDER);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderExceeded.selector, ORDER, 1, 0));
        share.forcedTransfer(alice, bob, 1, ORDER);
    }

    function test_revokeLawfulOrder_revertsForUnknownOrder() public {
        vm.prank(fundAdmin);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.UnknownLawfulOrder.selector, ORDER));
        share.revokeLawfulOrder(ORDER);
    }

    // ---------------------------------------------------------------- forced transfers

    function test_forcedTransfer_withLawfulOrderBypassesFreeze() public {
        _issueOrder(ORDER, alice, bob, 300 * USDC);
        _freeze(alice, 1000 * USDC);
        vm.expectEmit(address(share));
        emit IERC7943Fungible.Frozen(alice, 700 * USDC);
        vm.expectEmit(address(share));
        emit IERC20.Transfer(alice, bob, 300 * USDC);
        vm.expectEmit(address(share));
        emit IERC7943Fungible.ForcedTransfer(alice, bob, 300 * USDC);
        vm.expectEmit(address(share));
        emit FundShareToken.LawfulOrderEnforced(ORDER, keccak256("order pdf"), alice, bob, 300 * USDC, 0);
        vm.prank(transferAgent);
        assertTrue(share.forcedTransfer(alice, bob, 300 * USDC, ORDER));
        assertEq(share.balanceOf(bob), 1300 * USDC);
        assertEq(share.getFrozenTokens(alice), 700 * USDC);
    }

    function test_forcedTransfer_unfrozenPartLeavesFreezeUntouched() public {
        _issueOrder(ORDER, alice, bob, 400 * USDC);
        _freeze(alice, 500 * USDC);
        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, 400 * USDC, ORDER);
        assertEq(share.getFrozenTokens(alice), 500 * USDC);
    }

    function test_forcedTransfer_fromIneligibleSender() public {
        _issueOrder(ORDER, alice, bob, 1000 * USDC);
        vm.prank(complianceOfficer);
        registry.removeClaim(ID_ALICE, 2);
        assertFalse(share.canSend(alice));
        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, 1000 * USDC, ORDER);
        assertEq(share.balanceOf(alice), 0);
        assertEq(engine.holderCount(US), 1);
    }

    function test_forcedTransfer_neverBypassesRecipientEligibility() public {
        _issueOrder(ORDER, alice, unverified, 1);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, unverified));
        share.forcedTransfer(alice, unverified, 1, ORDER);
    }

    function test_forcedTransfer_unknownOrderRejected() public {
        bytes32 missing = keccak256("missing");
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.UnknownLawfulOrder.selector, missing));
        share.forcedTransfer(alice, bob, 1, missing);
    }

    function test_forcedTransfer_orderBindsBothParties() public {
        _issueOrder(ORDER, alice, bob, 1000 * USDC);
        _seed(carol, 10 * USDC);
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderMismatch.selector, ORDER, alice, carol));
        share.forcedTransfer(alice, carol, 1, ORDER);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderMismatch.selector, ORDER, carol, bob));
        share.forcedTransfer(carol, bob, 1, ORDER);
        vm.stopPrank();
    }

    function test_forcedTransfer_orderIsConsumedUpToItsAmount() public {
        _issueOrder(ORDER, alice, bob, 500 * USDC);
        vm.startPrank(transferAgent);
        share.forcedTransfer(alice, bob, 300 * USDC, ORDER);
        vm.expectRevert(
            abi.encodeWithSelector(FundShareToken.LawfulOrderExceeded.selector, ORDER, 200 * USDC + 1, 200 * USDC)
        );
        share.forcedTransfer(alice, bob, 200 * USDC + 1, ORDER);
        share.forcedTransfer(alice, bob, 200 * USDC, ORDER);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderExceeded.selector, ORDER, 1, 0));
        share.forcedTransfer(alice, bob, 1, ORDER);
        vm.stopPrank();
        assertEq(share.balanceOf(alice), 500 * USDC);
        assertEq(share.balanceOf(bob), 1500 * USDC);
    }

    function test_forcedTransfer_expiredOrderRejected() public {
        _issueOrder(ORDER, alice, bob, 500 * USDC);
        (, uint64 expiresAt,,,) = share.lawfulOrders(ORDER);
        vm.warp(expiresAt - 1);
        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, 1, ORDER);
        vm.warp(expiresAt);
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderExpired.selector, ORDER, expiresAt));
        share.forcedTransfer(alice, bob, 1, ORDER);
    }

    /// @dev Regression (review finding): any anchored document used to count as a lawful order, the order was
    ///      not tied to its parties or amount and could be replayed forever, and the transfer agent could bind
    ///      a wallet of its own to a verified identity. A transfer agent alone can no longer seize shares.
    function test_regression_transferAgentAloneCannotSeizeShares() public {
        address agentWallet = makeAddr("agentWallet");
        vm.prank(fundAdmin);
        documents.setDocument("PROSPECTUS", "ipfs://prospectus", keccak256("prospectus"));
        _issueOrder(ORDER, alice, bob, 100 * USDC); // a genuine order, for other parties

        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        registry.registerWallet(agentWallet, ID_CAROL);

        // Even with a wallet bound to a verified identity (which takes the compliance officer), no order allows it.
        _bind(agentWallet, ID_CAROL);
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.UnknownLawfulOrder.selector, bytes32("PROSPECTUS")));
        share.forcedTransfer(alice, agentWallet, 1000 * USDC, "PROSPECTUS");
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderMismatch.selector, ORDER, alice, agentWallet));
        share.forcedTransfer(alice, agentWallet, 100 * USDC, ORDER);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderMismatch.selector, ORDER, bob, agentWallet));
        share.forcedTransfer(bob, agentWallet, 100 * USDC, ORDER);
        share.forcedTransfer(alice, bob, 100 * USDC, ORDER);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.LawfulOrderExceeded.selector, ORDER, 100 * USDC, 0));
        share.forcedTransfer(alice, bob, 100 * USDC, ORDER); // no replay
        vm.stopPrank();

        assertEq(share.balanceOf(agentWallet), 0);
        assertEq(share.balanceOf(alice), 900 * USDC);
        assertEq(share.balanceOf(bob), 1100 * USDC);
    }

    function test_forcedTransfer_argumentValidation() public {
        // Zero and identical parties cannot be named in an order; the governance entry point checks them too.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        share.forcedTransfer(address(0), bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        share.forcedTransfer(alice, address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ForcedTransferToSelf.selector, alice));
        share.forcedTransfer(alice, alice, 1);

        _issueOrder(ORDER, alice, bob, 2000 * USDC);
        vm.prank(transferAgent);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000 * USDC, 1000 * USDC + 1)
        );
        share.forcedTransfer(alice, bob, 1000 * USDC + 1, ORDER);
    }

    function test_forcedTransfer_referencelessEntryPointIsGovernanceOnly() public {
        vm.prank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        share.forcedTransfer(alice, bob, 1);

        vm.expectEmit(address(share));
        emit IERC7943Fungible.ForcedTransfer(alice, bob, 1);
        assertTrue(share.forcedTransfer(alice, bob, 1)); // governance
    }

    function test_forcedTransfer_restrictedForStranger() public {
        _issueOrder(ORDER, alice, bob, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        share.forcedTransfer(alice, bob, 1, ORDER);
    }
}
