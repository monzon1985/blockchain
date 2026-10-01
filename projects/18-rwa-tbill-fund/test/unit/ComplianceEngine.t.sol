// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {ComplianceEngine} from "../../src/compliance/ComplianceEngine.sol";
import {TransferContext, TransferKind} from "../../src/interfaces/ICompliance.sol";
import {IIdentityRegistry} from "../../src/interfaces/IIdentityRegistry.sol";
import {ComplianceProbe, MockIdentityRegistry, MockLedgerToken, ToggleModule} from "../mocks/Mocks.sol";

/// @notice Engine in isolation: a mock token reports movements directly, so every engine branch is reachable
///         without the share token's own eligibility checks in front of it.
contract ComplianceEngineTest is Test {
    uint16 internal constant US = 840;
    uint16 internal constant DE = 276;

    AccessManager internal manager;
    MockIdentityRegistry internal registry;
    ComplianceEngine internal engine;
    MockLedgerToken internal token;
    ComplianceProbe internal probe;
    ToggleModule internal toggle;

    address internal a1 = makeAddr("a1");
    address internal a2 = makeAddr("a2");
    address internal b1 = makeAddr("b1");
    address internal c1 = makeAddr("c1");
    address internal nobody = makeAddr("nobody");
    bytes32 internal constant A = keccak256("A");
    bytes32 internal constant B = keccak256("B");
    bytes32 internal constant C = keccak256("C");

    function setUp() public {
        manager = new AccessManager(address(this));
        registry = new MockIdentityRegistry();
        engine = new ComplianceEngine(address(manager), IIdentityRegistry(address(registry)));
        token = new MockLedgerToken(engine);
        engine.bindToken(address(token));
        probe = new ComplianceProbe(address(engine));
        toggle = new ToggleModule(address(engine));
        engine.addModule(address(probe));
        engine.addModule(address(toggle));

        registry.set(a1, A, US);
        registry.set(a2, A, US);
        registry.set(b1, B, US);
        registry.set(c1, C, DE);
    }

    // ---------------------------------------------------------------- binding and modules

    function test_bindToken_isOneShot() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceEngine.TokenAlreadyBound.selector, address(token)));
        engine.bindToken(address(0xBEEF));
    }

    function test_bindToken_rejectsZero() public {
        ComplianceEngine fresh = new ComplianceEngine(address(manager), IIdentityRegistry(address(registry)));
        vm.expectRevert(abi.encodeWithSelector(ComplianceEngine.TokenAlreadyBound.selector, address(0)));
        fresh.bindToken(address(0));
    }

    function test_bindToken_emits() public {
        ComplianceEngine fresh = new ComplianceEngine(address(manager), IIdentityRegistry(address(registry)));
        vm.expectEmit(address(fresh));
        emit ComplianceEngine.TokenBound(address(0xBEEF));
        fresh.bindToken(address(0xBEEF));
        assertEq(fresh.token(), address(0xBEEF));
    }

    function test_bindToken_restricted() public {
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, nobody));
        engine.bindToken(address(0xBEEF));
    }

    function test_addModule_recordsStatefulFlagAndOrder() public view {
        address[] memory modules = engine.getModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], address(probe));
        assertEq(modules[1], address(toggle));
    }

    function test_addModule_revertsOnForeignEngine() public {
        ToggleModule foreign = new ToggleModule(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(ComplianceEngine.ModuleEngineMismatch.selector, address(foreign), address(0xDEAD))
        );
        engine.addModule(address(foreign));
    }

    function test_addModule_revertsOnDuplicate() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceEngine.ModuleAlreadyAdded.selector, address(toggle)));
        engine.addModule(address(toggle));
    }

    function test_addModule_revertsAboveMax() public {
        for (uint256 i = 2; i < engine.MAX_MODULES(); ++i) {
            engine.addModule(address(new ToggleModule(address(engine))));
        }
        address extra = address(new ToggleModule(address(engine)));
        vm.expectRevert(abi.encodeWithSelector(ComplianceEngine.TooManyModules.selector, uint256(8)));
        engine.addModule(extra);
    }

    function test_removeModule_swapsAndPops() public {
        ToggleModule third = new ToggleModule(address(engine));
        engine.addModule(address(third));
        vm.expectEmit(address(engine));
        emit ComplianceEngine.ModuleRemoved(address(probe));
        engine.removeModule(address(probe));
        address[] memory modules = engine.getModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], address(third));
        assertEq(modules[1], address(toggle));
        engine.removeModule(address(toggle));
        assertEq(engine.getModules().length, 1);
    }

    function test_removeModule_revertsWhenMissing() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceEngine.ModuleNotFound.selector, address(0xABC)));
        engine.removeModule(address(0xABC));
    }

    // ---------------------------------------------------------------- transferred: access and rejection

    function test_transferred_onlyToken() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceEngine.NotToken.selector, address(this)));
        engine.transferred(TransferKind.Mint, address(0), a1, 1);
    }

    function test_transferred_revertsForRecipientWithoutIdentity() public {
        vm.expectRevert(abi.encodeWithSelector(ComplianceEngine.RecipientWithoutIdentity.selector, nobody));
        token.move(TransferKind.Mint, address(0), nobody, 1);
    }

    function test_transferred_revertsWhenModuleRejects() public {
        toggle.setAllow(false);
        vm.expectRevert(
            abi.encodeWithSelector(
                ComplianceEngine.ComplianceModuleRejected.selector,
                address(toggle),
                TransferKind.Mint,
                address(0),
                a1,
                uint256(5)
            )
        );
        token.move(TransferKind.Mint, address(0), a1, 5);
    }

    function test_checkTransfer_reportsRejectingModule() public {
        token.move(TransferKind.Mint, address(0), a1, 5);
        toggle.setAllow(false);
        (bool ok, address by) = engine.checkTransfer(TransferKind.Transfer, a1, b1, 1);
        assertFalse(ok);
        assertEq(by, address(toggle));
        toggle.setAllow(true);
        (ok, by) = engine.checkTransfer(TransferKind.Transfer, a1, b1, 1);
        assertTrue(ok);
        assertEq(by, address(0));
    }

    function test_checkTransfer_falseForRecipientWithoutIdentity() public view {
        (bool ok, address by) = engine.checkTransfer(TransferKind.Mint, address(0), nobody, 1);
        assertFalse(ok);
        assertEq(by, address(0));
    }

    // ---------------------------------------------------------------- ledger and holder counts

    function test_mint_entersInvestorAndSnapshots() public {
        vm.expectEmit(address(engine));
        emit ComplianceEngine.InvestorEntered(A, US, 1);
        token.move(TransferKind.Mint, address(0), a1, 100);
        assertEq(engine.investorBalance(A), 100);
        assertEq(engine.investorCountry(A), US);
        assertEq(engine.walletIdentity(a1), A);
        assertEq(engine.holderCount(US), 1);
        assertEq(engine.totalHolders(), 1);
        assertEq(engine.trackedSupply(), 100);
        assertEq(probe.mirror(a1), 100);
    }

    function test_zeroAmount_changesNothing() public {
        token.move(TransferKind.Mint, address(0), a1, 0);
        assertEq(engine.totalHolders(), 0);
        assertEq(engine.walletIdentity(a1), bytes32(0));
        assertEq(probe.calls(), 1, "modules still see the movement");
    }

    function test_partialTransfer_keepsBothHolders() public {
        token.move(TransferKind.Mint, address(0), a1, 100);
        token.move(TransferKind.Transfer, a1, b1, 40);
        assertEq(engine.holderCount(US), 2);
        assertEq(engine.investorBalance(A), 60);
        assertEq(engine.investorBalance(B), 40);
    }

    function test_fullTransfer_exitsSenderAndClearsSnapshot() public {
        token.move(TransferKind.Mint, address(0), a1, 100);
        vm.expectEmit(address(engine));
        emit ComplianceEngine.InvestorExited(A, US, 0);
        token.move(TransferKind.Transfer, a1, c1, 100);
        assertEq(engine.holderCount(US), 0);
        assertEq(engine.holderCount(DE), 1);
        assertEq(engine.walletIdentity(a1), bytes32(0));
        assertEq(engine.totalHolders(), 1);
    }

    function test_sameInvestorAcrossWallets_isOneHolder() public {
        token.move(TransferKind.Mint, address(0), a1, 100);
        token.move(TransferKind.Mint, address(0), a2, 50);
        assertEq(engine.holderCount(US), 1);
        assertEq(engine.investorBalance(A), 150);

        TransferContext memory ctx = engine.previewContext(TransferKind.Transfer, a1, a2, 100);
        assertFalse(ctx.toBecomesHolder);
        assertFalse(ctx.fromLeavesHolders);
        token.move(TransferKind.Transfer, a1, a2, 100);
        assertEq(engine.holderCount(US), 1);
        assertEq(engine.investorBalance(A), 150);
        assertEq(engine.walletIdentity(a1), bytes32(0));
        assertEq(engine.walletIdentity(a2), A);

        token.move(TransferKind.Burn, a2, address(0), 150);
        assertEq(engine.holderCount(US), 0);
        assertEq(engine.trackedSupply(), 0);
    }

    function test_countryChangeWhileHolding_decrementsOriginalBucket() public {
        token.move(TransferKind.Mint, address(0), a1, 100);
        registry.setCountry(A, DE); // new jurisdiction claim while holding
        token.move(TransferKind.Mint, address(0), a1, 1);
        assertEq(engine.holderCount(US), 1, "still counted where it entered");
        assertEq(engine.holderCount(DE), 0);
        token.move(TransferKind.Burn, a1, address(0), 101);
        assertEq(engine.holderCount(US), 0, "decrement hits the entry bucket");
        assertEq(engine.holderCount(DE), 0);
        token.move(TransferKind.Mint, address(0), a1, 1);
        assertEq(engine.holderCount(DE), 1, "re-entry uses the new country");
    }

    function test_walletRebindWhileHolding_keepsSnapshotIdentity() public {
        token.move(TransferKind.Mint, address(0), a1, 100);
        registry.set(a1, B, US); // wallet re-bound to another identity while holding
        assertEq(engine.resolveIdentity(a1), A);
        token.move(TransferKind.Transfer, a1, b1, 100);
        assertEq(engine.investorBalance(A), 0);
        assertEq(engine.investorBalance(B), 100);
        assertEq(engine.resolveIdentity(a1), B, "snapshot released once empty");
    }

    function test_selfTransfer_isNeutral() public {
        token.move(TransferKind.Mint, address(0), a1, 100);
        token.move(TransferKind.Transfer, a1, a1, 100);
        assertEq(engine.walletIdentity(a1), A);
        assertEq(engine.investorBalance(A), 100);
        assertEq(engine.holderCount(US), 1);
    }

    function test_previewContext_exitAndEntrySameCountry() public {
        token.move(TransferKind.Mint, address(0), a1, 100);
        TransferContext memory ctx = engine.previewContext(TransferKind.Transfer, a1, b1, 100);
        assertTrue(ctx.fromLeavesHolders);
        assertTrue(ctx.toBecomesHolder);
        assertEq(ctx.fromCountry, US);
        assertEq(ctx.toCountry, US);
        assertEq(ctx.fromBalance, 100);
        assertEq(ctx.toInvestorBalance, 0);
        assertEq(ctx.fromId, A);
        assertEq(ctx.toId, B);
    }

    function test_statefulHooksReceiveEveryKind() public {
        token.move(TransferKind.Mint, address(0), a1, 10);
        token.move(TransferKind.Transfer, a1, b1, 3);
        token.move(TransferKind.Forced, b1, c1, 1);
        token.move(TransferKind.Recovery, a1, a2, 7);
        token.move(TransferKind.Burn, a2, address(0), 7);
        assertEq(probe.calls(), 5);
        assertEq(probe.callsByKind(TransferKind.Recovery), 1);
        assertEq(probe.mirroredSupply(), 3);
        assertEq(engine.trackedSupply(), 3);
    }
}
