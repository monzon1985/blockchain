// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NaiveAllocatorVault} from "../naive/NaiveAllocatorVault.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @title First-mover loss escape
/// @notice Half the vault sits in a strategy that loses 50 %. An informed depositor exits before the loss reaches the
///         price; whoever is left absorbs it.
///         - naive: strategy values are cached until the next harvest, so the first mover leaves whole and the last
///           one pays for both;
///         - AllocatorVault: every entry point values strategies live and recognizes the loss first, so the first and
///           the last to leave get the same price.
contract FirstMoverLossTest is VaultFixture {
    uint256 internal constant EACH = 1000e18;
    uint256 internal constant LOSS = 500e18;

    function _depositTo(IERC4626 target, address user, uint256 assets) internal returns (uint256 shares) {
        asset.mint(user, assets);
        vm.startPrank(user);
        asset.approve(address(target), assets);
        shares = target.deposit(assets, user);
        vm.stopPrank();
    }

    function test_firstMover_naive_earlyExitEscapesTheLoss() public {
        NaiveAllocatorVault naive = new NaiveAllocatorVault(IERC20(address(asset)), false);
        naive.addStrategy(lossy);
        uint256 aliceShares = _depositTo(naive, alice, EACH);
        uint256 bobShares = _depositTo(naive, bob, EACH);
        naive.allocate(lossy, EACH);

        lossy.simulateLoss(LOSS);
        vm.prank(alice);
        uint256 aliceOut = naive.redeem(aliceShares, alice, alice); // informed exit at the stale price
        naive.harvest();
        vm.prank(bob);
        uint256 bobOut = naive.redeem(bobShares, bob, bob);

        emit log_named_decimal_uint("naive: first mover receives (tokens)", aliceOut, 18);
        emit log_named_decimal_uint("naive: last mover receives  (tokens)", bobOut, 18);
        assertEq(aliceOut, EACH, "first mover escapes the loss entirely");
        assertEq(bobOut, EACH - LOSS, "last mover pays the whole loss");
    }

    function test_firstMover_hardened_everyoneGetsTheSamePrice() public {
        uint256 aliceShares = _deposit(alice, EACH);
        uint256 bobShares = _deposit(bob, EACH);
        _allocate(lossy, EACH);

        lossy.simulateLoss(LOSS);
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobOut = vault.redeem(bobShares, bob, bob);

        emit log_named_decimal_uint("hardened: first mover receives (tokens)", aliceOut, 18);
        emit log_named_decimal_uint("hardened: last mover receives  (tokens)", bobOut, 18);
        assertEq(aliceOut, EACH - LOSS / 2, "first mover bears exactly half");
        assertApproxEqAbs(aliceOut, bobOut, 1, "same price for early and late withdrawers");
    }

    function testFuzz_firstMover_hardened_samePriceForAnyLossAndOrder(uint256 a, uint256 b, uint256 loss, bool bobFirst)
        public
    {
        a = bound(a, 1e6, 1e27);
        b = bound(b, 1e6, 1e27);
        uint256 aliceShares = _deposit(alice, a);
        uint256 bobShares = _deposit(bob, b);
        _allocate(lossy, (a + b) / 2);
        loss = bound(loss, 0, (a + b) / 2);
        lossy.simulateLoss(loss);

        uint256 aliceOut;
        uint256 bobOut;
        if (bobFirst) {
            bobOut = _redeemAll(bob);
            aliceOut = _redeemAll(alice);
        } else {
            aliceOut = _redeemAll(alice);
            bobOut = _redeemAll(bob);
        }
        // Per-share payouts are equal up to one wei of rounding on each side.
        assertApproxEqAbs(aliceOut * bobShares / aliceShares, bobOut, 2 + bobShares / aliceShares);
    }
}
