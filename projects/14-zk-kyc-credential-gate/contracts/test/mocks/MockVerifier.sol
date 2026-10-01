// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IGroth16Verifier, IPlonkVerifier, PUBLIC_SIGNALS} from "../../src/interfaces/IVerifiers.sol";

/// @title MockVerifier
/// @notice A verifier whose result is settable, for exercising the gate's
///         validation and registry logic in fuzz/invariant tests without
///         generating real proofs. It is a test double only.
contract MockVerifier is IGroth16Verifier, IPlonkVerifier {
    /// @notice The value `verifyProof` returns.
    bool public result = true;

    /// @notice Set the result the verifier returns.
    /// @param value The new result.
    function setResult(bool value) external {
        result = value;
    }

    /// @inheritdoc IGroth16Verifier
    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[PUBLIC_SIGNALS] calldata
    ) external view returns (bool) {
        return result;
    }

    /// @inheritdoc IPlonkVerifier
    function verifyProof(uint256[24] calldata, uint256[PUBLIC_SIGNALS] calldata) external view returns (bool) {
        return result;
    }
}
