// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISchnorrVault} from "../../src/ISchnorrVault.sol";
import {SchnorrSecp256k1} from "../../src/SchnorrSecp256k1.sol";
import {SchnorrVault} from "../../src/SchnorrVault.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {SchnorrTestBase} from "../utils/SchnorrTestBase.sol";

/// @notice Drives the vault through random sequences of signed withdrawals, replays,
///         stale-key attempts, rotations, limit changes, pauses and time jumps, and keeps
///         an independent model of what must have happened (ghost variables).
/// @dev Every action predicts from the model whether it must succeed. A call the model says
///      is valid but the vault rejects is counted in `ghostUnexpectedReverts`, so a
///      regression that makes valid intents revert (wrong digest, broken signing) cannot hide
///      behind the handler's try/catch.
contract VaultHandler is SchnorrTestBase {
    SchnorrVault public vault;
    MockERC20 public token;
    address public guardian = makeAddr("guardian");

    uint256 public constant INITIAL_ETH = 1000 ether;
    uint256 public constant INITIAL_TOKEN = 1_000_000e18;

    Key[] internal keys;
    uint256 internal current;
    uint256 internal nextNonce = 1;

    // --- ghosts -----------------------------------------------------------------
    uint256 public ghostEthDeposited;
    uint256 public ghostEthWithdrawn;
    uint256 public ghostTokenWithdrawn;
    uint256 public ghostRotations;
    uint256 public ghostReplaySuccesses;
    uint256 public ghostStaleKeySuccesses;
    uint256 public ghostPausedWithdrawals;
    uint256 public ghostEarlyActivations;
    uint256 public ghostEarlyGuardianChanges;
    uint256 public ghostStaleEpochActivations;
    uint256 public ghostUnexpectedReverts;
    uint256 public ghostSignedActions;
    bool public ghostPaused;
    address public ghostGuardian;
    address internal ghostPendingGuardian;
    uint256 internal ghostPendingGuardianAt;
    uint256 internal ghostPendingGuardianEpoch;
    uint256[] public usedNonces;
    mapping(address asset => mapping(uint256 day => uint256)) public ghostSpentOnDay;
    mapping(address asset => mapping(uint256 day => uint256)) public ghostMaxLimitOnDay;
    mapping(address asset => uint256) public ghostLimit;
    mapping(address asset => uint256) public ghostPendingLimit;
    mapping(address asset => uint256) public ghostPendingAt;
    mapping(address asset => uint256) public ghostPendingEpoch;

    ISchnorrVault.WithdrawalIntent internal lastIntent;
    SchnorrSecp256k1.Signature internal lastSig;
    bool internal haveLast;

    constructor() {
        vm.warp(1_800_000_000);
        keys.push(makeKey(0x5EED));
        token = new MockERC20();
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(token);
        uint256[] memory limits = new uint256[](2);
        limits[0] = 10 ether;
        limits[1] = 10_000e18;
        vault = new SchnorrVault(keys[0].x, keys[0].parity, guardian, tokens, limits);
        ghostGuardian = guardian;
        ghostLimit[address(0)] = 10 ether;
        ghostLimit[address(token)] = 10_000e18;
        vm.deal(address(vault), INITIAL_ETH);
        token.mint(address(vault), INITIAL_TOKEN);
    }

    // --- helpers ------------------------------------------------------------------

    function assets() external view returns (address[2] memory) {
        return [address(0), address(token)];
    }

    function usedNonceCount() external view returns (uint256) {
        return usedNonces.length;
    }

    function currentKey() external view returns (uint256 x, uint8 parity) {
        return (keys[current].x, keys[current].parity);
    }

    function _asset(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? address(0) : address(token);
    }

    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(vault).balance : token.balanceOf(address(vault));
    }

    function _remaining(address asset) internal view returns (uint256) {
        uint256 limit = ghostLimit[asset];
        uint256 spent = ghostSpentOnDay[asset][_today()];
        return limit > spent ? limit - spent : 0;
    }

    function _isKnownKey(Key memory key) internal view returns (bool) {
        for (uint256 i = 0; i < keys.length; ++i) {
            if (keys[i].x == key.x && keys[i].parity == key.parity) return true;
        }
        return false;
    }

    function _unexpected(bool expected) internal {
        if (expected) ghostUnexpectedReverts++;
    }

    function _touchDay(address asset) internal {
        uint256 limit = vault.dailyLimit(asset);
        if (limit > ghostMaxLimitOnDay[asset][_today()]) {
            ghostMaxLimitOnDay[asset][_today()] = limit;
        }
    }

    // --- actions ------------------------------------------------------------------

    function withdraw(uint256 assetSeed, uint256 amount, uint256 recipientSeed) external {
        address asset = _asset(assetSeed);
        _touchDay(asset);
        uint256 cap = ghostLimit[asset] == 0 ? 1 : ghostLimit[asset];
        amount = bound(amount, 1, cap + cap / 2);
        address to = address(uint160(bound(recipientSeed, 0x1000, 0xffff)));
        uint256 nonce = nextNonce++;
        ISchnorrVault.WithdrawalIntent memory intent =
            withdrawal(to, asset, amount, nonce, block.timestamp + 1 hours);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, keys[current], intent);
        bool expected = !ghostPaused && amount <= _remaining(asset) && amount <= _balance(asset);
        try vault.withdraw(intent, sig) {
            ghostSignedActions++;
            if (ghostPaused) ghostPausedWithdrawals++;
            ghostSpentOnDay[asset][_today()] += amount;
            if (asset == address(0)) ghostEthWithdrawn += amount;
            else ghostTokenWithdrawn += amount;
            usedNonces.push(nonce);
            lastIntent = intent;
            lastSig = sig;
            haveLast = true;
        } catch {
            _unexpected(expected);
        }
    }

    function replayLast() external {
        if (!haveLast) return;
        try vault.withdraw(lastIntent, lastSig) {
            ghostReplaySuccesses++;
        } catch {}
    }

    function withdrawWithStaleKey(uint256 keySeed, uint256 amount) external {
        if (keys.length < 2) return;
        uint256 index = bound(keySeed, 0, keys.length - 1);
        if (keys[index].x == keys[current].x && keys[index].parity == keys[current].parity) return;
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(
            address(0xBEEF), address(0), bound(amount, 1, 1 ether), nextNonce++, block.timestamp
        );
        try vault.withdraw(intent, signWithdrawal(vault, keys[index], intent)) {
            ghostStaleKeySuccesses++;
        } catch {}
    }

    function rotate(uint256 skSeed) external {
        Key memory next = makeKey(bound(skSeed, 1, Q - 1));
        if (!SchnorrSecp256k1.isValidKeyX(next.x) || next.x == keys[current].x) return;
        ISchnorrVault.KeyRotation memory r = ISchnorrVault.KeyRotation({
            newPubKeyX: next.x,
            newPubKeyYParity: next.parity,
            nonce: nextNonce++,
            deadline: block.timestamp
        });
        bytes32 digest = vault.hashKeyRotation(r);
        // Valid unless the target was retired by an earlier rotation.
        bool expected = !_isKnownKey(next);
        try vault.rotateGroupKey(r, schnorrSign(keys[current], digest), schnorrSign(next, digest)) {
            ghostSignedActions++;
            keys.push(next);
            current = keys.length - 1;
            ghostRotations++;
            usedNonces.push(r.nonce);
        } catch {
            _unexpected(expected);
        }
    }

    function updateLimit(uint256 assetSeed, uint256 newLimit) external {
        address asset = _asset(assetSeed);
        newLimit = bound(newLimit, 0, asset == address(0) ? 50 ether : 50_000e18);
        ISchnorrVault.DailyLimitUpdate memory u = ISchnorrVault.DailyLimitUpdate({
            token: asset, newLimit: newLimit, nonce: nextNonce++, deadline: block.timestamp
        });
        try vault.updateDailyLimit(u, schnorrSign(keys[current], vault.hashDailyLimitUpdate(u))) {
            ghostSignedActions++;
            usedNonces.push(u.nonce);
            if (newLimit <= ghostLimit[asset]) {
                ghostLimit[asset] = newLimit;
                ghostPendingLimit[asset] = 0;
                ghostPendingAt[asset] = 0;
            } else {
                ghostPendingLimit[asset] = newLimit;
                ghostPendingAt[asset] = block.timestamp + vault.LIMIT_INCREASE_DELAY();
                ghostPendingEpoch[asset] = ghostRotations;
            }
        } catch {
            _unexpected(true);
        }
    }

    function activate(uint256 assetSeed) external {
        address asset = _asset(assetSeed);
        bool expected = ghostPendingAt[asset] != 0 && ghostPendingEpoch[asset] == ghostRotations
            && block.timestamp >= ghostPendingAt[asset];
        try vault.activateDailyLimit(asset) {
            if (block.timestamp < ghostPendingAt[asset]) ghostEarlyActivations++;
            if (ghostPendingEpoch[asset] != ghostRotations) ghostStaleEpochActivations++;
            ghostLimit[asset] = ghostPendingLimit[asset];
            ghostPendingLimit[asset] = 0;
            ghostPendingAt[asset] = 0;
            _touchDay(asset);
        } catch {
            _unexpected(expected);
        }
    }

    function cancelIncrease(uint256 assetSeed) external {
        address asset = _asset(assetSeed);
        bool expected = ghostPendingAt[asset] != 0;
        vm.prank(ghostGuardian);
        try vault.cancelDailyLimitIncrease(asset) {
            ghostPendingLimit[asset] = 0;
            ghostPendingAt[asset] = 0;
        } catch {
            _unexpected(expected);
        }
    }

    function togglePause() external {
        vm.prank(ghostGuardian);
        if (ghostPaused) {
            vault.unpause();
        } else {
            vault.pause();
        }
        ghostPaused = !ghostPaused;
    }

    function queueGuardian(uint256 guardianSeed) external {
        address next = address(uint160(bound(guardianSeed, 0x100000, 0x1fffff)));
        ISchnorrVault.GuardianUpdate memory u = ISchnorrVault.GuardianUpdate({
            newGuardian: next, nonce: nextNonce++, deadline: block.timestamp
        });
        try vault.queueGuardianReplacement(
            u, schnorrSign(keys[current], vault.hashGuardianUpdate(u))
        ) {
            ghostSignedActions++;
            usedNonces.push(u.nonce);
            ghostPendingGuardian = next;
            ghostPendingGuardianAt = block.timestamp + vault.GUARDIAN_CHANGE_DELAY();
            ghostPendingGuardianEpoch = ghostRotations;
        } catch {
            _unexpected(true);
        }
    }

    function activateGuardian() external {
        bool expected = ghostPendingGuardianAt != 0 && ghostPendingGuardianEpoch == ghostRotations
            && block.timestamp >= ghostPendingGuardianAt;
        try vault.activateGuardianReplacement() {
            if (block.timestamp < ghostPendingGuardianAt) ghostEarlyGuardianChanges++;
            if (ghostPendingGuardianEpoch != ghostRotations) ghostStaleEpochActivations++;
            ghostGuardian = ghostPendingGuardian;
            ghostPendingGuardian = address(0);
            ghostPendingGuardianAt = 0;
        } catch {
            _unexpected(expected);
        }
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        if (ok) ghostEthDeposited += amount;
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 30 hours));
    }

    // --- end-of-run liveness proof (called by afterInvariant, not by the fuzzer) ------

    /// @notice Proves that the state a run left behind is still operable: after the
    ///         guardian unpauses, a fresh in-limit withdrawal signed by the current key
    ///         pays out, a rotation to a fresh key succeeds, the retired key no longer
    ///         authorises, and the new key does. Runs on a state snapshot and restores it,
    ///         so the ghost model is untouched.
    function proveLiveness() external {
        uint256 snapshot = vm.snapshotState();
        if (vault.paused()) {
            vm.prank(vault.guardian());
            vault.unpause();
        }
        if (vault.dailyLimit(address(0)) == 0) {
            ISchnorrVault.DailyLimitUpdate memory u = ISchnorrVault.DailyLimitUpdate({
                token: address(0), newLimit: 1 ether, nonce: nextNonce++, deadline: block.timestamp
            });
            vault.updateDailyLimit(u, schnorrSign(keys[current], vault.hashDailyLimitUpdate(u)));
            vm.warp(block.timestamp + vault.LIMIT_INCREASE_DELAY());
            vault.activateDailyLimit(address(0));
        }
        vm.deal(address(vault), address(vault).balance + 2);
        _mustWithdrawOneWei(keys[current]);

        Key memory next =
            makeKey(uint256(keccak256(abi.encode("liveness", nextNonce))) % (Q - 1) + 1);
        require(SchnorrSecp256k1.isValidKeyX(next.x) && !_isKnownKey(next), "unusable test key");
        ISchnorrVault.KeyRotation memory r = ISchnorrVault.KeyRotation({
            newPubKeyX: next.x,
            newPubKeyYParity: next.parity,
            nonce: nextNonce++,
            deadline: block.timestamp
        });
        bytes32 digest = vault.hashKeyRotation(r);
        vault.rotateGroupKey(r, schnorrSign(keys[current], digest), schnorrSign(next, digest));

        ISchnorrVault.WithdrawalIntent memory stale =
            withdrawal(address(0xBEEF), address(0), 1, nextNonce++, block.timestamp);
        SchnorrSecp256k1.Signature memory staleSig = signWithdrawal(vault, keys[current], stale);
        vm.expectRevert();
        vault.withdraw(stale, staleSig);
        _mustWithdrawOneWei(next);
        require(vm.revertToState(snapshot), "snapshot lost");
    }

    function _mustWithdrawOneWei(Key memory key) internal {
        if (vault.remainingToday(address(0)) == 0) vm.warp(block.timestamp + 1 days);
        ISchnorrVault.WithdrawalIntent memory intent =
            withdrawal(address(0xBEEF), address(0), 1, nextNonce++, block.timestamp);
        uint256 before = address(0xBEEF).balance;
        vault.withdraw(intent, signWithdrawal(vault, key, intent));
        require(address(0xBEEF).balance == before + 1, "valid withdrawal did not pay");
    }
}
