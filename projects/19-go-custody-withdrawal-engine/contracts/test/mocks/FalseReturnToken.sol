// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title FalseReturnToken
/// @notice Token whose `transfer` reports failure by returning `false` instead of reverting.
///         SafeERC20 must turn that into a revert so a flush can never silently lose funds.
contract FalseReturnToken {
    /// @notice Balances by holder.
    mapping(address => uint256) public balanceOf;

    /// @notice Mints `amount` to `to`.
    /// @param to The recipient.
    /// @param amount The amount to mint.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Always fails softly.
    /// @return Always false.
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
