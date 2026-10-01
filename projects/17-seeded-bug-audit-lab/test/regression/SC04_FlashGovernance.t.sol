// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { BaseTest } from "../BaseTest.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";
import { FlashGovAttacker } from "../attacks/FlashGovAttacker.sol";
import { BorrowedStakeAttacker } from "../attacks/BorrowedStakeAttacker.sol";

/// @notice SC04 regression (fixed profile): emergency support is measured from checkpoints
///         {EMERGENCY_LOOKBACK} blocks in the past, so stake held for one transaction (flash
///         mint) or one block (an ordinary loan) carries zero weight.
contract SC04FlashGovernanceRegression is BaseTest {
    uint256 internal constant TREASURY = 100_000e18;
    uint256 internal constant REQUIRED = GOV_SUPPLY * EMERGENCY_QUORUM_BPS / 10_000;

    function setUp() public override {
        super.setUp();
        gov.transfer(address(governor), TREASURY);
        vm.roll(block.number + 1);
    }

    function test_regression_flashLoanHasNoPastVotes() public {
        FlashGovAttacker atk = new FlashGovAttacker(gov, governor);

        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.InsufficientSupport.selector, 0, REQUIRED));
        atk.attack(700_000e18, TREASURY);

        assertEq(gov.balanceOf(address(governor)), TREASURY, "treasury intact");
    }

    function test_regression_oneBlockBorrowedStakeHasNoWeight() public {
        BorrowedStakeAttacker atk = new BorrowedStakeAttacker(gov, governor);
        uint256 stake = 700_000e18;
        gov.transfer(address(atk), stake);
        atk.delegateSelf();
        vm.roll(block.number + 1);

        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.InsufficientSupport.selector, 0, REQUIRED));
        atk.drain(TREASURY, deployer, stake);

        assertEq(gov.balanceOf(address(governor)), TREASURY, "treasury intact");
    }

    /// @dev Stake held for less than the lookback still has no weight; held longer, it counts.
    function test_regression_stakeMustBeHeldForTheLookback() public {
        BorrowedStakeAttacker atk = new BorrowedStakeAttacker(gov, governor);
        uint256 stake = 700_000e18;
        gov.transfer(address(atk), stake);
        atk.delegateSelf();

        vm.roll(block.number + EMERGENCY_LOOKBACK - 1);
        vm.expectRevert(abi.encodeWithSelector(KestrelGovernor.InsufficientSupport.selector, 0, REQUIRED));
        atk.drain(TREASURY, deployer, stake);

        // A genuine supermajority stakeholder of `EMERGENCY_LOOKBACK` blocks may act.
        vm.roll(block.number + 2);
        atk.drain(TREASURY, deployer, stake);
        assertEq(gov.balanceOf(address(atk)), TREASURY, "long-held stake passes the emergency quorum");
    }
}
