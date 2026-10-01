// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/console2.sol";
import {FundFixture} from "../utils/FundFixture.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @notice Fund and vault handler shared by the vault invariant campaign and its smoke test.
abstract contract VaultHandlerSetup is FundFixture {
    uint256 internal constant WAD = 1e18;
    VaultHandler internal handler;

    /// @dev Every success counter the handler keeps.
    string[14] internal PATHS = [
        "requestDeposit",
        "requestRedeem",
        "requestForOther",
        "deposit",
        "mint",
        "redeem",
        "withdraw",
        "viaOperator",
        "otherReceiver",
        "closeEpoch",
        "settle",
        "deployIdle",
        "recall",
        "warp"
    ];

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(complianceOfficer);
        lockup.setLockupPeriod(0);
        vm.stopPrank();

        address[] memory actors = new address[](5);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        actors[4] = erin;
        handler = new VaultHandler(f, usdc, fundAdmin, navOracle, custodian, actors);
        handler.bootstrap();

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = VaultHandler.requestDeposit.selector;
        selectors[1] = VaultHandler.requestRedeem.selector;
        selectors[2] = VaultHandler.claimDeposit.selector;
        selectors[3] = VaultHandler.claimRedeem.selector;
        selectors[4] = VaultHandler.closeEpoch.selector;
        selectors[5] = VaultHandler.settle.selector;
        selectors[6] = VaultHandler.deployIdle.selector;
        selectors[7] = VaultHandler.recall.selector;
        selectors[8] = VaultHandler.warp.selector;
        selectors[9] = VaultHandler.settle.selector; // settlements weighted x2
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _calls(string memory path) internal view returns (uint256) {
        return handler.calls(keccak256(bytes(path)));
    }
}

/// @notice Stateful invariants of the ERC-7540 vault: solvency, request bookkeeping, asset conservation across
///         epochs, bounded rounding, and no dilution of remaining holders by settlement rounding.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: ci.invariant.fail-on-revert = true
contract VaultInvariantsTest is VaultHandlerSetup {
    /// @notice V-1 Σ pending deposit requests + Σ settled-but-unpaid redemptions <= vault assets.
    function invariant_pendingAndReservedAreBacked() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.totalPendingDepositAssets() + vault.totalReservedRedeemAssets());
    }

    /// @notice V-2 Request bookkeeping is exact: the global pending totals equal the sum of every controller's
    ///         pending requests, and the global claimable totals cover every controller's claimable balance.
    function invariant_requestBookkeeping() public view {
        uint256 pendingAssets;
        uint256 pendingShares;
        uint256 claimableShares;
        uint256 claimableAssets;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            pendingAssets += vault.pendingDepositRequest(0, actor);
            pendingShares += vault.pendingRedeemRequest(0, actor);
            claimableShares += vault.maxMint(actor);
            claimableAssets += vault.maxWithdraw(actor);
        }
        assertEq(vault.totalPendingDepositAssets(), pendingAssets);
        assertEq(vault.totalPendingRedeemShares(), pendingShares);
        assertGe(vault.totalClaimableDepositShares(), claimableShares);
        assertGe(vault.totalReservedRedeemAssets(), claimableAssets);
    }

    /// @notice V-3 Assets are conserved across epochs: the vault balance equals every asset that came in
    ///         (deposit requests, custodian recalls) minus every asset that went out (redemption payouts,
    ///         custodian deployments). Nothing is created or lost by settlement.
    function invariant_assetConservation() public view {
        assertEq(
            usdc.balanceOf(address(vault)),
            handler.gDeposited() + handler.gRecalled() - handler.gPaidOut() - handler.gDeployed()
        );
    }

    /// @notice V-4 Rounding is bounded and one-directional: summed over all epochs, shares issued minus shares
    ///         minted by claims minus shares still claimable is the dust returned to the fund, at most one base
    ///         unit per deposit request; symmetrically for redemption assets.
    function invariant_roundingDustBounded() public view {
        uint256 issued;
        uint256 reserved;
        uint256 lastEpoch = vault.currentEpoch();
        for (uint256 e = 1; e < lastEpoch; ++e) {
            issued += vault.getEpoch(e).depositShares;
            reserved += vault.getEpoch(e).redeemAssets;
        }
        uint256 depositDust = issued - handler.gMintedByClaims() - vault.totalClaimableDepositShares();
        assertLe(depositDust, handler.gDepositRequests());
        uint256 redeemDust = reserved - handler.gPaidOut() - vault.totalReservedRedeemAssets();
        assertLe(redeemDust, handler.gRedeemRequests());
    }

    /// @notice V-5 Settlement never dilutes the holders who stay: with fund P&L tracking the NAV, the fund's
    ///         own assets always cover outstanding shares at the reference NAV.
    function invariant_remainingHoldersNotDiluted() public view {
        uint256 fundAssets = usdc.balanceOf(address(vault)) + usdc.balanceOf(custodian)
            - vault.totalPendingDepositAssets() - vault.totalReservedRedeemAssets();
        (uint128 nav,) = vault.referenceNav();
        assertGe(fundAssets * WAD, vault.outstandingShares() * nav);
    }

    /// @notice V-6 Share conservation: every share minted by a claim is either still held, burned in a
    ///         pending redemption request, or burned in a redemption settled at some epoch. No other path mints.
    function invariant_shareConservation() public view {
        uint256 redeemedAtSettlement;
        uint256 lastEpoch = vault.currentEpoch();
        for (uint256 e = 1; e < lastEpoch; ++e) {
            if (vault.getEpoch(e).settledAt != 0) redeemedAtSettlement += vault.getEpoch(e).redeemShares;
        }
        assertEq(
            share.totalSupply() + vault.totalPendingRedeemShares() + redeemedAtSettlement, handler.gMintedByClaims()
        );
    }

    function afterInvariant() external view {
        for (uint256 i; i < PATHS.length; ++i) {
            console2.log(PATHS[i], _calls(PATHS[i]));
        }
    }
}

