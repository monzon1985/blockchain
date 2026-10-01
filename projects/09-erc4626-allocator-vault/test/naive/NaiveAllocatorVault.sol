// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title NaiveAllocatorVault
/// @notice DELIBERATELY VULNERABLE, TEST-ONLY. The textbook allocator vault the attack PoCs are run against, so each
///         PoC can show the attack profiting here and losing against `AllocatorVault`. No access control on purpose.
/// @dev Its flaws, one per attack:
///      1. Classic share formula with no virtual shares (`supply == 0 ? assets : assets * supply / totalAssets`):
///         first-depositor donation / inflation attack.
///      2. Strategy values are cached and refreshed only by `harvest()`; profit hits the price the instant it is
///         harvested: harvest sandwich.
///      3. The same cache hides losses until the next `harvest()`: first-mover loss escape.
///      4. Optional (`callerFavoringRounding`): deposit rounds shares up and withdraw rounds shares down: 1-wei
///         rounding extraction. Off by default so the other PoCs run against the standard rounding directions.
contract NaiveAllocatorVault is ERC4626 {
    using Math for uint256;
    using SafeERC20 for IERC20;

    bool public immutable callerFavoringRounding;
    IERC4626[] public strategies;
    mapping(IERC4626 strategy => uint256) public cachedAssets;
    uint256 public totalCached;

    constructor(IERC20 asset_, bool callerFavoringRounding_) ERC4626(asset_) ERC20("Naive Vault", "nV") {
        callerFavoringRounding = callerFavoringRounding_;
    }

    function addStrategy(IERC4626 strategy) external {
        strategies.push(strategy);
    }

    function allocate(IERC4626 strategy, uint256 assets) external {
        IERC20(asset()).forceApprove(address(strategy), assets);
        strategy.deposit(assets, address(this));
        cachedAssets[strategy] += assets;
        totalCached += assets;
    }

    /// @notice Keeper harvest: refreshes cached strategy values. Profit and loss both hit the price instantly.
    function harvest() external {
        uint256 total;
        for (uint256 i; i < strategies.length; ++i) {
            IERC4626 strategy = strategies[i];
            uint256 value = strategy.previewRedeem(strategy.balanceOf(address(this)));
            cachedAssets[strategy] = value;
            total += value;
        }
        totalCached = total;
    }

    /// @dev Flaws 2 and 3: idle balance (donations count at once) plus stale cached strategy values.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalCached;
    }

    /// @dev Flaw 1: no virtual shares.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : assets.mulDiv(supply, totalAssets(), rounding);
    }

    /// @dev Flaw 1: no virtual shares.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : shares.mulDiv(totalAssets(), supply, rounding);
    }

    /// @dev Flaw 4 (optional): shares minted round up.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, callerFavoringRounding ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    /// @dev Flaw 4 (optional): shares burned round down.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, callerFavoringRounding ? Math.Rounding.Floor : Math.Rounding.Ceil);
    }

    /// @dev Pays from idle first, then from strategies, decrementing the (possibly stale) cache by what it took.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);

        IERC20 token = IERC20(asset());
        uint256 idle = token.balanceOf(address(this));
        for (uint256 i; i < strategies.length && idle < assets; ++i) {
            IERC4626 strategy = strategies[i];
            uint256 amount = Math.min(assets - idle, strategy.maxWithdraw(address(this)));
            if (amount == 0) continue;
            strategy.withdraw(amount, address(this), address(this));
            uint256 cached = cachedAssets[strategy];
            uint256 reduction = Math.min(cached, amount);
            cachedAssets[strategy] = cached - reduction;
            totalCached -= reduction;
            idle += amount;
        }
        token.safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}
