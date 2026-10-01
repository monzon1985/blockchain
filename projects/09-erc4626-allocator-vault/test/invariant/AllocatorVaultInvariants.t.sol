// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockPausableStrategy} from "../mocks/MockStrategies.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @notice Stateful invariants (see the README's "Invariants" section, I1-I9). Fees are on, so every action runs
///         through the fee path; a fourth, pausable strategy and the removal actions put the vault through impaired
///         states; the handler latches violations of the per-action properties.
contract AllocatorVaultInvariantTest is VaultFixture {
    VaultHandler internal handler;
    MockPausableStrategy internal pausable;

    function _initialPerformanceFee() internal pure override returns (uint256) {
        return 0.2e18;
    }

    function _initialManagementFee() internal pure override returns (uint256) {
        return 0.02e18;
    }

    function setUp() public override {
        super.setUp();
        pausable = new MockPausableStrategy(IERC20(address(asset)));
        _listStrategy(pausable, _cap());
        handler = new VaultHandler(
            vault,
            asset,
            liquid,
            lossy,
            illiquid,
            pausable,
            VaultHandler.Roles({curator: curator, allocator: allocator, guardian: guardian, feeRecipient: feeRecipient})
        );

        bytes4[] memory selectors = new bytes4[](23);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.mint.selector;
        selectors[2] = VaultHandler.withdraw.selector;
        selectors[3] = VaultHandler.redeem.selector;
        selectors[4] = VaultHandler.reallocate.selector;
        selectors[5] = VaultHandler.reallocate.selector; // allocation moves are weighted up
        selectors[6] = VaultHandler.strategyYield.selector;
        selectors[7] = VaultHandler.strategyLoss.selector;
        selectors[8] = VaultHandler.donate.selector;
        selectors[9] = VaultHandler.lend.selector;
        selectors[10] = VaultHandler.repay.selector;
        selectors[11] = VaultHandler.accrue.selector;
        selectors[12] = VaultHandler.warp.selector;
        selectors[13] = VaultHandler.warp.selector; // timelocks need time to pass
        selectors[14] = VaultHandler.setPaused.selector;
        selectors[15] = VaultHandler.startRemoval.selector;
        selectors[16] = VaultHandler.revokeRemoval.selector;
        selectors[17] = VaultHandler.removeStrategy.selector;
        selectors[18] = VaultHandler.removeStrategy.selector; // removals wait out a timelock: weighted up
        selectors[19] = VaultHandler.submitRelist.selector;
        selectors[20] = VaultHandler.acceptRelist.selector;
        selectors[21] = VaultHandler.startRemoval.selector; // forced removals (and their write-offs) weighted up
        selectors[22] = VaultHandler.acceptRelist.selector; // re-listing brings removed strategies back
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice I1 - Solvency: the assets all holders could redeem (rounding down) never exceed `totalAssets`.
    function invariant_I1_sumOfRedeemableAssetsWithinTotalAssets() public view {
        uint256 sum = vault.convertToAssets(vault.balanceOf(feeRecipient));
        for (uint256 i; i < handler.actorsLength(); ++i) {
            sum += vault.convertToAssets(vault.balanceOf(handler.actors(i)));
        }
        assertLe(sum, vault.totalAssets());
    }

    /// @notice I2 - Backing: the gross assets the vault counts never exceed idle plus each strategy's own valuation of
    ///         the vault's shares (`convertToAssets`, read from the strategy, not through the vault's valuation code);
    ///         `totalAssets` never exceeds them; and the locked profit is part of the booked value, which is what
    ///         makes the impaired price `min(gross, booked - locked)` well defined. The last two lines restate the
    ///         accounting identity and only check internal consistency.
    function invariant_I2_totalAssetsBackedByRealAssets() public view {
        IAllocatorVault.Accrual memory a = vault.previewAccrual();
        uint256 strategyOwnValuation = asset.balanceOf(address(vault));
        for (uint256 i; i < vault.withdrawQueueLength(); ++i) {
            IERC4626 strategy = vault.withdrawQueue(i);
            strategyOwnValuation += strategy.convertToAssets(strategy.balanceOf(address(vault)));
        }
        assertLe(a.grossAssets, strategyOwnValuation, "counted value never above the strategies' own valuation");
        assertLe(a.totalAssets, a.grossAssets);

        bool impaired = address(a.impairedStrategy) != address(0);
        uint256 booked = impaired ? vault.lastTotalAssets() : a.grossAssets;
        assertLe(a.lockedProfit, booked, "locked profit is part of the booked value");
        if (impaired) assertLe(a.totalAssets + a.lockedProfit, booked);
        else assertEq(a.totalAssets + a.lockedProfit, a.grossAssets);
    }

    /// @notice I3 - The share price never decreases except through a loss (or, over time, the management fee).
    function invariant_I3_sharePriceMonotoneApartFromLossesAndFees() public view {
        assertFalse(handler.priceDroppedWithoutLoss(), "price fell on a non-loss action");
        assertFalse(handler.priceDroppedMoreThanFees(), "price fell by more than the management fee over time");
    }

    /// @notice I4 - Fee shares are bounded by the high-water-mark gain (performance) and by rate x time
    ///         (management), and every fee share minted is accounted for in an `Accrue` event.
    function invariant_I4_feeSharesBoundedByHighWaterMarkGain() public view {
        assertFalse(handler.feeAboveBound());
        assertFalse(handler.feeSharesMismatch());
    }

    /// @notice I5 - The high-water mark never decreases and is never below the initial price.
    function invariant_I5_highWaterMarkNeverDecreases() public view {
        assertFalse(handler.highWaterMarkDecreased());
        assertGe(vault.highWaterMark(), 1e21);
    }

    /// @notice I6 - Views and execution agree: an accrual writes exactly what `previewAccrual` predicted.
    function invariant_I6_accrualMatchesPreview() public view {
        assertFalse(handler.accrualMismatch());
    }

    /// @notice I7 - No profit is scheduled to unlock more than one unlock period into the future.
    function invariant_I7_unlockScheduleBounded() public view {
        IAllocatorVault.Accrual memory a = vault.previewAccrual();
        if (a.lockedProfit != 0) assertLe(a.unlockEnd, block.timestamp + vault.PROFIT_UNLOCK_PERIOD());
    }

    /// @notice I8 - The collateral-grade price is never above the share price.
    function invariant_I8_safePriceNeverAboveSharePrice() public view {
        assertLe(vault.safeSharePrice(), vault.sharePrice());
    }

    /// @notice I9 - Every actor's `maxWithdraw` and `maxRedeem` actually execute, and `maxWithdraw` is covered by the
    ///         liquidity summed independently here (idle plus each listed strategy's own `maxWithdraw`).
    function invariant_I9_maxWithdrawAndMaxRedeemExecute() public {
        uint256 liquidity = asset.balanceOf(address(vault));
        for (uint256 i; i < vault.withdrawQueueLength(); ++i) {
            liquidity += vault.withdrawQueue(i).maxWithdraw(address(vault));
        }
        for (uint256 i; i < handler.actorsLength(); ++i) {
            address actor = handler.actors(i);
            uint256 maxAssets = vault.maxWithdraw(actor);
            assertLe(maxAssets, liquidity, "covered by liquidity");
            assertLe(maxAssets, vault.convertToAssets(vault.balanceOf(actor)), "never above the holder's assets");

            uint256 snapshot = vm.snapshotState();
            vm.prank(actor);
            vault.withdraw(maxAssets, actor, actor);
            vm.revertToState(snapshot);

            uint256 maxShares = vault.maxRedeem(actor);
            vm.prank(actor);
            vault.redeem(maxShares, actor, actor);
            vm.revertToStateAndDelete(snapshot);
        }
    }

    /// @notice Every run ends with a deterministic probe that, from the run's final state, ends any impairment,
    ///         charges a day of fees and realizes a loss through the checked handler actions, then re-checks the
    ///         per-action properties. So each run exercises the fee and loss checks at least once.
    function afterInvariant() external {
        handler.probeFeesAndLoss();
        assertGt(handler.feeAccruals(), 0, "fee path exercised");
        assertGt(handler.lossActions(), 0, "loss path exercised");
        assertFalse(handler.priceDroppedWithoutLoss());
        assertFalse(handler.priceDroppedMoreThanFees());
        assertFalse(handler.feeAboveBound());
        assertFalse(handler.feeSharesMismatch());
        assertFalse(handler.highWaterMarkDecreased());
        assertFalse(handler.accrualMismatch());
    }
}
