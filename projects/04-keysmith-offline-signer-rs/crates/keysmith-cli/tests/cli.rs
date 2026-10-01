// SPDX-License-Identifier: MIT
//! End-to-end tests of the `keysmith` binary (no network, no Foundry needed).
//!
//! Every signing command is checked byte-for-byte against the outputs Foundry's `cast` 1.8.3
//! recorded in `test-vectors/cast/golden.json`; operator-facing reports are pinned with insta
//! snapshots of `keysmith decode` run on cast-produced transactions.

// Test harness code: an unwrap or panic here is a test failure, which is the intent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use assert_cmd::Command;
use keysmith_core::authorization::SignedAuthorization;
use keysmith_core::envelope::SignedEnvelope;
use keysmith_core::hex;
use predicates::prelude::*;
use serde_json::Value;
use std::path::PathBuf;
use tempfile::TempDir;

const ANVIL_MNEMONIC: &str = "test test test test test test test test test test test junk";
const ANVIL_0: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const ANVIL_1: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const ANVIL_2: &str = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";
/// anvil account 0's private key: a published test key, never funded on a real network.
const ANVIL_0_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

fn keysmith() -> Command {
    Command::new(env!("CARGO_BIN_EXE_keysmith"))
}

fn vectors_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-vectors/cast")
}

fn golden() -> Value {
    serde_json::from_str(&std::fs::read_to_string(vectors_dir().join("golden.json")).unwrap())
        .unwrap()
}

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("missing {key} in {v}"))
}

/// A temporary directory with the anvil mnemonic already written to `mnemonic.txt`.
struct Fixture {
    dir: TempDir,
}

impl Fixture {
    fn new() -> Self {
        let f = Self {
            dir: tempfile::tempdir().unwrap(),
        };
        f.file("mnemonic.txt", &format!("{ANVIL_MNEMONIC}\n"));
        f
    }

    fn file(&self, name: &str, contents: &str) -> PathBuf {
        let p = self.dir.path().join(name);
        std::fs::write(&p, contents).unwrap();
        p
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    fn mnemonic(&self) -> PathBuf {
        self.path("mnemonic.txt")
    }
}

fn stdout_of(cmd: &mut Command) -> String {
    let out = cmd.assert().success().get_output().stdout.clone();
    String::from_utf8(out).unwrap()
}

fn with_key(cmd: &mut Command, f: &Fixture, index: u64) {
    cmd.arg("--mnemonic-file")
        .arg(f.mnemonic())
        .arg("--mnemonic-index")
        .arg(index.to_string());
}

#[test]
fn help_lists_every_command() {
    let help = stdout_of(keysmith().arg("--help"));
    insta::assert_snapshot!("help", help);
}

#[test]
fn mnemonic_generation_and_validation() {
    let f = Fixture::new();
    for words in [12usize, 15, 18, 21, 24] {
        let phrase = stdout_of(keysmith().args(["mnemonic", "new", "--words", &words.to_string()]));
        assert_eq!(phrase.split_whitespace().count(), words);
        let file = f.file(&format!("m{words}.txt"), &phrase);
        keysmith()
            .args(["mnemonic", "validate", "--mnemonic-file"])
            .arg(&file)
            .assert()
            .success()
            .stdout(format!("valid BIP-39 mnemonic ({words} words)\n"));
    }
    keysmith()
        .args(["mnemonic", "new", "--words", "13"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "--words must be 12, 15, 18, 21 or 24",
        ));
    // --out writes the phrase to a new file and refuses to overwrite it.
    let out = f.path("fresh.txt");
    keysmith()
        .args(["mnemonic", "new", "--out"])
        .arg(&out)
        .assert()
        .success()
        .stdout("");
    assert_eq!(
        std::fs::read_to_string(&out)
            .unwrap()
            .split_whitespace()
            .count(),
        24
    );
    keysmith()
        .args(["mnemonic", "new", "--out"])
        .arg(&out)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("cannot create"));
    // A typo is reported by position; the word itself is never echoed.
    let typo = f.file("typo.txt", &ANVIL_MNEMONIC.replace("junk", "junkk"));
    keysmith()
        .args(["mnemonic", "validate", "--mnemonic-file"])
        .arg(&typo)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("word #12").and(predicate::str::contains("junkk").not()));
}