/// @notice Guards the vault handler itself: every action succeeds when driven with inputs known to be valid,
///         including requests booked for another controller and claims by an operator to another receiver.
contract VaultHandlerSmokeTest is VaultHandlerSetup {
    function _expectSuccess(string memory path, bytes memory action) internal {
        uint256 before = _calls(path);
        (bool ok, bytes memory ret) = address(handler).call(action);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        assertEq(_calls(path), before + 1, path);
    }

    function test_everyHandlerPathSucceeds() public {
        // Actor indexes: 0 alice, 1 bob, 2 carol, 3 dave, 4 erin. Odd `viaSeed` = an approved operator claims.
        _expectSuccess("requestForOther", abi.encodeCall(handler.requestDeposit, (0, 1, 1000 * USDC)));
        _expectSuccess("requestForOther", abi.encodeCall(handler.requestRedeem, (2, 3, 500 * USDC)));
        _expectSuccess("closeEpoch", abi.encodeCall(handler.closeEpoch, ()));
        _expectSuccess("settle", abi.encodeCall(handler.settle, (1.01e18)));
        _expectSuccess("viaOperator", abi.encodeCall(handler.claimDeposit, (1, 400 * USDC, false, 1, 4)));
        _expectSuccess("otherReceiver", abi.encodeCall(handler.claimDeposit, (1, 1, true, 3, 2)));
        _expectSuccess("viaOperator", abi.encodeCall(handler.claimRedeem, (3, 100 * USDC, false, 5, 0)));
        _expectSuccess("otherReceiver", abi.encodeCall(handler.claimRedeem, (3, 1, true, 0, 4)));
        _expectSuccess("deployIdle", abi.encodeCall(handler.deployIdle, ()));
        _expectSuccess("recall", abi.encodeCall(handler.recall, (1)));
        _expectSuccess("warp", abi.encodeCall(handler.warp, (1)));
        for (uint256 i; i < PATHS.length; ++i) {
            assertGt(_calls(PATHS[i]), 0, PATHS[i]);
        }
    }
}
