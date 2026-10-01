// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin-contracts/utils/Address.sol";

/// @title DepositForwarder
/// @notice Logic contract behind every per-user deposit address. Each user gets an ERC-1167
///         minimal-proxy clone of this contract, deployed with CREATE2 by {ForwarderFactory}.
///         Customers send ERC-20 deposits to the clone's (counterfactual) address; the custody
///         engine later deploys the clone and flushes its whole balance to the hot wallet.
/// @dev Clones `delegatecall` into this contract, so the two immutables below live in the
///      implementation's runtime code and are shared by every clone at zero storage cost. The
///      contract has no storage at all: there is nothing to initialise, nothing to front-run and a
///      forwarder can be flushed any number of times. Funds can only ever move to `DESTINATION`.
contract DepositForwarder {
    using SafeERC20 for IERC20;

    /// @notice The factory that deployed this implementation. It is the only address allowed to
    ///         trigger a flush, which keeps every hot-wallet inflow attributable to a factory call.
    address public immutable FACTORY;

    /// @notice The hot wallet that receives every flushed balance. It cannot be changed: rotating
    ///         the hot wallet requires a new factory and therefore new deposit addresses.
    address payable public immutable DESTINATION;

    /// @notice Emitted when a forwarder moves a non-zero balance to `DESTINATION`.
    /// @param token The ERC-20 token that was flushed, or `address(0)` for the native currency.
    /// @param amount The amount transferred, in the token's smallest unit.
    event Flushed(address indexed token, uint256 amount);

    /// @notice The destination passed to the constructor was the zero address.
    error ZeroDestination();

    /// @notice A flush was attempted by someone other than the factory.
    /// @param caller The address that attempted the call.
    /// @param factory The only address allowed to make it.
    error UnauthorizedCaller(address caller, address factory);

    /// @notice Restricts a function to calls coming from {FACTORY}.
    modifier onlyFactory() {
        require(msg.sender == FACTORY, UnauthorizedCaller(msg.sender, FACTORY));
        _;
    }

    /// @notice Deploys the shared implementation. Called once, by the factory's constructor.
    /// @param destination The hot wallet that will receive every flushed balance.
    constructor(address payable destination) {
        require(destination != address(0), ZeroDestination());
        FACTORY = msg.sender;
        DESTINATION = destination;
    }

    /// @notice Moves this forwarder's entire balance of `token` to {DESTINATION}.
    /// @dev Uses SafeERC20 so tokens that return no value (USDT-style) and tokens that return
    ///      `false` are both handled. A zero balance is a no-op and emits nothing.
    /// @param token The ERC-20 token to flush.
    /// @return amount The amount transferred.
    function flush(IERC20 token) external onlyFactory returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount != 0) {
            token.safeTransfer(DESTINATION, amount);
            // Emitted after the transfer so the log reflects a transfer that succeeded. Only the
            // factory can call flush, so a reentrant token cannot drive a second, forged flush.
            // forge-lint: disable-next-line(reentrancy-events)
            emit Flushed(address(token), amount);
        }
    }

    /// @notice Moves this forwarder's native balance to {DESTINATION}.
    /// @dev Deployed forwarders reject plain ETH transfers (there is no `receive`), but ETH sent to
    ///      the counterfactual address before deployment, or forced in by SELFDESTRUCT, would
    ///      otherwise be stranded. This is the recovery path for it.
    /// @return amount The amount transferred, in wei.
    function flushNative() external onlyFactory returns (uint256 amount) {
        amount = address(this).balance;
        if (amount != 0) {
            Address.sendValue(DESTINATION, amount);
            // Same justification as flush: the recipient is the immutable hot wallet.
            // forge-lint: disable-next-line(reentrancy-events)
            emit Flushed(address(0), amount);
        }
    }
}