#[test]
fn derive_matches_anvil_accounts_and_cast() {
    let f = Fixture::new();
    let text = stdout_of(
        keysmith()
            .args(["derive", "--count", "3", "--xpub", "--mnemonic-file"])
            .arg(f.mnemonic()),
    );
    for addr in [ANVIL_0, ANVIL_1, ANVIL_2] {
        assert!(text.contains(addr), "{text}");
    }
    let json = stdout_of(
        keysmith()
            .args([
                "derive",
                "--start",
                "1",
                "--count",
                "2",
                "--xpub",
                "--json",
                "--mnemonic-file",
            ])
            .arg(f.mnemonic()),
    );
    insta::assert_snapshot!("derive_json", json);
    // Paths and passphrases cast derived (golden.json `addresses`).
    let doc = golden();
    for case in doc["addresses"].as_array().unwrap() {
        let mut cmd = keysmith();
        cmd.args(["address", "--mnemonic-file"])
            .arg(f.mnemonic())
            .args(["--hd-path", s(case, "path")]);
        if !s(case, "passphrase").is_empty() {
            cmd.arg("--passphrase-file")
                .arg(f.file("pass.txt", &format!("{}\n", s(case, "passphrase"))));
        }
        assert_eq!(stdout_of(&mut cmd), format!("{}\n", s(case, "address")));
    }
    keysmith()
        .args([
            "derive",
            "--start",
            "2147483647",
            "--count",
            "2",
            "--mnemonic-file",
        ])
        .arg(f.mnemonic())
        .assert()
        .code(1)
        .stderr(predicate::str::contains("exceeds 2^31"));
}

#[test]
fn every_key_source_resolves_to_the_same_address() {
    let f = Fixture::new();
    let pk = f.file("pk.txt", &format!("{ANVIL_0_KEY}\n"));
    keysmith()
        .args(["address", "--private-key-file"])
        .arg(&pk)
        .assert()
        .success()
        .stdout(format!("{ANVIL_0}\n"));
    let mut by_index = keysmith();
    by_index.arg("address");
    with_key(&mut by_index, &f, 1);
    assert_eq!(stdout_of(&mut by_index), format!("{ANVIL_1}\n"));
    keysmith()
        .args(["address", "--private-key-file"])
        .arg(&pk)
        .args(["--expect-address", ANVIL_1])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("does not match --expect-address"));
    // Mutually exclusive sources and mnemonic-only options are rejected by the parser.
    keysmith()
        .args(["address", "--private-key-file"])
        .arg(&pk)
        .arg("--mnemonic-file")
        .arg(f.mnemonic())
        .assert()
        .code(2);
    // Regression: options of another key source must be rejected, never silently ignored
    // (clap alone treats `requires` as satisfied inside an exclusive group).
    for extra in [["--mnemonic-index", "1"], ["--hd-path", "m/0"]] {
        keysmith()
            .args(["address", "--private-key-file"])
            .arg(&pk)
            .args(extra)
            .assert()
            .code(2);
    }
    for flag in ["--passphrase-file", "--password-file"] {
        keysmith()
            .args(["address", "--private-key-file"])
            .arg(&pk)
            .arg(flag)
            .arg(&pk)
            .assert()
            .code(2);
    }
    let mut mixed = keysmith();
    mixed.args(["address", "--password-file"]).arg(&pk);
    with_key(&mut mixed, &f, 0);
    mixed.assert().code(2);
}

#[test]
fn secrets_cannot_be_passed_on_the_command_line_and_are_never_echoed() {
    let f = Fixture::new();
    // There is deliberately no --private-key / --mnemonic flag taking a secret inline.
    keysmith()
        .args(["address", "--private-key", ANVIL_0_KEY])
        .assert()
        .code(2);
    // A malformed key file: the error names the problem, not the content.
    let bad = f.file("bad.txt", &ANVIL_0_KEY[..60]);
    keysmith()
        .args(["address", "--private-key-file"])
        .arg(&bad)
        .assert()
        .code(1)
        .stderr(
            predicate::str::contains("32 bytes")
                .and(predicate::str::contains(&ANVIL_0_KEY[2..20]).not()),
        );
    // Mnemonic with a bad checksum: no word appears in the error.
    let wrong = f.file("wrong.txt", &ANVIL_MNEMONIC.replace("junk", "test"));
    keysmith()
        .args(["address", "--mnemonic-file"])
        .arg(&wrong)
        .assert()
        .code(1)
        .stderr(
            predicate::str::contains("checksum").and(predicate::str::contains("test test").not()),
        );
}

#[test]
fn keystore_export_inspect_and_reload() {
    let f = Fixture::new();
    let pw = f.file("pw.txt", "correct horse battery staple\n");
    let ks = f.path("ks.json");
    let mut export = keysmith();
    export
        .args(["keystore", "export", "--scrypt-log-n", "10", "--out"])
        .arg(&ks)
        .arg("--new-password-file")
        .arg(&pw);
    with_key(&mut export, &f, 2);
    assert_eq!(stdout_of(&mut export), format!("{ANVIL_2}\n"));
    let json = std::fs::read_to_string(&ks).unwrap();
    assert!(!json.contains("5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"));
    let info: Value = serde_json::from_str(&stdout_of(
        keysmith().args(["keystore", "inspect"]).arg(&ks),
    ))
    .unwrap();
    assert_eq!(info["address"], ANVIL_2);
    assert_eq!(info["kdf"]["kdf"], "scrypt");
    assert_eq!(info["kdf"]["n"], 1024);
    keysmith()
        .args(["address", "--keystore"])
        .arg(&ks)
        .arg("--password-file")
        .arg(&pw)
        .assert()
        .success()
        .stdout(format!("{ANVIL_2}\n"));
    let wrong = f.file("wrong.txt", "correct horse battery stapler\n");
    keysmith()
        .args(["address", "--keystore"])
        .arg(&ks)
        .arg("--password-file")
        .arg(&wrong)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("MAC mismatch"));
    // Refuses to overwrite and refuses an empty password.
    let mut again = keysmith();
    again
        .args(["keystore", "export", "--scrypt-log-n", "10", "--out"])
        .arg(&ks)
        .arg("--new-password-file")
        .arg(&pw);
    with_key(&mut again, &f, 2);
    again
        .assert()
        .code(1)
        .stderr(predicate::str::contains("cannot create"));
    let empty = f.file("empty.txt", "\n");
    let mut no_pw = keysmith();
    no_pw
        .args(["keystore", "export", "--scrypt-log-n", "10", "--out"])
        .arg(f.path("other.json"))
        .arg("--new-password-file")
        .arg(&empty);
    with_key(&mut no_pw, &f, 2);
    no_pw
        .assert()
        .code(1)
        .stderr(predicate::str::contains("empty password"));
}

