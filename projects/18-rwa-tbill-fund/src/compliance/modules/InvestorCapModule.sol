// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ComplianceModuleBase} from "./ComplianceModuleBase.sol";
import {IComplianceModule, TransferContext} from "../../interfaces/ICompliance.sol";

/// @title InvestorCapModule
/// @notice Concentration limit: the aggregate balance of one investor identity, across all of its wallets,
///         may not exceed `maxPerInvestor` after a credit.
/// @dev Applies to every credit that changes investor ownership (transfers, mints, forced transfers).
///      Recoveries and moves between wallets of the same identity are ownership-neutral and always pass.
contract InvestorCapModule is ComplianceModuleBase {
    /// @notice Maximum aggregate balance per investor; `type(uint256).max` disables the rule.
    uint256 public maxPerInvestor = type(uint256).max;

    /// @notice Emitted when the cap changes.
    /// @param maxPerInvestor New cap.
    event InvestorCapSet(uint256 maxPerInvestor);

    /// @param initialAuthority AccessManager.
    /// @param engine_ Compliance engine.
    constructor(address initialAuthority, address engine_) ComplianceModuleBase(initialAuthority, engine_) {}

    /// @notice Sets the per-investor cap.
    /// @param newCap New cap (share base units).
    function setMaxPerInvestor(uint256 newCap) external restricted {
        maxPerInvestor = newCap;
        emit InvestorCapSet(newCap);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "InvestorCap";
    }

    /// @inheritdoc IComplianceModule
    function check(TransferContext calldata ctx) external view returns (bool) {
        if (ctx.to == address(0) || ctx.amount == 0) return true;
        if (ctx.from != address(0) && ctx.fromId == ctx.toId) return true;
        uint256 cap = maxPerInvestor;
        // Written as a subtraction so that `toInvestorBalance + amount` cannot overflow.
        return ctx.toInvestorBalance <= cap && ctx.amount <= cap - ctx.toInvestorBalance;
    }
}
