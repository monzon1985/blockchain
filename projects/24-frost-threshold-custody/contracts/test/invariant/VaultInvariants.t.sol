// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {SchnorrVault} from "../../src/SchnorrVault.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// @notice Stateful invariants of SchnorrVault (see README "Invariants").
contract VaultInvariantsTest is StdInvariant, Test {
    VaultHandler internal handler;
    SchnorrVault internal vault;

    function setUp() public {
        handler = new VaultHandler();
        vault = handler.vault();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = VaultHandler.withdraw.selector;
        selectors[1] = VaultHandler.replayLast.selector;
        selectors[2] = VaultHandler.withdrawWithStaleKey.selector;
        selectors[3] = VaultHandler.rotate.selector;
        selectors[4] = VaultHandler.updateLimit.selector;
        selectors[5] = VaultHandler.activate.selector;
        selectors[6] = VaultHandler.cancelIncrease.selector;
        selectors[7] = VaultHandler.togglePause.selector;
        selectors[8] = VaultHandler.deposit.selector;
        selectors[9] = VaultHandler.warp.selector;
        selectors[10] = VaultHandler.queueGuardian.selector;
        selectors[11] = VaultHandler.activateGuardian.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice I1: withdrawals of a token during a UTC day never exceed the highest
    ///         limit in effect during that day, and the vault's own accounting agrees
    ///         with the independent model.
    function invariant_dailyCapNeverExceeded() public view {
        address[2] memory assets = handler.assets();
        uint256 today = block.timestamp / 1 days;
        for (uint256 i = 0; i < 2; ++i) {
            uint256 spent = handler.ghostSpentOnDay(assets[i], today);
            assertLe(spent, handler.ghostMaxLimitOnDay(assets[i], today), "daily cap exceeded");
            assertEq(vault.spentToday(assets[i]), spent, "spentToday diverges from model");
        }
    }

    /// @notice I2: assets are conserved: balance = initial + deposits - withdrawals.
    function invariant_assetsAreConserved() public view {
        assertEq(
            address(vault).balance,
            handler.INITIAL_ETH() + handler.ghostEthDeposited() - handler.ghostEthWithdrawn()
        );
        assertEq(
            handler.token().balanceOf(address(vault)),
            handler.INITIAL_TOKEN() - handler.ghostTokenWithdrawn()
        );
    }

    /// @notice I3: every executed intent burned its nonce, and no replay ever succeeds.
    function invariant_noncesAreSingleUse() public view {
        assertEq(handler.ghostReplaySuccesses(), 0, "replay succeeded");
        uint256 n = handler.usedNonceCount();
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(vault.isNonceUsed(handler.usedNonces(i)));
        }
    }

    /// @notice I4: only the current group key authorises; keys retired by rotation
    ///         are powerless, and the epoch counts rotations.
    function invariant_onlyCurrentKeyAuthorises() public view {
        assertEq(handler.ghostStaleKeySuccesses(), 0, "stale key authorised a withdrawal");
        (uint256 x, uint8 parity, uint64 epoch) = vault.groupKey();
        (uint256 ex, uint8 eparity) = handler.currentKey();
        assertEq(x, ex);
        assertEq(parity, eparity);
        assertEq(epoch, handler.ghostRotations());
    }

    /// @notice I5: limits follow the model: decreases immediate, increases never
    ///         before their time lock.
    function invariant_limitIncreasesAreTimeLocked() public view {
        assertEq(handler.ghostEarlyActivations(), 0, "increase activated early");
        address[2] memory assets = handler.assets();
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(vault.dailyLimit(assets[i]), handler.ghostLimit(assets[i]));
            (uint128 pendingLimit, uint64 effectiveAt, uint64 epoch) = vault.pendingLimit(assets[i]);
            assertEq(pendingLimit, handler.ghostPendingLimit(assets[i]));
            assertEq(effectiveAt, handler.ghostPendingAt(assets[i]));
            if (effectiveAt != 0) assertEq(epoch, handler.ghostPendingEpoch(assets[i]));
        }
    }

    /// @notice I6: nothing leaves the vault while it is paused.
    function invariant_pauseBlocksWithdrawals() public view {
        assertEq(handler.ghostPausedWithdrawals(), 0);
        assertEq(vault.paused(), handler.ghostPaused());
    }

    /// @notice I8: every call the model says is valid (fresh nonce, current key, in
    ///         limit, unpaused, mature and unexpired) succeeds. Without this, the handler's
    ///         try/catch would hide a regression that makes every intent revert.
    function invariant_validActionsSucceed() public view {
        assertEq(handler.ghostUnexpectedReverts(), 0, "a valid action reverted");
    }

    /// @notice After every run: the run did real work, and the state it left behind is
    ///         still operable (unpause, withdraw, rotate, retired key rejected, new key
    ///         accepted), checked on a snapshot that is then restored.
    function afterInvariant() public {
        assertGt(handler.ghostSignedActions(), 0, "run executed no signed action");
        handler.proveLiveness();
    }

    /// @notice I7: the guardian only changes through its own two-step transfer or a
    ///         group replacement that waited GUARDIAN_CHANGE_DELAY under the current
    ///         key; nothing queued under a retired key ever takes effect.
    function invariant_queuedChangesRespectDelayAndEpoch() public view {
        assertEq(vault.guardian(), handler.ghostGuardian());
        assertEq(handler.ghostEarlyGuardianChanges(), 0, "guardian replaced early");
        assertEq(
            handler.ghostStaleEpochActivations(), 0, "change queued under a retired key applied"
        );
    }
}