#[test]
fn keystore_written_by_cast_wallet_import_loads() {
    let doc = golden();
    let case = &doc["keystores"][0];
    let f = Fixture::new();
    let pw = f.file("pw.txt", s(case, "password"));
    keysmith()
        .args(["address", "--keystore"])
        .arg(vectors_dir().join(s(case, "file")))
        .arg("--password-file")
        .arg(&pw)
        .assert()
        .success()
        .stdout(format!("{}\n", s(case, "address")));
}

/// Writes the unsigned envelope of a golden case (with its sponsored authorizations, which cast
/// received as `--auth <rlp>`) and returns its path.
fn golden_envelope(f: &Fixture, case: &Value) -> PathBuf {
    let mut env = case["envelope"].clone();
    let auths: Vec<Value> = case["sponsoredAuthorizations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| {
            let auth = SignedAuthorization::decode(&hex::decode(s(a, "castRlp")).unwrap()).unwrap();
            serde_json::to_value(auth).unwrap()
        })
        .collect();
    if !auths.is_empty() {
        env["tx"]["authorizationList"] = Value::Array(auths);
    }
    f.file(&format!("{}.json", s(case, "name")), &env.to_string())
}

#[test]
fn sign_reproduces_cast_mktx_byte_for_byte() {
    let doc = golden();
    let f = Fixture::new();
    let cases = doc["transactions"].as_array().unwrap();
    assert_eq!(cases.len(), 11);
    // Two cases deploy contracts, which the default policy refuses.
    let policy = f.file("creation.json", r#"{"allowContractCreation":true}"#);
    for case in cases {
        let envelope = golden_envelope(&f, case);
        let index = case["signerIndex"].as_u64().unwrap();
        let mut raw = keysmith();
        raw.args(["sign", "--yes", "--format", "raw", "--envelope"])
            .arg(&envelope)
            .arg("--policy")
            .arg(&policy);
        with_key(&mut raw, &f, index);
        assert_eq!(
            stdout_of(&mut raw).trim(),
            s(&case["cast"], "raw"),
            "{}",
            s(case, "name")
        );
        let mut json = keysmith();
        json.args(["sign", "--yes", "--envelope"])
            .arg(&envelope)
            .arg("--policy")
            .arg(&policy);
        with_key(&mut json, &f, index);
        let signed = SignedEnvelope::from_json_str(&stdout_of(&mut json)).unwrap();
        assert_eq!(signed.hash, s(&case["cast"], "hash"));
        assert_eq!(
            signed.verify().unwrap().encoded(),
            hex::decode(s(&case["cast"], "raw")).unwrap()
        );
    }
}

#[test]
fn sign_reads_stdin_writes_files_and_prints_a_review() {
    let doc = golden();
    let case = &doc["transactions"][4];
    let f = Fixture::new();
    let envelope = std::fs::read_to_string(golden_envelope(&f, case)).unwrap();
    let out = f.path("signed.json");
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--envelope", "-", "--out"])
        .arg(&out)
        .write_stdin(envelope);
    with_key(&mut cmd, &f, 0);
    let assert = cmd
        .assert()
        .success()
        .stdout(format!("{}\n", s(&case["cast"], "hash")));
    let review = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
    insta::assert_snapshot!("sign_review_eip1559", review);
    let written = SignedEnvelope::from_json_str(&std::fs::read_to_string(&out).unwrap()).unwrap();
    assert_eq!(written.raw, s(&case["cast"], "raw"));
}

#[test]
fn refusals_exit_with_code_3_and_produce_nothing() {
    let f = Fixture::new();
    let tx = |gas: &str, value: &str| {
        format!(
            r#"{{"format":"keysmith/unsigned-tx@1","tx":{{"type":"eip1559","chainId":"1","nonce":"0","gasLimit":"{gas}",
               "maxFeePerGas":"30000000000","maxPriorityFeePerGas":"1000000000","to":"{ANVIL_1}","value":"{value}"}}}}"#
        )
    };
    let low_gas = f.file("low.json", &tx("20999", "1"));
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--envelope"]).arg(&low_gas);
    with_key(&mut cmd, &f, 0);
    cmd.assert().code(3).stdout("").stderr(
        predicate::str::contains("REFUSED")
            .and(predicate::str::contains("below the minimum 21000")),
    );
    let policy = f.file(
        "policy.json",
        &format!(r#"{{"allowedChainIds":[1],"allowedRecipients":["{ANVIL_1}"],"maxValueWei":"1000000000000000000"}}"#),
    );
    let too_much = f.file("big.json", &tx("21000", "1000000000000000001"));
    let out = f.path("never.json");
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--envelope"])
        .arg(&too_much)
        .arg("--policy")
        .arg(&policy)
        .arg("--out")
        .arg(&out);
    with_key(&mut cmd, &f, 0);
    cmd.assert()
        .code(3)
        .stderr(predicate::str::contains("[maxValueWei]"));
    assert!(
        !out.exists(),
        "a refused signature must not leave a file behind"
    );
    // Within policy: signs.
    let ok = f.file("ok.json", &tx("21000", "1000000000000000000"));
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--format", "raw", "--envelope"])
        .arg(&ok)
        .arg("--policy")
        .arg(&policy);
    with_key(&mut cmd, &f, 0);
    cmd.assert().success();
    // A typo in the policy file is an error, not a silently disabled limit.
    let typo = f.file("typo.json", r#"{"maxValeuWei":"1"}"#);
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--envelope"])
        .arg(&ok)
        .arg("--policy")
        .arg(&typo);
    with_key(&mut cmd, &f, 0);
    cmd.assert()
        .code(1)
        .stderr(predicate::str::contains("unknown field"));
    // The envelope names another signer.
    let other = f.file(
        "from.json",
        &tx("21000", "1").replacen("\"tx\"", &format!("\"from\":\"{ANVIL_2}\",\"tx\""), 1),
    );
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--envelope"]).arg(&other);
    with_key(&mut cmd, &f, 0);
    cmd.assert()
        .code(1)
        .stderr(predicate::str::contains("expects signer"));
}

#[test]
fn sign_auth_matches_cast_and_applies_the_self_executor_rule() {
    let doc = golden();
    let f = Fixture::new();
    for case in doc["authorizations"].as_array().unwrap() {
        let any_chain = s(case, "chainId") == "0";
        let mut cmd = keysmith();
        cmd.args([
            "sign-auth",
            "--yes",
            "--chain-id",
            s(case, "chainId"),
            "--address",
            s(case, "address"),
            "--nonce",
            s(case, "nonce"),
        ]);
        if any_chain {
            // The default policy refuses chainId-0 delegations; cast's vector needs the escape.
            cmd.arg("--no-policy");
        }
        with_key(&mut cmd, &f, case["signerIndex"].as_u64().unwrap());
        let assert = cmd
            .assert()
            .success()
            .stdout(format!("{}\n", s(&case["cast"], "rlp")));
        let stderr = String::from_utf8(assert.get_output().stderr.clone()).unwrap();
        assert_eq!(
            s(case, "chainId") == "0",
            stderr.contains("valid on EVERY EVM chain"),
            "{stderr}"
        );
    }
    // `--executor self` signs nonce + 1: current nonce 4 reproduces cast's nonce-5 tuple.
    let chain1 = &doc["authorizations"][0];
    assert_eq!(s(chain1, "nonce"), "5");
    let mut cmd = keysmith();
    cmd.args([
        "sign-auth",
        "--yes",
        "--chain-id",
        "1",
        "--address",
        s(chain1, "address"),
        "--nonce",
        "4",
        "--executor",
        "self",
        "--json",
    ]);
    with_key(&mut cmd, &f, 0);
    let json: Value = serde_json::from_str(&stdout_of(&mut cmd)).unwrap();
    assert_eq!(json["rlp"], s(&chain1["cast"], "rlp"));
    assert_eq!(json["authorization"]["nonce"], "5");
    assert_eq!(json["executor"], "self");
    assert_eq!(json["authority"], ANVIL_0);
    // The policy forbids any-chain delegations by default, with an empty policy file and with
    // no policy file at all.
    let policy = f.file("p.json", "{}");
    for extra in [vec!["--policy", policy.to_str().unwrap()], vec![]] {
        let mut cmd = keysmith();
        cmd.args([
            "sign-auth",
            "--yes",
            "--chain-id",
            "0",
            "--address",
            s(chain1, "address"),
            "--nonce",
            "0",
        ])
        .args(&extra);
        with_key(&mut cmd, &f, 0);
        cmd.assert()
            .code(3)
            .stdout("")
            .stderr(predicate::str::contains("[allowAnyChainAuthorizations]"));
    }
}

#[test]
fn personal_sign_matches_cast_and_verifies() {
    let doc = golden();
    let f = Fixture::new();
    for case in doc["messages"].as_array().unwrap() {
        let msg = &case["message"];
        let input: Vec<String> = match (msg.get("utf8"), msg.get("hex")) {
            (Some(Value::String(t)), _) => vec!["--message".into(), t.clone()],
            (_, Some(Value::String(h))) => vec!["--hex".into(), h.clone()],
            _ => panic!("bad case"),
        };
        let index = case["signerIndex"].as_u64().unwrap();
        let mut cmd = keysmith();
        cmd.args(["sign-message", "--yes"]).args(&input);
        with_key(&mut cmd, &f, index);
        let sig = stdout_of(&mut cmd);
        assert_eq!(
            sig.trim(),
            s(&case["cast"], "signature"),
            "{}",
            s(case, "name")
        );
        let signer = [ANVIL_0, ANVIL_1, ANVIL_2][usize::try_from(index).unwrap()];
        keysmith()
            .arg("verify-message")
            .args(&input)
            .args(["--address", signer, "--signature", sig.trim()])
            .assert()
            .success()
            .stdout(format!("valid signature by {signer}\n"));
    }
    // A file holding the same bytes signs identically.
    let file = f.file("msg.bin", "hello world");
    let mut cmd = keysmith();
    cmd.args(["sign-message", "--yes", "--message-file"])
        .arg(&file);
    with_key(&mut cmd, &f, 0);
    assert_eq!(
        stdout_of(&mut cmd).trim(),
        s(&doc["messages"][0]["cast"], "signature")
    );
    keysmith()
        .args([
            "verify-message",
            "--message",
            "hello world!",
            "--address",
            ANVIL_0,
            "--signature",
        ])
        .arg(s(&doc["messages"][0]["cast"], "signature"))
        .assert()
        .code(1)
        .stderr(predicate::str::contains("not 0xf39F"));
}

#[test]
fn typed_data_and_permit_match_cast() {
    let doc = golden();
    let f = Fixture::new();
    for case in doc["typedData"].as_array().unwrap() {
        let file = vectors_dir().join("typed-data").join(s(case, "file"));
        let mut cmd = keysmith();
        cmd.args(["sign-typed-data", "--yes", "--file"]).arg(&file);
        with_key(&mut cmd, &f, case["signerIndex"].as_u64().unwrap());
        assert_eq!(
            stdout_of(&mut cmd).trim(),
            s(&case["cast"], "signature"),
            "{}",
            s(case, "file")
        );
    }
    let hashes = stdout_of(
        keysmith()
            .args(["hash-typed-data", "--file"])
            .arg(vectors_dir().join("typed-data/mail.json")),
    );
    insta::assert_snapshot!("hash_typed_data_mail", hashes);
    // The permit helper signs the same digest as cast does for the equivalent typed data.
    let permit = doc["typedData"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["file"] == "permit.json")
        .unwrap();
    let mut cmd = keysmith();
    cmd.args([
        "permit",
        "--yes",
        "--token",
        "0x5FbDB2315678afecb367f032d93F642f64180aa3",
        "--name",
        "Keysmith Test Token",
        "--chain-id",
        "31337",
        "--spender",
        ANVIL_1,
        "--value",
        "115792089237316195423570985008687907853269984665640564039457584007913129639935",
        "--nonce",
        "0",
        "--deadline",
        "4102444800",
        "--json",
    ]);
    with_key(&mut cmd, &f, 0);
    let out: Value = serde_json::from_str(&stdout_of(&mut cmd)).unwrap();
    assert_eq!(out["signature"], s(&permit["cast"], "signature"));
    assert_eq!(out["owner"], ANVIL_0);
    // A typed-data file with a field the type does not declare is refused (it would be shown
    // to the operator but not signed).
    let mut doc_mail: Value = serde_json::from_str(
        &std::fs::read_to_string(vectors_dir().join("typed-data/mail.json")).unwrap(),
    )
    .unwrap();
    doc_mail["message"]["amount"] = Value::from("1000000");
    let tampered = f.file("tampered.json", &doc_mail.to_string());
    let mut cmd = keysmith();
    cmd.args(["sign-typed-data", "--yes", "--file"])
        .arg(&tampered);
    with_key(&mut cmd, &f, 0);
    cmd.assert()
        .code(1)
        .stderr(predicate::str::contains("undeclared member `amount`"));
}

#[test]
fn decode_reports_for_every_cast_transaction() {
    let doc = golden();
    for case in doc["transactions"].as_array().unwrap() {
        let name = s(case, "name");
        let raw = s(&case["cast"], "raw");
        let text = stdout_of(keysmith().args(["decode", raw, "--base-fee", "7gwei"]));
        insta::assert_snapshot!(format!("decode_{name}"), text);
        let json: Value =
            serde_json::from_str(&stdout_of(keysmith().args(["decode", "--json", raw]))).unwrap();
        assert_eq!(json["hash"], s(&case["cast"], "hash"), "{name}");
        assert_eq!(
            json["signer"].as_str().unwrap().to_ascii_lowercase(),
            s(&case["cast"], "signer"),
            "{name}: signer recovered by keysmith differs from cast decode-tx"
        );
    }
}

#[test]
fn decode_accepts_envelopes_and_rejects_malleable_bytes() {
    let doc = golden();
    let f = Fixture::new();
    let case = &doc["transactions"][0];
    let raw = s(&case["cast"], "raw");
    let env = format!(
        r#"{{"format":"keysmith/signed-tx@1","type":"legacy","from":"{ANVIL_0}","hash":"{}","raw":"{raw}"}}"#,
        s(&case["cast"], "hash")
    );
    let file = f.file("signed.json", &env);
    let from_file = stdout_of(keysmith().args(["decode", "--file"]).arg(&file));
    assert_eq!(from_file, stdout_of(keysmith().args(["decode", raw])));
    // Trailing byte.
    keysmith()
        .args(["decode", &format!("{raw}00")])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("trailing bytes"));
    // Blob transactions are out of scope.
    keysmith()
        .args(["decode", "0x03c0"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "unsupported transaction type 0x03",
        ));
    // A high-s twin decodes, but the report flags it and recovers no signer.
    let signed = keysmith_core::tx::SignedTransaction::decode(&hex::decode(raw).unwrap()).unwrap();
    let mut twin = signed.clone();
    twin.signature.s = keysmith_core::keys::CURVE_ORDER
        .checked_sub(&signed.signature.s)
        .unwrap();
    twin.signature.y_parity = !signed.signature.y_parity;
    let json: Value = serde_json::from_str(&stdout_of(keysmith().args([
        "decode",
        "--json",
        &hex::encode_prefixed(&twin.encoded()),
    ])))
    .unwrap();
    assert_eq!(json["signature"]["lowS"], false);
    assert_eq!(json["signer"], Value::Null);
    assert!(json["signerError"].as_str().unwrap().contains("EIP-2"));
}

