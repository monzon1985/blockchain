// SPDX-License-Identifier: MIT
//! Property tests that need no oracle: round trips, sign-then-recover, strictness under
//! mutation, and algebraic identities.

// Test harness code: an unwrap or panic here is a test failure, which is the intent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use keysmith_core::bip32::{ExtendedPrivateKey, HARDENED};
use keysmith_core::bip39::Mnemonic;
use keysmith_core::keys::{CURVE_ORDER, HALF_CURVE_ORDER};
use keysmith_core::keystore::{self, KdfLimits, KeystoreRandomness, ScryptParams};
use keysmith_core::permit::Permit;
use keysmith_core::rlp::{self, ListDecoder, RlpError, Value as Rlp};
use keysmith_core::tx::{SignedTransaction, Transaction, TxEip1559, TxKind, TxLegacy};
use keysmith_core::{Address, PrivateKey, U256, hex};
use proptest::prelude::*;

fn key_strategy() -> impl Strategy<Value = PrivateKey> {
    any::<[u8; 32]>().prop_filter_map("valid scalar", |b| PrivateKey::from_bytes(&b).ok())
}

fn rlp_value() -> impl Strategy<Value = Rlp> {
    let leaf = prop::collection::vec(any::<u8>(), 0..80).prop_map(Rlp::Bytes);
    leaf.prop_recursive(4, 64, 6, |inner| {
        prop::collection::vec(inner, 0..6).prop_map(Rlp::List)
    })
}

