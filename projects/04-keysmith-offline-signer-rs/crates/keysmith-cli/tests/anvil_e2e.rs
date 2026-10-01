// SPDX-License-Identifier: MIT
//! End-to-end tests against a live `anvil --hardfork osaka` (feature `anvil-e2e`; Foundry
//! must be on PATH). Run with `cargo test -p keysmith-cli --features anvil-e2e -- --test-threads=1`.
//!
//! The air-gap workflow is exercised exactly as an operator would run it:
//!
//! 1. the online half (`keysmith-relay`, used as a library) prepares an unsigned envelope from
//!    the node;
//! 2. the envelope is written to a file and signed by the real `keysmith` binary, which never
//!    talks to the node;
//! 3. the relay re-verifies the signed envelope, broadcasts it and waits for the receipt.
//!
//! Every transaction type is mined and its receipt asserted, including EIP-7702 delegations
//! (self-executed, sponsored and revoked). anvil binds an ephemeral port (`--port 0`), so
//! parallel runs never collide.
#![cfg(feature = "anvil-e2e")]
// Test harness code: an unwrap or panic here is a test failure, which is the intent.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use keysmith_core::authorization::SignedAuthorization;
use keysmith_core::bip32::{DerivationPath, derive_private_key};
use keysmith_core::bip39::Mnemonic;
use keysmith_core::envelope::{SelfAuthorization, SignedEnvelope, UnsignedEnvelope};
use keysmith_core::gas::intrinsic_gas;
use keysmith_core::tx::{AccessListItem, SignedTransaction, TxType};
use keysmith_core::{Address, PrivateKey, U256, eip191, hex};
use keysmith_relay::{
    HttpTransport, PrepareRequest, Receipt, RelayError, RpcClient, broadcast, prepare,
    wait_for_receipt,
};
use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

const MNEMONIC: &str = "test test test test test test test test test test test junk";
const CHAIN_ID: u64 = 31_337;
/// `PUSH1 5 PUSH1 10 PUSH0 CODECOPY PUSH1 5 PUSH0 RETURN` deploying the 5-byte runtime
/// `PUSH0 CALLDATALOAD PUSH0 SSTORE STOP`: it stores the first calldata word in slot 0.
const INITCODE: &str = "0x6005600a5f3960055ff35f355f5500";
const RUNTIME: &str = "0x5f355f5500";
const ETHER: u128 = 1_000_000_000_000_000_000;

fn key(index: u32) -> PrivateKey {
    let seed = Mnemonic::parse(MNEMONIC).unwrap().to_seed("");
    derive_private_key(&seed, &DerivationPath::ethereum(index).unwrap()).unwrap()
}

fn addr(index: u32) -> Address {
    key(index).address()
}

fn word(byte: u8) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[0] = byte;
    w[31] = byte;
    w
}

/// An anvil child process, killed (by PID, through the handle) when dropped.
struct Anvil {
    child: Child,
    url: String,
}

impl Anvil {
    fn spawn() -> Self {
        let bin = std::env::var("ANVIL").unwrap_or_else(|_| "anvil".to_owned());
        let mut child = Command::new(bin)
            .args(["--hardfork", "osaka", "--port", "0", "--host", "127.0.0.1"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("cannot start anvil (is Foundry on PATH?)");
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        // Keep draining stdout for the life of the process so anvil never blocks on a full pipe.
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Some(address) = line.strip_prefix("Listening on ") {
                    let _ = tx.send(address.trim().to_owned());
                }
            }
        });
        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(address) => Self {
                child,
                url: format!("http://{address}"),
            },
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                panic!("anvil did not report its listening address within 60 s");
            }
        }
    }
}

impl Drop for Anvil {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// One anvil, one RPC client, one scratch directory with the mnemonic on disk.
struct Session {
    _anvil: Anvil,
    rpc: RpcClient<HttpTransport>,
    dir: tempfile::TempDir,
    files: std::cell::Cell<u32>,
}

impl Session {
    fn start() -> Self {
        let anvil = Anvil::spawn();
        let rpc = RpcClient::new(HttpTransport::new(&anvil.url, Duration::from_secs(30)).unwrap());
        assert_eq!(rpc.chain_id().unwrap(), CHAIN_ID);
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("mnemonic.txt"), format!("{MNEMONIC}\n")).unwrap();
        Self {
            _anvil: anvil,
            rpc,
            dir,
            files: std::cell::Cell::new(0),
        }
    }