/// A minimal EIP-1559 envelope on chain 1; `tx_extra` and `top_extra` are spliced in as
/// additional JSON members of `tx` and of the envelope.
fn envelope_json(tx_extra: &str, top_extra: &str) -> String {
    format!(
        r#"{{"format":"keysmith/unsigned-tx@1"{top_extra},"tx":{{"type":"eip1559","chainId":"1","nonce":"0",
           "gasLimit":"100000","maxFeePerGas":"30000000000","maxPriorityFeePerGas":"1000000000"{tx_extra}}}}}"#
    )
}

fn stderr_of(assert: &assert_cmd::assert::Assert) -> String {
    String::from_utf8(assert.get_output().stderr.clone()).unwrap()
}

/// Regression: the review used to be printed after the signature was made, with no way to
/// decline. Now every signing command reviews, then asks, and a non-interactive caller that did
/// not pass --yes gets the review and nothing else.
#[test]
fn signing_waits_for_confirmation_and_never_signs_unattended() {
    let f = Fixture::new();
    let env = f.file(
        "env.json",
        &envelope_json(&format!(r#","to":"{ANVIL_1}""#), ""),
    );
    let out = f.path("signed.json");
    let mut cmd = keysmith();
    cmd.args(["sign", "--envelope"])
        .arg(&env)
        .arg("--out")
        .arg(&out);
    with_key(&mut cmd, &f, 0);
    // assert_cmd connects stdin to a pipe, not a terminal, so keysmith cannot ask.
    cmd.assert().code(1).stdout("").stderr(
        predicate::str::contains("--- keysmith sign: review (nothing is signed until you confirm)")
            .and(predicate::str::contains("re-run with --yes")),
    );
    assert!(!out.exists(), "nothing may be written without confirmation");
    let mail = vectors_dir().join("typed-data/mail.json");
    let others: [Vec<String>; 4] = [
        vec!["sign-message".into(), "--message".into(), "hi".into()],
        [
            "sign-auth",
            "--chain-id",
            "1",
            "--address",
            ANVIL_2,
            "--nonce",
            "0",
        ]
        .map(String::from)
        .to_vec(),
        vec![
            "sign-typed-data".into(),
            "--file".into(),
            mail.to_str().unwrap().into(),
        ],
        [
            "permit",
            "--token",
            ANVIL_2,
            "--name",
            "T",
            "--chain-id",
            "1",
            "--spender",
            ANVIL_1,
            "--value",
            "1",
            "--nonce",
            "0",
            "--deadline",
            "1",
        ]
        .map(String::from)
        .to_vec(),
    ];
    for args in others {
        let mut cmd = keysmith();
        cmd.args(&args);
        with_key(&mut cmd, &f, 0);
        cmd.assert().code(1).stdout("").stderr(
            predicate::str::contains(format!("--- keysmith {}: review", args[0]))
                .and(predicate::str::contains("re-run with --yes")),
        );
    }
}

/// Regression: without --policy no policy applied at all, so contract creations, pre-EIP-155
/// legacy transactions and chainId-0 delegations were signed with only a warning.
#[test]
fn the_default_policy_applies_without_a_policy_file() {
    let f = Fixture::new();
    let sign = |env: &PathBuf, extra: &[&str]| {
        let mut cmd = keysmith();
        cmd.args(["sign", "--yes", "--format", "raw", "--envelope"])
            .arg(env)
            .args(extra);
        with_key(&mut cmd, &f, 0);
        cmd.assert()
    };
    let create = f.file(
        "create.json",
        &envelope_json(r#","to":null,"input":"0x6000""#, ""),
    );
    sign(&create, &[]).code(3).stdout("").stderr(
        predicate::str::contains("REFUSED")
            .and(predicate::str::contains("[allowContractCreation]")),
    );
    sign(&create, &["--no-policy"]).success();
    let legacy = f.file(
        "legacy.json",
        &format!(
            r#"{{"format":"keysmith/unsigned-tx@1","tx":{{"type":"legacy","nonce":"0","gasLimit":"21000",
               "gasPrice":"1000000000","to":"{ANVIL_1}"}}}}"#
        ),
    );
    sign(&legacy, &[])
        .code(3)
        .stderr(predicate::str::contains("[allowUnprotectedLegacy]"));
    sign(&legacy, &["--no-policy"]).success().stderr(
        predicate::str::contains("no-replay-protection")
            .and(predicate::str::contains("NONE (--no-policy)")),
    );
    let any_chain = f.file(
        "any.json",
        &format!(
            r#"{{"format":"keysmith/unsigned-tx@1","tx":{{"type":"eip7702","chainId":"1","nonce":"0",
               "gasLimit":"100000","maxFeePerGas":"2","maxPriorityFeePerGas":"1","to":"{ANVIL_0}"}},
               "selfAuthorizations":[{{"chainId":"0","address":"{ANVIL_2}"}}]}}"#
        ),
    );
    sign(&any_chain, &[])
        .code(3)
        .stderr(predicate::str::contains("[allowAnyChainAuthorizations]"));
    let p = f.file("p.json", "{}");
    sign(&create, &["--no-policy", "--policy", p.to_str().unwrap()]).code(2);
}

