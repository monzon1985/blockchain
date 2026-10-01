// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MockERC20} from "./MockERC20.sol";

/// @notice Shared base of the in-repo strategies: a plain OpenZeppelin ERC-4626 vault whose yield is simulated by
///         minting the asset into it (what a strategy's own harvest would do).
abstract contract MockStrategyBase is ERC4626 {
    constructor(IERC20 asset_, string memory name_) ERC4626(asset_) ERC20(name_, name_) {}

    /// @notice Realizes `assets` of yield inside the strategy: its share price jumps in this transaction.
    function simulateYield(uint256 assets) external {
        MockERC20(asset()).mint(address(this), assets);
    }
}

/// @notice Fully liquid strategy: everything can be withdrawn at any time.
contract MockLiquidStrategy is MockStrategyBase {
    constructor(IERC20 asset_) MockStrategyBase(asset_, "Mock Liquid Strategy") {}
}

/// @notice Liquid strategy that can suffer a loss (a hack, bad debt, a depeg), recognized in its share price at once.
contract MockLossyStrategy is MockStrategyBase {
    constructor(IERC20 asset_) MockStrategyBase(asset_, "Mock Lossy Strategy") {}

    /// @notice Destroys `assets` held by the strategy.
    function simulateLoss(uint256 assets) external {
        MockERC20(asset()).burn(address(this), assets);
    }
}

/// @notice Strategy that can be paused or broken.
///         - Paused (EIP-4626 compliant): `previewRedeem` and every deposit/withdrawal revert, `maxWithdraw` and
///           `maxRedeem` return 0. EIP-4626 lets `previewRedeem` revert whenever `redeem` would.
///         - Broken (not compliant, but possible): every view the vault uses reverts, `balanceOf` and `max*` included.
///         - Withdrawals blocked (not compliant): views and `max*` answer normally, but withdrawals and redemptions
///           revert, so the strategy reports liquidity it then refuses.
contract MockPausableStrategy is MockStrategyBase {
    error StrategyPaused();

    bool public paused;
    bool public broken;
    bool public withdrawalsBlocked;

    constructor(IERC20 asset_) MockStrategyBase(asset_, "Mock Pausable Strategy") {}

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function setWithdrawalsBlocked(bool blocked) external {
        withdrawalsBlocked = blocked;
    }

    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        if (broken) revert StrategyPaused();
        return super.balanceOf(account);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (paused || broken) revert StrategyPaused();
        return super.previewRedeem(shares);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (broken) revert StrategyPaused();
        return paused ? 0 : super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (broken) revert StrategyPaused();
        return paused ? 0 : super.maxRedeem(owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (paused || broken) revert StrategyPaused();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (paused || broken || withdrawalsBlocked) revert StrategyPaused();
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}

/// @notice Strategy whose `previewRedeem` needs `gasToBurn` gas (think of a meta-vault valuing many markets). Used to
///         show that a caller who under-funds a transaction cannot make the vault count it as a failing strategy.
contract MockGasHeavyStrategy is MockStrategyBase {
    uint256 public gasToBurn;

    constructor(IERC20 asset_) MockStrategyBase(asset_, "Mock Gas-Heavy Strategy") {}

    function setGasToBurn(uint256 gasToBurn_) external {
        gasToBurn = gasToBurn_;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 start = gasleft();
        while (start - gasleft() < gasToBurn) {} // runs out of gas if less than `gasToBurn` is available
        return super.previewRedeem(shares);
    }
}

/// @notice Lending-market-like strategy: assets lent out still count in `totalAssets` but cannot be withdrawn until
///         repaid, so the vault can only withdraw partially.
contract MockIlliquidStrategy is MockStrategyBase {
    /// @notice Assets lent out: valued, but not withdrawable.
    uint256 public lentOut;

    constructor(IERC20 asset_) MockStrategyBase(asset_, "Mock Illiquid Strategy") {}

    /// @notice Lends `assets` of cash out (utilization goes up).
    function lend(uint256 assets) external {
        MockERC20(asset()).burn(address(this), assets);
        lentOut += assets;
    }

    /// @notice Borrowers repay `assets` (utilization goes down).
    function repay(uint256 assets) external {
        lentOut -= assets;
        MockERC20(asset()).mint(address(this), assets);
    }

    /// @notice Cash available for withdrawals.
    function cash() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function totalAssets() public view override returns (uint256) {
        return cash() + lentOut;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(_convertToAssets(balanceOf(owner), Math.Rounding.Floor), cash());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(balanceOf(owner), _convertToShares(cash(), Math.Rounding.Floor));
    }
}
