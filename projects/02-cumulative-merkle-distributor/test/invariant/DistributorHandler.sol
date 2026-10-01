// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CumulativeMerkleDistributor} from "../../src/CumulativeMerkleDistributor.sol";
import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MerkleBuilder} from "../utils/MerkleBuilder.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Drives the distributor through its whole lifecycle: the updater proposes cumulative roots (and funds them,
///         as an operator would), the guardian revokes some, anyone tries to accept them at arbitrary times, and
///         accounts claim directly, through signed `claimFor` (EOAs and one ERC-1271 wallet) and in multiproof batches.
///         Hostile actions (forged amounts, stale proofs, replayed signatures, premature accepts) must revert. Ghost
///         variables mirror everything the invariants compare against.
/// @dev 8 accounts x 2 tokens = 16 (account, token) pairs; pair p is (accounts[p >> 1], tokens[p & 1]) and is leaf p
///      of every tree. Most roots are monotonic per pair, as tree-builder produces them; one proposal in four is a
///      corrective root that may also lower pairs, below what they already claimed included.
contract DistributorHandler is CommonBase, StdCheats, StdUtils, StdAssertions {
    uint256 public constant PAIRS = 16;
    uint256 internal constant ACCOUNTS = 8;

    CumulativeMerkleDistributor public immutable distributor;
    address public immutable updater;
    address public immutable guardian;
    MockERC20[2] public tokens;
    address[ACCOUNTS] public accounts;
    uint256[ACCOUNTS] internal keys;
    address[3] internal recipients;
    address internal relayer = makeAddr("relayer");

    // ------------------------------------------------------------------ model of the on-chain roots
    bool public hasActive;
    bytes32 public activeRoot;
    uint256[PAIRS] public activeAmounts;

    bool public hasPending;
    bytes32 public pendingRoot;
    uint256 public pendingProposedAt;
    uint256[PAIRS] internal pendingAmounts;
    bool internal pendingLowers;

    /// @dev claimed[pair] at the moment the active root was accepted.
    uint256[PAIRS] public claimedAtActivation;

    bool internal hasPrevious;
    bytes32 internal previousRoot;
    uint256[PAIRS] internal previousAmounts;

    // ------------------------------------------------------------------ ghosts
    mapping(address token => uint256) public ghostFunded;
    mapping(address token => uint256) public ghostPaid;
    uint256[PAIRS] public ghostClaimedSnapshot;
    uint256 public ghostAccepted;
    /// @dev Smallest (acceptance time - proposal time) over every acceptRoot the contract let through. The handler
    ///      tries to accept at arbitrary times, so this measures the contract's timelock, not the handler's.
    uint256 public ghostMinAcceptDelay = type(uint256).max;
    uint256 public ghostEarlyAcceptsRejected;
    uint256 public ghostLoweringAccepted;
    uint256 public ghostPairsLoweredBelowClaimed;
    uint256 public ghostSignedClaims;
    uint256 public ghostInvalidations;
    uint256 public ghostHostileRejected;
    mapping(string action => uint256) public calls;

    constructor(CumulativeMerkleDistributor distributor_, address updater_, address guardian_) {
        distributor = distributor_;
        updater = updater_;
        guardian = guardian_;
        tokens[0] = new MockERC20("Reward A", "RWA");
        tokens[1] = new MockERC20("Reward B", "RWB");
        for (uint256 i; i < ACCOUNTS - 1; ++i) {
            (accounts[i], keys[i]) = makeAddrAndKey(string.concat("account-", vm.toString(i)));
        }
        // The last account is a smart-contract wallet: its claimFor signatures go through ERC-1271.
        (address walletOwner, uint256 walletOwnerKey) = makeAddrAndKey("wallet owner");
        accounts[ACCOUNTS - 1] = address(new MockERC1271Wallet(walletOwner));
        keys[ACCOUNTS - 1] = walletOwnerKey;
        recipients = [makeAddr("recipient-0"), makeAddr("recipient-1"), makeAddr("recipient-2")];
    }

    // ------------------------------------------------------------------ helpers

    function pairAccount(uint256 p) public view returns (address) {
        return accounts[p >> 1];
    }

    function pairToken(uint256 p) public view returns (address) {
        return address(tokens[p & 1]);
    }

    function _leaves(uint256[PAIRS] memory amounts) internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](PAIRS);
        for (uint256 p; p < PAIRS; ++p) {
            leaves[p] = MerkleBuilder.leaf(pairAccount(p), pairToken(p), amounts[p]);
        }
    }

    function _proof(uint256[PAIRS] memory amounts, uint256 p) internal view returns (bytes32[] memory) {
        return MerkleBuilder.proof(MerkleBuilder.build(_leaves(amounts)), MerkleBuilder.treeIndexOf(PAIRS, p));
    }

    /// @dev Signature of pair p's account (or of the wallet owner, for the ERC-1271 account) over a claim authorization.
    function _sign(uint256 p, uint256 amount, address recipient, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            distributor.hashClaimAuthorization(pairAccount(p), pairToken(p), amount, recipient, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[p >> 1], digest);
        return abi.encodePacked(r, s, v);
    }

    function _selector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length >= 4) sel = bytes4(err);
    }

    /// @dev After every action: `claimed` never decreases, then the snapshot moves forward.
    function _checkpoint() internal {
        for (uint256 p; p < PAIRS; ++p) {
            uint256 c = distributor.claimed(pairAccount(p), pairToken(p));
            assertGe(c, ghostClaimedSnapshot[p], "claimed decreased");
            ghostClaimedSnapshot[p] = c;
        }
    }

    function _recordPayout(uint256 p, uint256 paid, uint256 expected) internal {
        assertEq(paid, expected, "payout != cumulative - claimed");
        ghostPaid[pairToken(p)] += paid;
    }

    // ------------------------------------------------------------------ root lifecycle

    function proposeRoot(uint256 seed) external {
        calls["proposeRoot"]++;
        uint256[PAIRS] memory amounts = activeAmounts;
        // One proposal in four is a corrective root: besides topping pairs up, it lowers about a quarter of them, to any
        // value down to zero (below what the pair already claimed included).
        bool corrective = seed % 4 == 0;
        bool lowers;
        for (uint256 p; p < PAIRS; ++p) {
            uint256 r = uint256(keccak256(abi.encode(seed, p)));
            if (corrective && r % 4 == 0 && amounts[p] != 0) {
                amounts[p] = bound(r >> 2, 0, amounts[p] - 1);
                lowers = true;
            } else if (r & 1 == 1) {
                amounts[p] += bound(r >> 1, 0, 1e24);
            }
        }
        bytes32 newRoot = MerkleBuilder.root(_leaves(amounts));

        // Fund the outstanding liability of the proposed root, like an operator topping up the vault.
        for (uint256 t; t < 2; ++t) {
            address token = address(tokens[t]);
            uint256 liability;
            for (uint256 p = t; p < PAIRS; p += 2) {
                uint256 already = distributor.claimed(pairAccount(p), token);
                if (amounts[p] > already) liability += amounts[p] - already;
            }
            uint256 balance = tokens[t].balanceOf(address(distributor));
            if (liability > balance) {
                tokens[t].mint(address(distributor), liability - balance);
                ghostFunded[token] += liability - balance;
            }
        }

        vm.prank(updater);
        distributor.proposeRoot(newRoot, keccak256(abi.encode("manifest", seed)));
        hasPending = true;
        pendingRoot = newRoot;
        pendingProposedAt = block.timestamp;
        pendingAmounts = amounts;
        pendingLowers = lowers;
        _checkpoint();
    }

    function revokePendingRoot() external {
        if (!hasPending) return;
        calls["revokePendingRoot"]++;
        vm.prank(guardian);
        distributor.revokePendingRoot();
        hasPending = false;
        pendingRoot = bytes32(0);
        _checkpoint();
    }

    /// @notice Tries to accept the pending root at a time chosen by `timing`: right now, one second before the deadline,
    ///         exactly at it, or some time after it. Whatever the contract does is checked against the model: the call
    ///         must succeed exactly when 24 h have passed since the proposal, and fail with `RootTimelocked` otherwise.
    function acceptRoot(uint256 callerSeed, uint256 timing) external {
        if (!hasPending) return;
        calls["acceptRoot"]++;
        // Deadline from the model (the handler's own record of the proposal time), not from the contract.
        uint256 validAt = pendingProposedAt + distributor.ROOT_TIMELOCK();
        (,, uint64 onChainValidAt) = distributor.pendingRoot();
        assertEq(onChainValidAt, validAt, "pending validAt != proposal time + timelock");

        uint256 mode = timing % 4;
        if (mode == 1 && block.timestamp + 1 < validAt) vm.warp(validAt - 1);
        else if (mode == 2 && block.timestamp < validAt) vm.warp(validAt);
        else if (mode == 3 && block.timestamp < validAt) vm.warp(validAt + bound(timing >> 2, 0, 3 days));
        bool due = block.timestamp >= validAt;

        vm.prank(accounts[callerSeed % ACCOUNTS]);
        try distributor.acceptRoot() {
            assertTrue(due, "accepted inside the timelock");
        } catch (bytes memory err) {
            // Hostile when early: accepting inside the veto window must fail, and only then.
            assertFalse(due, "acceptRoot reverted after the timelock");
            assertEq(_selector(err), ICumulativeMerkleDistributor.RootTimelocked.selector);
            ghostHostileRejected++;
            ghostEarlyAcceptsRejected++;
            _checkpoint();
            return;
        }

        if (hasActive) {
            hasPrevious = true;
            previousRoot = activeRoot;
            previousAmounts = activeAmounts;
        }
        hasActive = true;
        activeRoot = pendingRoot;
        activeAmounts = pendingAmounts;
        hasPending = false;
        pendingRoot = bytes32(0);
        ghostAccepted++;
        if (pendingLowers) ghostLoweringAccepted++;
        for (uint256 p; p < PAIRS; ++p) {
            uint256 c = distributor.claimed(pairAccount(p), pairToken(p));
            claimedAtActivation[p] = c;
            if (activeAmounts[p] < c) ghostPairsLoweredBelowClaimed++;
        }
        uint256 delay = block.timestamp - pendingProposedAt;
        if (delay < ghostMinAcceptDelay) ghostMinAcceptDelay = delay;
        _checkpoint();
    }

    function warp(uint256 secs) external {
        calls["warp"]++;
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    // ------------------------------------------------------------------ claims

    function claim(uint256 pairSeed, uint256 callerSeed) external {
        if (!hasActive) return;
        calls["claim"]++;
        uint256 p = pairSeed % PAIRS;
        address account = pairAccount(p);
        address token = pairToken(p);
        uint256 amount = activeAmounts[p];
        uint256 already = distributor.claimed(account, token);
        bytes32[] memory proof = _proof(activeAmounts, p);

        if (amount > already) {
            uint256 before = MockERC20(token).balanceOf(account);
            vm.prank(recipients[callerSeed % 3]);
            uint256 paid = distributor.claim(account, token, amount, proof);
            _recordPayout(p, paid, amount - already);
            assertEq(MockERC20(token).balanceOf(account), before + paid, "claim must pay the account");
        } else {
            try distributor.claim(account, token, amount, proof) {
                fail("claimed nothing twice");
            } catch (bytes memory err) {
                assertEq(_selector(err), ICumulativeMerkleDistributor.NothingToClaim.selector);
            }
        }
        _checkpoint();
    }

    function claimFor(uint256 pairSeed, uint256 recipientSeed, uint256 deadlineSeed) external {
        if (!hasActive) return;
        uint256 p = pairSeed % PAIRS;
        uint256 already = distributor.claimed(pairAccount(p), pairToken(p));
        if (activeAmounts[p] <= already) return;
        calls["claimFor"]++;

        address recipient = recipients[recipientSeed % 3];
        uint256 before = MockERC20(pairToken(p)).balanceOf(recipient);
        uint256 paid = _signedClaim(p, recipient, block.timestamp + bound(deadlineSeed, 0, 7 days));
        _recordPayout(p, paid, activeAmounts[p] - already);
        assertEq(MockERC20(pairToken(p)).balanceOf(recipient), before + paid, "claimFor must pay the recipient");
        ghostSignedClaims++;
        _checkpoint();
    }

    function _signedClaim(uint256 p, address recipient, uint256 deadline) internal returns (uint256) {
        address account = pairAccount(p);
        bytes memory signature = _sign(p, activeAmounts[p], recipient, distributor.nonces(account), deadline);
        bytes32[] memory proof = _proof(activeAmounts, p);
        vm.prank(relayer);
        return distributor.claimFor(account, pairToken(p), activeAmounts[p], proof, recipient, deadline, signature);
    }

    function claimMany(uint256 mask, uint256 callerSeed) external {
        if (!hasActive) return;
        calls["claimMany"]++;
        mask &= (1 << PAIRS) - 1;
        if (mask == 0) mask = 1 << (callerSeed % PAIRS);

        uint256[] memory treeIndices = new uint256[](PAIRS);
        uint256 n;
        for (uint256 p; p < PAIRS; ++p) {
            if ((mask >> p) & 1 == 1) treeIndices[n++] = MerkleBuilder.treeIndexOf(PAIRS, p);
        }
        // Shrink to the selected pairs. Memory-safe: lowers the length of an array allocated above.
        assembly ("memory-safe") {
            mstore(treeIndices, n)
        }
        MerkleBuilder.MultiProof memory mp =
            MerkleBuilder.multiProof(MerkleBuilder.build(_leaves(activeAmounts)), treeIndices);

        ICumulativeMerkleDistributor.ClaimLeaf[] memory batch = new ICumulativeMerkleDistributor.ClaimLeaf[](n);
        uint256[] memory expected = new uint256[](n);
        uint256[] memory pairOf = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 p = 2 * PAIRS - 2 - mp.treeIndices[i];
            pairOf[i] = p;
            batch[i] = ICumulativeMerkleDistributor.ClaimLeaf(pairAccount(p), pairToken(p), activeAmounts[p]);
            uint256 already = distributor.claimed(pairAccount(p), pairToken(p));
            expected[i] = activeAmounts[p] > already ? activeAmounts[p] - already : 0;
        }

        vm.prank(recipients[callerSeed % 3]);
        uint256[] memory paid = distributor.claimMany(batch, mp.proof, mp.proofFlags);
        for (uint256 i; i < n; ++i) {
            _recordPayout(pairOf[i], paid[i], expected[i]);
        }
        _checkpoint();
    }

    function invalidateNonce(uint256 accountSeed) external {
        calls["invalidateNonce"]++;
        vm.prank(accounts[accountSeed % ACCOUNTS]);
        distributor.invalidateNonce();
        ghostInvalidations++;
        _checkpoint();
    }

    // ------------------------------------------------------------------ hostile actions (must always revert)

    function claimInflated(uint256 pairSeed, uint256 extra) external {
        if (!hasActive) return;
        calls["claimInflated"]++;
        uint256 p = pairSeed % PAIRS;
        uint256 inflated = activeAmounts[p] + bound(extra, 1, 1e30);
        try distributor.claim(pairAccount(p), pairToken(p), inflated, _proof(activeAmounts, p)) {
            fail("inflated claim paid out");
        } catch (bytes memory err) {
            assertEq(_selector(err), ICumulativeMerkleDistributor.InvalidProof.selector);
            ghostHostileRejected++;
        }
        _checkpoint();
    }

    function claimStale(uint256 pairSeed) external {
        if (!hasPrevious || previousRoot == activeRoot) return;
        calls["claimStale"]++;
        uint256 p = pairSeed % PAIRS;
        try distributor.claim(pairAccount(p), pairToken(p), previousAmounts[p], _proof(previousAmounts, p)) {
            fail("stale proof accepted");
        } catch (bytes memory err) {
            // The old leaf is either absent from the new root or, if unchanged, its old sibling path is stale.
            assertEq(_selector(err), ICumulativeMerkleDistributor.InvalidProof.selector);
            ghostHostileRejected++;
        }
        _checkpoint();
    }

    function claimForWithReplayedSignature(uint256 pairSeed) external {
        if (!hasActive) return;
        uint256 p = pairSeed % PAIRS;
        address account = pairAccount(p);
        uint256 nonce = distributor.nonces(account);
        if (nonce == 0) return;
        calls["claimForReplay"]++;
        // A signature over an already-consumed nonce can never be used again.
        uint256 deadline = block.timestamp + 1 days;
        bytes memory stale = _sign(p, activeAmounts[p], recipients[0], nonce - 1, deadline);
        try distributor.claimFor(
            account, pairToken(p), activeAmounts[p], _proof(activeAmounts, p), recipients[0], deadline, stale
        ) {
            fail("replayed signature accepted");
        } catch (bytes memory err) {
            assertEq(_selector(err), ICumulativeMerkleDistributor.InvalidSignature.selector);
            ghostHostileRejected++;
        }
        _checkpoint();
    }

    // ------------------------------------------------------------------ views for the invariant contract

    function sumClaimed(uint256 t) external view returns (uint256 sum) {
        for (uint256 p = t; p < PAIRS; p += 2) {
            sum += distributor.claimed(pairAccount(p), address(tokens[t]));
        }
    }

    /// @notice Most a pair may have claimed under the active root: its leaf, or what it had already claimed when the
    ///         root was accepted if a corrective root lowered it below that (such a pair is paid nothing).
    function claimCeiling(uint256 p) public view returns (uint256) {
        uint256 leaf = activeAmounts[p];
        uint256 before = claimedAtActivation[p];
        return leaf > before ? leaf : before;
    }

    function sumCeiling(uint256 t) external view returns (uint256 sum) {
        for (uint256 p = t; p < PAIRS; p += 2) {
            sum += claimCeiling(p);
        }
    }

    function sumNonces() external view returns (uint256 sum) {
        for (uint256 i; i < ACCOUNTS; ++i) {
            sum += distributor.nonces(accounts[i]);
        }
    }
}
