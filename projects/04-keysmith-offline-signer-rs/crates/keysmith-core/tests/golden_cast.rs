// SPDX-License-Identifier: MIT
//! Golden vectors produced by Foundry's `cast` 1.8.3 (`cargo xtask regen-golden`).
//!
//! Every expected value in `test-vectors/cast/golden.json` is cast output; every actual value
//! here is computed by keysmith-core from the recorded inputs. Byte equality is required.

// Test harness code: an unwrap or panic here is a test failure, which is the intent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use keysmith_core::authorization::{Authorization, SignedAuthorization};
use keysmith_core::bip32::{DerivationPath, derive_private_key};
use keysmith_core::bip39::Mnemonic;
use keysmith_core::eip712::TypedData;
use keysmith_core::envelope::{UnsignedEnvelope, sign_envelope};
use keysmith_core::keystore::{self, KdfLimits};
use keysmith_core::permit::Permit;
use keysmith_core::rlp::Value as Rlp;
use keysmith_core::tx::SignedTransaction;
use keysmith_core::{Address, PrivateKey, U256, eip191, hex};
use serde_json::Value;
use std::path::PathBuf;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-vectors/cast")
}

fn golden() -> Value {
    serde_json::from_str(&std::fs::read_to_string(root().join("golden.json")).unwrap()).unwrap()
}

fn str_of<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("missing string {key} in {v}"))
}

fn key(doc: &Value, index: &Value) -> PrivateKey {
    let m = Mnemonic::parse(str_of(doc, "mnemonic")).unwrap();
    let i = u32::try_from(index.as_u64().unwrap()).unwrap();
    derive_private_key(&m.to_seed(""), &DerivationPath::ethereum(i).unwrap()).unwrap()
}

#[test]
fn transactions_are_byte_identical_to_cast_mktx() {
    let doc = golden();
    let cases = doc["transactions"].as_array().unwrap();
    assert_eq!(cases.len(), 11);
    for case in cases {
        let name = str_of(case, "name");
        let mut env: UnsignedEnvelope = serde_json::from_value(case["envelope"].clone()).unwrap();
        for sponsored in case["sponsoredAuthorizations"].as_array().unwrap() {
            let auth = Authorization {
                chain_id: U256::parse(str_of(sponsored, "chainId")).unwrap(),
                address: Address::parse(str_of(sponsored, "address")).unwrap(),
                nonce: str_of(sponsored, "nonce").parse().unwrap(),
            }
            .sign(&key(&doc, &sponsored["signerIndex"]))
            .unwrap();
            assert_eq!(
                hex::encode_prefixed(&auth.encode()),
                str_of(sponsored, "castRlp"),
                "{name}: sponsored auth"
            );
            env.tx.authorization_list.push(auth);
        }
        let signer = key(&doc, &case["signerIndex"]);
        let out = sign_envelope(&env, &signer, None).unwrap_or_else(|e| panic!("{name}: {e}"));
        let cast = &case["cast"];
        assert_eq!(
            out.envelope.raw,
            str_of(cast, "raw"),
            "{name}: raw bytes differ from cast"
        );
        assert_eq!(
            out.envelope.hash,
            str_of(cast, "hash"),
            "{name}: hash differs from cast decode-tx"
        );
        // Decoding cast's bytes yields the same transaction and the same signer cast reports.
        let decoded =
            SignedTransaction::decode(&hex::decode(str_of(cast, "raw")).unwrap()).unwrap();
        assert_eq!(
            decoded, out.signed,
            "{name}: decode(cast) != our transaction"
        );
        assert_eq!(
            decoded.recover_signer().unwrap(),
            Address::parse(str_of(cast, "signer")).unwrap(),
            "{name}: signer"
        );
    }
}

#[test]
fn authorizations_match_cast_sign_auth() {
    let doc = golden();
    for case in doc["authorizations"].as_array().unwrap() {
        let signer = key(&doc, &case["signerIndex"]);
        let auth = Authorization {
            chain_id: U256::parse(str_of(case, "chainId")).unwrap(),
            address: Address::parse(str_of(case, "address")).unwrap(),
            nonce: str_of(case, "nonce").parse().unwrap(),
        };
        let signed = auth.sign(&signer).unwrap();
        let cast_rlp = str_of(&case["cast"], "rlp");
        assert_eq!(
            hex::encode_prefixed(&signed.encode()),
            cast_rlp,
            "{}",
            str_of(case, "name")
        );
        let decoded = SignedAuthorization::decode(&hex::decode(cast_rlp).unwrap()).unwrap();
        assert_eq!(decoded.recover_authority().unwrap(), signer.address());
    }
}

