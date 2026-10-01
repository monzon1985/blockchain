// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {FundFixture} from "../utils/FundFixture.sol";

/// @notice Rounding fuzz on epoch settlement: claims are order-independent, partial claims sum exactly to the
///         entitlement, round trips at a constant NAV never profit, and settlement never dilutes the holders
///         that stay in the fund. The NAV is fuzzed over six orders of magnitude (0.001 to 1000 assets per share,
///         reached through `resetNavReference`), because rounding magnitudes scale with it: a deposit loses less
///         than one share (worth `nav / 1e18` asset units), a redemption less than one asset unit.
contract EpochRoundingFuzzTest is FundFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MIN_NAV = 1e15;
    uint256 internal constant MAX_NAV = 1e21;
    address[4] internal investors;

    function setUp() public override {
        super.setUp();
        investors = [alice, bob, carol, dave];
        vm.prank(complianceOfficer);
        lockup.setLockupPeriod(0);
    }

    /// @dev Re-anchors the fund at a fuzzed NAV anywhere in [0.001, 1000] assets per share.
    function _resetToNav(uint256 seed) internal returns (uint128 nav) {
        nav = uint128(bound(seed, MIN_NAV, MAX_NAV));
        vm.warp(block.timestamp + 1);
        vault.resetNavReference(nav, uint64(block.timestamp));
    }

    /// @dev A NAV the circuit breaker accepts right now (per-epoch band and 24 h window).
    function _navNear(uint256 seed) internal view returns (uint128) {
        (uint256 minNav, uint256 maxNav) = vault.navBounds();
        return uint128(bound(seed, minNav, maxNav));
    }

    function _shuffle(uint256 seed) internal pure returns (uint256[4] memory order) {
        order = [uint256(0), 1, 2, 3];
        for (uint256 i = 3; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
    }

    function testFuzz_depositClaimsAreOrderIndependent(uint256[4] memory amounts, uint256 navSeed, uint256 orderSeed)
        public
    {
        uint128 nav = _resetToNav(navSeed);
        for (uint256 i; i < 4; ++i) {
            amounts[i] = bound(amounts[i], 1, 10_000_000 * USDC);
            _requestDeposit(investors[i], amounts[i]);
        }
        _closeAndSettle(nav);
        uint256 epochShares = vault.getEpoch(1).depositShares;

        uint256[4] memory order = _shuffle(orderSeed);
        uint256 minted;
        for (uint256 k; k < 4; ++k) {
            uint256 i = order[k];
            vm.prank(investors[i]);
            uint256 shares = vault.deposit(amounts[i], investors[i], investors[i]);
            assertEq(shares, Math.mulDiv(amounts[i], WAD, nav), "entitlement depends only on own request");
            // Share units: the investor loses less than one share, i.e. assets < (shares + 1) * nav / 1e18.
            assertLt(amounts[i] * WAD, (shares + 1) * nav, "deposit loss below one share");
            minted += shares;
        }
        assertLe(minted, epochShares, "never more than the epoch issued");
        assertLt(epochShares - minted, 4, "dust below one share per request");
        assertEq(vault.totalClaimableDepositShares(), 0, "dust returned to the fund");
    }

    function testFuzz_redeemClaimsAreOrderIndependent(uint256[4] memory amounts, uint256 navSeed, uint256 orderSeed)
        public
    {
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            amounts[i] = bound(amounts[i], 1, 1_000_000 * USDC);
            total += amounts[i];
            _requestDeposit(investors[i], amounts[i]);
        }
        _closeAndSettle(NAV_ONE);
        for (uint256 i; i < 4; ++i) {
            vm.startPrank(investors[i]);
            vault.deposit(amounts[i], investors[i], investors[i]);
            vault.requestRedeem(amounts[i], investors[i], investors[i]);
            vm.stopPrank();
        }
        uint128 nav = _resetToNav(navSeed);
        uint256 need = Math.mulDiv(total, nav, WAD);
        if (need > total) usdc.mint(address(vault), need - total); // gains realised into the vault
        _closeAndSettle(nav);
        uint256 epochAssets = vault.getEpoch(2).redeemAssets;

        uint256[4] memory order = _shuffle(orderSeed);
        uint256 paid;
        for (uint256 k; k < 4; ++k) {
            uint256 i = order[k];
            vm.prank(investors[i]);
            uint256 assets = vault.redeem(amounts[i], investors[i], investors[i]);
            assertEq(assets, Math.mulDiv(amounts[i], nav, WAD), "payout depends only on own request");
            // Asset units: the redeemer loses less than one base unit of the settlement asset.
            assertLt(amounts[i] * nav, (assets + 1) * WAD, "redemption loss below one asset unit");
            paid += assets;
        }
        assertLe(paid, epochAssets, "never more than the epoch reserved");
        assertLt(epochAssets - paid, 4, "dust below one asset unit per request");
        assertEq(vault.totalReservedRedeemAssets(), 0, "dust returned to the fund");
    }

    function testFuzz_partialClaimsSumExactlyToEntitlement(uint256 assets, uint256 navSeed, uint256[6] memory cuts)
        public
    {
        assets = bound(assets, 1, 10_000_000 * USDC);
        uint128 nav = _resetToNav(navSeed);
        _requestDeposit(alice, assets);
        _closeAndSettle(nav);
        uint256 entitlement = vault.maxMint(alice);
        assertEq(entitlement, Math.mulDiv(assets, WAD, nav));

        uint256 assetsUsed;
        uint256 sharesGot;
        vm.startPrank(alice);
        for (uint256 k; k < cuts.length; ++k) {
            uint256 claimableAssets = vault.maxDeposit(alice);
            uint256 claimableShares = vault.maxMint(alice);
            if (claimableAssets == 0 && claimableShares == 0) break;
            if (k % 2 == 0 && claimableAssets != 0) {
                uint256 part = bound(cuts[k], 1, claimableAssets);
                sharesGot += vault.deposit(part, alice, alice);
                assetsUsed += part;
            } else if (claimableShares != 0) {
                uint256 part = bound(cuts[k], 1, claimableShares);
                sharesGot += part;
                assetsUsed += vault.mint(part, alice, alice);
            }
        }
        // Sweep whatever is left.
        if (vault.maxDeposit(alice) != 0) {
            uint256 rest = vault.maxDeposit(alice);
            sharesGot += vault.deposit(rest, alice, alice);
            assetsUsed += rest;
        }
        if (vault.maxMint(alice) != 0) {
            uint256 rest = vault.maxMint(alice);
            sharesGot += rest;
            assetsUsed += vault.mint(rest, alice, alice);
        }
        vm.stopPrank();
        assertEq(sharesGot, entitlement, "all shares, no more, no less");
        assertEq(assetsUsed, assets, "all assets accounted");
        assertEq(share.balanceOf(alice), entitlement);
    }

    function testFuzz_roundTripAtConstantNavNeverProfits(uint256 assets, uint256 navSeed) public {
        assets = bound(assets, 1, 10_000_000 * USDC);
        uint128 nav = _resetToNav(navSeed);

        _requestDeposit(alice, assets);
        _closeAndSettle(nav);
        vm.startPrank(alice);
        uint256 shares = vault.deposit(assets, alice, alice);
        if (shares == 0) return; // entire request was rounding dust (< 1 share): nothing to redeem, nothing gained
        vault.requestRedeem(shares, alice, alice);
        vm.stopPrank();
        _closeAndSettle(nav);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, assets, "rounding always favours the fund");
        // Less than one share (nav / 1e18 asset units) on the way in plus one asset unit on the way out.
        assertLt((assets - out) * WAD, uint256(nav) + WAD, "round-trip loss below one share plus one unit");
    }

    /// @dev Multi-epoch scenario with P&L applied to the custodian so that the fund's backing tracks the NAV,
    ///      starting from a fuzzed NAV and sometimes letting the 24 h NAV window roll between epochs. After every
    ///      settlement and claim the fund's own assets must cover outstanding shares at the NAV: no rounding path
    ///      lets an exiting or entering investor take value from the ones who stay.
    function testFuzz_settlementNeverDilutesRemainingHolders(
        uint256 startNavSeed,
        uint256[5] memory navSeeds,
        uint256[5] memory flows
    ) public {
        _resetToNav(startNavSeed);
        for (uint256 epoch; epoch < 5; ++epoch) {
            // Random subscriptions and redemptions.
            for (uint256 i; i < 4; ++i) {
                uint256 flow = uint256(keccak256(abi.encode(flows[epoch], i)));
                address who = investors[i];
                uint256 held = share.balanceOf(who);
                if (flow % 3 == 0 && held != 0) {
                    vm.prank(who);
                    vault.requestRedeem(bound(flow >> 8, 1, held), who, who);
                } else {
                    _requestDeposit(who, bound(flow >> 8, 1, 5_000_000 * USDC));
                }
            }
            if (navSeeds[epoch] % 2 == 0) vm.warp(block.timestamp + 1 days); // let the NAV window roll
            _close();
            vm.warp(block.timestamp + 1 hours);
            uint128 nav = _navNear(navSeeds[epoch]);
            _applyPnl(nav);
            vm.prank(navOracle);
            vault.postNav(nav, uint64(block.timestamp));
            vm.prank(fundAdmin);
            vault.settleEpoch();
            _assertBacked();
            // Everyone claims everything.
            for (uint256 i; i < 4; ++i) {
                address who = investors[i];
                vm.startPrank(who);
                if (vault.maxDeposit(who) != 0) vault.deposit(vault.maxDeposit(who), who, who);
                if (vault.maxMint(who) != 0) vault.mint(vault.maxMint(who), who, who);
                if (vault.maxRedeem(who) != 0) vault.redeem(vault.maxRedeem(who), who, who);
                if (vault.maxWithdraw(who) != 0) vault.withdraw(vault.maxWithdraw(who), who, who);
                vm.stopPrank();
                _assertBacked();
            }
        }
    }

    function _fundAssets() internal view returns (uint256) {
        return usdc.balanceOf(address(vault)) + usdc.balanceOf(custodian) - vault.totalPendingDepositAssets()
            - vault.totalReservedRedeemAssets();
    }

    function _assertBacked() internal view {
        (uint128 nav,) = vault.referenceNav();
        assertGe(_fundAssets() * WAD, vault.outstandingShares() * nav, "remaining holders diluted");
    }

    /// @dev Moves the fund's assets so that the backing follows `newNav`: gains are rounded up, losses down.
    function _applyPnl(uint128 newNav) internal {
        uint256 idle = vault.idleAssets();
        if (idle != 0) {
            vm.prank(fundAdmin);
            vault.deployToCustodian(idle);
        }
        (uint128 oldNav,) = vault.referenceNav();
        uint256 outstanding = vault.outstandingShares();
        if (newNav > oldNav) {
            usdc.mint(custodian, Math.mulDiv(outstanding, newNav - oldNav, WAD, Math.Rounding.Ceil));
        } else if (newNav < oldNav) {
            usdc.burn(custodian, Math.mulDiv(outstanding, oldNav - newNav, WAD));
        }
        // Recall what the pending redemptions will need.
        uint256 redeemShares = vault.getEpoch(vault.epochAwaitingSettlement()).redeemShares;
        uint256 need = Math.mulDiv(redeemShares, newNav, WAD);
        uint256 recall = Math.min(need, usdc.balanceOf(custodian));
        if (recall != 0) {
            vm.prank(fundAdmin);
            vault.recallFromCustodian(recall);
        }
    }
}
