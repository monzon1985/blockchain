// SPDX-License-Identifier: MIT
//! Tests of the `keysmith-relay` binary against an in-process mock JSON-RPC node.
//!
//! The mock is a minimal HTTP/1.1 server on an ephemeral port (`127.0.0.1:0`): it answers each
//! request from a method -> response table and records every request, so the tests can assert
//! not only what the relay printed but also what it did (or did not) send to the node.

// Test harness code: an unwrap or panic here is a test failure, which is the intent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use assert_cmd::Command;
use keysmith_core::envelope::{SignedEnvelope, UnsignedEnvelope, sign_envelope};
use keysmith_core::hash::keccak256;
use keysmith_core::{Address, PrivateKey, hex};
use predicates::prelude::*;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

type Handler = dyn Fn(&str, &Value) -> Value + Send + Sync;

/// A JSON-RPC node that answers from `handler(method, params)`; the result is wrapped in a
/// response unless the handler returns an object with an `error` key.
struct MockNode {
    url: String,
    requests: Arc<Mutex<Vec<Value>>>,
}

fn read_request(stream: &mut TcpStream) -> Option<Value> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut length = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse::<usize>().ok();
        }
    }
    let mut body = vec![0u8; length.expect("mock node only supports Content-Length bodies")];
    reader.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}

impl MockNode {
    fn start(handler: Box<Handler>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&requests);
        // The thread ends with the test process; it holds no resources beyond the socket.
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let Some(request) = read_request(&mut stream) else {
                    continue;
                };
                log.lock().unwrap().push(request.clone());
                let method = request["method"].as_str().unwrap_or_default().to_owned();
                let answer = handler(&method, &request["params"]);
                let body = if answer.get("error").is_some() {
                    json!({"jsonrpc": "2.0", "id": request["id"], "error": answer["error"]})
                } else {
                    json!({"jsonrpc": "2.0", "id": request["id"], "result": answer})
                }
                .to_string();
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        Self { url, requests }
    }

    fn methods(&self) -> Vec<String> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(|r| r["method"].as_str().unwrap().to_owned())
            .collect()
    }
}

const FROM: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const TO: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const DELEGATE: &str = "0x5FbDB2315678afecb367f032d93F642f64180aa3";

/// A node on chain 31337 with fixed fee and nonce answers.
/// `eth_estimateGas` answers 21000 for a plain transfer and 30000 when there is calldata.
fn anvil_like(method: &str, params: &Value) -> Value {
    match method {
        "eth_chainId" => json!("0x7a69"),
        "eth_getTransactionCount" => json!("0x5"),
        "eth_gasPrice" => json!("0x77359400"),
        "eth_maxPriorityFeePerGas" => json!("0x3b9aca00"),
        "eth_getBlockByNumber" => json!({"number": "0x9", "baseFeePerGas": "0x3b9aca00"}),
        "eth_estimateGas" if params[0]["data"] == "0x" => json!("0x5208"),
        "eth_estimateGas" => json!("0x7530"),
        other => {
            json!({"error": {"code": -32601, "message": format!("method {other} not mocked")}})
        }
    }
}

fn relay(node: &MockNode) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_keysmith-relay"));
    cmd.args(["--rpc-url", &node.url, "--timeout-secs", "10"]);
    cmd
}

fn stdout(cmd: &mut Command) -> String {
    String::from_utf8(cmd.assert().success().get_output().stdout.clone()).unwrap()
}

