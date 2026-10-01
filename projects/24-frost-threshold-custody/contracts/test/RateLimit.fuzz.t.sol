// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISchnorrVault} from "../src/ISchnorrVault.sol";
import {SchnorrSecp256k1} from "../src/SchnorrSecp256k1.sol";
import {SchnorrVault} from "../src/SchnorrVault.sol";
import {SchnorrTestBase} from "./utils/SchnorrTestBase.sol";

/// @notice Stateless fuzzing of the per-UTC-day limit against a reference model.
contract RateLimitFuzzTest is SchnorrTestBase {
    SchnorrVault internal vault;
    Key internal group;
    address internal alice = makeAddr("alice");
    uint256 internal constant LIMIT = 10 ether;
    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        group = makeKey(0xF00D);
        address[] memory tokens = new address[](1);
        uint256[] memory limits = new uint256[](1);
        limits[0] = LIMIT;
        vault = new SchnorrVault(group.x, group.parity, makeAddr("guardian"), tokens, limits);
        vm.deal(address(vault), 1000 ether);
    }

    function _try(uint256 amount, uint256 nonce) internal returns (bool ok, bytes memory err) {
        ISchnorrVault.WithdrawalIntent memory intent =
            withdrawal(alice, address(0), amount, nonce, type(uint64).max);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        try vault.withdraw(intent, sig) {
            ok = true;
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    /// @notice A random sequence of withdrawals and time jumps: every call succeeds
    ///         exactly when the reference model says it fits in the current UTC day,
    ///         and otherwise reverts with the model's remaining allowance.
    function testFuzz_withdrawalsFollowTheDailyModel(
        uint256[10] memory amounts,
        uint256[10] memory gaps
    ) public {
        uint256 day = block.timestamp / 1 days;
        uint256 spent;
        uint256 total;
        for (uint256 i = 0; i < amounts.length; ++i) {
            vm.warp(block.timestamp + bound(gaps[i], 0, 18 hours));
            if (block.timestamp / 1 days != day) {
                day = block.timestamp / 1 days;
                spent = 0;
            }
            uint256 amount = bound(amounts[i], 1, LIMIT + 1 ether);
            uint256 remaining = LIMIT - spent;
            (bool ok, bytes memory err) = _try(amount, i + 1);
            if (amount <= remaining) {
                assertTrue(ok, "withdrawal within the allowance must succeed");
                spent += amount;
                total += amount;
            } else {
                assertFalse(ok);
                assertEq(
                    err,
                    abi.encodeWithSelector(
                        ISchnorrVault.DailyLimitExceeded.selector, address(0), amount, remaining
                    )
                );
            }
            assertEq(vault.spentToday(address(0)), spent);
            assertEq(vault.remainingToday(address(0)), LIMIT - spent);
            assertLe(spent, LIMIT);
        }
        assertEq(alice.balance, total);
    }

    /// @notice Decreases bind immediately; increases only after the time lock.
    function testFuzz_increasesAreTimeLocked(uint256 newLimit, uint256 wait) public {
        newLimit = bound(newLimit, 0, 1000 ether);
        wait = bound(wait, 0, 5 days);
        ISchnorrVault.DailyLimitUpdate memory u = ISchnorrVault.DailyLimitUpdate({
            token: address(0), newLimit: newLimit, nonce: 1, deadline: T0
        });
        vault.updateDailyLimit(u, schnorrSign(group, vault.hashDailyLimitUpdate(u)));
        if (newLimit <= LIMIT) {
            assertEq(vault.dailyLimit(address(0)), newLimit);
            return;
        }
        assertEq(vault.dailyLimit(address(0)), LIMIT);
        vm.warp(T0 + wait);
        if (wait < vault.LIMIT_INCREASE_DELAY()) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISchnorrVault.IncreaseNotMature.selector,
                    address(0),
                    uint64(T0 + vault.LIMIT_INCREASE_DELAY()),
                    T0 + wait
                )
            );
            vault.activateDailyLimit(address(0));
            assertEq(vault.dailyLimit(address(0)), LIMIT);
        } else {
            vault.activateDailyLimit(address(0));
            assertEq(vault.dailyLimit(address(0)), newLimit);
        }
    }

    /// @notice Lowering the limit below what was already spent never underflows and
    ///         blocks every further withdrawal until the next UTC day.
    function testFuzz_decreaseBelowSpent(uint256 spend, uint256 newLimit) public {
        spend = bound(spend, 1, LIMIT);
        newLimit = bound(newLimit, 0, spend);
        (bool ok,) = _try(spend, 1);
        assertTrue(ok);
        ISchnorrVault.DailyLimitUpdate memory u = ISchnorrVault.DailyLimitUpdate({
            token: address(0), newLimit: newLimit, nonce: 2, deadline: T0
        });
        vault.updateDailyLimit(u, schnorrSign(group, vault.hashDailyLimitUpdate(u)));
        assertEq(vault.remainingToday(address(0)), 0);
        (ok,) = _try(1, 3);
        assertFalse(ok);
        vm.warp((T0 / 1 days + 1) * 1 days);
        assertEq(vault.remainingToday(address(0)), newLimit);
    }
}
