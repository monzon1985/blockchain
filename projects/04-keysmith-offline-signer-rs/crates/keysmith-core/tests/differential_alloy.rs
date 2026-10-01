// SPDX-License-Identifier: MIT
//! Differential property tests: keysmith-core against alloy 2.5 (alloy-consensus, alloy-eips,
//! alloy-rlp, alloy-dyn-abi, alloy-primitives/ruint) and eth-keystore / coins-bip39 via
//! alloy-signer-local. alloy is a dev-dependency only; it never ships in the signer.

// Test harness code: an unwrap or panic here is a test failure, which is the intent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use alloy::consensus::{SignableTransaction, TxEnvelope};
use alloy::eips::eip2718::{Decodable2718, Encodable2718};
use alloy::primitives::{self as ap, B256, Bytes};
use alloy::signers::local::coins_bip39::English;
use alloy::signers::local::{MnemonicBuilder, PrivateKeySigner};
use keysmith_core::authorization::{Authorization, SignedAuthorization};
use keysmith_core::bip32::{DerivationPath, derive_private_key};
use keysmith_core::bip39::Mnemonic;
use keysmith_core::eip712::TypedData;
use keysmith_core::keystore::{self, KdfLimits, KeystoreRandomness, ScryptParams};
use keysmith_core::rlp::Value as Rlp;
use keysmith_core::tx::{
    AccessListItem, SignedTransaction, Transaction, TxEip1559, TxEip2930, TxEip7702, TxKind,
    TxLegacy,
};
use keysmith_core::{Address, PrivateKey, U256, eip191, hex};
use proptest::prelude::*;
use serde_json::{Value, json};

// ---------------------------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------------------------

fn a_u256(v: &U256) -> ap::U256 {
    ap::U256::from_limbs(*v.as_limbs())
}

fn a_addr(a: &Address) -> ap::Address {
    ap::Address::from(a.0)
}

fn a_kind(k: &TxKind) -> ap::TxKind {
    match k {
        TxKind::Create => ap::TxKind::Create,
        TxKind::Call(a) => ap::TxKind::Call(a_addr(a)),
    }
}

fn a_access(list: &[AccessListItem]) -> alloy::eips::eip2930::AccessList {
    alloy::eips::eip2930::AccessList(
        list.iter()
            .map(|i| alloy::eips::eip2930::AccessListItem {
                address: a_addr(&i.address),
                storage_keys: i.storage_keys.iter().map(|k| B256::from(*k)).collect(),
            })
            .collect(),
    )
}

fn a_auth(a: &SignedAuthorization) -> alloy::eips::eip7702::SignedAuthorization {
    alloy::eips::eip7702::SignedAuthorization::new_unchecked(
        alloy::eips::eip7702::Authorization {
            chain_id: a_u256(&a.chain_id),
            address: a_addr(&a.address),
            nonce: a.nonce,
        },
        a.y_parity,
        a_u256(&a.r),
        a_u256(&a.s),
    )
}

enum AlloyTx {
    Legacy(alloy::consensus::TxLegacy),
    Eip2930(alloy::consensus::TxEip2930),
    Eip1559(alloy::consensus::TxEip1559),
    Eip7702(alloy::consensus::TxEip7702),
}

