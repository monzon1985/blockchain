// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ZkGate} from "../../src/ZkGate.sol";
import {PUBLIC_SIGNALS} from "../../src/interfaces/IVerifiers.sol";

/// @title ZkGateHarness
/// @notice Test-only subclass that exposes the internal public-input validation
///         so it can be fuzzed directly (no proof required).
contract ZkGateHarness is ZkGate {
    constructor(GateConfig memory cfg) ZkGate(cfg) {}

    /// @notice Run the gate's public-input validation (as msg.sender) and revert on any failure.
    /// @param pub The public signals to validate.
    /// @return epoch The epoch the validation bound the scope to.
    function exposedValidate(uint256[PUBLIC_SIGNALS] calldata pub) external view returns (uint256 epoch) {
        epoch = _validatePublicInputs(pub);
    }
}
