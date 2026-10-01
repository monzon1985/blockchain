// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice Pause, blocklist, freeze and the two lawful-order paths (seize, burnFrozen), entry point by entry point.
contract ComplianceTest is StablecoinTestBase {
    function setUp() public override {
        super.setUp();
        _mint(alice, 1000e6);
        _mint(bob, 1000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------------------------------------------------

    function test_pause_blocksEveryValueMovement() public {
        vm.prank(alice);
        token.approve(carol, 100e6);
        vm.prank(pauser);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        token.transfer(bob, 1);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(carol);
        token.transferFrom(alice, bob, 1);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        token.approve(bob, 1);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(bridge);
        token.crosschainBurn(alice, 1);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(bridge);
        token.crosschainMint(alice, 1);

        vm.prank(compliance);
        token.freeze(alice, ORDER_REF); // freezing itself is not a value movement and stays available
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(compliance);
        token.seize(alice, custody, 1, ORDER_REF);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(compliance);
        token.burnFrozen(alice, ORDER_REF);

        vm.prank(pauser);
        token.unpause();
        vm.prank(bob);
        token.transfer(carol, 1);
        assertEq(token.balanceOf(carol), 1);
    }

    /// Revoking an allowance moves no value, so `approve(spender, 0)` and zero-value permits work while paused and
    /// for a restricted owner; any non-zero approval is still refused in those states.
    function test_revokingAllowance_alwaysPossible() public {
        vm.prank(alice);
        token.approve(carol, 100e6);
        vm.prank(bob);
        token.approve(carol, 50e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory bobRevokes = _signPermit(bobKey, bob, carol, 0, deadline);

        // During a pause: holders revoke ahead of the unpause, with approve and with a relayed permit.
        vm.prank(pauser);
        token.pause();
        vm.prank(alice);
        token.approve(carol, 0);
        assertEq(token.allowance(alice, carol), 0);
        token.permit(bob, carol, 0, deadline, bobRevokes);
        assertEq(token.allowance(bob, carol), 0);
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.approve(carol, 1);
        vm.prank(pauser);
        token.unpause();

        // A frozen owner can cut off its spenders but not grant anything.
        vm.prank(alice);
        token.approve(bob, 7e6);
        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);
        vm.prank(alice);
        token.approve(bob, 0);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, alice));
        token.approve(bob, 1);

        // A blocklisted owner can revoke with a (v, r, s) permit, but not grant.
        vm.prank(bob);
        token.approve(carol, 9e6);
        vm.prank(blocklister);
        token.blocklist(bob);
        (uint8 v, bytes32 r, bytes32 s) = _split(_signPermit(bobKey, bob, carol, 0, deadline));
        token.permit(bob, carol, 0, deadline, v, r, s);
        assertEq(token.allowance(bob, carol), 0);
        bytes memory grant = _signPermit(bobKey, bob, carol, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, bob));
        token.permit(bob, carol, 1, deadline, grant);
    }

    function test_pause_revertsWhenAlreadyInState() public {
        vm.prank(pauser);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        token.unpause();
        vm.prank(pauser);
        token.pause();
        vm.prank(pauser);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.pause();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Blocklist
    // ------------------------------------------------------------------------------------------------------------

    function test_blocklist_lifecycle() public {
        vm.expectEmit(true, false, false, false);
        emit Blocklisted(alice);
        vm.prank(blocklister);
        token.blocklist(alice);
        assertTrue(token.isBlocklisted(alice));

        vm.prank(blocklister);
        vm.expectRevert(abi.encodeWithSelector(BlocklistStatusUnchanged.selector, alice, true));
        token.blocklist(alice);

        vm.expectEmit(true, false, false, false);
        emit UnBlocklisted(alice);
        vm.prank(blocklister);
        token.unBlocklist(alice);
        assertFalse(token.isBlocklisted(alice));

        vm.prank(blocklister);
        vm.expectRevert(abi.encodeWithSelector(BlocklistStatusUnchanged.selector, alice, false));
        token.unBlocklist(alice);

        vm.prank(blocklister);
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        token.blocklist(address(0));
    }

    function test_blocklisted_cannotSendReceiveApproveOrSpend() public {
        vm.prank(bob);
        token.approve(alice, 10e6);
        vm.prank(alice);
        token.approve(carol, 10e6);
        vm.prank(blocklister);
        token.blocklist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, alice));
        token.transfer(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, alice));
        token.transfer(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, alice));
        token.approve(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, alice));
        token.approve(alice, 1);

        // Blocklisted spender cannot use an existing allowance.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, alice));
        token.transferFrom(bob, carol, 1);

        // A clean spender cannot move the blocklisted owner's funds.
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, alice));
        token.transferFrom(alice, carol, 1);

        // Revoking an allowance towards a blocklisted spender stays possible.
        vm.prank(bob);
        token.approve(alice, 0);
        assertEq(token.allowance(bob, alice), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Freeze
    // ------------------------------------------------------------------------------------------------------------

    function test_freeze_lifecycle() public {
        vm.expectEmit(true, true, false, false);
        emit Frozen(alice, ORDER_REF);
        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);
        assertTrue(token.isFrozen(alice));

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(FreezeStatusUnchanged.selector, alice, true));
        token.freeze(alice, ORDER_REF);

        vm.prank(compliance);
        vm.expectRevert(MissingOrderReference.selector);
        token.unfreeze(alice, bytes32(0));

        vm.expectEmit(true, true, false, false);
        emit Unfrozen(alice, keccak256("release"));
        vm.prank(compliance);
        token.unfreeze(alice, keccak256("release"));
        assertFalse(token.isFrozen(alice));

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(FreezeStatusUnchanged.selector, alice, false));
        token.unfreeze(alice, ORDER_REF);
    }

    function test_freeze_revertsOnBadInput() public {
        vm.prank(compliance);
        vm.expectRevert(MissingOrderReference.selector);
        token.freeze(alice, bytes32(0));
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        token.freeze(address(0), ORDER_REF);
    }

    function test_frozen_cannotSendReceiveApproveOrSpend() public {
        vm.prank(bob);
        token.approve(alice, 10e6);
        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, alice));
        token.transfer(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, alice));
        token.transfer(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, alice));
        token.approve(bob, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, alice));
        token.transferFrom(bob, carol, 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Seize
    // ------------------------------------------------------------------------------------------------------------

    function test_seize_movesFrozenFundsUnderOrder() public {
        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, custody, 400e6);
        vm.expectEmit(true, true, true, true);
        emit Seized(alice, custody, 400e6, ORDER_REF);
        vm.prank(compliance);
        token.seize(alice, custody, 400e6, ORDER_REF);
        assertEq(token.balanceOf(alice), 600e6);
        assertEq(token.balanceOf(custody), 400e6);
        assertEq(token.totalSupply(), 2000e6);
        assertTrue(token.isFrozen(alice), "seizure does not lift the freeze");
    }

    function test_seize_reverts() public {
        vm.startPrank(compliance);
        vm.expectRevert(abi.encodeWithSelector(AccountNotFrozen.selector, alice));
        token.seize(alice, custody, 1, ORDER_REF);

        token.freeze(alice, ORDER_REF);
        vm.expectRevert(MissingOrderReference.selector);
        token.seize(alice, custody, 1, bytes32(0));
        vm.expectRevert(ZeroAmount.selector);
        token.seize(alice, custody, 0, ORDER_REF);
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        token.seize(alice, address(0), 1, ORDER_REF);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000e6, 1001e6));
        token.seize(alice, custody, 1001e6, ORDER_REF);

        token.freeze(bob, ORDER_REF);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, bob));
        token.seize(alice, bob, 1, ORDER_REF);
        vm.stopPrank();

        vm.prank(blocklister);
        token.blocklist(carol);
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, carol));
        token.seize(alice, carol, 1, ORDER_REF);
    }

    function test_seize_worksOnBlocklistedAndFrozenAccount() public {
        vm.prank(blocklister);
        token.blocklist(alice);
        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);
        vm.prank(compliance);
        token.seize(alice, custody, 1000e6, ORDER_REF);
        assertEq(token.balanceOf(custody), 1000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Burn frozen
    // ------------------------------------------------------------------------------------------------------------

    function test_burnFrozen_destroysWholeBalance() public {
        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(alice, address(0), 1000e6);
        vm.expectEmit(true, true, false, true);
        emit FrozenFundsBurned(alice, 1000e6, ORDER_REF);
        vm.prank(compliance);
        token.burnFrozen(alice, ORDER_REF);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 1000e6);
    }

    function test_burnFrozen_reverts() public {
        vm.startPrank(compliance);
        vm.expectRevert(abi.encodeWithSelector(AccountNotFrozen.selector, alice));
        token.burnFrozen(alice, ORDER_REF);
        token.freeze(alice, ORDER_REF);
        vm.expectRevert(MissingOrderReference.selector);
        token.burnFrozen(alice, bytes32(0));
        token.burnFrozen(alice, ORDER_REF);
        vm.expectRevert(ZeroAmount.selector);
        token.burnFrozen(alice, ORDER_REF);
        vm.stopPrank();
    }
}