fn simple_tx() -> impl Strategy<Value = Transaction> {
    (
        any::<u64>(),
        any::<u128>(),
        any::<u128>(),
        any::<u64>(),
        any::<[u8; 20]>(),
        any::<[u64; 4]>(),
        prop::collection::vec(any::<u8>(), 0..100),
        prop::option::of(any::<u64>()),
        any::<bool>(),
    )
        .prop_map(|(nonce, a, b, gas, to, value, input, chain, typed)| {
            if typed {
                Transaction::Eip1559(TxEip1559 {
                    chain_id: chain.unwrap_or(1),
                    nonce,
                    max_priority_fee_per_gas: a.min(b),
                    max_fee_per_gas: a.max(b),
                    gas_limit: gas,
                    to: TxKind::Call(Address(to)),
                    value: U256::from_limbs(value),
                    input,
                    access_list: Vec::new(),
                })
            } else {
                Transaction::Legacy(TxLegacy {
                    chain_id: chain,
                    nonce,
                    gas_price: a,
                    gas_limit: gas,
                    to: TxKind::Call(Address(to)),
                    value: U256::from_limbs(value),
                    input,
                })
            }
        })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// decode(encode(v)) == v for arbitrary nested RLP values.
    #[test]
    fn rlp_round_trip(v in rlp_value()) {
        prop_assert_eq!(Rlp::decode(&v.encode()).unwrap(), v);
    }

    /// Integers with a leading zero byte are rejected; canonical ones round-trip.
    #[test]
    fn rlp_integer_canonicality(x in any::<u64>()) {
        let mut canonical = Vec::new();
        rlp::encode_u64(&mut canonical, x);
        let list = rlp::list_with(|p| p.extend_from_slice(&canonical));
        prop_assert_eq!(ListDecoder::from_exact(&list).unwrap().u64().unwrap(), x);
        let trimmed: Vec<u8> = x.to_be_bytes().iter().copied().skip_while(|b| *b == 0).collect();
        let mut padded = vec![0u8];
        padded.extend_from_slice(&trimmed);
        let list = rlp::list_with(|p| rlp::encode_bytes(p, &padded));
        prop_assert_eq!(ListDecoder::from_exact(&list).unwrap().u64(), Err(RlpError::LeadingZeroInteger));
    }

    /// Sign-then-recover: every signature is low-s and recovers the signing key's address.
    #[test]
    fn sign_then_recover(key in key_strategy(), hash in any::<[u8; 32]>()) {
        let sig = key.sign_hash(&hash).unwrap();
        prop_assert!(sig.s <= HALF_CURVE_ORDER);
        prop_assert!(sig.r < CURVE_ORDER && !sig.r.is_zero());
        prop_assert_eq!(sig.recover_address(&hash).unwrap(), key.address());
    }

    /// Signed transactions round-trip, recover their signer, and any truncation or trailing
    /// byte is rejected (no lenient decoding of what was signed).
    #[test]
    fn signed_transactions_are_strict(tx in simple_tx(), key in key_strategy(), cut in any::<prop::sample::Index>(), extra in any::<u8>()) {
        let signed = tx.sign(&key).unwrap();
        let raw = signed.encoded();
        let back = SignedTransaction::decode(&raw).unwrap();
        prop_assert_eq!(&back, &signed);
        prop_assert_eq!(back.recover_signer().unwrap(), key.address());
        let n = cut.index(raw.len());
        prop_assert!(SignedTransaction::decode(&raw[..n]).is_err());
        let mut longer = raw.clone();
        longer.push(extra);
        prop_assert!(SignedTransaction::decode(&longer).is_err());
    }

    /// CKDpub(N(k), i) == N(CKDpriv(k, i)) for every non-hardened index.
    #[test]
    fn public_and_private_derivation_commute(seed in prop::collection::vec(any::<u8>(), 16..=64), index in 0u32..HARDENED) {
        let master = ExtendedPrivateKey::master(&seed).unwrap();
        prop_assert_eq!(master.public().derive_child(index).unwrap(), master.derive_child(index).unwrap().public());
    }

    /// Mnemonics round-trip their entropy.
    #[test]
    fn mnemonic_entropy_round_trip(len in prop::sample::select(vec![16usize, 20, 24, 28, 32]), bytes in any::<[u8; 32]>()) {
        let m = Mnemonic::from_entropy(&bytes[..len]).unwrap();
        let parsed = Mnemonic::parse(m.phrase()).unwrap();
        prop_assert_eq!(parsed.entropy(), &bytes[..len]);
        prop_assert_eq!(m.word_count(), len * 3 / 4);
    }

    /// Hex round trip.
    #[test]
    fn hex_round_trip(bytes in prop::collection::vec(any::<u8>(), 0..64)) {
        prop_assert_eq!(hex::decode(&hex::encode_prefixed(&bytes)).unwrap(), bytes);
    }

    /// The permit helper's direct digest always equals the generic EIP-712 engine's.
    #[test]
    fn permit_direct_equals_generic(chain in any::<u64>(), token in any::<[u8; 20]>(), spender in any::<[u8; 20]>(),
                                    owner in any::<[u8; 20]>(), value in any::<[u64; 4]>(), nonce in any::<u64>(),
                                    deadline in any::<u64>(), name in "[ -~]{0,24}") {
        let p = Permit {
            token_name: name,
            token_version: "1".into(),
            chain_id: U256::from_u64(chain),
            token: Address(token),
            owner: Address(owner),
            spender: Address(spender),
            value: U256::from_limbs(value),
            nonce: U256::from_u64(nonce),
            deadline: U256::from_u64(deadline),
        };
        prop_assert_eq!(p.typed_data().unwrap().signing_hash().unwrap(), p.signing_hash());
    }
}

proptest! {
    // Each case runs scrypt twice, hence the smaller default.
    #![proptest_config(ProptestConfig::with_cases(24))]

    /// Keystore encrypt / decrypt round trip; any other password fails the MAC.
    #[test]
    fn keystore_round_trip(key in key_strategy(), password in "[ -~]{1,32}", salt in any::<[u8; 32]>(), iv in any::<[u8; 16]>()) {
        let params = ScryptParams { log_n: 10, r: 8, p: 1 };
        let json = keystore::encrypt(&key, password.as_bytes(), params, &KeystoreRandomness { salt, iv, uuid: [7; 16] }).unwrap();
        let back = keystore::decrypt(&json, password.as_bytes(), &KdfLimits::default()).unwrap();
        prop_assert_eq!(back.address(), key.address());
        let wrong = format!("{password}!");
        prop_assert!(keystore::decrypt(&json, wrong.as_bytes(), &KdfLimits::default()).is_err());
    }
}
