// SPDX-License-Identifier: MIT
//! The fixtures are a pure function of the seed, and every recorded verdict
//! matches the Rust model of the on-chain verifier.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use frost_keccak::evm::{self, EvmGroupKey, EvmSignature};

fn word<const N: usize>(v: &serde_json::Value) -> [u8; N] {
    let s = v.as_str().unwrap();
    hex::decode(s.trim_start_matches("0x"))
        .unwrap()
        .try_into()
        .unwrap()
}

#[test]
fn generation_is_deterministic() {
    assert_eq!(
        fixtures_gen::render().unwrap(),
        fixtures_gen::render().unwrap()
    );
}

#[test]
fn verifier_cases_match_the_rust_model() {
    let doc = fixtures_gen::generate().unwrap();
    let cases = doc["verifierCases"].as_array().unwrap();
    assert_eq!(
        cases.len(),
        doc["verifierCaseCount"].as_u64().unwrap() as usize
    );
    let mut valid = 0;
    for case in cases {
        let key = EvmGroupKey {
            x: word(&case["pubKeyX"]),
            y_parity: u8::try_from(case["pubKeyYParity"].as_u64().unwrap()).unwrap(),
        };
        let sig = EvmSignature {
            r_address: word(&case["rAddr"]),
            z: word(&case["z"]),
        };
        let expected = case["valid"].as_bool().unwrap();
        assert_eq!(
            evm::verify(&key, &word(&case["msgHash"]), &sig),
            expected,
            "{}",
            case["name"]
        );
        valid += usize::from(expected);
    }
    assert_eq!(valid, 4, "exactly the four untampered signatures are valid");
}
