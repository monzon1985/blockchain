// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {AllocatorVault} from "../src/AllocatorVault.sol";
import {VaultRoles} from "../src/access/VaultRoles.sol";
import {IAllocatorVault} from "../src/interfaces/IAllocatorVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockIlliquidStrategy, MockLiquidStrategy, MockLossyStrategy} from "../test/mocks/MockStrategies.sol";

/// @notice Three-phase local demo on anvil, driven by script/local-demo.sh, which moves the chain's clock between
///         phases with `evm_increaseTime` (real block timestamps, no cheat codes):
///         1. `deploy()`   - asset, AccessManager, vault, three strategies; the sender takes every role for the demo,
///                           submits the three caps (timelocked) and deposits 1,000,000 mUSD.
///         2. `allocate()` - after 3 days: accepts the caps, allocates, lets a strategy harvest 7,000 mUSD of yield.
///         3. `report()`   - after 3.5 more days: half the yield is unlocked; redeems 10 % and prints the state.
contract LocalDemo is Script {
    uint256 internal constant DEPOSIT = 1_000_000e18;
    uint256 internal constant YIELD = 7000e18;
    address internal constant FEE_RECIPIENT = address(0xFEE);

    function deploy() external {
        vm.startBroadcast();
        address me = msg.sender;
        MockERC20 asset = new MockERC20("Mock USD", "mUSD", 18);
        AccessManager manager = new AccessManager(me);
        AllocatorVault vault = new AllocatorVault(
            AllocatorVault.InitParams({
                asset: IERC20(address(asset)),
                name: "Curated USD Vault",
                symbol: "cvUSD",
                authority: address(manager),
                feeRecipient: FEE_RECIPIENT,
                performanceFee: 0.1e18,
                managementFee: 0.01e18,
                maxSharePriceGrowthPerYear: 0.25e18
            })
        );
        VaultRoles.configure(manager, address(vault));
        manager.grantRole(VaultRoles.CURATOR, me, 0);
        manager.grantRole(VaultRoles.ALLOCATOR, me, 0);
        manager.grantRole(VaultRoles.GUARDIAN, me, 0);

        MockLiquidStrategy liquid = new MockLiquidStrategy(IERC20(address(asset)));
        MockLossyStrategy lossy = new MockLossyStrategy(IERC20(address(asset)));
        MockIlliquidStrategy illiquid = new MockIlliquidStrategy(IERC20(address(asset)));
        vault.submitCap(liquid, 500_000e18);
        vault.submitCap(lossy, 300_000e18);
        vault.submitCap(illiquid, 300_000e18);

        asset.mint(me, DEPOSIT);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, me);
        vm.stopBroadcast();

        console2.log("Vault:", address(vault));
        console2.log("Liquid:", address(liquid));
        console2.log("Lossy:", address(lossy));
        console2.log("Illiquid:", address(illiquid));
        console2.log("Caps submitted; acceptable at:", vault.pendingCap(liquid).validAt);
    }

    function allocate(AllocatorVault vault, IERC4626 liquid, IERC4626 lossy, IERC4626 illiquid) external {
        vm.startBroadcast();
        vault.acceptCap(liquid);
        vault.acceptCap(lossy);
        vault.acceptCap(illiquid);
        IAllocatorVault.Allocation[] memory a = new IAllocatorVault.Allocation[](3);
        a[0] = IAllocatorVault.Allocation({strategy: liquid, assets: 400_000e18});
        a[1] = IAllocatorVault.Allocation({strategy: lossy, assets: 300_000e18});
        a[2] = IAllocatorVault.Allocation({strategy: illiquid, assets: 200_000e18});
        vault.reallocate(a);
        MockLiquidStrategy(address(liquid)).simulateYield(YIELD);
        vault.accrue();
        vm.stopBroadcast();

        IAllocatorVault.Accrual memory s = vault.previewAccrual();
        console2.log("Strategies in withdraw queue:", vault.withdrawQueueLength());
        console2.log("Idle assets (mUSD, wei):", IERC20(vault.asset()).balanceOf(address(vault)));
        console2.log("Locked profit (wei):", s.lockedProfit);
        console2.log("Unlock end (timestamp):", s.unlockEnd);
        console2.log("totalAssets right after the harvest (wei):", s.totalAssets);
    }

    /// @notice A demo outcome the README describes did not happen.
    /// @param what Which check.
    /// @param actual The observed value.
    /// @param expected The expected value (or bound).
    error DemoCheckFailed(string what, uint256 actual, uint256 expected);

    function report(AllocatorVault vault) external {
        address me = msg.sender;
        IAllocatorVault.Accrual memory s = vault.previewAccrual();
        uint256 price = vault.sharePrice();
        uint256 safePrice = vault.safeSharePrice();
        console2.log("totalAssets 3.5 days later (wei):", s.totalAssets);
        console2.log("Still locked (wei):", s.lockedProfit);
        console2.log("Share price (RAY):", price);
        console2.log("Safe share price (RAY):", safePrice);

        // What the README says this demo shows, checked rather than only printed:
        // half of the 7,000 mUSD harvest is still locked (within 1 %: block timestamps drift by seconds) ...
        uint256 half = YIELD / 2;
        uint256 off = s.lockedProfit > half ? s.lockedProfit - half : half - s.lockedProfit;
        if (off > half / 100) revert DemoCheckFailed("half of the yield still locked", s.lockedProfit, half);
        // ... the unlocked half lifted the price faster than 25 %/year, so the safe price lags behind it ...
        if (safePrice >= price) revert DemoCheckFailed("safe price lags the share price", safePrice, price);
        // ... and a 10 % redemption pays exactly its preview.
        uint256 shares = vault.balanceOf(me) / 10;
        uint256 expected = vault.previewRedeem(shares);
        vm.startBroadcast();
        uint256 out = vault.redeem(shares, me, me);
        vm.stopBroadcast();
        if (out != expected) revert DemoCheckFailed("redemption pays its preview", out, expected);
        console2.log("Redeemed 10% of the position for (wei):", out);
        console2.log("Fee recipient's shares are worth (wei):", vault.convertToAssets(vault.balanceOf(FEE_RECIPIENT)));
        console2.log("High-water mark (RAY):", vault.highWaterMark());
    }
}