fn anvil_key() -> PrivateKey {
    PrivateKey::from_hex("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
        .unwrap()
}

#[test]
fn prepare_fills_chain_state_and_the_result_signs() {
    let node = MockNode::start(Box::new(anvil_like));
    let json = stdout(relay(&node).args([
        "prepare", "--type", "eip1559", "--from", FROM, "--to", TO, "--value", "1.5ether",
        "--data", "0x1234", "--note", "rent",
    ]));
    let env = UnsignedEnvelope::from_json_str(&json).unwrap();
    assert_eq!(env.from, Some(Address::parse(FROM).unwrap()));
    assert_eq!(env.tx.chain_id, Some(31_337));
    assert_eq!(env.tx.nonce, 5);
    assert_eq!(env.tx.gas_limit, 30_000);
    assert_eq!(env.tx.max_priority_fee_per_gas, Some(1_000_000_000));
    assert_eq!(env.tx.max_fee_per_gas, Some(3_000_000_000));
    assert_eq!(env.tx.value.to_string(), "1500000000000000000");
    assert_eq!(env.note.as_deref(), Some("rent"));
    // The estimate request carried the call the operator described.
    let requests = node.requests.lock().unwrap().clone();
    let estimate = requests
        .iter()
        .find(|r| r["method"] == "eth_estimateGas")
        .unwrap();
    assert_eq!(estimate["params"][0]["data"], "0x1234");
    assert_eq!(estimate["params"][0]["value"], "0x14d1120d7b160000");
    // The envelope is accepted by the offline signer as-is...
    assert!(sign_envelope(&env, &anvil_key(), None).is_ok());
    // ...but a node that under-estimates cannot get an invalid transaction signed: 2 non-zero
    // calldata bytes make the intrinsic gas 21032 and the EIP-7623 floor 21000 + 10 * 8 = 21080.
    let mut lowballed = env.clone();
    lowballed.tx.gas_limit = 21_000;
    let err = sign_envelope(&lowballed, &anvil_key(), None).unwrap_err();
    assert!(err.to_string().contains("below the minimum 21080"), "{err}");
}

#[test]
fn prepare_options_and_errors() {
    let node = MockNode::start(Box::new(anvil_like));
    let dir = tempfile::tempdir().unwrap();
    // Contract creation, explicit nonce / gas, legacy without replay protection, written to a file.
    let out = dir.path().join("deploy.json");
    relay(&node)
        .args([
            "prepare",
            "--type",
            "legacy",
            "--from",
            FROM,
            "--create",
            "--data",
            "0x6000",
            "--nonce",
            "9",
            "--gas-limit",
            "60000",
            "--gas-price",
            "2gwei",
            "--no-replay-protection",
            "--out",
        ])
        .arg(&out)
        .assert()
        .success();
    let env = UnsignedEnvelope::from_json_str(&std::fs::read_to_string(&out).unwrap()).unwrap();
    assert_eq!(env.tx.to, Some(None));
    assert_eq!(env.tx.chain_id, None);
    assert_eq!(
        (env.tx.nonce, env.tx.gas_limit, env.tx.gas_price),
        (9, 60_000, Some(2_000_000_000))
    );
    relay(&node)
        .args([
            "prepare", "--type", "legacy", "--from", FROM, "--to", TO, "--out",
        ])
        .arg(&out)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("cannot create"));

    // EIP-2930 access list from a file.
    let al = dir.path().join("al.json");
    std::fs::write(
        &al,
        format!(
            r#"[{{"address":"{DELEGATE}","storageKeys":["0x{}"]}}]"#,
            "00".repeat(32)
        ),
    )
    .unwrap();
    let env = UnsignedEnvelope::from_json_str(&stdout(
        relay(&node)
            .args([
                "prepare",
                "--type",
                "eip2930",
                "--from",
                FROM,
                "--to",
                TO,
                "--access-list",
            ])
            .arg(&al),
    ))
    .unwrap();
    assert_eq!(env.tx.access_list.len(), 1);
    assert_eq!(env.tx.gas_price, Some(2_000_000_000));

    // EIP-7702 with a sponsored authorization (RLP from `cast wallet sign-auth`) and a self one.
    let cast_auth = "0xf85a01945fbdb2315678afecb367f032d93f642f64180aa30501a06e0089c7283c53da6377df27399347d3578ff4276431e323f1d897a39e40f22ba01608b9af83e8953b993de8a64a9274eb7183f687048a0e0155cc267d93d73abe";
    let env = UnsignedEnvelope::from_json_str(&stdout(relay(&node).args([
        "prepare",
        "--type",
        "eip7702",
        "--from",
        FROM,
        "--to",
        TO,
        "--gas-limit",
        "100000",
        "--auth",
        cast_auth,
        "--self-auth",
        &format!("31337:{DELEGATE}"),
        "--chain-id",
        "31337",
    ])))
    .unwrap();
    assert_eq!(env.tx.authorization_list[0].nonce, 5);
    assert_eq!(
        env.self_authorizations[0].address,
        Address::parse(DELEGATE).unwrap()
    );

    for (args, message) in [
        (vec!["--type", "eip7702", "--to", TO], "explicit gas limit"),
        (
            vec!["--type", "eip1559", "--to", TO, "--self-auth", "bogus"],
            "CHAIN_ID:ADDRESS",
        ),
        (
            vec!["--type", "eip1559", "--to", TO, "--auth", "0x80"],
            "--auth",
        ),
        (
            vec!["--type", "eip1559", "--to", TO, "--chain-id", "1"],
            "not the expected chain 1",
        ),
        (
            vec!["--type", "eip1559", "--to", TO, "--gas-price", "1"],
            "max fee / priority fee",
        ),
        (vec!["--type", "eip1559", "--to", "0x1234"], "20 bytes"),
    ] {
        relay(&node)
            .args(["prepare", "--from", FROM])
            .args(&args)
            .assert()
            .code(1)
            .stderr(predicate::str::contains(message));
    }
}

fn signed_envelope(chain: u64) -> SignedEnvelope {
    let env = UnsignedEnvelope::from_json_str(&format!(
        r#"{{"format":"keysmith/unsigned-tx@1","tx":{{"type":"eip1559","chainId":"{chain}","nonce":"0",
            "gasLimit":"21000","maxFeePerGas":"2000000000","maxPriorityFeePerGas":"1000000000","to":"{TO}","value":"1"}}}}"#
    ))
    .unwrap();
    sign_envelope(&env, &anvil_key(), None).unwrap().envelope
}

