// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AllocatorVault} from "../../src/AllocatorVault.sol";
import {VaultRoles} from "../../src/access/VaultRoles.sol";
import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIlliquidStrategy, MockLiquidStrategy, MockLossyStrategy} from "../mocks/MockStrategies.sol";

/// @notice Shared deployment: an AccessManager, the vault, three listed strategies and the role holders.
/// @dev Override the virtual hooks to change asset decimals, initial fees or the listed strategies.
abstract contract VaultFixture is Test {
    AccessManager internal manager;
    AllocatorVault internal vault;
    MockERC20 internal asset;
    MockLiquidStrategy internal liquid;
    MockLossyStrategy internal lossy;
    MockIlliquidStrategy internal illiquid;

    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant GROWTH_LIMIT = 0.25e18; // 25 % per year

    function _assetDecimals() internal pure virtual returns (uint8) {
        return 18;
    }

    function _initialPerformanceFee() internal pure virtual returns (uint256) {
        return 0;
    }

    function _initialManagementFee() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @dev One whole asset unit, cached so that computing it never consumes a pending `vm.prank`.
    uint256 internal unit;

    function _unit() internal view returns (uint256) {
        return unit;
    }

    /// @dev Whether `setUp` lists the three default strategies (the zero-strategy gas bench turns it off).
    function _listDefaultStrategies() internal pure virtual returns (bool) {
        return true;
    }

    function _cap() internal view virtual returns (uint256) {
        return 1e12 * _unit();
    }

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        asset = new MockERC20("Mock USD", "mUSD", _assetDecimals());
        unit = 10 ** _assetDecimals();
        manager = new AccessManager(admin);
        vault = _deployVault(IERC20(address(asset)));

        vm.startPrank(admin);
        VaultRoles.configure(manager, address(vault));
        manager.grantRole(VaultRoles.CURATOR, curator, 0);
        manager.grantRole(VaultRoles.ALLOCATOR, allocator, 0);
        manager.grantRole(VaultRoles.GUARDIAN, guardian, 0);
        vm.stopPrank();

        liquid = new MockLiquidStrategy(IERC20(address(asset)));
        lossy = new MockLossyStrategy(IERC20(address(asset)));
        illiquid = new MockIlliquidStrategy(IERC20(address(asset)));
        if (_listDefaultStrategies()) {
            _listStrategy(IERC4626(address(liquid)), _cap());
            _listStrategy(IERC4626(address(lossy)), _cap());
            _listStrategy(IERC4626(address(illiquid)), _cap());
        }

        vm.label(address(vault), "vault");
        vm.label(address(asset), "asset");
        vm.label(address(liquid), "liquid");
        vm.label(address(lossy), "lossy");
        vm.label(address(illiquid), "illiquid");
    }

    function _deployVault(IERC20 token) internal returns (AllocatorVault) {
        return new AllocatorVault(
            AllocatorVault.InitParams({
                asset: token,
                name: "Curated USD Vault",
                symbol: "cvUSD",
                authority: address(manager),
                feeRecipient: feeRecipient,
                performanceFee: _initialPerformanceFee(),
                managementFee: _initialManagementFee(),
                maxSharePriceGrowthPerYear: GROWTH_LIMIT
            })
        );
    }

    function _listStrategy(IERC4626 strategy, uint256 cap) internal {
        vm.prank(curator);
        vault.submitCap(strategy, cap);
        vm.warp(block.timestamp + vault.TIMELOCK());
        vault.acceptCap(strategy);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        asset.mint(user, assets);
        vm.startPrank(user);
        asset.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _redeemAll(address user) internal returns (uint256 assets) {
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        assets = vault.redeem(shares, user, user);
    }

    function _allocate(IERC4626 strategy, uint256 target) internal {
        IAllocatorVault.Allocation[] memory allocations = new IAllocatorVault.Allocation[](1);
        allocations[0] = IAllocatorVault.Allocation({strategy: strategy, assets: target});
        vm.prank(allocator);
        vault.reallocate(allocations);
    }

    function _strategyValue(IERC4626 strategy) internal view returns (uint256) {
        return strategy.previewRedeem(strategy.balanceOf(address(vault)));
    }

    function _grossAssets() internal view returns (uint256 gross) {
        gross = asset.balanceOf(address(vault));
        uint256 length = vault.withdrawQueueLength();
        for (uint256 i; i < length; ++i) {
            gross += _strategyValue(vault.withdrawQueue(i));
        }
    }
}