fn to_alloy(tx: &Transaction) -> AlloyTx {
    match tx {
        Transaction::Legacy(t) => AlloyTx::Legacy(alloy::consensus::TxLegacy {
            chain_id: t.chain_id,
            nonce: t.nonce,
            gas_price: t.gas_price,
            gas_limit: t.gas_limit,
            to: a_kind(&t.to),
            value: a_u256(&t.value),
            input: Bytes::from(t.input.clone()),
        }),
        Transaction::Eip2930(t) => AlloyTx::Eip2930(alloy::consensus::TxEip2930 {
            chain_id: t.chain_id,
            nonce: t.nonce,
            gas_price: t.gas_price,
            gas_limit: t.gas_limit,
            to: a_kind(&t.to),
            value: a_u256(&t.value),
            access_list: a_access(&t.access_list),
            input: Bytes::from(t.input.clone()),
        }),
        Transaction::Eip1559(t) => AlloyTx::Eip1559(alloy::consensus::TxEip1559 {
            chain_id: t.chain_id,
            nonce: t.nonce,
            gas_limit: t.gas_limit,
            max_fee_per_gas: t.max_fee_per_gas,
            max_priority_fee_per_gas: t.max_priority_fee_per_gas,
            to: a_kind(&t.to),
            value: a_u256(&t.value),
            access_list: a_access(&t.access_list),
            input: Bytes::from(t.input.clone()),
        }),
        Transaction::Eip7702(t) => AlloyTx::Eip7702(alloy::consensus::TxEip7702 {
            chain_id: t.chain_id,
            nonce: t.nonce,
            gas_limit: t.gas_limit,
            max_fee_per_gas: t.max_fee_per_gas,
            max_priority_fee_per_gas: t.max_priority_fee_per_gas,
            to: a_addr(&t.to),
            value: a_u256(&t.value),
            access_list: a_access(&t.access_list),
            authorization_list: t.authorization_list.iter().map(a_auth).collect(),
            input: Bytes::from(t.input.clone()),
        }),
    }
}

/// (signing payload, signing hash, signed EIP-2718 encoding) as computed by alloy.
fn alloy_encodings(
    tx: &Transaction,
    sig: &keysmith_core::Signature,
) -> (Vec<u8>, [u8; 32], Vec<u8>) {
    let asig = ap::Signature::new(a_u256(&sig.r), a_u256(&sig.s), sig.y_parity);
    macro_rules! go {
        ($t:expr) => {{
            let mut payload = Vec::new();
            $t.encode_for_signing(&mut payload);
            let hash = $t.signature_hash();
            let env: TxEnvelope = $t.into_signed(asig).into();
            (payload, hash.0, env.encoded_2718())
        }};
    }
    match to_alloy(tx) {
        AlloyTx::Legacy(t) => go!(t),
        AlloyTx::Eip2930(t) => go!(t),
        AlloyTx::Eip1559(t) => go!(t),
        AlloyTx::Eip7702(t) => go!(t),
    }
}

// ---------------------------------------------------------------------------------------------
// Strategies
// ---------------------------------------------------------------------------------------------

fn u256_strategy() -> impl Strategy<Value = U256> {
    prop_oneof![
        Just(U256::ZERO),
        Just(U256::MAX),
        any::<u64>().prop_map(U256::from_u64),
        any::<u128>().prop_map(U256::from_u128),
        any::<[u64; 4]>().prop_map(U256::from_limbs),
    ]
}

fn address_strategy() -> impl Strategy<Value = Address> {
    any::<[u8; 20]>().prop_map(Address)
}

fn kind_strategy() -> impl Strategy<Value = TxKind> {
    prop_oneof![
        Just(TxKind::Create),
        address_strategy().prop_map(TxKind::Call)
    ]
}

fn input_strategy() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        Just(Vec::new()),
        prop::collection::vec(any::<u8>(), 1..8),
        prop::collection::vec(any::<u8>(), 50..70),
        prop::collection::vec(any::<u8>(), 200..600),
    ]
}

fn access_list_strategy() -> impl Strategy<Value = Vec<AccessListItem>> {
    prop::collection::vec(
        (
            address_strategy(),
            prop::collection::vec(any::<[u8; 32]>(), 0..3),
        )
            .prop_map(|(address, storage_keys)| AccessListItem {
                address,
                storage_keys,
            }),
        0..3,
    )
}

fn auth_strategy() -> impl Strategy<Value = SignedAuthorization> {
    (
        u256_strategy(),
        address_strategy(),
        any::<u64>(),
        any::<u8>(),
        u256_strategy(),
        u256_strategy(),
    )
        .prop_map(
            |(chain_id, address, nonce, y_parity, r, s)| SignedAuthorization {
                chain_id,
                address,
                nonce,
                y_parity,
                r,
                s,
            },
        )
}

