// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {IComplianceModule, TransferContext} from "../../interfaces/ICompliance.sol";

/// @title ComplianceModuleBase
/// @notice Shared plumbing for compliance modules: engine binding and AccessManager-governed configuration.
abstract contract ComplianceModuleBase is AccessManaged, IComplianceModule {
    /// @inheritdoc IComplianceModule
    address public immutable engine;

    /// @notice Caller is not the bound engine.
    error NotEngine(address caller);
    /// @notice The engine address is zero.
    error InvalidEngine();

    /// @param initialAuthority AccessManager governing configuration setters.
    /// @param engine_ Compliance engine this module serves.
    constructor(address initialAuthority, address engine_) AccessManaged(initialAuthority) {
        require(engine_ != address(0), InvalidEngine());
        engine = engine_;
    }

    /// @inheritdoc IComplianceModule
    function isStateful() external pure virtual returns (bool) {
        return false;
    }

    /// @inheritdoc IComplianceModule
    /// @dev Stateless modules keep the engine-only guard so that nobody can spoof a callback; the engine never
    ///      calls it for them because `isStateful()` is false.
    function onTransfer(TransferContext calldata ctx) external virtual {
        require(msg.sender == engine, NotEngine(msg.sender));
        _onTransfer(ctx);
    }

    /// @dev Hook for stateful modules.
    function _onTransfer(TransferContext calldata ctx) internal virtual {}
}
