// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title SchnorrSecp256k1
/// @notice Verifies secp256k1 Schnorr signatures produced by the
///         FROST(secp256k1, KECCAK-256) ciphersuite (crates/frost-keccak) with a
///         single call to the `ecrecover` precompile.
/// @dev Signature scheme (all arithmetic modulo the group order `Q`):
///
///          e = keccak256(abi.encodePacked(address(R), pkYParity, pkX, msgHash)) mod Q
///          z·G = R + e·P
///
///      `ecrecover(h, v, r, s)` returns `address(r⁻¹·(s·R' − h·G))` where `R'` has
///      x-coordinate `r` and parity `v − 27`. Choosing `r = P.x`, `v = 27 + parity(P)`,
///      `s = −e·P.x` and `h = −z·P.x` makes the precompile compute `z·G − e·P`, which is
///      `R` exactly when the signature is valid. The signature therefore only needs to
///      carry `address(R)` (20 bytes) and `z` (32 bytes).
///
///      The construction follows the Chainlink `SchnorrSECP256K1` verifier and
///      Vitalik Buterin's ecrecover-based ecmul observation (see README, References),
///      adapted to the FROST addition convention `z = k + e·x`.
library SchnorrSecp256k1 {
    /// @notice Order of the secp256k1 group.
    uint256 internal constant Q =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice A FROST aggregate signature in EVM form.
    /// @param rAddr Ethereum address of the nonce commitment `R`.
    /// @param z Response scalar, `0 < z < Q`.
    struct Signature {
        address rAddr;
        uint256 z;
    }

    /// @notice Returns true iff `pkX` can be used with the ecrecover trick,
    ///         i.e. it is a valid ECDSA `r` value (`0 < pkX < Q`).
    /// @dev On-curve membership is not checked here; the vault instead requires a
    ///      signature by the new key (proof of possession) before storing it.
    /// @param pkX x-coordinate of the group public key.
    /// @return True if `pkX` is in `[1, Q-1]`.
    function isValidKeyX(uint256 pkX) internal pure returns (bool) {
        return pkX != 0 && pkX < Q;
    }

    /// @notice Computes the Schnorr challenge `e`.
    /// @param rAddr Address of the nonce commitment `R`.
    /// @param pkYParity 0 if the group key has even y, 1 if odd.
    /// @param pkX x-coordinate of the group key.
    /// @param msgHash The signed 32-byte message (an EIP-712 digest in the vault).
    /// @return e The challenge scalar, reduced modulo `Q`.
    function challenge(address rAddr, uint8 pkYParity, uint256 pkX, bytes32 msgHash)
        internal
        pure
        returns (uint256 e)
    {
        e = uint256(keccak256(abi.encodePacked(rAddr, pkYParity, pkX, msgHash))) % Q;
    }

    /// @notice Verifies a Schnorr signature over `msgHash` under the key `(pkX, pkYParity)`.
    /// @dev Never reverts; malformed inputs return false. Rejects `z == 0`, `z >= Q`
    ///      (non-canonical encodings), `rAddr == 0` (ecrecover's failure value),
    ///      `pkX` outside `[1, Q-1]` and parities other than 0 or 1.
    /// @param pkX x-coordinate of the group key.
    /// @param pkYParity y-parity of the group key.
    /// @param msgHash The signed message.
    /// @param sig The signature `(address(R), z)`.
    /// @return True iff the signature is valid.
    function verify(uint256 pkX, uint8 pkYParity, bytes32 msgHash, Signature memory sig)
        internal
        pure
        returns (bool)
    {
        if (sig.rAddr == address(0) || sig.z == 0 || sig.z >= Q) return false;
        if (!isValidKeyX(pkX) || pkYParity > 1) return false;

        uint256 e = challenge(sig.rAddr, pkYParity, pkX, msgHash);
        uint256 ePx = mulmod(e, pkX, Q);
        // e == 0 (probability 2^-256) would make s == 0, which ecrecover rejects anyway.
        if (ePx == 0) return false;

        // Both subtractions are safe: mulmod returns a value in [0, Q-1], ePx != 0, and
        // z·pkX mod Q != 0 because Q is prime and 0 < z, pkX < Q.
        bytes32 s = bytes32(Q - ePx);
        bytes32 h = bytes32(Q - mulmod(sig.z, pkX, Q));

        // Not an ECDSA check: ecrecover is used as a multi-scalar multiplication that returns
        // address(z*G - e*P). (r, s) malleability does not apply; z < n and 0 < P.x < n are
        // enforced above, and the result is compared with the committed address(R).
        // forge-lint: disable-next-line(ecrecover)
        address recovered = ecrecover(h, 27 + pkYParity, bytes32(pkX), s);
        return recovered == sig.rAddr;
    }
}