prop_compose! {
    fn legacy()(chain_id in prop::option::of(any::<u64>()), nonce in any::<u64>(), gas_price in any::<u128>(),
                gas_limit in any::<u64>(), to in kind_strategy(), value in u256_strategy(), input in input_strategy())
                -> Transaction {
        Transaction::Legacy(TxLegacy { chain_id, nonce, gas_price, gas_limit, to, value, input })
    }
}

prop_compose! {
    fn eip2930()(chain_id in any::<u64>(), nonce in any::<u64>(), gas_price in any::<u128>(), gas_limit in any::<u64>(),
                 to in kind_strategy(), value in u256_strategy(), input in input_strategy(),
                 access_list in access_list_strategy()) -> Transaction {
        Transaction::Eip2930(TxEip2930 { chain_id, nonce, gas_price, gas_limit, to, value, input, access_list })
    }
}

prop_compose! {
    fn eip1559()(chain_id in any::<u64>(), nonce in any::<u64>(), tip in any::<u128>(), fee in any::<u128>(),
                 gas_limit in any::<u64>(), to in kind_strategy(), value in u256_strategy(), input in input_strategy(),
                 access_list in access_list_strategy()) -> Transaction {
        Transaction::Eip1559(TxEip1559 { chain_id, nonce, max_priority_fee_per_gas: tip, max_fee_per_gas: fee,
                                         gas_limit, to, value, input, access_list })
    }
}

prop_compose! {
    fn eip7702()(chain_id in any::<u64>(), nonce in any::<u64>(), tip in any::<u128>(), fee in any::<u128>(),
                 gas_limit in any::<u64>(), to in address_strategy(), value in u256_strategy(), input in input_strategy(),
                 access_list in access_list_strategy(),
                 authorization_list in prop::collection::vec(auth_strategy(), 0..3)) -> Transaction {
        Transaction::Eip7702(TxEip7702 { chain_id, nonce, max_priority_fee_per_gas: tip, max_fee_per_gas: fee,
                                         gas_limit, to, value, input, access_list, authorization_list })
    }
}

fn any_tx() -> impl Strategy<Value = Transaction> {
    prop_oneof![legacy(), eip2930(), eip1559(), eip7702()]
}

fn key_strategy() -> impl Strategy<Value = PrivateKey> {
    any::<[u8; 32]>().prop_filter_map("valid scalar", |b| PrivateKey::from_bytes(&b).ok())
}

fn rlp_value(depth: u32) -> BoxedStrategy<Rlp> {
    let leaf = prop_oneof![
        prop::collection::vec(any::<u8>(), 0..3).prop_map(Rlp::Bytes),
        prop::collection::vec(any::<u8>(), 50..60).prop_map(Rlp::Bytes),
        prop::collection::vec(any::<u8>(), 250..270).prop_map(Rlp::Bytes),
    ]
    .boxed();
    if depth == 0 {
        return leaf;
    }
    prop_oneof![
        3 => leaf,
        1 => prop::collection::vec(rlp_value(depth - 1), 0..5).prop_map(Rlp::List),
    ]
    .boxed()
}

fn alloy_rlp_encode(v: &Rlp, out: &mut Vec<u8>) {
    use alloy::rlp::{Encodable, Header};
    match v {
        Rlp::Bytes(b) => b.as_slice().encode(out),
        Rlp::List(items) => {
            let mut payload = Vec::new();
            for i in items {
                alloy_rlp_encode(i, &mut payload);
            }
            Header {
                list: true,
                payload_length: payload.len(),
            }
            .encode(out);
            out.extend_from_slice(&payload);
        }
    }
}

