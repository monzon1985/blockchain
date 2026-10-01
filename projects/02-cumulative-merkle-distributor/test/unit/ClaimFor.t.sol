// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {BatchExecutor7702, RejectingDelegate7702, SmartAccount7702} from "../mocks/Delegates7702.sol";
import {MockERC1271Wallet, RevertingWallet, WrongMagicWallet} from "../mocks/MockERC1271Wallet.sol";
import {DistributorBase} from "../utils/DistributorBase.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract ClaimForTest is DistributorBase {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    address internal treasury = makeAddr("treasury");

    Allocation[] internal book;
    bytes32[] internal tree;

    /// @dev Publishes a root where `account` is owed 40e18 of tokenA (leaf 0) next to three other leaves.
    function _publishFor(address account) internal returns (bytes32[] memory proof) {
        delete book;
        book.push(Allocation(account, address(tokenA), 40e18));
        book.push(Allocation(bob, address(tokenA), 10e18));
        book.push(Allocation(carol, address(tokenB), 5e18));
        book.push(Allocation(makeAddr("dave"), address(tokenB), 1e18));
        Allocation[] memory allocs = new Allocation[](book.length);
        for (uint256 i; i < book.length; ++i) {
            allocs[i] = book[i];
        }
        tree = _publish(allocs);
        proof = _proof(tree, 4, 0);
    }

    function _claimFor(address account, bytes32[] memory proof, uint256 deadline, bytes memory signature)
        internal
        returns (uint256)
    {
        vm.prank(relayer);
        return distributor.claimFor(account, address(tokenA), 40e18, proof, treasury, deadline, signature);
    }

    function _expectInvalid(address account, uint256 nonce, uint256 deadline) internal {
        bytes32 digest = distributor.hashClaimAuthorization(account, address(tokenA), 40e18, treasury, nonce, deadline);
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidSignature.selector, account, digest));
    }

    // ------------------------------------------------------------------------------------------------ EOA

    function test_claimFor_eoaSignaturePaysRecipient() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.NonceUsed(alice, 0);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.Claimed(alice, address(tokenA), treasury, 40e18, 40e18);
        uint256 paid = _claimFor(alice, proof, deadline, sig);

        assertEq(paid, 40e18);
        assertEq(tokenA.balanceOf(treasury), 40e18);
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(tokenA.balanceOf(relayer), 0);
        assertEq(distributor.claimed(alice, address(tokenA)), 40e18);
        assertEq(distributor.nonces(alice), 1);
    }

    function test_claimFor_digestMatchesIndependentEip712Encoding() public view {
        assertEq(
            distributor.hashClaimAuthorization(alice, address(tokenA), 40e18, treasury, 3, 1234),
            _expectedDigest(address(distributor), alice, address(tokenA), 40e18, treasury, 3, 1234)
        );
    }

    function test_claimFor_deadlineIsInclusive() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);
        assertEq(_claimFor(alice, proof, deadline, sig), 40e18);
    }

    function test_claimFor_revertsAfterDeadline() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.SignatureExpired.selector, deadline, deadline + 1)
        );
        _claimFor(alice, proof, deadline, sig);
    }

    function test_claimFor_revertsOnInvalidRecipient() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        address[2] memory bad = [address(0), address(distributor)];
        for (uint256 i; i < bad.length; ++i) {
            bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, bad[i], deadline);
            vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidRecipient.selector, bad[i]));
            vm.prank(relayer);
            distributor.claimFor(alice, address(tokenA), 40e18, proof, bad[i], deadline, sig);
        }
    }

    function test_claimFor_revertsForWrongSigner() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(bobKey, alice, address(tokenA), 40e18, treasury, deadline);
        _expectInvalid(alice, 0, deadline);
        _claimFor(alice, proof, deadline, sig);
    }

    function test_claimFor_signatureCannotBeRedirected() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);

        // Same signature, different recipient: the digest changes, so the signature no longer matches.
        bytes32 digest = distributor.hashClaimAuthorization(alice, address(tokenA), 40e18, relayer, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidSignature.selector, alice, digest));
        vm.prank(relayer);
        distributor.claimFor(alice, address(tokenA), 40e18, proof, relayer, deadline, sig);

        // Same signature, extended deadline.
        _expectInvalid(alice, 0, deadline + 1);
        _claimFor(alice, proof, deadline + 1, sig);
    }

    function test_claimFor_replayIsRejectedByNonce() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);
        _claimFor(alice, proof, deadline, sig);

        // Replaying the used signature against the same root and leaf fails on the consumed nonce (the digest is
        // rebuilt with nonce 1), before the proof or the amount are looked at. Cumulative accounting would also stop
        // this exact replay (with NothingToClaim); asserting InvalidSignature pins the nonce itself (mutant M15).
        _expectInvalid(alice, 1, deadline);
        _claimFor(alice, proof, deadline, sig);
        assertEq(distributor.nonces(alice), 1, "a rejected replay does not move the nonce");
    }

    /// @notice `ecrecover` returns address(0) for malformed signatures. A root may contain a leaf for address(0) (a
    ///         builder bug, a burn allocation): recovery errors are rejected before addresses are compared, so no
    ///         garbage signature can ever "recover to" that account and drain its leaf to an arbitrary recipient.
    function test_claimFor_zeroAddressAccountRejectsRecoveryFailures() public {
        bytes32[] memory proof = _publishFor(address(0));
        uint256 deadline = block.timestamp + 1 hours;
        bytes[4] memory garbage = [
            bytes(""), // wrong length: recovers address(0) with InvalidSignatureLength
            new bytes(64), // wrong length (no EIP-2098 compact signatures)
            new bytes(65), // r = s = v = 0: the precompile returns address(0)
            abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(0)) // invalid v: address(0) again
        ];
        for (uint256 i; i < garbage.length; ++i) {
            _expectInvalid(address(0), 0, deadline);
            _claimFor(address(0), proof, deadline, garbage[i]);
        }
        assertEq(tokenA.balanceOf(treasury), 0);
        assertEq(distributor.claimed(address(0), address(tokenA)), 0);
        assertEq(distributor.nonces(address(0)), 0);
    }

    function test_claimFor_invalidateNonceCancelsOutstandingSignature() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit ICumulativeMerkleDistributor.NonceUsed(alice, 0);
        vm.prank(alice);
        distributor.invalidateNonce();
        assertEq(distributor.nonces(alice), 1);

        _expectInvalid(alice, 1, deadline);
        _claimFor(alice, proof, deadline, sig);
    }

    function test_claimFor_rejectsHighSMalleableSignature() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = distributor.hashClaimAuthorization(alice, address(tokenA), 40e18, treasury, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        // (r, n - s, v ^ 1) recovers to the same key but is not canonical.
        bytes memory malleable = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        assertEq(ecrecover(digest, v == 27 ? 28 : 27, r, bytes32(SECP256K1_N - uint256(s))), alice);
        _expectInvalid(alice, 0, deadline);
        _claimFor(alice, proof, deadline, malleable);
    }

    function test_claimFor_rejectsGarbageSignatures() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes[3] memory garbage = [bytes(""), new bytes(64), new bytes(65)];
        for (uint256 i; i < garbage.length; ++i) {
            _expectInvalid(alice, 0, deadline);
            _claimFor(alice, proof, deadline, garbage[i]);
        }
    }

    function test_claimFor_stillRequiresValidProofAndBalance() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);
        proof[0] ^= bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidProof.selector, alice, address(tokenA), 40e18)
        );
        _claimFor(alice, proof, deadline, sig);
        assertEq(distributor.nonces(alice), 0, "a failed claim does not burn the nonce");
    }

    // ------------------------------------------------------------------------------------------------ chain id

    function test_domainSeparator_rebuiltWhenChainIdChanges() public {
        bytes32 original = distributor.DOMAIN_SEPARATOR();
        assertEq(original, _domain(block.chainid));

        uint256 originalChain = block.chainid;
        vm.chainId(originalChain + 1);
        bytes32 forked = distributor.DOMAIN_SEPARATOR();
        assertTrue(forked != original);
        assertEq(forked, _domain(originalChain + 1));

        (, string memory name, string memory version, uint256 chainId, address verifying,,) = distributor.eip712Domain();
        assertEq(name, "CumulativeMerkleDistributor");
        assertEq(version, "1");
        assertEq(chainId, originalChain + 1);
        assertEq(verifying, address(distributor));

        vm.chainId(originalChain);
        assertEq(distributor.DOMAIN_SEPARATOR(), original, "cached value is used again on the original chain");
    }

    function test_claimFor_signatureDoesNotReplayAcrossChains() public {
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);

        uint256 originalChain = block.chainid;
        vm.chainId(originalChain + 1);
        _expectInvalid(alice, 0, deadline);
        _claimFor(alice, proof, deadline, sig);

        vm.chainId(originalChain);
        assertEq(_claimFor(alice, proof, deadline, sig), 40e18);
    }

    function _domain(uint256 chainId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("CumulativeMerkleDistributor"),
                keccak256("1"),
                chainId,
                address(distributor)
            )
        );
    }

    // ------------------------------------------------------------------------------------------------ ERC-1271

    function test_claimFor_erc1271WalletAuthorizes() public {
        (address walletOwner, uint256 walletOwnerKey) = makeAddrAndKey("wallet owner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);
        bytes32[] memory proof = _publishFor(address(wallet));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(walletOwnerKey, address(wallet), address(tokenA), 40e18, treasury, deadline);

        assertEq(_claimFor(address(wallet), proof, deadline, sig), 40e18);
        assertEq(tokenA.balanceOf(treasury), 40e18);
        assertEq(distributor.nonces(address(wallet)), 1);
    }

    function test_claimFor_erc1271RevokedApprovalIsRejected() public {
        (address walletOwner, uint256 walletOwnerKey) = makeAddrAndKey("wallet owner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);
        bytes32[] memory proof = _publishFor(address(wallet));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(walletOwnerKey, address(wallet), address(tokenA), 40e18, treasury, deadline);

        // Contract signatures are revocable: the same bytes stop working once the wallet says so.
        vm.prank(walletOwner);
        wallet.setRevoked(true);
        _expectInvalid(address(wallet), 0, deadline);
        _claimFor(address(wallet), proof, deadline, sig);
    }

    function test_claimFor_erc1271WrongMagicOrRevertIsRejected() public {
        address[2] memory wallets = [address(new WrongMagicWallet()), address(new RevertingWallet())];
        for (uint256 i; i < wallets.length; ++i) {
            bytes32[] memory proof = _publishFor(wallets[i]);
            uint256 deadline = block.timestamp + 1 hours;
            _expectInvalid(wallets[i], 0, deadline);
            _claimFor(wallets[i], proof, deadline, new bytes(65));
        }
    }

    function test_claimFor_contractWithoutErc1271IsRejected() public {
        // tokenB is a contract with code and no isValidSignature: the call returns nothing useful.
        bytes32[] memory proof = _publishFor(address(tokenB));
        uint256 deadline = block.timestamp + 1 hours;
        _expectInvalid(address(tokenB), 0, deadline);
        _claimFor(address(tokenB), proof, deadline, new bytes(65));
    }

    // ------------------------------------------------------------------------------------------------ EIP-7702

    /// @notice alice delegates her EOA to a smart-account implementation and signs with her own key.
    function test_claimFor_7702AccountWithErc1271Delegate() public {
        SmartAccount7702 impl = new SmartAccount7702();
        vm.signAndAttachDelegation(address(impl), aliceKey);
        vm.prank(alice);
        SmartAccount7702(alice).setSessionKey(address(0)); // the delegated call itself, from alice to alice
        assertGt(alice.code.length, 0, "alice is now a 7702 account");
        assertEq(alice.code, abi.encodePacked(hex"ef0100", address(impl)));

        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);
        assertEq(_claimFor(alice, proof, deadline, sig), 40e18);
    }

    /// @notice The 7702 account's delegate authorizes a session key through ERC-1271: the fallback path is used.
    function test_claimFor_7702AccountSessionKeyViaErc1271() public {
        (address session, uint256 sessionKey) = makeAddrAndKey("session key");
        SmartAccount7702 impl = new SmartAccount7702();
        vm.signAndAttachDelegation(address(impl), aliceKey);
        vm.prank(alice);
        SmartAccount7702(alice).setSessionKey(session);
        assertEq(SmartAccount7702(alice).sessionKey(), session);

        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(sessionKey, alice, address(tokenA), 40e18, treasury, deadline);
        assertEq(_claimFor(alice, proof, deadline, sig), 40e18);
    }

    /// @notice A 7702 account whose delegate has no ERC-1271 hook. OpenZeppelin's `SignatureChecker` rejects the EOA's
    ///         own signature (it only tries ERC-1271 once there is code); the distributor accepts it, because the key
    ///         still controls the account.
    function test_claimFor_7702AccountWithoutErc1271Delegate() public {
        BatchExecutor7702 impl = new BatchExecutor7702();
        vm.signAndAttachDelegation(address(impl), aliceKey);
        vm.prank(alice);
        BatchExecutor7702(alice).execute(new BatchExecutor7702.Call[](0));
        assertEq(alice.code, abi.encodePacked(hex"ef0100", address(impl)));

        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);
        bytes32 digest = distributor.hashClaimAuthorization(alice, address(tokenA), 40e18, treasury, 0, deadline);

        assertFalse(SignatureChecker.isValidSignatureNow(alice, digest, sig), "stock SignatureChecker says no");
        assertEq(_claimFor(alice, proof, deadline, sig), 40e18, "the distributor says yes");
    }

    /// @notice A 7702 delegate cannot veto its own key: the EOA key is authoritative under EIP-7702 (it can always
    ///         re-delegate), so rejecting it in ERC-1271 would add no security.
    function test_claimFor_7702KeyIsAuthoritativeEvenIfDelegateRejects() public {
        RejectingDelegate7702 impl = new RejectingDelegate7702();
        vm.signAndAttachDelegation(address(impl), aliceKey);
        vm.prank(alice);
        // The call only carries the authorization; the delegate answers "invalid" to everything.
        assertEq(RejectingDelegate7702(alice).isValidSignature(bytes32(0), ""), bytes4(0xffffffff));
        assertEq(alice.code, abi.encodePacked(hex"ef0100", address(impl)));

        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(aliceKey, alice, address(tokenA), 40e18, treasury, deadline);
        assertEq(_claimFor(alice, proof, deadline, sig), 40e18);

        // A foreign key is still rejected on the next top-up: ECDSA does not recover to alice and the delegate's
        // hook says no.
        (, uint256 mallory) = makeAddrAndKey("mallory");
        book[0].cumulativeAmount = 80e18;
        Allocation[] memory allocs = new Allocation[](book.length);
        for (uint256 i; i < book.length; ++i) {
            allocs[i] = book[i];
        }
        tree = _publish(allocs);
        deadline = block.timestamp + 1 hours;
        bytes memory forged = _authorization(mallory, alice, address(tokenA), 80e18, treasury, deadline);
        bytes32 digest = distributor.hashClaimAuthorization(alice, address(tokenA), 80e18, treasury, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(ICumulativeMerkleDistributor.InvalidSignature.selector, alice, digest));
        vm.prank(relayer);
        distributor.claimFor(alice, address(tokenA), 80e18, _proof(tree, 4, 0), treasury, deadline, forged);
    }

    // ------------------------------------------------------------------------------------------------ fuzz

    function testFuzz_claimFor_anyEoaAnyDeadline(uint256 key, uint256 deadlineOffset, uint256 warpBy) public {
        key = bound(key, 1, SECP256K1_N - 1);
        address signer = vm.addr(key);
        vm.assume(signer.code.length == 0);
        deadlineOffset = bound(deadlineOffset, 0, 365 days);
        warpBy = bound(warpBy, 0, 400 days);

        bytes32[] memory proof = _publishFor(signer);
        uint256 deadline = block.timestamp + deadlineOffset;
        bytes memory sig = _authorization(key, signer, address(tokenA), 40e18, treasury, deadline);
        vm.warp(block.timestamp + warpBy);

        if (block.timestamp > deadline) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICumulativeMerkleDistributor.SignatureExpired.selector, deadline, block.timestamp
                )
            );
            _claimFor(signer, proof, deadline, sig);
        } else {
            assertEq(_claimFor(signer, proof, deadline, sig), 40e18);
            assertEq(tokenA.balanceOf(treasury), 40e18);
        }
    }

    function testFuzz_claimFor_foreignKeyNeverAuthorizes(uint256 foreignKey) public {
        foreignKey = bound(foreignKey, 1, SECP256K1_N - 1);
        vm.assume(foreignKey != aliceKey);
        bytes32[] memory proof = _publishFor(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _authorization(foreignKey, alice, address(tokenA), 40e18, treasury, deadline);
        _expectInvalid(alice, 0, deadline);
        _claimFor(alice, proof, deadline, sig);
    }
}
