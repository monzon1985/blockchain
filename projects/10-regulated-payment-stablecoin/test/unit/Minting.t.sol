// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC7802} from "@openzeppelin/contracts/interfaces/draft-IERC7802.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {MintController} from "../../src/modules/MintController.sol";
import {Roles} from "../../src/access/Roles.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice Master minter, minters and bridge: allowances, rolling 24 h limits, the governance ceiling and the
///         reserve gate on every supply increase.
contract MintingTest is StablecoinTestBase {
    // ------------------------------------------------------------------------------------------------------------
    // configureMinter / removeMinter
    // ------------------------------------------------------------------------------------------------------------

    function test_configureMinter_setsAllowanceAndLimit() public {
        address m = makeAddr("m");
        vm.expectEmit(true, false, false, true);
        emit MinterConfigured(m, 123e6, 45e6);
        vm.prank(masterMinter);
        token.configureMinter(m, 123e6, 45e6);
        assertTrue(token.isMinter(m));
        assertEq(token.minterAllowance(m), 123e6);
        assertEq(token.minterDailyLimit(m), 45e6);
        assertEq(token.minterWindowAvailable(m), 45e6);
    }

    function test_configureMinter_setsRatherThanIncrements() public {
        vm.prank(masterMinter);
        token.configureMinter(minter, 7e6, MINTER_DAILY);
        assertEq(token.minterAllowance(minter), 7e6);
    }

    function test_configureMinter_revertsOnZeroAddress() public {
        vm.prank(masterMinter);
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        token.configureMinter(address(0), 1, 1);
    }

    function test_configureMinter_revertsAboveCeiling() public {
        vm.prank(masterMinter);
        vm.expectRevert(abi.encodeWithSelector(DailyLimitAboveCeiling.selector, MINTER_CEILING + 1, MINTER_CEILING));
        token.configureMinter(minter, 1, MINTER_CEILING + 1);
    }

    function test_removeMinter_zeroesEverything() public {
        vm.expectEmit(true, false, false, false);
        emit MinterRemoved(minter);
        vm.prank(masterMinter);
        token.removeMinter(minter);
        assertFalse(token.isMinter(minter));
        assertEq(token.minterAllowance(minter), 0);
        assertEq(token.minterDailyLimit(minter), 0);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterNotConfigured.selector, minter));
        token.mint(alice, 1);
    }

    function test_removeMinter_revertsWhenNotConfigured() public {
        vm.prank(masterMinter);
        vm.expectRevert(abi.encodeWithSelector(MinterNotConfigured.selector, alice));
        token.removeMinter(alice);
    }

    function test_removeAndReconfigure_doesNotResetRollingWindow() public {
        _mint(alice, MINTER_DAILY);
        vm.startPrank(masterMinter);
        token.removeMinter(minter);
        token.configureMinter(minter, MINTER_ALLOWANCE, MINTER_DAILY);
        vm.stopPrank();
        assertEq(token.minterWindowAvailable(minter), 0);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterRateLimitExceeded.selector, minter, 0, 1));
        token.mint(alice, 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // mint
    // ------------------------------------------------------------------------------------------------------------

    function test_mint_happyPath() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, 250e6);
        vm.expectEmit(true, true, false, true);
        emit Mint(minter, alice, 250e6);
        _mint(alice, 250e6);
        assertEq(token.balanceOf(alice), 250e6);
        assertEq(token.totalSupply(), 250e6);
        assertEq(token.minterAllowance(minter), MINTER_ALLOWANCE - 250e6);
        assertEq(token.minterWindowAvailable(minter), MINTER_DAILY - 250e6);
        assertEq(token.mintHeadroom(), INITIAL_RESERVES - 250e6);
    }

    function test_mint_revertsForUnconfiguredRoleHolder() public {
        vm.prank(masterMinter);
        token.removeMinter(minter2);
        vm.prank(minter2);
        vm.expectRevert(abi.encodeWithSelector(MinterNotConfigured.selector, minter2));
        token.mint(alice, 1);
    }

    function test_mint_revertsOnZeroAmount() public {
        vm.prank(minter);
        vm.expectRevert(ZeroAmount.selector);
        token.mint(alice, 0);
    }

    function test_mint_revertsWhenMinterBlocklisted() public {
        vm.prank(blocklister);
        token.blocklist(minter);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, minter));
        token.mint(alice, 1);
    }

    function test_mint_revertsWhenMinterFrozen() public {
        vm.prank(compliance);
        token.freeze(minter, ORDER_REF);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, minter));
        token.mint(alice, 1);
    }

    function test_mint_revertsAboveAllowance() public {
        vm.prank(masterMinter);
        token.configureMinter(minter, 10e6, MINTER_DAILY);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterAllowanceExceeded.selector, minter, 10e6, 10e6 + 1));
        token.mint(alice, 10e6 + 1);
    }

    function test_mint_revertsAboveRollingLimit() public {
        _mint(alice, MINTER_DAILY - 5);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterRateLimitExceeded.selector, minter, 5, 6));
        token.mint(alice, 6);
    }

    function test_mint_rollingWindowSlides() public {
        _mint(alice, 600_000e6);
        vm.warp(block.timestamp + 12 hours);
        _attest(INITIAL_RESERVES);
        _mint(alice, 400_000e6);
        // 24 h after the first mint minus one second: both mints are still inside the window.
        vm.warp(block.timestamp + 12 hours - 1);
        assertEq(token.minterWindowAvailable(minter), 0);
        // Exactly 24 h after the first mint it drops out of the window, the second one does not.
        vm.warp(block.timestamp + 1);
        assertEq(token.minterWindowAvailable(minter), 600_000e6);
        _attest(INITIAL_RESERVES);
        _mint(alice, 600_000e6);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterRateLimitExceeded.selector, minter, 0, 1));
        token.mint(alice, 1);
    }

    function test_mint_limitsArePerMinter() public {
        _mint(alice, MINTER_DAILY);
        vm.prank(minter2);
        token.mint(bob, MINTER_DAILY);
        assertEq(token.totalSupply(), 2 * uint256(MINTER_DAILY));
    }

    function test_mint_revertsAboveAttestedReserves() public {
        _reattest(100e6);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAttestedReserves.selector, 0, 100e6 + 1, 100e6));
        token.mint(alice, 100e6 + 1);
        _mint(alice, 100e6);
        assertEq(token.totalSupply(), 100e6);
    }

    function test_mint_revertsWhenAttestationStale() public {
        uint64 asOf = uint64(block.timestamp);
        vm.warp(block.timestamp + 26 hours);
        _mint(alice, 1); // exactly 26 h old: still fresh
        vm.warp(block.timestamp + 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StaleReserveAttestation.selector, asOf, block.timestamp));
        token.mint(alice, 1);
    }

    function test_mint_revertsToRestrictedOrZero() public {
        vm.prank(blocklister);
        token.blocklist(bob);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, bob));
        token.mint(bob, 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1);
    }

    function test_mint_revertsWhilePaused() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(minter);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.mint(alice, 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // burn
    // ------------------------------------------------------------------------------------------------------------

    function test_burn_happyPath() public {
        _mint(minter, 50e6);
        vm.expectEmit(true, false, false, true);
        emit Burn(minter, 20e6);
        vm.prank(minter);
        token.burn(20e6);
        assertEq(token.balanceOf(minter), 30e6);
        assertEq(token.totalSupply(), 30e6);
        // Burning never restores the allowance.
        assertEq(token.minterAllowance(minter), MINTER_ALLOWANCE - 50e6);
    }

    function test_burn_reverts() public {
        _mint(minter, 50e6);
        vm.prank(minter);
        vm.expectRevert(ZeroAmount.selector);
        token.burn(0);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 50e6, 51e6));
        token.burn(51e6);
        vm.prank(masterMinter);
        token.removeMinter(minter);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterNotConfigured.selector, minter));
        token.burn(1);
    }

    function test_burn_revertsWhenMinterFrozenOrPaused() public {
        _mint(minter, 50e6);
        vm.prank(compliance);
        token.freeze(minter, ORDER_REF);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, minter));
        token.burn(1);
        vm.prank(compliance);
        token.unfreeze(minter, ORDER_REF);
        vm.prank(pauser);
        token.pause();
        vm.prank(minter);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.burn(1);
    }

    function test_burn_worksDuringShortfall() public {
        _mint(minter, 1000e6);
        _reattest(500e6); // shortfall
        vm.prank(minter);
        token.burn(600e6);
        assertEq(token.totalSupply(), 400e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Governance ceiling
    // ------------------------------------------------------------------------------------------------------------

    function test_ceiling_boundsMasterMinter() public {
        _governance(address(token), abi.encodeCall(MintController.setMinterLimitCeiling, (100e6)));
        assertEq(token.minterLimitCeiling(), 100e6);
        // Existing limits are untouched until the minter is reconfigured.
        assertEq(token.minterDailyLimit(minter), MINTER_DAILY);
        vm.prank(masterMinter);
        vm.expectRevert(abi.encodeWithSelector(DailyLimitAboveCeiling.selector, 100e6 + 1, 100e6));
        token.configureMinter(minter, MINTER_ALLOWANCE, 100e6 + 1);
        vm.prank(masterMinter);
        token.configureMinter(minter, MINTER_ALLOWANCE, 100e6);
        assertEq(token.minterDailyLimit(minter), 100e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Bridge (ERC-7802)
    // ------------------------------------------------------------------------------------------------------------

    function test_crosschainMint_happyPath() public {
        vm.expectEmit(true, true, false, true);
        emit IERC7802.CrosschainMint(alice, 70e6, bridge);
        vm.prank(bridge);
        token.crosschainMint(alice, 70e6);
        assertEq(token.balanceOf(alice), 70e6);
        (uint256 mintAvail, uint256 burnAvail) = token.bridgeAvailable(bridge);
        assertEq(mintAvail, BRIDGE_MINT_LIMIT - 70e6);
        assertEq(burnAvail, BRIDGE_BURN_LIMIT);
        // Bridge mints do not touch minter allowances.
        assertEq(token.minterAllowance(minter), MINTER_ALLOWANCE);
    }

    function test_crosschainMint_reverts() public {
        vm.prank(bridge);
        vm.expectRevert(ZeroAmount.selector);
        token.crosschainMint(alice, 0);
        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeMintLimitExceeded.selector, bridge, BRIDGE_MINT_LIMIT, BRIDGE_MINT_LIMIT + 1)
        );
        token.crosschainMint(alice, BRIDGE_MINT_LIMIT + 1);
        _reattest(10e6);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAttestedReserves.selector, 0, 11e6, 10e6));
        token.crosschainMint(alice, 11e6);
        vm.prank(compliance);
        token.freeze(alice, ORDER_REF);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, alice));
        token.crosschainMint(alice, 1);
    }

    function test_crosschainBurn_happyPath() public {
        _mint(alice, 100e6);
        vm.expectEmit(true, true, false, true);
        emit IERC7802.CrosschainBurn(alice, 40e6, bridge);
        vm.prank(bridge);
        token.crosschainBurn(alice, 40e6);
        assertEq(token.balanceOf(alice), 60e6);
        (, uint256 burnAvail) = token.bridgeAvailable(bridge);
        assertEq(burnAvail, BRIDGE_BURN_LIMIT - 40e6);
    }

    function test_crosschainBurn_reverts() public {
        _mint(alice, MINTER_DAILY);
        vm.prank(minter2);
        token.mint(alice, BRIDGE_BURN_LIMIT + 10 - MINTER_DAILY);
        vm.prank(bridge);
        vm.expectRevert(ZeroAmount.selector);
        token.crosschainBurn(alice, 0);
        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(BridgeBurnLimitExceeded.selector, bridge, BRIDGE_BURN_LIMIT, BRIDGE_BURN_LIMIT + 1)
        );
        token.crosschainBurn(alice, BRIDGE_BURN_LIMIT + 1);
        vm.prank(blocklister);
        token.blocklist(alice);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, alice));
        token.crosschainBurn(alice, 1);
    }

    /// A blocklisted or frozen bridge is refused on both entry points, like a restricted minter, and consumes none
    /// of its rolling windows; lifting the restriction restores it.
    function test_crosschain_restrictedBridgeIsRefused() public {
        _mint(alice, 100e6);
        vm.prank(blocklister);
        token.blocklist(bridge);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, bridge));
        token.crosschainMint(alice, 10e6);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(AccountBlocklisted.selector, bridge));
        token.crosschainBurn(alice, 4e6);

        vm.prank(blocklister);
        token.unBlocklist(bridge);
        vm.prank(compliance);
        token.freeze(bridge, ORDER_REF);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, bridge));
        token.crosschainMint(alice, 10e6);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(AccountFrozen.selector, bridge));
        token.crosschainBurn(alice, 4e6);

        assertEq(token.balanceOf(alice), 100e6);
        (uint256 mintAvail, uint256 burnAvail) = token.bridgeAvailable(bridge);
        assertEq(mintAvail, BRIDGE_MINT_LIMIT);
        assertEq(burnAvail, BRIDGE_BURN_LIMIT);

        vm.prank(compliance);
        token.unfreeze(bridge, ORDER_REF);
        vm.prank(bridge);
        token.crosschainMint(alice, 10e6);
        vm.prank(bridge);
        token.crosschainBurn(alice, 4e6);
        assertEq(token.balanceOf(alice), 106e6);
    }

    function test_bridgeLimits_governance() public {
        _governance(address(token), abi.encodeCall(MintController.setBridgeLimits, (5e6, 6e6)));
        (uint256 mintLimit, uint256 burnLimit) = token.bridgeLimits();
        assertEq(mintLimit, 5e6);
        assertEq(burnLimit, 6e6);
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(BridgeMintLimitExceeded.selector, bridge, 5e6, 5e6 + 1));
        token.crosschainMint(alice, 5e6 + 1);
    }

    function test_bridgeLimits_arePerBridge() public {
        address bridge2 = makeAddr("bridge2");
        _governance(address(manager), abi.encodeCall(AccessManager.grantRole, (Roles.BRIDGE, bridge2, 0)));
        _reattest(INITIAL_RESERVES);
        vm.prank(bridge);
        token.crosschainMint(alice, BRIDGE_MINT_LIMIT);
        vm.prank(bridge2);
        token.crosschainMint(alice, BRIDGE_MINT_LIMIT);
        assertEq(token.balanceOf(alice), 2 * uint256(BRIDGE_MINT_LIMIT));
    }
}