/// A strict dynamic decoder built only from `alloy_rlp::Header::decode`.
fn alloy_rlp_decode(buf: &mut &[u8]) -> Result<Rlp, alloy::rlp::Error> {
    let header = alloy::rlp::Header::decode(buf)?;
    let (payload, rest) = buf.split_at(header.payload_length);
    *buf = rest;
    if !header.list {
        return Ok(Rlp::Bytes(payload.to_vec()));
    }
    let mut inner = payload;
    let mut items = Vec::new();
    while !inner.is_empty() {
        items.push(alloy_rlp_decode(&mut inner)?);
    }
    Ok(Rlp::List(items))
}

// ---------------------------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// Signing payload, signing hash and signed encoding are byte-identical to alloy-consensus,
    /// and each side decodes the other's bytes to the same transaction.
    #[test]
    fn transactions_match_alloy(tx in any_tx(), key in key_strategy()) {
        let signed = tx.clone().sign(&key).unwrap();
        let (payload, hash, encoded) = alloy_encodings(&tx, &signed.signature);
        prop_assert_eq!(tx.signing_payload(), payload);
        prop_assert_eq!(tx.signing_hash(), hash);
        prop_assert_eq!(signed.encoded(), encoded.clone());
        let ours = SignedTransaction::decode(&encoded).unwrap();
        prop_assert_eq!(&ours, &signed);
        let theirs = TxEnvelope::decode_2718_exact(&signed.encoded()).unwrap();
        prop_assert_eq!(theirs.encoded_2718(), signed.encoded());
        prop_assert_eq!(theirs.tx_hash().0, signed.hash());
        let recovered = alloy::consensus::transaction::SignerRecoverable::recover_signer(&theirs).unwrap();
        prop_assert_eq!(recovered.0, key.address().0);
        prop_assert_eq!(signed.recover_signer().unwrap(), key.address());
    }

    /// Differential fuzzing of the strict decoder on corrupted transactions (byte flips,
    /// insertions, deletions, truncation, trailing bytes, swapped type bytes):
    ///
    /// * whatever keysmith accepts, alloy-consensus accepts too, and both re-encode it to the
    ///   exact input bytes and the same hash (keysmith never accepts a malleated encoding);
    /// * the only bytes alloy accepts and keysmith rejects are EIP-4844 blob transactions,
    ///   which are out of scope by design.
    #[test]
    fn corrupted_transactions_never_split_the_decoders(
        tx in any_tx(),
        key in key_strategy(),
        mutation in 0usize..6,
        pos in any::<prop::sample::Index>(),
        byte in any::<u8>(),
    ) {
        let mut bytes = tx.sign(&key).unwrap().encoded();
        match mutation {
            0 => { let i = pos.index(bytes.len()); bytes[i] = byte; }
            1 => { let i = pos.index(bytes.len() + 1); bytes.insert(i, byte); }
            2 => { let i = pos.index(bytes.len()); bytes.remove(i); }
            3 => { let i = pos.index(bytes.len()); bytes.truncate(i); }
            4 => bytes.push(byte),
            // Re-label the envelope: a typed body under another type byte, or a bare list.
            _ => match bytes[0] {
                0x01..=0x04 => bytes[0] = [0x01, 0x02, 0x03, 0x04][usize::from(byte % 4)],
                _ => bytes.insert(0, [0x01, 0x02, 0x03, 0x04][usize::from(byte % 4)]),
            },
        }
        let ours = SignedTransaction::decode(&bytes);
        let theirs = TxEnvelope::decode_2718_exact(&bytes);
        match (&ours, &theirs) {
            (Ok(ours), Ok(theirs)) => {
                prop_assert_eq!(ours.encoded(), bytes.clone());
                prop_assert_eq!(theirs.encoded_2718(), bytes.clone());
                prop_assert_eq!(theirs.tx_hash().0, ours.hash());
            }
            (Ok(_), Err(e)) => prop_assert!(false, "keysmith accepted bytes alloy rejects ({e}): 0x{}", hex::encode(&bytes)),
            (Err(_), Ok(theirs)) => prop_assert!(
                theirs.is_eip4844(),
                "alloy accepted a {:?} transaction keysmith rejects: 0x{}", theirs.tx_type(), hex::encode(&bytes)
            ),
            (Err(_), Err(_)) => {}
        }
    }

    /// EIP-7702 authorization hashing, encoding and recovery match alloy-eips.
    #[test]
    fn authorizations_match_alloy(chain_id in u256_strategy(), address in address_strategy(),
                                  nonce in any::<u64>(), key in key_strategy()) {
        let auth = Authorization { chain_id, address, nonce };
        let theirs = alloy::eips::eip7702::Authorization { chain_id: a_u256(&chain_id), address: a_addr(&address), nonce };
        prop_assert_eq!(auth.signing_hash(), theirs.signature_hash().0);
        let signed = auth.sign(&key).unwrap();
        let theirs_signed = a_auth(&signed);
        let mut enc = Vec::new();
        alloy::rlp::Encodable::encode(&theirs_signed, &mut enc);
        prop_assert_eq!(signed.encode(), enc);
        prop_assert_eq!(theirs_signed.recover_authority().unwrap().0, key.address().0);
    }

    /// Canonical RLP: encodings equal alloy-rlp's; decoding accepts exactly what alloy-rlp's
    /// strict header decoder accepts, on valid encodings and on mutated ones.
    #[test]
    fn rlp_matches_alloy(value in rlp_value(3), mutation in 0usize..4, pos in any::<prop::sample::Index>(), byte in any::<u8>()) {
        let ours = value.encode();
        let mut theirs = Vec::new();
        alloy_rlp_encode(&value, &mut theirs);
        prop_assert_eq!(&ours, &theirs);
        prop_assert_eq!(Rlp::decode(&ours).unwrap(), value);
        let mut bytes = ours.clone();
        match mutation {
            0 => { let i = pos.index(bytes.len()); bytes[i] = byte; }
            1 => { let i = pos.index(bytes.len() + 1); bytes.insert(i, byte); }
            2 => { let i = pos.index(bytes.len()); bytes.truncate(i); }
            _ => bytes.push(byte),
        }
        let mut buf = bytes.as_slice();
        let theirs = alloy_rlp_decode(&mut buf).ok().filter(|_| buf.is_empty());
        prop_assert_eq!(Rlp::decode(&bytes).ok(), theirs);
    }

    /// U256 arithmetic, parsing and printing agree with ruint.
    #[test]
    fn u256_matches_ruint(a in u256_strategy(), b in u256_strategy()) {
        let (x, y) = (a_u256(&a), a_u256(&b));
        prop_assert_eq!(a.checked_add(&b).map(|v| a_u256(&v)), x.checked_add(y));
        prop_assert_eq!(a.checked_sub(&b).map(|v| a_u256(&v)), x.checked_sub(y));
        prop_assert_eq!(a.checked_mul(&b).map(|v| a_u256(&v)), x.checked_mul(y));
        prop_assert_eq!(a.cmp(&b), x.cmp(&y));
        prop_assert_eq!(a.to_string(), x.to_string());
        prop_assert_eq!(format!("{a:#x}"), format!("{x:#x}"));
        prop_assert_eq!(a.to_be_bytes(), x.to_be_bytes::<32>());
        prop_assert_eq!(a.bits(), u32::try_from(x.bit_len()).unwrap());
        prop_assert_eq!(U256::parse(&x.to_string()).unwrap(), a);
        prop_assert_eq!(U256::parse(&format!("{x:#x}")).unwrap(), a);
    }

    /// `personal_sign` digest equals alloy's `eip191_hash_message`.
    #[test]
    fn eip191_matches_alloy(msg in prop::collection::vec(any::<u8>(), 0..300)) {
        prop_assert_eq!(eip191::personal_message_hash(&msg), ap::eip191_hash_message(&msg).0);
    }

    /// BIP-39 + BIP-32/44 derivation equals coins-bip39/coins-bip32 (alloy MnemonicBuilder).
    #[test]
    fn hd_derivation_matches_alloy_mnemonic_builder(
        entropy in prop_oneof![
            prop::collection::vec(any::<u8>(), 16), prop::collection::vec(any::<u8>(), 20),
            prop::collection::vec(any::<u8>(), 24), prop::collection::vec(any::<u8>(), 28),
            prop::collection::vec(any::<u8>(), 32)],
        index in 0u32..(1 << 31), passphrase in "[a-zA-Z0-9 ]{0,12}")
    {
        let m = Mnemonic::from_entropy(&entropy).unwrap();
        let ours = derive_private_key(&m.to_seed(&passphrase), &DerivationPath::ethereum(index).unwrap()).unwrap();
        let theirs = MnemonicBuilder::<English>::default()
            .phrase(m.phrase())
            .index(index).unwrap()
            .password(passphrase.clone())
            .build().unwrap();
        prop_assert_eq!(ours.address().0, theirs.address().0);
    }
}

