// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title NoReturnToken
/// @notice Minimal USDT-style token whose `transfer` returns nothing. Used to check that the
///         forwarder's SafeERC20 path handles non-compliant tokens.
contract NoReturnToken {
    /// @notice Balances by holder.
    mapping(address => uint256) public balanceOf;

    /// @notice Emitted on every balance movement.
    /// @param from The sender (zero for mints).
    /// @param to The recipient.
    /// @param value The amount moved.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Mints `amount` to `to`.
    /// @param to The recipient.
    /// @param amount The amount to mint.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Transfers without returning a boolean, like USDT on mainnet.
    /// @param to The recipient.
    /// @param amount The amount to move.
    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }
}