/// Regression: the review printed only "input 68 bytes", so an online machine could swap
/// `transfer(alice, 1)` for `approve(attacker, MAX)` on an allowed token unnoticed, and the
/// envelope note ("shown to the operator") was never printed at all.
#[test]
fn the_review_shows_calldata_authorities_and_the_untrusted_note() {
    let f = Fixture::new();
    let usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    let approve = format!("0x095ea7b3{:0>64}{}", "dead", "f".repeat(64));
    // The note tries to forge a "findings none" line of its own.
    let env = f.file(
        "approve.json",
        &envelope_json(
            &format!(r#","to":"{usdc}","input":"{approve}""#),
            r#","note":"pay alice 1 USDC\nfindings        none""#,
        ),
    );
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--envelope"]).arg(&env);
    with_key(&mut cmd, &f, 0);
    let review = stderr_of(&cmd.assert().success());
    for expected in [
        "selector 0x095ea7b3 = ERC-20 approve(address,uint256)".to_owned(),
        format!(
            "APPROVE 0x000000000000000000000000000000000000dEaD to spend {} (2^256-1: UNLIMITED) base units",
            keysmith_core::U256::MAX
        ),
        format!("{:<16}0x095ea7b3", "calldata"),
        format!("  {:0>64}", "dead"),
        format!("  {}", "f".repeat(64)),
        r#"UNTRUSTED text from the envelope author, not a description of what is signed: "pay alice 1 USDC\u{a}findings        none""#.to_owned(),
    ] {
        assert!(review.contains(&expected), "missing {expected:?} in\n{review}");
    }
    assert_eq!(
        review.lines().filter(|l| l.starts_with("findings")).count(),
        1,
        "the note must not be able to add a review line:\n{review}"
    );

    // A type-4 transaction with an access list, a sponsored authorization, a self-executed one
    // and calldata: every part of it appears in the review.
    let doc = golden();
    let case = doc["transactions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "eip7702-sponsored-and-self-with-access-list")
        .unwrap();
    let path = golden_envelope(&f, case);
    let mut env: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    env["note"] = Value::from("delegate to the batch executor");
    env["tx"]["input"] = Value::from(format!(
        "0xa9059cbb{:0>64}{:0>64}",
        ANVIL_2[2..].to_ascii_lowercase(),
        "64"
    ));
    let path = f.file("7702.json", &env.to_string());
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--envelope"]).arg(&path);
    with_key(&mut cmd, &f, case["signerIndex"].as_u64().unwrap());
    insta::assert_snapshot!("sign_review_eip7702", stderr_of(&cmd.assert().success()));
}

/// Regression: two self-authorizations were both signed at `tx.nonce + 1`, so the second was
/// skipped on every node (see the anvil e2e for the on-chain proof).
#[test]
fn several_self_authorizations_are_signed_at_consecutive_nonces() {
    let f = Fixture::new();
    let env = f.file(
        "two.json",
        &format!(
            r#"{{"format":"keysmith/unsigned-tx@1","tx":{{"type":"eip7702","chainId":"1","nonce":"4",
               "gasLimit":"100000","maxFeePerGas":"2","maxPriorityFeePerGas":"1","to":"{ANVIL_0}"}},
               "selfAuthorizations":[{{"chainId":"1","address":"{ANVIL_1}"}},{{"chainId":"1","address":"{ANVIL_2}"}}]}}"#
        ),
    );
    let mut cmd = keysmith();
    cmd.args(["sign", "--yes", "--format", "raw", "--envelope"])
        .arg(&env);
    with_key(&mut cmd, &f, 0);
    let assert = cmd.assert().success();
    assert!(stderr_of(&assert).contains("authorization-duplicate-authority"));
    let raw = String::from_utf8(assert.get_output().stdout.clone()).unwrap();
    let signed =
        keysmith_core::tx::SignedTransaction::decode(&hex::decode(raw.trim()).unwrap()).unwrap();
    let auths = signed.tx.authorization_list();
    assert_eq!(auths.iter().map(|a| a.nonce).collect::<Vec<_>>(), [5, 6]);
    for a in auths {
        assert_eq!(a.recover_authority().unwrap().to_checksum(), ANVIL_0);
    }
}