// ---------------------------------------------------------------------------------------------
// EIP-712 against alloy-dyn-abi
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
enum Field {
    Uint(u32),
    Int(u32),
    FixedBytes(usize),
    Bool,
    Address,
    Str,
    Bytes,
}

impl Field {
    fn type_name(&self) -> String {
        match self {
            Field::Uint(b) => format!("uint{b}"),
            Field::Int(b) => format!("int{b}"),
            Field::FixedBytes(n) => format!("bytes{n}"),
            Field::Bool => "bool".into(),
            Field::Address => "address".into(),
            Field::Str => "string".into(),
            Field::Bytes => "bytes".into(),
        }
    }
}

fn field_strategy() -> impl Strategy<Value = Field> {
    prop_oneof![
        (1u32..=32).prop_map(|k| Field::Uint(8 * k)),
        (1u32..=32).prop_map(|k| Field::Int(8 * k)),
        (1usize..=32).prop_map(Field::FixedBytes),
        Just(Field::Bool),
        Just(Field::Address),
        Just(Field::Str),
        Just(Field::Bytes),
    ]
}

fn value_for(field: &Field, seed: &[u8; 32], neg: bool) -> Value {
    let word = U256::from_be_bytes(*seed);
    let mask = |bits: u32| -> U256 {
        let mut b = *seed;
        let keep = usize::try_from(bits.div_ceil(8)).unwrap();
        for byte in b.iter_mut().take(32 - keep) {
            *byte = 0;
        }
        if !bits.is_multiple_of(8) {
            b[32 - keep] &= (1u8 << (bits % 8)) - 1;
        }
        U256::from_be_bytes(b)
    };
    match field {
        Field::Uint(bits) => json!(mask(*bits).to_string()),
        Field::Int(bits) => {
            let magnitude = mask(bits - 1);
            if neg && !magnitude.is_zero() {
                json!(format!("-{magnitude}"))
            } else {
                json!(magnitude.to_string())
            }
        }
        Field::FixedBytes(n) => json!(hex::encode_prefixed(&seed[..*n])),
        Field::Bool => json!(seed[0].is_multiple_of(2)),
        Field::Address => json!(hex::encode_prefixed(&seed[..20])),
        Field::Str => json!(format!(
            "keysmith-{}",
            word.to_string()
                .chars()
                .take(usize::from(seed[1] % 20))
                .collect::<String>()
        )),
        Field::Bytes => json!(hex::encode_prefixed(&seed[..usize::from(seed[2] % 33)])),
    }
}

