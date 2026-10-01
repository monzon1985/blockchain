// SPDX-License-Identifier: MIT
//! EIP-191 signed data.
//!
//! * Version `0x45` (`personal_sign`): `keccak256("\x19Ethereum Signed Message:\n" ‖ len ‖ message)`,
//!   where `len` is the decimal byte length of the message.
//! * Version `0x00` (data with intended validator): `keccak256(0x19 ‖ 0x00 ‖ validator ‖ data)`.

use crate::address::Address;
use crate::hash::keccak256_concat;
use crate::keys::{PrivateKey, Signature, SignatureError};
use alloc::string::ToString;

/// The `personal_sign` prefix.
pub const PERSONAL_PREFIX: &[u8] = b"\x19Ethereum Signed Message:\n";

/// `personal_sign` digest of `message`.
pub fn personal_message_hash(message: &[u8]) -> [u8; 32] {
    let len = message.len().to_string();
    keccak256_concat(&[PERSONAL_PREFIX, len.as_bytes(), message])
}

/// Signs `message` with the `personal_sign` scheme.
pub fn sign_personal_message(
    key: &PrivateKey,
    message: &[u8],
) -> Result<Signature, SignatureError> {
    key.sign_hash(&personal_message_hash(message))
}

/// Recovers the signer of a `personal_sign` signature.
pub fn recover_personal_message(
    message: &[u8],
    signature: &Signature,
) -> Result<Address, SignatureError> {
    signature.recover_address(&personal_message_hash(message))
}

/// Version `0x00` digest: data addressed to a specific validator contract.
pub fn validator_data_hash(validator: &Address, data: &[u8]) -> [u8; 32] {
    keccak256_concat(&[&[0x19, 0x00], &validator.0, data])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    #[test]
    fn personal_sign_known_vector() {
        // `cast wallet sign "hello world"` with anvil account 0.
        let key = PrivateKey::from_hex(
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        )
        .unwrap();
        assert_eq!(
            hex::encode(&personal_message_hash(b"hello world")),
            "d9eba16ed0ecae432b71fe008c98cc872bb4cc214d3220a36f365326cf807d68"
        );
        let sig = sign_personal_message(&key, b"hello world").unwrap();
        assert_eq!(
            recover_personal_message(b"hello world", &sig).unwrap(),
            key.address()
        );
        assert_ne!(
            recover_personal_message(b"hello worle", &sig).ok(),
            Some(key.address())
        );
        let v0 = validator_data_hash(&Address([0x11; 20]), b"x");
        assert_ne!(v0, personal_message_hash(b"x"));
    }
}