fn write_envelope(dir: &tempfile::TempDir, env: &SignedEnvelope) -> std::path::PathBuf {
    let path = dir.path().join("signed.json");
    std::fs::write(&path, serde_json::to_string(env).unwrap()).unwrap();
    path
}

fn node_with_receipt(status: &'static str) -> MockNode {
    MockNode::start(Box::new(move |method, params| match method {
        "eth_sendRawTransaction" => {
            let raw = hex::decode(params[0].as_str().unwrap()).unwrap();
            json!(hex::encode_prefixed(&keccak256(&raw)))
        }
        "eth_getTransactionReceipt" => json!({
            "transactionHash": params[0], "status": status, "type": "0x2", "from": FROM.to_ascii_lowercase(),
            "to": TO.to_ascii_lowercase(), "contractAddress": null, "gasUsed": "0x5208",
            "effectiveGasPrice": "0x77359400", "blockNumber": "0xa"
        }),
        other => anvil_like(other, params),
    }))
}

#[test]
fn broadcast_verifies_sends_and_waits() {
    let node = node_with_receipt("0x1");
    let dir = tempfile::tempdir().unwrap();
    let env = signed_envelope(31_337);
    let path = write_envelope(&dir, &env);
    let receipt: Value = serde_json::from_str(&stdout(
        relay(&node)
            .args(["broadcast", "--wait", "--envelope"])
            .arg(&path),
    ))
    .unwrap();
    assert_eq!(receipt["status"], true);
    assert_eq!(receipt["transactionHash"], env.hash);
    assert_eq!(receipt["gasUsed"], "21000");
    let requests = node.requests.lock().unwrap().clone();
    let sent = requests
        .iter()
        .find(|r| r["method"] == "eth_sendRawTransaction")
        .unwrap();
    assert_eq!(
        sent["params"][0], env.raw,
        "the verified bytes are what reaches the node"
    );
    // Without --wait only the hash is printed; `receipt` fetches it later.
    let hash = stdout(relay(&node).args(["broadcast", "--envelope"]).arg(&path));
    assert_eq!(hash.trim(), env.hash);
    let fetched: Value =
        serde_json::from_str(&stdout(relay(&node).args(["receipt", &env.hash]))).unwrap();
    assert_eq!(fetched["blockNumber"], "10");
}

#[test]
fn broadcast_refusals_send_nothing() {
    let dir = tempfile::tempdir().unwrap();
    // Tampered envelope: refused before any RPC call at all.
    let node = node_with_receipt("0x1");
    let mut forged = signed_envelope(31_337);
    forged.from = Address::parse(TO).unwrap();
    relay(&node)
        .args(["broadcast", "--envelope"])
        .arg(write_envelope(&dir, &forged))
        .assert()
        .code(3)
        .stderr(
            predicate::str::contains("REFUSED").and(predicate::str::contains("recovered signer")),
        );
    assert!(node.methods().is_empty());
    // Wrong chain: only eth_chainId is asked.
    relay(&node)
        .args(["broadcast", "--envelope"])
        .arg(write_envelope(&dir, &signed_envelope(1)))
        .assert()
        .code(3)
        .stderr(predicate::str::contains(
            "chain 1 but the node serves chain 31337",
        ));
    assert_eq!(node.methods(), ["eth_chainId"]);
    // Mined but reverted: exit code 4 with the receipt.
    let reverted = node_with_receipt("0x0");
    relay(&reverted)
        .args(["broadcast", "--wait", "--envelope"])
        .arg(write_envelope(&dir, &signed_envelope(31_337)))
        .assert()
        .code(4)
        .stderr(predicate::str::contains("transaction reverted"));
}

#[test]
fn node_and_transport_failures_are_reported() {
    let failing = MockNode::start(Box::new(
        |_, _| json!({"error": {"code": -32000, "message": "header not found"}}),
    ));
    relay(&failing)
        .args(["prepare", "--type", "eip1559", "--from", FROM, "--to", TO])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "JSON-RPC error -32000: header not found",
        ));
    relay(&failing).args(["receipt", "0x00"]).assert().code(1);
    let pending = MockNode::start(Box::new(|_, _| Value::Null));
    relay(&pending)
        .args(["receipt", "0x00"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("pending or unknown"));
    // Nothing listens on a port we bound and released.
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    Command::new(env!("CARGO_BIN_EXE_keysmith-relay"))
        .args([
            "--rpc-url",
            &format!("http://127.0.0.1:{port}"),
            "receipt",
            "0x00",
        ])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("transport error"));
    Command::new(env!("CARGO_BIN_EXE_keysmith-relay"))
        .args(["receipt", "0x00"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("--rpc-url is required"));
    Command::new(env!("CARGO_BIN_EXE_keysmith-relay"))
        .args(["--rpc-url", "ws://127.0.0.1:1", "receipt", "0x00"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("http:// or https://"));
}
