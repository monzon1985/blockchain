// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {FundFixture} from "../utils/FundFixture.sol";
import {MockERC1271Issuer} from "../mocks/Mocks.sol";

contract IdentityRegistryTest is FundFixture {
    address internal newWallet = makeAddr("newWallet");
    bytes32 internal constant ID_NEW = keccak256("identity:new");

    // ---------------------------------------------------------------- constructor / configuration

    function test_constructor_setsRequiredTopics() public view {
        assertEq(registry.requiredTopics(), ALL_TOPICS);
    }

    function test_constructor_revertsWithoutJurisdiction() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.JurisdictionTopicRequired.selector, uint256(1 << 1)));
        new IdentityRegistry(address(manager), 1 << 1);
    }

    function test_constructor_revertsOnTopicZeroBit() public {
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidTopic.selector, uint256(1 | (1 << 3))));
        new IdentityRegistry(address(manager), 1 | (1 << 3));
    }

    function test_setRequiredTopics_addsTopicAndUnverifiesUntilClaimed() public {
        uint256 topics = ALL_TOPICS | (1 << 4);
        vm.expectEmit(address(registry));
        emit IdentityRegistry.RequiredTopicsSet(topics);
        vm.prank(complianceOfficer);
        registry.setRequiredTopics(topics);
        assertFalse(registry.isVerified(alice));

        vm.prank(complianceOfficer);
        registry.setTrustedIssuer(issuer, topics);
        _addClaim(ID_ALICE, 4, 7);
        assertTrue(registry.isVerified(alice));
    }

    function test_setRequiredTopics_revertsWithoutJurisdiction() public {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.JurisdictionTopicRequired.selector, uint256(1 << 1)));
        registry.setRequiredTopics(1 << 1);
    }

    function test_setRequiredTopics_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        registry.setRequiredTopics(ALL_TOPICS);
    }

    function test_setTrustedIssuer_revertsOnOutOfRangeTopic() public {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidTopic.selector, uint256(1 << 32)));
        registry.setTrustedIssuer(issuer, 1 << 32);
    }

    function test_setTrustedIssuer_removalInvalidatesClaims() public {
        assertTrue(registry.isVerified(alice));
        vm.expectEmit(address(registry));
        emit IdentityRegistry.TrustedIssuerSet(issuer, 0);
        vm.prank(complianceOfficer);
        registry.setTrustedIssuer(issuer, 0);
        assertFalse(registry.isVerified(alice));
        assertEq(registry.investorCountry(ID_ALICE), 0);
    }

    // ---------------------------------------------------------------- wallet binding

    function test_registerWallet_bindsAndEmits() public {
        vm.expectEmit(address(registry));
        emit IdentityRegistry.WalletRegistered(newWallet, ID_NEW);
        vm.prank(complianceOfficer);
        registry.registerWallet(newWallet, ID_NEW);
        assertEq(registry.identityOf(newWallet), ID_NEW);
        assertFalse(registry.isVerified(newWallet), "no claims yet");
    }

    function test_registerWallet_secondWalletOfSameIdentityIsVerified() public {
        vm.prank(complianceOfficer);
        registry.registerWallet(alice2, ID_ALICE);
        assertTrue(registry.isVerified(alice2));
    }

    function test_registerWallet_revertsOnZeroWallet() public {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidRegistration.selector, address(0), ID_NEW));
        registry.registerWallet(address(0), ID_NEW);
    }

    function test_registerWallet_revertsOnZeroIdentity() public {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidRegistration.selector, newWallet, bytes32(0)));
        registry.registerWallet(newWallet, bytes32(0));
    }

    function test_registerWallet_revertsIfAlreadyRegistered() public {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WalletAlreadyRegistered.selector, alice, ID_ALICE));
        registry.registerWallet(alice, ID_BOB);
    }

    function test_registerWallet_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        registry.registerWallet(newWallet, ID_NEW);
    }

    function test_walletBinding_isNotATransferAgentPower() public {
        vm.startPrank(transferAgent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        registry.registerWallet(newWallet, ID_ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, transferAgent));
        registry.unregisterWallet(alice);
        vm.stopPrank();
    }

    function test_unregisterWallet_unbinds() public {
        vm.expectEmit(address(registry));
        emit IdentityRegistry.WalletUnregistered(alice, ID_ALICE);
        vm.prank(complianceOfficer);
        registry.unregisterWallet(alice);
        assertEq(registry.identityOf(alice), bytes32(0));
        assertFalse(registry.isVerified(alice));
    }

    function test_unregisterWallet_revertsIfNotRegistered() public {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WalletNotRegistered.selector, newWallet));
        registry.unregisterWallet(newWallet);
    }

    // ---------------------------------------------------------------- claims: happy paths

    function test_addClaim_storesAndEmits() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 3, FR);
        bytes32 digest = registry.claimDigest(c);
        vm.expectEmit(address(registry));
        emit IdentityRegistry.ClaimAdded(ID_NEW, 3, issuer, digest, FR, c.expiresAt);
        vm.prank(stranger); // anyone may relay a signed claim
        assertEq(registry.addClaim(c, _sign(c, issuerKey)), digest);

        IdentityRegistry.StoredClaim memory stored = registry.getClaim(ID_NEW, 3);
        assertEq(stored.issuer, issuer);
        assertEq(stored.data, FR);
        assertEq(stored.digest, digest);
        assertEq(stored.issuedAt, c.issuedAt);
        assertTrue(registry.claimUsed(digest));
        assertEq(registry.investorCountry(ID_NEW), FR);
        assertTrue(registry.isClaimValid(ID_NEW, 3));
    }

    function test_addClaim_onboardingCompletesVerification() public {
        vm.prank(complianceOfficer);
        registry.registerWallet(newWallet, ID_NEW);
        _addClaim(ID_NEW, 1, 1);
        _addClaim(ID_NEW, 2, 1);
        assertFalse(registry.isVerified(newWallet));
        assertFalse(registry.isIdentityVerified(ID_NEW));
        _addClaim(ID_NEW, 3, FR);
        assertTrue(registry.isVerified(newWallet));
        assertTrue(registry.isIdentityVerified(ID_NEW));
    }

    function test_addClaim_newerClaimReplacesOlder() public {
        vm.warp(block.timestamp + 10);
        _addClaim(ID_ALICE, 3, DE);
        assertEq(registry.investorCountry(ID_ALICE), DE);
    }

    function test_addClaim_olderClaimRejectedEvenWhenStoredOneExpired() public {
        IdentityRegistry.Claim memory older = _claim(ID_ALICE, 1, 1);
        older.issuedAt = uint64(block.timestamp - 1 days);
        older.expiresAt = uint64(block.timestamp + 730 days);
        bytes memory sig = _sign(older, issuerKey);
        vm.warp(block.timestamp + 366 days); // the claims added at onboarding have expired
        assertFalse(registry.isVerified(alice));
        uint64 watermark = registry.getClaim(ID_ALICE, 1).minIssuedAt;
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimNotNewer.selector, older.issuedAt, watermark));
        registry.addClaim(older, sig);
        _addClaim(ID_ALICE, 1, 1); // a renewal issued now is accepted
        assertTrue(registry.isClaimValid(ID_ALICE, 1));
    }

    function test_addClaim_watermarkFollowsEveryAcceptedClaim() public {
        assertEq(registry.getClaim(ID_NEW, 1).minIssuedAt, 0);
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        registry.addClaim(c, _sign(c, issuerKey));
        assertEq(registry.getClaim(ID_NEW, 1).minIssuedAt, c.issuedAt);
        vm.warp(block.timestamp + 5);
        IdentityRegistry.Claim memory renewal = _claim(ID_NEW, 1, 1);
        registry.addClaim(renewal, _sign(renewal, issuerKey));
        assertEq(registry.getClaim(ID_NEW, 1).minIssuedAt, renewal.issuedAt);
    }

    /// @dev Regression (review finding): removing a claim left no trace, so an older claim that was signed but
    ///      never submitted (unexpired, unrevoked) could be relayed by anyone and re-verify the identity at once.
    function test_regression_removedClaimCannotBeRevivedByAStaleSignedClaim() public {
        vm.warp(block.timestamp + 1);
        IdentityRegistry.Claim memory stale = _claim(ID_ALICE, 1, 1); // signed at t, never submitted
        bytes memory staleSig = _sign(stale, issuerKey);
        vm.warp(block.timestamp + 30 days);
        _addClaim(ID_ALICE, 1, 1); // a newer KYC claim at t + 30 days
        assertTrue(registry.isVerified(alice));

        vm.prank(complianceOfficer);
        registry.removeClaim(ID_ALICE, 1); // sanctions hit
        assertFalse(registry.isVerified(alice));

        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.ClaimNotNewer.selector, stale.issuedAt, uint64(block.timestamp))
        );
        registry.addClaim(stale, staleSig);
        // Even a claim signed in the very block of the removal is dead; only a later issuance re-verifies.
        IdentityRegistry.Claim memory sameBlock = _claim(ID_ALICE, 1, 1);
        bytes memory sameBlockSig = _sign(sameBlock, issuerKey);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.ClaimNotNewer.selector, sameBlock.issuedAt, uint64(block.timestamp))
        );
        registry.addClaim(sameBlock, sameBlockSig);
        assertFalse(registry.isVerified(alice));

        vm.warp(block.timestamp + 1);
        _addClaim(ID_ALICE, 1, 1);
        assertTrue(registry.isVerified(alice));
    }

    function test_revokeClaim_activeRevocationRaisesWatermark() public {
        IdentityRegistry.Claim memory stale = _claim(ID_NEW, 1, 1);
        bytes memory staleSig = _sign(stale, issuerKey);
        vm.warp(block.timestamp + 1);
        IdentityRegistry.Claim memory active = _claim(ID_NEW, 1, 1);
        registry.addClaim(active, _sign(active, issuerKey));
        vm.warp(block.timestamp + 1 days);
        vm.prank(issuer);
        registry.revokeClaim(active);
        assertEq(registry.getClaim(ID_NEW, 1).minIssuedAt, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.ClaimNotNewer.selector, stale.issuedAt, uint64(block.timestamp))
        );
        registry.addClaim(stale, staleSig);
    }

    function test_revokeClaim_strangerCannotRaiseAnotherIdentitysWatermark() public {
        IdentityRegistry.Claim memory fake = _claim(ID_NEW, 1, 1);
        fake.issuer = stranger; // made up, never signed by a trusted issuer
        fake.issuedAt = type(uint64).max - 1;
        fake.expiresAt = type(uint64).max;
        vm.prank(stranger);
        registry.revokeClaim(fake);
        assertEq(registry.getClaim(ID_NEW, 1).minIssuedAt, 0, "inactive revocations never move the watermark");
        _addClaim(ID_NEW, 1, 1);
        assertTrue(registry.isClaimValid(ID_NEW, 1));
    }

    function test_addClaim_acceptsErc1271Issuer() public {
        MockERC1271Issuer contractIssuer = new MockERC1271Issuer();
        vm.prank(complianceOfficer);
        registry.setTrustedIssuer(address(contractIssuer), 1 << 1);
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        c.issuer = address(contractIssuer);
        contractIssuer.approve(registry.claimDigest(c), true);
        registry.addClaim(c, "");
        assertTrue(registry.isClaimValid(ID_NEW, 1));
    }

    function test_addClaim_rejectsUnapprovedErc1271Digest() public {
        MockERC1271Issuer contractIssuer = new MockERC1271Issuer();
        vm.prank(complianceOfficer);
        registry.setTrustedIssuer(address(contractIssuer), 1 << 1);
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        c.issuer = address(contractIssuer);
        bytes32 digest = registry.claimDigest(c);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, address(contractIssuer), digest)
        );
        registry.addClaim(c, "");
    }

    // ---------------------------------------------------------------- claims: every revert path

    function test_addClaim_revertsOnZeroIdentity() public {
        IdentityRegistry.Claim memory c = _claim(bytes32(0), 1, 1);
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(IdentityRegistry.InvalidIdentity.selector);
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnTopicZero() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 0, 1);
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidTopic.selector, uint256(0)));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnTopicAboveMax() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 32, 1);
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidTopic.selector, uint256(32)));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsForUntrustedIssuer() public {
        (address rogue, uint256 rogueKey) = makeAddrAndKey("rogue");
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        c.issuer = rogue;
        bytes memory sig = _sign(c, rogueKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UntrustedIssuer.selector, rogue, uint256(1)));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsForIssuerTrustedForOtherTopic() public {
        (address kycOnly, uint256 kycOnlyKey) = makeAddrAndKey("kycOnly");
        vm.prank(complianceOfficer);
        registry.setTrustedIssuer(kycOnly, 1 << 1);
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 3, US);
        c.issuer = kycOnly;
        bytes memory sig = _sign(c, kycOnlyKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UntrustedIssuer.selector, kycOnly, uint256(3)));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnEmptyWindow() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        c.expiresAt = c.issuedAt;
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                IdentityRegistry.InvalidClaimWindow.selector, c.issuedAt, c.expiresAt, block.timestamp
            )
        );
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsWhenIssuedInFuture() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        c.issuedAt = uint64(block.timestamp + 1);
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                IdentityRegistry.InvalidClaimWindow.selector, c.issuedAt, c.expiresAt, block.timestamp
            )
        );
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsWhenExpired() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        c.issuedAt = uint64(block.timestamp - 10);
        c.expiresAt = uint64(block.timestamp);
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimExpired.selector, c.expiresAt, block.timestamp));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnCountryZero() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 3, 0);
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidCountry.selector, uint32(0)));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnCountryAboveIso() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 3, 1000);
        bytes memory sig = _sign(c, issuerKey);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidCountry.selector, uint32(1000)));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnReplay() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        bytes memory sig = _sign(c, issuerKey);
        bytes32 digest = registry.addClaim(c, sig);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimAlreadyUsed.selector, digest));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnReplayAfterRemoval() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        bytes memory sig = _sign(c, issuerKey);
        bytes32 digest = registry.addClaim(c, sig);
        vm.prank(complianceOfficer);
        registry.removeClaim(ID_NEW, 1);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimAlreadyUsed.selector, digest));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsWhenNotNewerThanValidStoredClaim() public {
        IdentityRegistry.Claim memory c = _claim(ID_ALICE, 3, DE); // same issuedAt as the onboarding claim
        bytes memory sig = _sign(c, issuerKey);
        uint64 storedIssuedAt = registry.getClaim(ID_ALICE, 3).issuedAt;
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimNotNewer.selector, c.issuedAt, storedIssuedAt));
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnWrongSigner() public {
        (, uint256 otherKey) = makeAddrAndKey("impostor");
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        bytes memory sig = _sign(c, otherKey);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, registry.claimDigest(c))
        );
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnMalformedSignature() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, registry.claimDigest(c))
        );
        registry.addClaim(c, hex"deadbeef");
    }

    function test_addClaim_revertsOnTamperedPayload() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 3, US);
        bytes memory sig = _sign(c, issuerKey);
        c.data = SG; // investor tries to change the signed jurisdiction
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, registry.claimDigest(c))
        );
        registry.addClaim(c, sig);
    }

    function test_addClaim_revertsOnOtherRegistryDomain() public {
        IdentityRegistry other = new IdentityRegistry(address(manager), ALL_TOPICS);
        vm.prank(complianceOfficer);
        vm.expectRevert(); // `other` is not wired in the AccessManager: only ADMIN may configure it
        other.setTrustedIssuer(issuer, ALL_TOPICS);
        other.setTrustedIssuer(issuer, ALL_TOPICS);

        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        bytes memory sig = _sign(c, issuerKey); // signed for `registry`'s domain
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, other.claimDigest(c))
        );
        other.addClaim(c, sig);
    }

    function test_addClaim_revertsOnOtherChain() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        bytes memory sig = _sign(c, issuerKey);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IdentityRegistry.InvalidClaimSignature.selector, issuer, registry.claimDigest(c))
        );
        registry.addClaim(c, sig);
    }

    // ---------------------------------------------------------------- revocation and removal

    function test_revokeClaim_deletesActiveClaim() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        bytes32 digest = registry.addClaim(c, _sign(c, issuerKey));
        vm.expectEmit(address(registry));
        emit IdentityRegistry.ClaimRevoked(digest, ID_NEW, 1, issuer, true);
        vm.prank(issuer);
        registry.revokeClaim(c);
        assertTrue(registry.claimRevoked(digest));
        assertFalse(registry.isClaimValid(ID_NEW, 1));
        assertEq(registry.getClaim(ID_NEW, 1).issuer, address(0));
    }

    function test_revokeClaim_preemptiveRevocationBlocksSubmission() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        bytes memory sig = _sign(c, issuerKey);
        bytes32 digest = registry.claimDigest(c);
        vm.expectEmit(address(registry));
        emit IdentityRegistry.ClaimRevoked(digest, ID_NEW, 1, issuer, false);
        vm.prank(issuer);
        registry.revokeClaim(c);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimIsRevoked.selector, digest));
        registry.addClaim(c, sig);
    }

    function test_revokeClaim_revokingSupersededClaimKeepsCurrent() public {
        IdentityRegistry.Claim memory first = _claim(ID_NEW, 1, 1);
        registry.addClaim(first, _sign(first, issuerKey));
        vm.warp(block.timestamp + 1);
        IdentityRegistry.Claim memory second = _claim(ID_NEW, 1, 2);
        registry.addClaim(second, _sign(second, issuerKey));
        vm.prank(issuer);
        registry.revokeClaim(first);
        assertTrue(registry.isClaimValid(ID_NEW, 1), "the newer claim stays");
    }

    function test_revokeClaim_revertsForNonIssuer() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotClaimIssuer.selector, stranger, issuer));
        registry.revokeClaim(c);
    }

    function test_revokeClaim_revertsWhenAlreadyRevoked() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 1, 1);
        vm.startPrank(issuer);
        registry.revokeClaim(c);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ClaimIsRevoked.selector, registry.claimDigest(c)));
        registry.revokeClaim(c);
        vm.stopPrank();
    }

    function test_removeClaim_deletesAndUnverifies() public {
        bytes32 digest = registry.getClaim(ID_ALICE, 2).digest;
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(address(registry));
        emit IdentityRegistry.ClaimRemoved(ID_ALICE, 2, digest, uint64(block.timestamp));
        vm.prank(complianceOfficer);
        registry.removeClaim(ID_ALICE, 2);
        assertFalse(registry.isVerified(alice));
        IdentityRegistry.StoredClaim memory stored = registry.getClaim(ID_ALICE, 2);
        assertEq(stored.issuer, address(0));
        assertEq(stored.digest, bytes32(0));
        assertEq(stored.issuedAt, 0);
        assertEq(stored.minIssuedAt, block.timestamp);
    }

    function test_removeClaim_revertsWhenMissing() public {
        vm.prank(complianceOfficer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NoSuchClaim.selector, ID_NEW, uint256(1)));
        registry.removeClaim(ID_NEW, 1);
    }

    // ---------------------------------------------------------------- views

    function test_isVerified_falseAfterExpiry() public {
        assertTrue(registry.isVerified(alice));
        vm.warp(block.timestamp + 365 days);
        assertFalse(registry.isVerified(alice));
        assertEq(registry.investorCountry(ID_ALICE), 0);
    }

    function test_isVerified_falseForUnregisteredWallet() public view {
        assertFalse(registry.isVerified(newWallet));
    }

    function test_claimDigest_matchesManualEip712() public {
        IdentityRegistry.Claim memory c = _claim(ID_NEW, 3, US);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TBillFund IdentityRegistry"),
                keccak256("1"),
                block.chainid,
                address(registry)
            )
        );
        assertEq(registry.domainSeparator(), domain);
        bytes32 structHash = keccak256(
            abi.encode(
                registry.CLAIM_TYPEHASH(), c.identity, c.topic, c.data, c.issuer, c.issuedAt, c.expiresAt, c.nonce
            )
        );
        assertEq(registry.claimDigest(c), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }
}
