// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Number of public signals for the production credential circuit:
// 1 output (nullifier) + 21 inputs (currentDate, issuerRoot, revocationRoot,
// sanctioned[16], appScope, recipient).
uint256 constant PUBLIC_SIGNALS = 22;

/// @title IGroth16Verifier
/// @notice ABI of the snarkjs-generated Groth16 verifier for the credential
///         circuit. `verifyProof` returns true iff the proof is valid for the
///         given public signals. It does NOT revert on an out-of-field signal:
///         the snarkjs template's `checkField` makes it return false instead,
///         which is why ZkGate range-checks every signal itself first (to fail
///         with a precise error).
interface IGroth16Verifier {
    /// @notice Verify a Groth16 proof against the circuit's verification key.
    /// @param a Proof element A (G1).
    /// @param b Proof element B (G2).
    /// @param c Proof element C (G1).
    /// @param pubSignals The 22 public signals in circuit order.
    /// @return ok True iff the proof verifies; false for an invalid proof or an out-of-field signal.
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[PUBLIC_SIGNALS] calldata pubSignals
    ) external view returns (bool ok);
}

/// @title IPlonkVerifier
/// @notice ABI of the snarkjs-generated PLONK verifier for the credential
///         circuit. The proof is a flat 24-word array (9 G1 points, 6 field
///         evaluations). Like the Groth16 verifier it returns false, rather
///         than reverting, for out-of-field inputs.
interface IPlonkVerifier {
    /// @notice Verify a PLONK proof against the circuit's verification key.
    /// @param proof The 24-word PLONK proof.
    /// @param pubSignals The 22 public signals in circuit order.
    /// @return ok True iff the proof verifies; false for an invalid proof or an out-of-field value.
    function verifyProof(uint256[24] calldata proof, uint256[PUBLIC_SIGNALS] calldata pubSignals)
        external
        view
        returns (bool ok);
}