/// Regression: sign-typed-data and permit printed only the signature and accepted no policy,
/// so a dApp-supplied unlimited permit to any spender on any chain was signed blind.
#[test]
fn typed_data_is_reviewed_and_policy_checked_before_signing() {
    let f = Fixture::new();
    let mail = vectors_dir().join("typed-data/mail.json");
    let mut cmd = keysmith();
    cmd.args(["sign-typed-data", "--yes", "--file"]).arg(&mail);
    with_key(&mut cmd, &f, 1);
    insta::assert_snapshot!(
        "sign_typed_data_review_mail",
        stderr_of(&cmd.assert().success())
    );
    // allowedChainIds applies to the domain's chainId.
    let chains = f.file("chains.json", r#"{"allowedChainIds":[31337]}"#);
    let mut cmd = keysmith();
    cmd.args(["sign-typed-data", "--yes", "--file"])
        .arg(&mail)
        .arg("--policy")
        .arg(&chains);
    with_key(&mut cmd, &f, 1);
    cmd.assert().code(3).stdout("").stderr(
        predicate::str::contains("[allowedChainIds]")
            .and(predicate::str::contains("chain id 1 is not allowed")),
    );

    let token = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
    let policy = f.file(
        "permit-policy.json",
        &format!(
            r#"{{"allowedChainIds":[31337],"allowedVerifyingContracts":["{token}"],
               "allowedSpenders":["{ANVIL_2}"],"maxPermitValue":"1000000"}}"#
        ),
    );
    let permit = |spender: &str, value: &str, extra: &[&str]| {
        let mut cmd = keysmith();
        cmd.args([
            "permit",
            "--yes",
            "--token",
            token,
            "--name",
            "Keysmith Test Token",
            "--chain-id",
            "31337",
            "--spender",
            spender,
            "--value",
            value,
            "--nonce",
            "0",
            "--deadline",
            "4102444800",
        ])
        .args(extra);
        with_key(&mut cmd, &f, 0);
        cmd.assert()
    };
    let max = keysmith_core::U256::MAX.to_string();
    permit(ANVIL_1, &max, &["--policy", policy.to_str().unwrap()])
        .code(3)
        .stdout("")
        .stderr(
            predicate::str::contains("[allowedSpenders]")
                .and(predicate::str::contains("[maxPermitValue]")),
        );
    // Within the policy it signs, after a review of every field.
    let review =
        stderr_of(&permit(ANVIL_2, "1000000", &["--policy", policy.to_str().unwrap()]).success());
    for expected in [
        "--- keysmith permit: review (nothing is signed until you confirm) ---".to_owned(),
        "primary type    Permit".to_owned(),
        format!("  spender (address): {ANVIL_2}"),
        "  value (uint256): 1000000".to_owned(),
        format!("  verifyingContract (address): {token}"),
        "typed-data-far-deadline".to_owned(),
    ] {
        assert!(
            review.contains(&expected),
            "missing {expected:?} in\n{review}"
        );
    }
    // Without a restricting policy an unlimited permit still signs, but it is flagged.
    let review = stderr_of(&permit(ANVIL_1, &max, &[]).success());
    assert!(review.contains("typed-data-max-uint"), "{review}");
}

#[cfg(unix)]
#[test]
fn secret_files_are_created_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    let phrase = f.path("phrase.txt");
    keysmith()
        .args(["mnemonic", "new", "--out"])
        .arg(&phrase)
        .assert()
        .success();
    assert_eq!(mode(&phrase), 0o600);
    let pw = f.file("pw.txt", "correct horse battery staple\n");
    let ks = f.path("ks.json");
    let mut export = keysmith();
    export
        .args(["keystore", "export", "--scrypt-log-n", "10", "--out"])
        .arg(&ks)
        .arg("--new-password-file")
        .arg(&pw);
    with_key(&mut export, &f, 2);
    export.assert().success();
    assert_eq!(mode(&ks), 0o600);
}
