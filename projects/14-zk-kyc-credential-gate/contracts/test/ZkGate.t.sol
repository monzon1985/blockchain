// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixtureLoader} from "./base/FixtureLoader.sol";
import {ZkGate} from "../src/ZkGate.sol";
import {PUBLIC_SIGNALS} from "../src/interfaces/IVerifiers.sol";
import {CredentialVerifier} from "generated/CredentialVerifier.sol";
import {CredentialVerifierPlonk} from "generated/CredentialVerifierPlonk.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title ZkGateTest
/// @notice Unit and integration tests for the production gate against real, committed Groth16/PLONK
///         proof fixtures (bound to gate.json's address, epoch and recipient 0xB0B).
contract ZkGateTest is FixtureLoader {
    uint256 internal constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    /// @dev BN254 base-field prime; (x, Q - y) is the negation of the G1 point (x, y).
    uint256 internal constant Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    ZkGate internal gate;
    CredentialVerifier internal groth16;
    CredentialVerifierPlonk internal plonk;
    GateFixture internal g;
    Groth16Fixture internal valid;

    address internal admin = address(0xA11CE);
    address internal user;
    address internal attacker = address(0xBAD);

    function setUp() public {
        g = loadGate();
        useFixtureChain(g);
        user = g.recipient;
        groth16 = new CredentialVerifier();
        plonk = new CredentialVerifierPlonk();
        valid = loadGroth16("valid_groth16.json");
        gate = deployGateAt(g.gateAddress, fixtureConfig(g, address(groth16), address(plonk), admin));
    }

    function _register(ZkGate target, Groth16Fixture memory f) internal {
        vm.prank(user);
        target.registerWithGroth16(f.a, f.b, f.c, f.pub);
    }

    // ------------------------------------------------------------------
    // Scope binding
    // ------------------------------------------------------------------

    function test_ScopeMatchesFixture() public view {
        assertEq(gate.appScope(), valid.pub[20], "gate scope must equal proof appScope");
        assertEq(gate.appScope(), g.appScope);
        assertEq(gate.currentEpoch(), g.epoch);
        assertEq(valid.pub[21], uint256(uint160(user)), "proof is bound to 0xB0B");
    }

    function test_ScopeBindsAddressAndEpoch() public {
        assertTrue(gate.scopeForEpoch(g.epoch + 1) != gate.appScope(), "next epoch has a new scope");
        ZkGate clone = deployGateAt(g.gateBAddress, fixtureConfig(g, address(groth16), address(plonk), admin));
        assertEq(clone.actionId(), gate.actionId(), "same actionId");
        assertEq(clone.appScope(), g.appScopeB);
        assertTrue(clone.appScope() != gate.appScope(), "a different address means a different scope");
    }

    // ------------------------------------------------------------------
    // Registration happy paths
    // ------------------------------------------------------------------

    function test_ValidGroth16Registers() public {
        vm.expectEmit(true, true, false, true, address(gate));
        emit ZkGate.Registered(user, valid.pub[0], g.epoch, ZkGate.ProofSystem.Groth16);
        _register(gate, valid);
        assertTrue(gate.isRegistered(user));
        assertEq(gate.registrationCount(), 1);
        assertTrue(gate.isNullifierUsed(valid.pub[0]));
        assertEq(gate.registeredUntil(user), (g.epoch + 1) * g.epochDuration);
    }

    function test_ValidPlonkRegisters() public {
        PlonkFixture memory pf = loadPlonk("valid_plonk.json");
        vm.prank(user);
        gate.registerWithPlonk(pf.proof, pf.pub);
        assertTrue(gate.isRegistered(user));
        assertEq(gate.registrationCount(), 1);
    }

    function test_ReplayReverts() public {
        _register(gate, valid);
        vm.expectRevert(abi.encodeWithSelector(ZkGate.NullifierAlreadyUsed.selector, valid.pub[0]));
        _register(gate, valid);
    }

    function test_PlonkReplayOfGroth16NullifierReverts() public {
        _register(gate, valid);
        PlonkFixture memory pf = loadPlonk("valid_plonk.json");
        assertEq(pf.pub[0], valid.pub[0], "same credential + scope = same nullifier in both systems");
        vm.expectRevert(abi.encodeWithSelector(ZkGate.NullifierAlreadyUsed.selector, valid.pub[0]));
        vm.prank(user);
        gate.registerWithPlonk(pf.proof, pf.pub);
    }

    // ------------------------------------------------------------------
    // Front-running and cross-gate replay (regressions)
    // ------------------------------------------------------------------

    /// @notice Regression: a mempool observer resubmitting the victim's exact calldata used to be
    ///         allowlisted and burn the victim's nullifier. The proof is now bound to its recipient.
    function test_FrontRunnerCannotStealRegistration() public {
        vm.expectRevert(
            abi.encodeWithSelector(ZkGate.RecipientMismatch.selector, valid.pub[21], uint256(uint160(attacker)))
        );
        vm.prank(attacker);
        gate.registerWithGroth16(valid.a, valid.b, valid.c, valid.pub);

        // Re-targeting the recipient signal breaks the proof itself.
        uint256[PUBLIC_SIGNALS] memory retargeted = valid.pub;
        retargeted[21] = uint256(uint160(attacker));
        vm.expectRevert(ZkGate.InvalidProof.selector);
        vm.prank(attacker);
        gate.registerWithGroth16(valid.a, valid.b, valid.c, retargeted);

        assertFalse(gate.isRegistered(attacker));
        assertFalse(gate.isNullifierUsed(valid.pub[0]), "victim's nullifier is untouched");
        _register(gate, valid);
        assertTrue(gate.isRegistered(user));
    }

    /// @notice Regression: with appScope = keccak(chainId, appId) a clone gate sharing the appId
    ///         accepted proofs made for the real gate. The scope now binds address(this).
    function test_CloneGateWithSameActionIdRejectsProof() public {
        ZkGate clone = deployGateAt(g.gateBAddress, fixtureConfig(g, address(groth16), address(plonk), admin));
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedAppScope.selector, valid.pub[20], g.appScopeB));
        _register(clone, valid);
    }

    // ------------------------------------------------------------------
    // Public-input validation
    // ------------------------------------------------------------------

    function test_UnknownIssuerRootReverts() public {
        ZkGate.GateConfig memory cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.issuerRoot = uint256(0xdead);
        ZkGate other = deployGateAt(g.gateBAddress, cfg); // root check precedes the scope check
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownIssuerRoot.selector, valid.pub[2]));
        _register(other, valid);
    }

    function test_UnknownRevocationRootReverts() public {
        ZkGate.GateConfig memory cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.revocationRoot = uint256(0xbeef);
        ZkGate other = deployGateAt(g.gateBAddress, cfg);
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownRevocationRoot.selector, valid.pub[3]));
        _register(other, valid);
    }

    function test_OutOfFieldReverts() public {
        uint256[PUBLIC_SIGNALS] memory pub = valid.pub;
        pub[1] = FIELD; // exactly the modulus: out of field
        vm.expectRevert(abi.encodeWithSelector(ZkGate.PublicInputOutOfField.selector, uint256(1), FIELD));
        vm.prank(user);
        gate.registerWithGroth16(valid.a, valid.b, valid.c, pub);
    }

    function test_UnexpectedCurrentDateReverts() public {
        uint256[PUBLIC_SIGNALS] memory pub = valid.pub;
        pub[1] = valid.pub[1] + 1;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedCurrentDate.selector, pub[1], valid.pub[1]));
        vm.prank(user);
        gate.registerWithGroth16(valid.a, valid.b, valid.c, pub);
    }

    function test_SanctionedListMismatchReverts() public {
        uint256[PUBLIC_SIGNALS] memory pub = valid.pub;
        pub[4] = valid.pub[4] + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ZkGate.SanctionedListMismatch.selector, uint256(0), pub[4], valid.pub[4])
        );
        vm.prank(user);
        gate.registerWithGroth16(valid.a, valid.b, valid.c, pub);
    }

    function test_UnexpectedAppScopeReverts() public {
        uint256[PUBLIC_SIGNALS] memory pub = valid.pub;
        pub[20] = valid.pub[20] + 1;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedAppScope.selector, pub[20], valid.pub[20]));
        vm.prank(user);
        gate.registerWithGroth16(valid.a, valid.b, valid.c, pub);
    }

    function test_TamperedGroth16ProofReverts() public {
        // Negating A keeps it a valid curve point, so the verifier runs the pairing and returns false
        // (an off-curve point would make the precompile burn all forwarded gas instead).
        uint256[2] memory a = valid.a;
        a[1] = Q - a[1];
        vm.expectRevert(ZkGate.InvalidProof.selector);
        vm.prank(user);
        gate.registerWithGroth16(a, valid.b, valid.c, valid.pub);
    }

    function test_TamperedPlonkProofReverts() public {
        PlonkFixture memory pf = loadPlonk("valid_plonk.json");
        pf.proof[18] = addmod(pf.proof[18], 1, FIELD); // eval_a: still in field, no longer consistent
        vm.expectRevert(ZkGate.InvalidProof.selector);
        vm.prank(user);
        gate.registerWithPlonk(pf.proof, pf.pub);
    }

    // ------------------------------------------------------------------
    // Registration lifetime: epochs and deregistration
    // ------------------------------------------------------------------

    function test_RegistrationLapsesAtEpochEnd() public {
        _register(gate, valid);
        uint256 end = (g.epoch + 1) * g.epochDuration;
        vm.warp(end - 1);
        assertTrue(gate.isRegistered(user), "still registered in the last second of the epoch");
        vm.warp(end);
        assertFalse(gate.isRegistered(user), "lapses when the epoch ends");
        // A new epoch has a new scope: the old proof cannot renew the registration.
        uint256 newScope = gate.appScope();
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedAppScope.selector, valid.pub[20], newScope));
        _register(gate, valid);
    }

    function test_DeregisterRemovesAccountAndKeepsNullifierBurned() public {
        _register(gate, valid);
        vm.expectEmit(true, true, false, false, address(gate));
        emit ZkGate.Deregistered(user, admin);
        vm.prank(admin);
        gate.deregister(user);
        assertFalse(gate.isRegistered(user));
        assertTrue(gate.isNullifierUsed(valid.pub[0]));
        vm.expectRevert(abi.encodeWithSelector(ZkGate.NullifierAlreadyUsed.selector, valid.pub[0]));
        _register(gate, valid);
    }

    function test_DeregisterRequiresGovernor() public {
        _register(gate, valid);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, gate.GOVERNOR_ROLE())
        );
        vm.prank(user);
        gate.deregister(user);
    }

    function test_DeregisterUnregisteredReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ZkGate.NotRegistered.selector, user));
        vm.prank(admin);
        gate.deregister(user);
    }

    // ------------------------------------------------------------------
    // Governance: access control
    // ------------------------------------------------------------------

    function _expectUnauthorized(address who, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role));
        vm.prank(who);
    }

    function test_AddIssuerRootRequiresGovernor() public {
        _expectUnauthorized(user, gate.GOVERNOR_ROLE());
        gate.addIssuerRoot(uint256(0x1234));
    }

    function test_AddRevocationRootRequiresGovernor() public {
        _expectUnauthorized(user, gate.GOVERNOR_ROLE());
        gate.addRevocationRoot(uint256(0x1234));
    }

    function test_InvalidateIssuerRootRequiresGovernor() public {
        _expectUnauthorized(user, gate.GOVERNOR_ROLE());
        gate.invalidateIssuerRoot(g.issuerRoot);
    }

    function test_InvalidateRevocationRootRequiresGovernor() public {
        _expectUnauthorized(user, gate.GOVERNOR_ROLE());
        gate.invalidateRevocationRoot(g.revocationRoot);
    }

    function test_SetCurrentDateRequiresOracle() public {
        _expectUnauthorized(user, gate.DATE_ORACLE_ROLE());
        gate.setCurrentDate(20270101);
    }

    function test_SetSanctionedListRequiresGovernor() public {
        uint256[16] memory list;
        _expectUnauthorized(user, gate.GOVERNOR_ROLE());
        gate.setSanctionedList(list);
    }

    // ------------------------------------------------------------------
    // Governance: root histories
    // ------------------------------------------------------------------

    function test_ZeroIssuerRootReverts() public {
        vm.expectRevert(ZkGate.ZeroRoot.selector);
        vm.prank(admin);
        gate.addIssuerRoot(0);
    }

    function test_ZeroRevocationRootReverts() public {
        vm.expectRevert(ZkGate.ZeroRoot.selector);
        vm.prank(admin);
        gate.addRevocationRoot(0);
    }

    function test_IssuerRootAlreadyKnownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ZkGate.RootAlreadyKnown.selector, g.issuerRoot));
        vm.prank(admin);
        gate.addIssuerRoot(g.issuerRoot);
    }

    function test_RevocationRootAlreadyKnownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ZkGate.RootAlreadyKnown.selector, g.revocationRoot));
        vm.prank(admin);
        gate.addRevocationRoot(g.revocationRoot);
    }

    function test_SupersededIssuerRootAcceptedWithinGrace() public {
        vm.expectEmit(true, true, false, true, address(gate));
        emit ZkGate.RootSuperseded(ZkGate.RootKind.Issuer, g.issuerRoot, block.timestamp + ISSUER_GRACE);
        vm.prank(admin);
        gate.addIssuerRoot(uint256(0xabcabc));
        vm.warp(block.timestamp + ISSUER_GRACE - 1);
        assertTrue(gate.isAcceptedIssuerRoot(g.issuerRoot));
        _register(gate, valid);
        assertTrue(gate.isRegistered(user));
    }

    function test_SupersededIssuerRootStaleAfterGrace() public {
        vm.prank(admin);
        gate.addIssuerRoot(uint256(0xabcabc));
        uint256 supersededAt = vm.getBlockTimestamp();
        vm.warp(supersededAt + ISSUER_GRACE);
        assertFalse(gate.isAcceptedIssuerRoot(g.issuerRoot));
        vm.expectRevert(
            abi.encodeWithSelector(ZkGate.StaleRoot.selector, ZkGate.RootKind.Issuer, g.issuerRoot, supersededAt)
        );
        _register(gate, valid);
    }

    function test_SupersededRevocationRootAcceptedWithinGrace() public {
        vm.prank(admin);
        gate.addRevocationRoot(uint256(0xcafe));
        vm.warp(block.timestamp + REVOCATION_GRACE - 1);
        _register(gate, valid);
        assertTrue(gate.isRegistered(user));
    }

    /// @notice Regression: a holder whose credential was revoked in a newer root could keep proving
    ///         against the previous root for as long as it sat in the 30-deep history.
    function test_StaleRevocationRootRejectedAfterGrace() public {
        vm.prank(admin);
        gate.addRevocationRoot(uint256(0xcafe)); // e.g. the root that revokes this credential
        uint256 supersededAt = vm.getBlockTimestamp();
        vm.warp(supersededAt + REVOCATION_GRACE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ZkGate.StaleRoot.selector, ZkGate.RootKind.Revocation, g.revocationRoot, supersededAt
            )
        );
        _register(gate, valid);
    }

    function test_ZeroGraceAcceptsOnlyLatestRevocationRoot() public {
        ZkGate.GateConfig memory cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.revocationRootGracePeriod = 0;
        ZkGate strict = deployGateAt(g.gateBAddress, cfg);
        vm.prank(admin);
        strict.addRevocationRoot(uint256(0xcafe));
        assertFalse(strict.isAcceptedRevocationRoot(g.revocationRoot));
        vm.expectRevert(
            abi.encodeWithSelector(
                ZkGate.StaleRoot.selector, ZkGate.RootKind.Revocation, g.revocationRoot, block.timestamp
            )
        );
        _register(strict, valid);
    }

    function test_InvalidatedIssuerRootRejectedImmediately() public {
        vm.expectEmit(true, true, false, false, address(gate));
        emit ZkGate.RootInvalidated(ZkGate.RootKind.Issuer, g.issuerRoot);
        vm.prank(admin);
        gate.invalidateIssuerRoot(g.issuerRoot);
        assertFalse(gate.isAcceptedIssuerRoot(g.issuerRoot));
        vm.expectRevert(
            abi.encodeWithSelector(ZkGate.RootWasInvalidated.selector, ZkGate.RootKind.Issuer, g.issuerRoot)
        );
        _register(gate, valid);
    }

    function test_InvalidatedRevocationRootRejectedImmediately() public {
        vm.prank(admin);
        gate.invalidateRevocationRoot(g.revocationRoot);
        vm.expectRevert(
            abi.encodeWithSelector(ZkGate.RootWasInvalidated.selector, ZkGate.RootKind.Revocation, g.revocationRoot)
        );
        _register(gate, valid);
    }

    function test_InvalidateUnknownRootReverts() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownIssuerRoot.selector, uint256(0x99)));
        gate.invalidateIssuerRoot(0x99);
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownRevocationRoot.selector, uint256(0x99)));
        gate.invalidateRevocationRoot(0x99);
        vm.stopPrank();
    }

    function test_InvalidateTwiceReverts() public {
        vm.startPrank(admin);
        gate.invalidateRevocationRoot(g.revocationRoot);
        vm.expectRevert(
            abi.encodeWithSelector(ZkGate.RootWasInvalidated.selector, ZkGate.RootKind.Revocation, g.revocationRoot)
        );
        gate.invalidateRevocationRoot(g.revocationRoot);
        vm.stopPrank();
    }

    function test_IssuerRootEvictionAfterHistoryFull() public {
        vm.startPrank(admin);
        for (uint256 i = 1; i <= gate.ROOT_HISTORY(); i++) {
            gate.addIssuerRoot(1000 + i);
        }
        vm.stopPrank();
        assertFalse(gate.issuerRootInfo(g.issuerRoot).inHistory, "old root should be evicted");
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownIssuerRoot.selector, valid.pub[2]));
        _register(gate, valid);
    }

    function test_RevocationRootEvictionAfterHistoryFull() public {
        vm.startPrank(admin);
        for (uint256 i = 1; i <= gate.ROOT_HISTORY(); i++) {
            gate.addRevocationRoot(2000 + i);
        }
        vm.stopPrank();
        assertFalse(gate.revocationRootInfo(g.revocationRoot).inHistory, "old root should be evicted");
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownRevocationRoot.selector, valid.pub[3]));
        _register(gate, valid);
    }

    function test_RootHistoryViews() public {
        vm.startPrank(admin);
        gate.addIssuerRoot(uint256(0x1111));
        gate.addRevocationRoot(uint256(0x2222));
        vm.stopPrank();
        uint256[30] memory ir = gate.issuerRoots();
        uint256[30] memory rr = gate.revocationRoots();
        assertEq(ir[0], g.issuerRoot);
        assertEq(ir[1], uint256(0x1111));
        assertEq(rr[0], g.revocationRoot);
        assertEq(rr[1], uint256(0x2222));
        assertEq(gate.latestIssuerRoot(), uint256(0x1111));
        assertEq(gate.latestRevocationRoot(), uint256(0x2222));
        assertEq(gate.issuerRootInfo(g.issuerRoot).supersededAt, block.timestamp);
        assertEq(gate.revocationRootInfo(uint256(0x2222)).supersededAt, 0);
    }

    // ------------------------------------------------------------------
    // Governance: date oracle and sanctioned list
    // ------------------------------------------------------------------

    function test_SetCurrentDate() public {
        vm.expectEmit(false, false, false, true, address(gate));
        emit ZkGate.CurrentDateUpdated(valid.pub[1], 20270101);
        vm.prank(admin);
        gate.setCurrentDate(20270101);
        assertEq(gate.currentDate(), 20270101);
        // The fixture proof now attests a stale date and is rejected.
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedCurrentDate.selector, valid.pub[1], uint256(20270101)));
        _register(gate, valid);
    }

    function test_SetCurrentDateRejectsNonDates() public {
        uint256[8] memory bad = [uint256(1) << 40, 0, 18991231, 20261301, 20260230, 20270229, 20260431, 100000101];
        vm.startPrank(admin);
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(ZkGate.InvalidDate.selector, bad[i]));
            gate.setCurrentDate(bad[i]);
        }
        gate.setCurrentDate(20280229); // a real leap day is fine
        gate.setCurrentDate(99991231); // the latest representable date
        vm.stopPrank();
        assertEq(gate.currentDate(), 99991231);
    }

    function test_SetCurrentDateRejectsRegression() public {
        vm.expectRevert(abi.encodeWithSelector(ZkGate.DateRegression.selector, uint256(19000101), g.currentDate));
        vm.prank(admin);
        gate.setCurrentDate(19000101);
        vm.prank(admin);
        gate.setCurrentDate(g.currentDate); // same date is a no-op, not a regression
    }

    function test_SetSanctionedList() public {
        uint256[16] memory list;
        for (uint256 i = 0; i < 16; i++) {
            list[i] = 900 + i;
        }
        vm.prank(admin);
        gate.setSanctionedList(list);
        uint256[16] memory stored = gate.sanctionedList();
        for (uint256 i = 0; i < 16; i++) {
            assertEq(stored[i], 900 + i);
        }
        vm.expectRevert(
            abi.encodeWithSelector(ZkGate.SanctionedListMismatch.selector, uint256(0), valid.pub[4], uint256(900))
        );
        _register(gate, valid);
    }

    // ------------------------------------------------------------------
    // Constructor validation
    // ------------------------------------------------------------------

    function _expectConstructorRevert(ZkGate.GateConfig memory cfg, bytes memory err) internal {
        vm.expectRevert(err);
        new ZkGate(cfg);
    }

    function test_ConstructorRejectsZeroAddresses() public {
        ZkGate.GateConfig memory cfg = fixtureConfig(g, address(0), address(plonk), admin);
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.ZeroAddress.selector));
        cfg = fixtureConfig(g, address(groth16), address(0), admin);
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.ZeroAddress.selector));
        cfg = fixtureConfig(g, address(groth16), address(plonk), address(0));
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.ZeroAddress.selector));
    }

    function test_ConstructorRejectsZeroEpochDuration() public {
        ZkGate.GateConfig memory cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.epochDuration = 0;
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.ZeroEpochDuration.selector));
    }

    function test_ConstructorRejectsLongGracePeriods() public {
        uint256 tooLong = 30 days + 1;
        ZkGate.GateConfig memory cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.issuerRootGracePeriod = tooLong;
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.GracePeriodTooLong.selector, tooLong));
        cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.revocationRootGracePeriod = tooLong;
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.GracePeriodTooLong.selector, tooLong));
    }

    function test_ConstructorRejectsInvalidInitialStateValues() public {
        ZkGate.GateConfig memory cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.currentDate = 20261301;
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.InvalidDate.selector, uint256(20261301)));
        cfg = fixtureConfig(g, address(groth16), address(plonk), admin);
        cfg.revocationRoot = 0; // an empty SMT: deployments must revoke the sentinel id
        _expectConstructorRevert(cfg, abi.encodeWithSelector(ZkGate.ZeroRoot.selector));
    }
}