#[test]
fn personal_messages_match_cast_wallet_sign() {
    let doc = golden();
    for case in doc["messages"].as_array().unwrap() {
        let msg = &case["message"];
        let bytes = match (msg.get("utf8"), msg.get("hex")) {
            (Some(Value::String(s)), _) => s.as_bytes().to_vec(),
            (_, Some(Value::String(h))) => hex::decode(h).unwrap(),
            _ => panic!("bad message case"),
        };
        let signer = key(&doc, &case["signerIndex"]);
        let sig = eip191::sign_personal_message(&signer, &bytes).unwrap();
        assert_eq!(
            hex::encode_prefixed(&sig.to_rsv_bytes()),
            str_of(&case["cast"], "signature"),
            "{}",
            str_of(case, "name")
        );
    }
}

#[test]
fn typed_data_matches_cast_wallet_sign_data() {
    let doc = golden();
    let cases = doc["typedData"].as_array().unwrap();
    assert_eq!(cases.len(), 4);
    for case in cases {
        let file = str_of(case, "file");
        let json = std::fs::read_to_string(root().join("typed-data").join(file)).unwrap();
        let td = TypedData::from_json_str(&json).unwrap();
        let signer = key(&doc, &case["signerIndex"]);
        let sig = signer.sign_hash(&td.signing_hash().unwrap()).unwrap();
        assert_eq!(
            hex::encode_prefixed(&sig.to_rsv_bytes()),
            str_of(&case["cast"], "signature"),
            "{file}"
        );
    }
}

#[test]
fn permit_helper_matches_cast_signature_of_the_equivalent_typed_data() {
    let doc = golden();
    let case = doc["typedData"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["file"] == "permit.json")
        .unwrap();
    let signer = key(&doc, &case["signerIndex"]);
    let permit = Permit {
        token_name: "Keysmith Test Token".into(),
        token_version: "1".into(),
        chain_id: U256::from_u64(31_337),
        token: Address::parse("0x5FbDB2315678afecb367f032d93F642f64180aa3").unwrap(),
        owner: signer.address(),
        spender: Address::parse("0x70997970C51812dc3A010C7d01b50e0d17dc79C8").unwrap(),
        value: U256::MAX,
        nonce: U256::ZERO,
        deadline: U256::from_u64(4_102_444_800),
    };
    let signed = permit.sign(&signer).unwrap();
    assert_eq!(
        hex::encode_prefixed(&signed.signature.to_rsv_bytes()),
        str_of(&case["cast"], "signature")
    );
}

#[test]
fn mnemonic_derivation_matches_cast() {
    let doc = golden();
    let m = Mnemonic::parse(str_of(&doc, "mnemonic")).unwrap();
    let cases = doc["addresses"].as_array().unwrap();
    assert_eq!(cases.len(), 8);
    for case in cases {
        let seed = m.to_seed(str_of(case, "passphrase"));
        let path = DerivationPath::parse(str_of(case, "path")).unwrap();
        let key = derive_private_key(&seed, &path).unwrap();
        assert_eq!(
            key.address().to_checksum(),
            str_of(case, "address"),
            "{}",
            str_of(case, "path")
        );
    }
}

fn to_rlp(v: &Value) -> Rlp {
    match v {
        Value::String(s) => Rlp::Bytes(hex::decode(s).unwrap()),
        Value::Array(items) => Rlp::List(items.iter().map(to_rlp).collect()),
        other => panic!("unsupported rlp json {other}"),
    }
}

#[test]
fn rlp_matches_cast_to_rlp() {
    let doc = golden();
    for case in doc["rlp"].as_array().unwrap() {
        let value = to_rlp(&case["value"]);
        let encoded = str_of(&case["cast"], "encoded");
        assert_eq!(
            hex::encode_prefixed(&value.encode()),
            encoded,
            "{}",
            str_of(case, "name")
        );
        assert_eq!(Rlp::decode(&hex::decode(encoded).unwrap()).unwrap(), value);
    }
}

#[test]
fn keystore_written_by_cast_wallet_import_decrypts() {
    let doc = golden();
    let case = &doc["keystores"][0];
    let json = std::fs::read_to_string(root().join(str_of(case, "file"))).unwrap();
    let key = keystore::decrypt(
        &json,
        str_of(case, "password").as_bytes(),
        &KdfLimits::default(),
    )
    .unwrap();
    assert_eq!(key.address().to_checksum(), str_of(case, "address"));
    assert_eq!(
        key.address(),
        self::key(&doc, &case["signerIndex"]).address()
    );
    assert!(keystore::decrypt(&json, b"not the password", &KdfLimits::default()).is_err());
}
