// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";

import {ISchnorrVault} from "../../src/ISchnorrVault.sol";
import {SchnorrSecp256k1} from "../../src/SchnorrSecp256k1.sol";
import {SchnorrVault} from "../../src/SchnorrVault.sol";

/// @notice Exposes the library through external calls (gas measurement, coverage).
contract VerifierHarness {
    /// @notice Wraps SchnorrSecp256k1.verify.
    function verify(
        uint256 pkX,
        uint8 pkYParity,
        bytes32 msgHash,
        SchnorrSecp256k1.Signature memory sig
    ) external pure returns (bool) {
        return SchnorrSecp256k1.verify(pkX, pkYParity, msgHash, sig);
    }

    /// @notice Wraps SchnorrSecp256k1.challenge.
    function challenge(address rAddr, uint8 pkYParity, uint256 pkX, bytes32 msgHash)
        external
        pure
        returns (uint256)
    {
        return SchnorrSecp256k1.challenge(rAddr, pkYParity, pkX, msgHash);
    }
}

/// @notice Single-key Schnorr signer for tests. A FROST aggregate signature is a
///         plain Schnorr signature under the group key, so a test key with a known
///         secret produces exactly what the vault verifies. Signatures from the real
///         Rust FROST implementation are covered by RustFixtures.t.sol.
abstract contract SchnorrTestBase is Test {
    uint256 internal constant Q = SchnorrSecp256k1.Q;

    /// @notice A test group key with its secret.
    struct Key {
        uint256 sk;
        uint256 x;
        uint8 parity;
    }

    /// @notice Derives the public key of `sk` (sk must be in [1, Q-1]).
    function makeKey(uint256 sk) internal returns (Key memory key) {
        Vm.Wallet memory wallet = vm.createWallet(sk);
        key = Key({sk: sk, x: wallet.publicKeyX, parity: uint8(wallet.publicKeyY & 1)});
    }

    /// @notice Schnorr-signs `msgHash` with a nonce derived from `(sk, msgHash, salt)`.
    function schnorrSign(Key memory key, bytes32 msgHash, uint256 salt)
        internal
        pure
        returns (SchnorrSecp256k1.Signature memory sig)
    {
        uint256 k = (uint256(keccak256(abi.encode(key.sk, msgHash, salt))) % (Q - 1)) + 1;
        address rAddr = vm.addr(k);
        uint256 e = SchnorrSecp256k1.challenge(rAddr, key.parity, key.x, msgHash);
        sig = SchnorrSecp256k1.Signature({rAddr: rAddr, z: addmod(k, mulmod(e, key.sk, Q), Q)});
    }

    /// @notice Schnorr-signs with the default salt.
    function schnorrSign(Key memory key, bytes32 msgHash)
        internal
        pure
        returns (SchnorrSecp256k1.Signature memory)
    {
        return schnorrSign(key, msgHash, 0);
    }

    /// @notice Builds a withdrawal intent.
    function withdrawal(address to, address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (ISchnorrVault.WithdrawalIntent memory)
    {
        return ISchnorrVault.WithdrawalIntent({
            to: to, token: token, amount: amount, nonce: nonce, deadline: deadline
        });
    }

    /// @notice Signs a withdrawal for `vault` with `key`.
    function signWithdrawal(
        SchnorrVault vault,
        Key memory key,
        ISchnorrVault.WithdrawalIntent memory intent
    ) internal view returns (SchnorrSecp256k1.Signature memory) {
        return schnorrSign(key, vault.hashWithdrawal(intent));
    }
}