    fn file(&self, stem: &str, contents: &str) -> PathBuf {
        let n = self.files.get();
        self.files.set(n + 1);
        let path = self.dir.path().join(format!("{n:02}-{stem}"));
        std::fs::write(&path, contents).unwrap();
        path
    }

    /// Runs the real `keysmith` binary with the anvil mnemonic as key source.
    fn keysmith(&self, args: &[&str], signer: u32) -> std::process::Output {
        Command::new(env!("CARGO_BIN_EXE_keysmith"))
            .args(args)
            .arg("--mnemonic-file")
            .arg(self.dir.path().join("mnemonic.txt"))
            .args(["--mnemonic-index", &signer.to_string()])
            .output()
            .unwrap()
    }

    /// Offline step: the unsigned envelope crosses the "air gap" as a file.
    fn sign_offline(&self, env: &UnsignedEnvelope, signer: u32) -> SignedEnvelope {
        let path = self.file("unsigned.json", &serde_json::to_string_pretty(env).unwrap());
        let path = path.to_str().unwrap().to_owned();
        let out = self.keysmith(&["sign", "--envelope", &path], signer);
        assert!(
            out.status.success(),
            "keysmith sign failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        SignedEnvelope::from_json_str(std::str::from_utf8(&out.stdout).unwrap()).unwrap()
    }

    fn send(&self, signed: &SignedEnvelope) -> Receipt {
        let sent = broadcast(&self.rpc, signed).unwrap();
        assert_eq!(sent.hash, signed.hash);
        let receipt = wait_for_receipt(
            &self.rpc,
            &sent.hash,
            Duration::from_secs(30),
            Duration::from_millis(50),
        )
        .unwrap();
        assert!(receipt.status, "transaction reverted: {receipt:?}");
        assert_eq!(receipt.transaction_hash, signed.hash);
        assert_eq!(receipt.from, signed.from);
        receipt
    }

    /// prepare (online) -> sign (offline binary) -> broadcast (online), returning both ends.
    fn round_trip(&self, req: &PrepareRequest, signer: u32) -> (SignedEnvelope, Receipt) {
        assert_eq!(req.from, addr(signer));
        let unsigned = prepare(&self.rpc, req).unwrap();
        let signed = self.sign_offline(&unsigned, signer);
        let receipt = self.send(&signed);
        assert_eq!(receipt.tx_type, req.tx_type.type_byte().unwrap_or(0));
        (signed, receipt)
    }

    fn nonce(&self, a: &Address) -> u64 {
        self.rpc.pending_nonce(a).unwrap()
    }
}

fn decoded(signed: &SignedEnvelope) -> SignedTransaction {
    signed.verify().unwrap()
}

fn delegation_designator(target: &Address) -> Vec<u8> {
    let mut code = vec![0xef, 0x01, 0x00];
    code.extend_from_slice(&target.0);
    code
}

#[test]
fn every_transaction_type_is_mined_through_the_air_gap() {
    let s = Session::start();
    let recipient = addr(5);

    // --- Legacy with EIP-155 replay protection: plain transfer. ---------------------------------
    let before = s.rpc.balance(&recipient).unwrap();
    let mut req = PrepareRequest::new(TxType::Legacy, addr(0), Some(recipient));
    req.value = U256::from_u128(ETHER);
    let (signed, receipt) = s.round_trip(&req, 0);
    assert_eq!(decoded(&signed).tx.chain_id(), Some(CHAIN_ID));
    assert_eq!(receipt.gas_used, 21_000);
    assert_eq!(
        s.rpc.balance(&recipient).unwrap(),
        before.checked_add(&U256::from_u128(ETHER)).unwrap()
    );

    // --- Legacy without replay protection (pre-EIP-155): flagged, but valid. ------------------
    let mut req = PrepareRequest::new(TxType::Legacy, addr(6), Some(recipient));
    req.value = U256::ONE;
    req.replay_protected = false;
    let (signed, receipt) = s.round_trip(&req, 6);
    assert_eq!(decoded(&signed).tx.chain_id(), None);
    assert_eq!(receipt.gas_used, 21_000);

    // --- EIP-2930: the node charges exactly keysmith's intrinsic gas for an EOA call. ----------
    let mut req = PrepareRequest::new(TxType::Eip2930, addr(0), Some(recipient));
    req.access_list = vec![AccessListItem {
        address: recipient,
        storage_keys: vec![[0u8; 32], word(1)],
    }];
    let (signed, receipt) = s.round_trip(&req, 0);
    let expected = intrinsic_gas(&decoded(&signed).tx);
    assert_eq!(expected.total, 21_000 + 2_400 + 2 * 1_900);
    assert_eq!(receipt.gas_used, expected.minimum_gas_limit);

    // --- EIP-1559 with calldata to an EOA: the EIP-7623 floor is what gets charged. -------------
    let mut req = PrepareRequest::new(TxType::Eip1559, addr(0), Some(recipient));
    req.input = vec![0xff; 100];
    let (signed, receipt) = s.round_trip(&req, 0);
    let expected = intrinsic_gas(&decoded(&signed).tx);
    assert_eq!((expected.total, expected.floor), (22_600, 25_000));
    assert_eq!(
        receipt.gas_used, 25_000,
        "revm applies the calldata floor keysmith computed"
    );

    // --- EIP-1559 contract creation. ------------------------------------------------------------
    let deployer_nonce = s.nonce(&addr(0));
    let mut req = PrepareRequest::new(TxType::Eip1559, addr(0), None);
    req.input = hex::decode(INITCODE).unwrap();
    let (_, receipt) = s.round_trip(&req, 0);
    let contract = Address::create(&addr(0), deployer_nonce);
    assert_eq!(receipt.contract_address, Some(contract));
    assert_eq!(receipt.to, None);
    assert_eq!(
        s.rpc.code(&contract).unwrap(),
        hex::decode(RUNTIME).unwrap()
    );

    // --- EIP-1559 call into the contract. ---------------------------------------------------------
    let mut req = PrepareRequest::new(TxType::Eip1559, addr(0), Some(contract));
    req.input = word(0x11).to_vec();
    s.round_trip(&req, 0);
    assert_eq!(
        s.rpc.storage_at(&contract, &U256::ZERO).unwrap(),
        word(0x11)
    );

    // --- EIP-7702, self-executed: authority = sender, authorization nonce = tx nonce + 1. -------
    let authority = addr(1);
    let nonce_before = s.nonce(&authority);
    let mut req = PrepareRequest::new(TxType::Eip7702, authority, Some(authority));
    req.gas_limit = Some(150_000);
    req.input = word(0x22).to_vec();
    req.self_authorizations = vec![SelfAuthorization {
        chain_id: U256::from_u64(CHAIN_ID),
        address: contract,
    }];
    let (signed, receipt) = s.round_trip(&req, 1);
    let tx = decoded(&signed);
    assert_eq!(tx.tx.authorization_list()[0].nonce, nonce_before + 1);
    assert_eq!(
        tx.tx.authorization_list()[0].recover_authority().unwrap(),
        authority
    );
    assert_eq!(receipt.to, Some(authority));
    assert_eq!(
        s.rpc.code(&authority).unwrap(),
        delegation_designator(&contract)
    );
    // The delegated code ran in the authority's own storage.
    assert_eq!(
        s.rpc.storage_at(&authority, &U256::ZERO).unwrap(),
        word(0x22)
    );
    assert_eq!(
        s.nonce(&authority),
        nonce_before + 2,
        "tx nonce and authorization nonce"
    );

    // --- EIP-7702, sponsored: account 2 signs offline (`keysmith sign-auth`), account 0 pays. ---
    let sponsored = addr(2);
    let auth_nonce = s.nonce(&sponsored);
    let auth = sign_auth(&s, 2, &contract, auth_nonce, "sponsor");
    let sponsor_nonce = s.nonce(&addr(0));
    let mut req = PrepareRequest::new(TxType::Eip7702, addr(0), Some(sponsored));
    req.gas_limit = Some(150_000);
    req.input = word(0x33).to_vec();
    req.authorizations = vec![auth];
    s.round_trip(&req, 0);
    assert_eq!(
        s.rpc.code(&sponsored).unwrap(),
        delegation_designator(&contract)
    );
    assert_eq!(
        s.rpc.storage_at(&sponsored, &U256::ZERO).unwrap(),
        word(0x33)
    );
    assert_eq!(
        s.nonce(&sponsored),
        auth_nonce + 1,
        "only the authorization bumped it"
    );
    assert_eq!(s.nonce(&addr(0)), sponsor_nonce + 1);

    // --- EIP-7702 revocation: delegating to the zero address clears the code. ---------------------
    let revoke = sign_auth(&s, 2, &Address::ZERO, s.nonce(&sponsored), "sponsor");
    let mut req = PrepareRequest::new(TxType::Eip7702, addr(0), Some(addr(7)));
    req.gas_limit = Some(100_000);
    req.authorizations = vec![revoke];
    s.round_trip(&req, 0);
    assert!(s.rpc.code(&sponsored).unwrap().is_empty());
    // The storage written while delegated stays (EIP-7702 does not clear it).
    assert_eq!(
        s.rpc.storage_at(&sponsored, &U256::ZERO).unwrap(),
        word(0x33)
    );
}

/// `keysmith sign-auth` run as a separate offline step; returns the decoded tuple.
fn sign_auth(
    s: &Session,
    signer: u32,
    delegate: &Address,
    nonce: u64,
    executor: &str,
) -> SignedAuthorization {
    let out = s.keysmith(
        &[
            "sign-auth",
            "--chain-id",
            &CHAIN_ID.to_string(),
            "--address",
            &delegate.to_checksum(),
            "--nonce",
            &nonce.to_string(),
            "--executor",
            executor,
        ],
        signer,
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let rlp = String::from_utf8(out.stdout).unwrap();
    SignedAuthorization::decode(&hex::decode(rlp.trim()).unwrap()).unwrap()
}

#[test]
fn refusals_never_reach_the_chain() {
    let s = Session::start();
    let sender = addr(3);
    let nonce = s.nonce(&sender);
    let mut req = PrepareRequest::new(TxType::Eip1559, sender, Some(addr(4)));
    req.value = U256::from_u128(5 * ETHER);
    let unsigned = prepare(&s.rpc, &req).unwrap();

    // Offline policy: max 1 ether per transaction. Exit code 3, nothing on stdout.
    let policy = s.file(
        "policy.json",
        r#"{"allowedChainIds":[31337],"maxValueWei":"1000000000000000000"}"#,
    );
    let env = s.file("unsigned.json", &serde_json::to_string(&unsigned).unwrap());
    let out = s.keysmith(
        &[
            "sign",
            "--envelope",
            env.to_str().unwrap(),
            "--policy",
            policy.to_str().unwrap(),
        ],
        3,
    );
    assert_eq!(out.status.code(), Some(3));
    assert!(out.stdout.is_empty());
    assert!(String::from_utf8_lossy(&out.stderr).contains("[maxValueWei]"));

    // A signed envelope tampered with on the online machine is refused before broadcast.
    let mut forged = s.sign_offline(&unsigned, 3);
    forged.from = addr(4);
    assert!(matches!(
        broadcast(&s.rpc, &forged),
        Err(RelayError::Envelope(_))
    ));

    // A transaction for another chain is refused before broadcast.
    let mut mainnet = unsigned.clone();
    mainnet.tx.chain_id = Some(1);
    let signed = s.sign_offline(&mainnet, 3);
    assert!(matches!(
        broadcast(&s.rpc, &signed),
        Err(RelayError::ChainMismatch {
            envelope: 1,
            node: CHAIN_ID
        })
    ));
    assert_eq!(s.nonce(&sender), nonce, "nothing was mined");

    // Sanity: the untampered envelope does go through.
    let good = s.sign_offline(&unsigned, 3);
    s.send(&good);
    assert_eq!(s.nonce(&sender), nonce + 1);
}

/// Calls the ecrecover precompile (address 0x01) through `eth_call`.
fn ecrecover(s: &Session, digest: &[u8; 32], v: u8, r: &[u8], sig_s: &[u8]) -> Address {
    let mut input = digest.to_vec();
    let mut v_word = [0u8; 32];
    v_word[31] = v;
    input.extend_from_slice(&v_word);
    input.extend_from_slice(r);
    input.extend_from_slice(sig_s);
    let mut precompile = [0u8; 20];
    precompile[19] = 1;
    let out = s.rpc.call(&Address(precompile), &input).unwrap();
    assert_eq!(out.len(), 32, "ecrecover rejected the signature");
    Address(out[12..].try_into().unwrap())
}

fn json_output(out: std::process::Output) -> Value {
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn message_signatures_verify_in_the_evm() {
    let s = Session::start();
    // EIP-191 personal_sign.
    let out = s.keysmith(&["sign-message", "--message", "Keysmith e2e"], 4);
    assert!(out.status.success());
    let sig = hex::decode(String::from_utf8(out.stdout).unwrap().trim()).unwrap();
    let digest = eip191::personal_message_hash(b"Keysmith e2e");
    assert_eq!(
        ecrecover(&s, &digest, sig[64], &sig[..32], &sig[32..64]),
        addr(4)
    );

    // EIP-712 typed data (the EIP-712 specification's Mail example).
    let mail = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../test-vectors/cast/typed-data/mail.json");
    let td = json_output(s.keysmith(
        &[
            "sign-typed-data",
            "--json",
            "--file",
            mail.to_str().unwrap(),
        ],
        5,
    ));
    let digest: [u8; 32] = hex::decode_array(td["digest"].as_str().unwrap()).unwrap();
    let r = hex::decode(td["r"].as_str().unwrap()).unwrap();
    let ss = hex::decode(td["s"].as_str().unwrap()).unwrap();
    let v = u8::try_from(td["v"].as_u64().unwrap()).unwrap();
    assert_eq!(ecrecover(&s, &digest, v, &r, &ss), addr(5));

    // ERC-2612 permit.
    let permit = json_output(s.keysmith(
        &[
            "permit",
            "--token",
            "0x5FbDB2315678afecb367f032d93F642f64180aa3",
            "--name",
            "Keysmith Test Token",
            "--chain-id",
            "31337",
            "--spender",
            &addr(6).to_checksum(),
            "--value",
            "1.5ether",
            "--nonce",
            "0",
            "--deadline",
            "4102444800",
            "--json",
        ],
        6,
    ));
    let digest: [u8; 32] = hex::decode_array(permit["digest"].as_str().unwrap()).unwrap();
    let r = hex::decode(permit["r"].as_str().unwrap()).unwrap();
    let ss = hex::decode(permit["s"].as_str().unwrap()).unwrap();
    let v = u8::try_from(permit["v"].as_u64().unwrap()).unwrap();
    assert_eq!(ecrecover(&s, &digest, v, &r, &ss), addr(6));
    assert_eq!(permit["value"], "1500000000000000000");
}

fn cast(args: &[&str]) -> String {
    let bin = std::env::var("CAST").unwrap_or_else(|_| "cast".to_owned());
    let out = Command::new(bin)
        .args(args)
        .output()
        .expect("cannot run cast (is Foundry on PATH?)");
    assert!(
        out.status.success(),
        "cast {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

#[test]
fn keystores_interoperate_with_cast_wallet() {
    let dir = tempfile::tempdir().unwrap();
    let d = dir.path().to_str().unwrap().to_owned();
    let pw = dir.path().join("pw.txt");
    std::fs::write(&pw, "keysmith-e2e-password\n").unwrap();
    let mnemonic = dir.path().join("mnemonic.txt");
    std::fs::write(&mnemonic, MNEMONIC).unwrap();
    let keysmith = || Command::new(env!("CARGO_BIN_EXE_keysmith"));

    // keysmith export -> cast wallet decrypt-keystore.
    let out = keysmith()
        .args(["keystore", "export", "--scrypt-log-n", "13", "--out"])
        .arg(dir.path().join("from-keysmith.json"))
        .arg("--new-password-file")
        .arg(&pw)
        .arg("--mnemonic-file")
        .arg(&mnemonic)
        .args(["--mnemonic-index", "8"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let decrypted = cast(&[
        "wallet",
        "decrypt-keystore",
        "from-keysmith.json",
        "--keystore-dir",
        &d,
        "--unsafe-password",
        "keysmith-e2e-password",
    ]);
    assert!(
        decrypted.contains(&hex::encode_prefixed(key(8).to_bytes().as_ref())),
        "{decrypted}"
    );

    // cast wallet import -> keysmith.
    let pk9 = hex::encode_prefixed(key(9).to_bytes().as_ref());
    cast(&[
        "wallet",
        "import",
        "from-cast",
        "--keystore-dir",
        &d,
        "--private-key",
        &pk9,
        "--unsafe-password",
        "keysmith-e2e-password",
    ]);
    let out = keysmith()
        .args(["address", "--keystore"])
        .arg(dir.path().join("from-cast"))
        .arg("--password-file")
        .arg(&pw)
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8(out.stdout).unwrap().trim(),
        addr(9).to_checksum()
    );

    // cast wallet new (fresh random key) -> keysmith agrees with cast on the address.
    cast(&[
        "wallet",
        "new",
        &d,
        "--unsafe-password",
        "keysmith-e2e-password",
    ]);
    let fresh = std::fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| {
            let name = p.file_name().unwrap().to_string_lossy().into_owned();
            !name.ends_with(".txt") && !name.starts_with("from-")
        })
        .expect("cast wallet new wrote no keystore");
    let expected = cast(&[
        "wallet",
        "address",
        "--keystore",
        fresh.to_str().unwrap(),
        "--password",
        "keysmith-e2e-password",
    ]);
    let out = keysmith()
        .args(["address", "--keystore"])
        .arg(&fresh)
        .arg("--password-file")
        .arg(&pw)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        String::from_utf8(out.stdout)
            .unwrap()
            .trim()
            .to_ascii_lowercase(),
        expected.trim().to_ascii_lowercase()
    );
}