prop_compose! {
    fn typed_data_strategy()(
        fields in prop::collection::vec(field_strategy(), 1..6),
        arrays in prop::collection::vec(field_strategy(), 0..3),
        seeds in prop::collection::vec(any::<[u8; 32]>(), 24),
        negs in prop::collection::vec(any::<bool>(), 24),
        items in 0usize..4,
        domain_mask in 0u8..32,
        chain in any::<u64>(),
    ) -> Value {
        let mut inner_types = Vec::new();
        let mut inner_value = serde_json::Map::new();
        for (i, f) in fields.iter().enumerate() {
            inner_types.push(json!({"name": format!("f{i}"), "type": f.type_name()}));
            inner_value.insert(format!("f{i}"), value_for(f, &seeds[i], negs[i]));
        }
        let mut outer_types = vec![json!({"name": "inner", "type": "Inner"}), json!({"name": "list", "type": "Inner[]"})];
        let mut outer_value = serde_json::Map::new();
        outer_value.insert("inner".into(), Value::Object(inner_value.clone()));
        outer_value.insert("list".into(), Value::Array(vec![Value::Object(inner_value); items]));
        for (j, f) in arrays.iter().enumerate() {
            outer_types.push(json!({"name": format!("a{j}"), "type": format!("{}[]", f.type_name())}));
            let elems: Vec<Value> = (0..items).map(|k| value_for(f, &seeds[6 + j * 4 + k], negs[6 + j * 4 + k])).collect();
            outer_value.insert(format!("a{j}"), Value::Array(elems));
        }
        let all = [
            ("name", "string", json!("Keysmith")),
            ("version", "string", json!("1")),
            ("chainId", "uint256", json!(chain.to_string())),
            ("verifyingContract", "address", json!(hex::encode_prefixed(&seeds[20][..20]))),
            ("salt", "bytes32", json!(hex::encode_prefixed(&seeds[21]))),
        ];
        let mut domain_types = Vec::new();
        let mut domain = serde_json::Map::new();
        for (bit, (name, ty, v)) in all.into_iter().enumerate() {
            if domain_mask & (1 << bit) != 0 {
                domain_types.push(json!({"name": name, "type": ty}));
                domain.insert(name.into(), v);
            }
        }
        json!({
            "types": {"EIP712Domain": domain_types, "Inner": inner_types, "Outer": outer_types},
            "primaryType": "Outer",
            "domain": domain,
            "message": outer_value,
        })
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Random schemas (all atomic widths, dynamic types, struct arrays, domain subsets):
    /// the digest equals alloy-dyn-abi's `TypedData::eip712_signing_hash`.
    #[test]
    fn eip712_matches_alloy(doc in typed_data_strategy()) {
        let ours = TypedData::from_value(&doc).unwrap().signing_hash().unwrap();
        let theirs: alloy::dyn_abi::TypedData = serde_json::from_value(doc).unwrap();
        prop_assert_eq!(ours, theirs.eip712_signing_hash().unwrap().0);
    }
}

// ---------------------------------------------------------------------------------------------
// Keystore interoperability with eth-keystore (the implementation behind alloy and Foundry)
// ---------------------------------------------------------------------------------------------

#[test]
fn keystore_round_trips_with_eth_keystore() {
    let dir = tempfile::tempdir().unwrap();
    for seed in 1u8..=3 {
        // keysmith writes, eth-keystore reads.
        let key = PrivateKey::from_bytes(&[seed; 32]).unwrap();
        let randomness = KeystoreRandomness {
            salt: [seed ^ 0x5a; 32],
            iv: [seed; 16],
            uuid: [seed; 16],
        };
        let json =
            keystore::encrypt(&key, b"correct horse", ScryptParams::LIGHT, &randomness).unwrap();
        let path = dir.path().join(format!("ks-{seed}.json"));
        std::fs::write(&path, &json).unwrap();
        let theirs = PrivateKeySigner::decrypt_keystore(&path, "correct horse").unwrap();
        assert_eq!(theirs.address().0, key.address().0);

        // eth-keystore writes, keysmith reads.
        let secret = [seed.wrapping_add(100); 32];
        let (signer, _) = PrivateKeySigner::encrypt_keystore(
            dir.path(),
            &mut rand::thread_rng(),
            secret,
            "battery staple",
            Some(&format!("eth-{seed}")),
        )
        .unwrap();
        let written = std::fs::read_to_string(dir.path().join(format!("eth-{seed}"))).unwrap();
        let ours = keystore::decrypt(&written, b"battery staple", &KdfLimits::default()).unwrap();
        assert_eq!(ours.address().0, signer.address().0);
    }
}
