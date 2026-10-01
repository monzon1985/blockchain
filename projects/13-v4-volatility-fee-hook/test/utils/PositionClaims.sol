// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice What a liquidity position can withdraw right now, computed from PoolManager state alone (price, tick,
/// position liquidity, fee growth), without executing a withdrawal. It mirrors v4-core's Pool.modifyLiquidity for a
/// full removal: principal rounded down from the current tick's side of the range, plus the fees owed since the
/// position's last checkpoint. Used by the solvency invariant, so that the PoolManager's balances are compared
/// against claims that were NOT measured by withdrawing them.
library PositionClaims {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q128 = 1 << 128;

    function claimOf(IPoolManager manager, PoolId id, address owner, int24 lower, int24 upper, bytes32 salt)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        // Position key as in v4-core's Position.calculatePositionKey.
        bytes32 positionId = keccak256(abi.encodePacked(owner, lower, upper, salt));
        (uint128 liquidity,,) = manager.getPositionInfo(id, positionId);
        if (liquidity == 0) return (0, 0);
        (amount0, amount1) = _principal(manager, id, lower, upper, liquidity);
        (uint256 fees0, uint256 fees1) = _fees(manager, id, positionId, lower, upper, liquidity);
        amount0 += fees0;
        amount1 += fees1;
    }

    function _principal(IPoolManager manager, PoolId id, int24 lower, int24 upper, uint128 liquidity)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        // Branch on the tick exactly as Pool.modifyLiquidity does (after a zeroForOne swap that ends on a tick boundary
        // the tick is one below it while the price sits on it, and the tick decides).
        if (tick < lower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (tick < upper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        }
    }

    function _fees(IPoolManager manager, PoolId id, bytes32 positionId, int24 lower, int24 upper, uint128 liquidity)
        private
        view
        returns (uint256 fees0, uint256 fees1)
    {
        (, uint256 last0, uint256 last1) = manager.getPositionInfo(id, positionId);
        (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(id, lower, upper);
        // Fee growth is a wrapping accumulator in v4-core (Position.update subtracts without overflow checks).
        unchecked {
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, Q128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, Q128);
        }
    }
}
