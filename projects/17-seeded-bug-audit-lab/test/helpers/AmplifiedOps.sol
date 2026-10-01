// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { IAmplifiedOperation } from "./PrecisionAmplifier.sol";

/// @notice Amplified operation: withdraw `amount` wei from the vault. The fair value of a step
///         is the value of the shares it burned at the pre-step share price, so `paid - fair`
///         is exactly the value extracted by rounding (floored to whole wei).
contract VaultWithdrawOp is IAmplifiedOperation {
    /// @notice Vault under test.
    KestrelVault public immutable vault;

    /// @param _vault Vault under test.
    constructor(KestrelVault _vault) {
        vault = _vault;
    }

    /// @notice Deposit `msg.value` so the operation holds shares to withdraw against.
    function fund() external payable {
        vault.deposit{ value: msg.value }(address(this), 0);
    }

    /// @inheritdoc IAmplifiedOperation
    function step(uint256 amount) external returns (uint256 paid, uint256 fair) {
        uint256 supply = vault.totalSupply();
        uint256 managed = vault.totalManaged();
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        vault.withdraw(amount, address(this));
        uint256 burned = sharesBefore - vault.balanceOf(address(this));
        paid = address(this).balance - ethBefore;
        // Exact comparison: the step is fair iff paid / burned <= managed / supply.
        uint256 lhs = paid * supply;
        uint256 rhs = burned * managed;
        fair = lhs > rhs ? paid - (lhs - rhs) / supply : paid;
    }

    /// @notice Accept ETH from the vault.
    receive() external payable { }
}

/// @notice Amplified operation: one single-step {KestrelPool.batchSwap}. The fair value of a
///         step is the pool's own single-swap quote for the same input at the same reserves.
contract PoolBatchOp is IAmplifiedOperation {
    /// @notice Pool under test.
    KestrelPool public immutable pool;
    /// @notice Token sold.
    address public immutable tokenIn;
    /// @notice Token bought.
    address public immutable tokenOut;

    /// @param _pool Pool under test.
    /// @param _tokenIn Token sold each step (the operation must hold it).
    /// @param _tokenOut Token bought each step.
    constructor(KestrelPool _pool, address _tokenIn, address _tokenOut) {
        pool = _pool;
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        IERC20(_tokenIn).approve(address(_pool), type(uint256).max);
    }

    /// @inheritdoc IAmplifiedOperation
    function step(uint256 amount) external returns (uint256 paid, uint256 fair) {
        fair = pool.getAmountOut(tokenIn, amount);
        address[] memory assets = new address[](2);
        assets[0] = tokenIn;
        assets[1] = tokenOut;
        KestrelPool.BatchStep[] memory steps = new KestrelPool.BatchStep[](1);
        steps[0] = KestrelPool.BatchStep({ assetInIndex: 0, assetOutIndex: 1, amountIn: amount });
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        pool.batchSwap(assets, steps, address(this));
        paid = IERC20(tokenOut).balanceOf(address(this)) - before;
    }
}
