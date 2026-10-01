// SPDX-License-Identifier: MIT
//! Official test vectors: BIP-32 vectors 1-5 and the BIP-39 Trezor English vectors.

// Test harness code: an unwrap or panic here is a test failure, which is the intent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use keysmith_core::bip32::{
    Bip32Error, DerivationPath, ExtendedKey, ExtendedPrivateKey, Network, parse_extended_key,
};
use keysmith_core::bip39::Mnemonic;
use keysmith_core::hex;
use serde_json::Value;
use std::path::PathBuf;

fn vectors(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../test-vectors/official")
        .join(name);
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
}

fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or_else(|| panic!("missing {key}"))
}

#[test]
fn bip32_vectors_1_to_4_derive_every_chain() {
    let doc = vectors("bip32.json");
    let mut checked = 0;
    for vector in doc["valid"].as_array().unwrap() {
        let seed = hex::decode(text(vector, "seed")).unwrap();
        let master = ExtendedPrivateKey::master(&seed).unwrap();
        for chain in vector["chains"].as_array().unwrap() {
            let path = DerivationPath::parse(text(chain, "path")).unwrap();
            let key = master.derive_path(&path).unwrap();
            assert_eq!(
                key.to_extended_string(Network::Mainnet).as_str(),
                text(chain, "xprv"),
                "xprv of vector {} {}",
                vector["vector"],
                text(chain, "path")
            );
            assert_eq!(
                key.public().to_extended_string(Network::Mainnet),
                text(chain, "xpub")
            );
            // Both serialisations parse back to the same key.
            let (ExtendedKey::Private(parsed), Network::Mainnet) =
                parse_extended_key(text(chain, "xprv")).unwrap()
            else {
                panic!("xprv did not parse as a mainnet private key");
            };
            assert_eq!(parsed.private_key().address(), key.private_key().address());
            let (ExtendedKey::Public(xpub), _) = parse_extended_key(text(chain, "xpub")).unwrap()
            else {
                panic!("xpub did not parse as a public key");
            };
            assert_eq!(xpub, key.public());
            checked += 1;
        }
    }
    assert_eq!(checked, 17, "vectors 1-4 contain 17 chains");
}

#[test]
fn bip32_public_derivation_matches_vector_1_non_hardened_steps() {
    // m/0H/1 -> m/0H/1/2H is hardened, but m/0H/1/2H/2 -> .../1000000000 is not.
    let doc = vectors("bip32.json");
    let chains = doc["valid"][0]["chains"].as_array().unwrap();
    let (ExtendedKey::Public(parent), _) = parse_extended_key(text(&chains[4], "xpub")).unwrap()
    else {
        panic!("expected xpub");
    };
    let child = parent.derive_child(1_000_000_000).unwrap();
    assert_eq!(
        child.to_extended_string(Network::Mainnet),
        text(&chains[5], "xpub")
    );
}

#[test]
fn bip32_vector_5_rejects_every_invalid_key() {
    let doc = vectors("bip32.json");
    let invalid = doc["invalid"].as_array().unwrap();
    assert_eq!(invalid.len(), 16);
    for case in invalid {
        let reason = text(case, "reason");
        let err = parse_extended_key(text(case, "key"))
            .map(|_| ())
            .unwrap_err();
        let ok = match reason {
            "pubkey version / prvkey mismatch" | "prvkey version / pubkey mismatch" => {
                err == Bip32Error::VersionKeyMismatch
            }
            "invalid pubkey prefix 04" | "invalid prvkey prefix 04" => {
                err == Bip32Error::InvalidKeyPrefix(0x04)
            }
            "invalid pubkey prefix 01" | "invalid prvkey prefix 01" => {
                err == Bip32Error::InvalidKeyPrefix(0x01)
            }
            "zero depth with non-zero parent fingerprint" => err == Bip32Error::ZeroDepthWithParent,
            "zero depth with non-zero index" => err == Bip32Error::ZeroDepthWithIndex,
            "unknown extended key version" => matches!(err, Bip32Error::UnknownVersion(_)),
            "private key 0 not in 1..n-1" | "private key n not in 1..n-1" => {
                err == Bip32Error::InvalidPrivateKey
            }
            r if r.starts_with("invalid pubkey 02") => err == Bip32Error::InvalidPublicKey,
            "invalid checksum" => err == Bip32Error::InvalidChecksum,
            other => panic!("unmapped reason {other}"),
        };
        assert!(ok, "{reason}: got {err:?}");
    }
}

#[test]
fn bip39_trezor_vectors() {
    let doc = vectors("bip39-trezor-english.json");
    let passphrase = text(&doc, "passphrase");
    let list = doc["vectors"].as_array().unwrap();
    assert_eq!(list.len(), 26);
    for v in list {
        let entropy = hex::decode(text(v, "entropy")).unwrap();
        let from_entropy = Mnemonic::from_entropy(&entropy).unwrap();
        assert_eq!(from_entropy.phrase(), text(v, "mnemonic"));
        let parsed = Mnemonic::parse(text(v, "mnemonic")).unwrap();
        assert_eq!(parsed.entropy(), entropy.as_slice());
        let seed = parsed.to_seed(passphrase);
        assert_eq!(hex::encode(seed.as_bytes()), text(v, "seed"));
        let master = ExtendedPrivateKey::from_seed(&seed).unwrap();
        assert_eq!(
            master.to_extended_string(Network::Mainnet).as_str(),
            text(v, "master_xprv")
        );
    }
}

#[test]
fn bip39_passphrase_is_nfkd_normalised() {
    // "é" precomposed (U+00E9) and decomposed (e + U+0301) must yield the same seed.
    let m = Mnemonic::from_entropy(&[0x42; 16]).unwrap();
    assert_eq!(
        m.to_seed("caf\u{e9}").as_bytes(),
        m.to_seed("cafe\u{301}").as_bytes()
    );
    assert_ne!(
        m.to_seed("cafe").as_bytes(),
        m.to_seed("caf\u{e9}").as_bytes()
    );
}

#[test]
fn anvil_default_accounts() {
    // anvil's default mnemonic derives the well-known dev accounts on m/44'/60'/0'/0/i.
    let m = Mnemonic::parse("test test test test test test test test test test test junk").unwrap();
    let seed = m.to_seed("");
    let expected = [
        "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    ];
    for (i, want) in expected.iter().enumerate() {
        let path = DerivationPath::ethereum(u32::try_from(i).unwrap()).unwrap();
        let key = keysmith_core::bip32::derive_private_key(&seed, &path).unwrap();
        assert_eq!(key.address().to_checksum(), *want);
    }
}
