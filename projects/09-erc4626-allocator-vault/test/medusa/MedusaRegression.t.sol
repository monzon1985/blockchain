// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {AllocatorVault} from "../../src/AllocatorVault.sol";
import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {AllocatorVaultMedusa} from "./AllocatorVaultMedusa.sol";

/// @notice Replays, call for call, the sequence Medusa shrank in CI when it reported a violation of
///         `property_feeSharesBoundedByHighWaterMarkGain`, against a harness deployed the way `medusa.json` deploys it
///         (deployer 0x30000, no constructor arguments), with each call's sender, block number and timestamp.
///
///         The sequence: the actor deposits; the allocator moves part of it into the illiquid strategy, which lends
///         part of that out; the curator announces the strategy's forced removal (the lent-out part now counts as 0
///         and the vault is impaired); the actor withdraws at the conservative price; borrowers repay most of the loan;
///         the curator executes the removal, which recovers the repaid part, writes off the rest and ends the
///         impairment. Because the exit paid the conservative price, the shares left end above the high-water mark,
///         and the removal's final accrual charges a performance fee on exactly that gain. The harness used to price
///         the gain at the pre-action (impaired) totals, which leave out the PnL the removal realizes, and so reported
///         a correct fee as an overcharge.
contract MedusaRegressionTest is Test {
    uint256 internal constant V = 1e6;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    address internal constant FEE_RECIPIENT = address(0xFEE);

    // `medusa.json`: deployerAddress and senderAddresses.
    address internal constant DEPLOYER = address(0x30000);
    address internal constant SENDER_1 = address(0x10000);
    address internal constant SENDER_2 = address(0x20000);
    address internal constant SENDER_3 = address(0x30000);

    AllocatorVaultMedusa internal harness;
    AllocatorVault internal vault;
    address internal actor;

    function setUp() public {
        vm.recordLogs();
        vm.prank(DEPLOYER);
        harness = new AllocatorVaultMedusa();
        // The harness keeps its contracts internal; find them from the deployment's events.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IAllocatorVault.SetFees.selector) vault = AllocatorVault(logs[i].emitter);
        }
        for (uint256 i; i < logs.length; ++i) {
            // The second holder approves the harness for its vault shares in its constructor.
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == IERC20.Approval.selector) {
                actor = address(uint160(uint256(logs[i].topics[1])));
            }
        }
        assertEq(vault.feeRecipient(), FEE_RECIPIENT, "vault found");
        assertTrue(actor != address(0), "actor found");
    }

    /// @notice The CI sequence keeps every property (and never hits a harness assertion), and its last call really
    ///         charges a performance fee above the high-water mark, so the replay exercises the fixed check.
    function test_ciSequence_keepsEveryProperty() public {
        _replayUntilRepay(true);
        uint256 hwmBefore = vault.highWaterMark();
        uint256 feeSharesBefore = vault.balanceOf(FEE_RECIPIENT);

        _finalRemoval();

        assertGt(vault.balanceOf(FEE_RECIPIENT), feeSharesBefore, "the removal minted fee shares");
        assertGt(vault.highWaterMark(), hwmBefore, "the price ended above the old mark");
        assertEq(address(vault.previewAccrual().impairedStrategy), address(0), "the impairment ended");
    }

    /// @notice The removal's fee, read from its `Accrue` events, is at most the performance fee times the gain above the
    ///         mark at that accrual's own totals (the per-accrual bound of the Foundry handler, I4), and it is charged
    ///         only by the final, unimpaired accrual: the impaired one before the recovery charges nothing.
    function test_ciSequence_removalFeeIsAtMostTheGainAboveTheMark() public {
        _replayUntilRepay(true);
        uint256 supply = vault.totalSupply();
        uint256 hwm = vault.highWaterMark();

        vm.recordLogs();
        _finalRemoval();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 accruals;
        uint256 charged;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != IAllocatorVault.Accrue.selector) continue;
            ++accruals;
            uint256 perfShares;
            (perfShares, hwm) = _checkAccrual(logs[i].data, supply, hwm);
            if (perfShares != 0) ++charged;
            supply += perfShares;
        }
        // The harness's explicit accrual, the removal's own first (impaired, no-op) accrual, and its final accrual.
        assertEq(accruals, 3, "accruals");
        assertEq(charged, 1, "one accrual charged a fee");
    }

    /// @notice Counterfactual: the same sequence without the exit during the impairment. The recovery then only brings
    ///         the price back towards the mark (part of the position is written off), and no performance fee is charged
    ///         (only the management fee for the time since the last accrual). So the performance fee in the CI sequence
    ///         is charged on the stayers' gain from an exit at the conservative price, not on the recovery of the
    ///         deferred markdown.
    function test_ciSequenceWithoutTheExit_recoveryBelowTheMarkChargesNoFee() public {
        _replayUntilRepay(false);
        uint256 hwmBefore = vault.highWaterMark();

        vm.recordLogs();
        _finalRemoval();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != IAllocatorVault.Accrue.selector) continue;
            (,,,,, uint256 perfShares,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(perfShares, 0, "no performance fee on a recovery below the mark");
        }
        assertEq(vault.highWaterMark(), hwmBefore, "mark unchanged");
        assertLt(vault.sharePrice(), hwmBefore, "price still below the mark");
        assertEq(address(vault.previewAccrual().impairedStrategy), address(0), "the impairment ended");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Calls 1-7 of the CI sequence (call 6, the exit, only if `withExit`), checking every property after each.
    function _replayUntilRepay(bool withExit) internal {
        _next(26, 259_226, SENDER_1);
        harness.deposit(254523333349203216032194592372969923295096696557929955194568, true);
        _assertProperties();

        _next(26, 259_226, SENDER_3);
        harness.reallocate(
            50656695323652276348085024560365862814280912402644656377085597577942188896954,
            274686784097056990020945315437625615004027727088153818282829803444657335612
        );
        _assertProperties();

        _next(26, 259_226, SENDER_3);
        harness.lend(11300817967384418648812510376819836022177644877121685470535239989);
        _assertProperties();

        _next(26, 259_226, SENDER_3);
        harness.startRemoval(499103832919466359584357694002965119624774218397692279297420108543102384043);
        _assertProperties();
        assertTrue(address(vault.previewAccrual().impairedStrategy) != address(0), "impaired after the announcement");

        _next(27, 478_858, SENDER_1);
        harness.removeStrategy(862718293348820473494947350804571189340613642615508265799311789463698);
        _assertProperties();

        if (withExit) {
            _next(28, 519_493, SENDER_2);
            harness.withdraw(5986310751108868750024807090627201306449101298819578, true);
            _assertProperties();
        }

        _next(28, 519_493, SENDER_3);
        harness.repay(411376139330301510538742295647125692231650012767168338017019171);
        _assertProperties();
    }

    /// @dev Call 8 of the CI sequence: the forced removal executes after its timelock.
    function _finalRemoval() internal {
        _next(28, 519_493, SENDER_1);
        harness.removeStrategy(115792089237316195423570985008202155920698623752284056713960331916773761933403);
        _assertProperties();
    }

    /// @dev Checks one `Accrue` event against the per-accrual bound, given the supply and mark before that accrual.
    function _checkAccrual(bytes memory data, uint256 supply, uint256 hwm)
        internal
        view
        returns (uint256 perfShares, uint256 newHwm)
    {
        uint256 ta;
        uint256 mgmtShares;
        (, ta,,, mgmtShares, perfShares, newHwm) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(mgmtShares, 0, "no time elapses within the removal");
        uint256 price = Math.mulDiv(ta + 1, RAY, supply + V);
        uint256 gain = price > hwm ? Math.mulDiv(price - hwm, supply, RAY) : 0;
        uint256 perfValue = Math.mulDiv(perfShares, ta + 1, supply + perfShares + V);
        assertLe(perfValue, Math.mulDiv(gain, vault.performanceFee(), WAD), "fee <= rate x gain above the mark");
        if (perfShares != 0) assertGt(gain, 0, "fee only above the mark");
    }

    function _next(uint256 blockNumber, uint256 timestamp, address sender) internal {
        vm.roll(blockNumber);
        vm.warp(timestamp);
        vm.prank(sender);
    }

    function _assertProperties() internal view {
        assertTrue(harness.property_solvency(), "solvency");
        assertTrue(harness.property_totalAssetsBacked(), "backing");
        assertTrue(harness.property_sharePriceMonotoneApartFromLosses(), "price");
        assertTrue(harness.property_feeSharesBoundedByHighWaterMarkGain(), "fees");
        assertTrue(harness.property_highWaterMarkNeverDecreases(), "hwm");
        assertTrue(harness.property_accrualMatchesPreview(), "accrual");
        assertTrue(harness.property_safePriceNeverAboveSharePrice(), "safe price");
    }
}
