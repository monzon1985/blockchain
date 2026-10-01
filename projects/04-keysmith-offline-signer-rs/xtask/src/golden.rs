// SPDX-License-Identifier: MIT
//! `cargo xtask regen-golden [--check]`: regenerates `test-vectors/cast/golden.json` by running
//! Foundry's `cast` (1.8.3) on a fixed set of inputs.
//!
//! The file records the *inputs* in Keysmith's own formats next to cast's *outputs*; the tests in
//! `keysmith-core/tests/golden_cast.rs` rebuild every output from the inputs with the hand-written
//! core and require byte equality. Keysmith code is never used to produce expected values here.
//!
//! All keys come from anvil's public test mnemonic. They are published test keys: never fund them.
//!
//! `--check` regenerates in memory and fails on any difference (CI runs it with Foundry installed).
//! Keystores contain a random salt and cannot be regenerated identically, so `--check` instead
//! asks `cast wallet decrypt-keystore` to decrypt the committed file and compares the key.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// anvil's default mnemonic (public test vector).
pub const MNEMONIC: &str = "test test test test test test test test test test test junk";
const KEYSTORE_PASSWORD: &str = "keysmith-golden-password";
const KEYSTORE_SIGNER: usize = 3;

const ALICE: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const DELEGATE: &str = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
const OTHER_DELEGATE: &str = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
const TOKEN_TRANSFER: &str = "0xa9059cbb00000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c80000000000000000000000000000000000000000000000000de0b6b3a7640000";
/// Minimal initcode deploying `PUSH0 CALLDATALOAD PUSH0 SSTORE STOP` (see the anvil e2e test).
const INITCODE: &str = "0x6005600a5f3960055ff35f355f5500";

fn cast_bin() -> String {
    std::env::var("CAST").unwrap_or_else(|_| "cast".to_owned())
}

fn run_cast(args: &[String], stdin: Option<&str>) -> Result<String, String> {
    let mut cmd = Command::new(cast_bin());
    cmd.args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        });
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("cannot run cast (is Foundry on PATH?): {e}"))?;
    if let (Some(input), Some(mut pipe)) = (stdin, child.stdin.take()) {
        use std::io::Write;
        pipe.write_all(input.as_bytes())
            .map_err(|e| format!("cannot write to cast stdin: {e}"))?;
    }
    let out = child
        .wait_with_output()
        .map_err(|e| format!("cast did not finish: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "cast {} failed: {}",
            args.first().map_or("", String::as_str),
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn cast(args: &[&str]) -> Result<String, String> {
    run_cast(
        &args.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>(),
        None,
    )
}

fn private_key(index: usize) -> Result<String, String> {
    cast(&[
        "wallet",
        "private-key",
        "--mnemonic",
        MNEMONIC,
        "--mnemonic-index",
        &index.to_string(),
    ])
}

fn address_of(pk: &str) -> Result<String, String> {
    cast(&["wallet", "address", "--private-key", pk])
}

fn s(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_owned)
}

/// A transaction case: Keysmith envelope inputs plus how to express them to `cast mktx`.
struct TxCase {
    name: &'static str,
    signer: usize,
    tx: Value,
    /// Authorizations signed by other accounts (sponsor flow), appended first.
    sponsored: Vec<(usize, &'static str, &'static str, u64)>,
    /// Delegations signed by the sender itself (nonce = tx nonce + 1), appended last.
    self_auths: Vec<(&'static str, &'static str)>,
}

fn tx_cases() -> Vec<TxCase> {
    let al = json!([{
        "address": DELEGATE,
        "storageKeys": [
            "0x0000000000000000000000000000000000000000000000000000000000000000",
            "0x00000000000000000000000000000000000000000000000000000000000000ff"
        ]
    }]);
    vec![
        TxCase {
            name: "legacy-eip155-transfer",
            signer: 0,
            tx: json!({"type":"legacy","chainId":"1","nonce":"0","gasLimit":"21000","gasPrice":"1000000000","to":ALICE,"value":"1","input":"0x"}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "legacy-eip155-anvil-chain-calldata",
            signer: 1,
            tx: json!({"type":"legacy","chainId":"31337","nonce":"7","gasLimit":"60000","gasPrice":"875000000","to":DELEGATE,"value":"0","input":TOKEN_TRANSFER}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "legacy-create",
            signer: 0,
            tx: json!({"type":"legacy","chainId":"1","nonce":"3","gasLimit":"100000","gasPrice":"20000000000","to":null,"value":"0","input":INITCODE}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "eip2930-access-list",
            signer: 0,
            tx: json!({"type":"eip2930","chainId":"1","nonce":"0","gasLimit":"30000","gasPrice":"1000000000","to":ALICE,"value":"1","input":"0x","accessList":al}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "eip1559-transfer-one-ether",
            signer: 0,
            tx: json!({"type":"eip1559","chainId":"1","nonce":"0","gasLimit":"21000","maxFeePerGas":"30000000000","maxPriorityFeePerGas":"1000000000","to":ALICE,"value":"1000000000000000000","input":"0x"}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "eip1559-erc20-transfer-calldata",
            signer: 2,
            tx: json!({"type":"eip1559","chainId":"8453","nonce":"4294967296","gasLimit":"65000","maxFeePerGas":"2000000000","maxPriorityFeePerGas":"1000000","to":DELEGATE,"value":"0","input":TOKEN_TRANSFER}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "eip1559-create",
            signer: 0,
            tx: json!({"type":"eip1559","chainId":"1","nonce":"0","gasLimit":"100000","maxFeePerGas":"2000000000","maxPriorityFeePerGas":"1000000000","to":null,"value":"0","input":INITCODE}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "eip1559-access-list-large-value",
            signer: 1,
            tx: json!({"type":"eip1559","chainId":"10","nonce":"255","gasLimit":"50000","maxFeePerGas":"123456789012","maxPriorityFeePerGas":"123456789012","to":ALICE,"value":"1000000000000000000000000000","input":"0x","accessList":al}),
            sponsored: vec![],
            self_auths: vec![],
        },
        TxCase {
            name: "eip7702-self-executed",
            signer: 0,
            tx: json!({"type":"eip7702","chainId":"1","nonce":"4","gasLimit":"60000","maxFeePerGas":"2000000000","maxPriorityFeePerGas":"1000000000","to":ALICE,"value":"0","input":"0x"}),
            sponsored: vec![],
            self_auths: vec![("1", DELEGATE)],
        },
        TxCase {
            name: "eip7702-sponsored",
            signer: 0,
            tx: json!({"type":"eip7702","chainId":"31337","nonce":"9","gasLimit":"80000","maxFeePerGas":"2000000000","maxPriorityFeePerGas":"1000000000","to":"0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC","value":"0","input":"0xdeadbeef"}),
            sponsored: vec![(2, "31337", DELEGATE, 0)],
            self_auths: vec![],
        },
        TxCase {
            name: "eip7702-sponsored-and-self-with-access-list",
            signer: 1,
            tx: json!({"type":"eip7702","chainId":"1","nonce":"12","gasLimit":"120000","maxFeePerGas":"3000000000","maxPriorityFeePerGas":"2000000000","to":ALICE,"value":"5","input":"0x","accessList":al}),
            sponsored: vec![(2, "1", OTHER_DELEGATE, 3)],
            self_auths: vec![("1", DELEGATE)],
        },
    ]
}

fn mktx_args(case: &TxCase, pk: &str, sponsored_rlps: &[String]) -> Result<Vec<String>, String> {
    let tx = &case.tx;
    let field = |k: &str| s(tx, k).ok_or_else(|| format!("{}: missing {k}", case.name));
    let mut args: Vec<String> = vec!["mktx".into()];
    let create = tx.get("to").is_some_and(Value::is_null);
    let input = field("input")?;
    if !create {
        args.push(field("to")?);
        if input != "0x" {
            args.push(input.clone());
        }
    }
    for (flag, key) in [
        ("--nonce", "nonce"),
        ("--gas-limit", "gasLimit"),
        ("--chain", "chainId"),
        ("--value", "value"),
    ] {
        args.push(flag.into());
        args.push(field(key)?);
    }
    match field("type")?.as_str() {
        "legacy" | "eip2930" => {
            args.push("--legacy".into());
            args.push("--gas-price".into());
            args.push(field("gasPrice")?);
        }
        _ => {
            args.push("--gas-price".into());
            args.push(field("maxFeePerGas")?);
            args.push("--priority-gas-price".into());
            args.push(field("maxPriorityFeePerGas")?);
        }
    }
    if let Some(al) = tx.get("accessList") {
        args.push("--access-list".into());
        args.push(al.to_string());
    }
    for rlp in sponsored_rlps {
        args.push("--auth".into());
        args.push(rlp.clone());
    }
    for (_, address) in &case.self_auths {
        args.push("--auth".into());
        args.push((*address).to_owned());
    }
    args.push("--private-key".into());
    args.push(pk.to_owned());
    if create {
        args.push("--create".into());
        args.push(input);
    }
    Ok(args)
}

fn redact(args: &[String]) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut hide = false;
    for a in args {
        if hide {
            out.push("<anvil test key>".to_owned());
            hide = false;
        } else {
            hide = a == "--private-key";
            out.push(a.clone());
        }
    }
    out
}

fn sign_auth(
    pk: &str,
    chain: &str,
    address: &str,
    nonce: u64,
) -> Result<(Vec<String>, String), String> {
    let args: Vec<String> = [
        "wallet",
        "sign-auth",
        address,
        "--nonce",
        &nonce.to_string(),
        "--chain",
        chain,
        "--private-key",
        pk,
    ]
    .iter()
    .map(|x| (*x).to_owned())
    .collect();
    // cast asks for confirmation before signing a chainId-0 (any chain) authorization.
    let stdin = (chain == "0").then_some("y\n");
    let rlp = run_cast(&args, stdin)?;
    let rlp = rlp
        .lines()
        .rev()
        .find(|l| l.starts_with("0x"))
        .ok_or("cast sign-auth printed no hex")?
        .to_owned();
    Ok((redact(&args), rlp))
}

fn decode_tx(raw: &str) -> Result<Value, String> {
    let out = cast(&["decode-tx", raw])?;
    // cast prints the JSON document as a JSON string literal.
    let inner: String = serde_json::from_str(&out).map_err(|e| format!("decode-tx output: {e}"))?;
    serde_json::from_str(&inner).map_err(|e| format!("decode-tx inner JSON: {e}"))
}

fn transactions(keys: &[String]) -> Result<Vec<Value>, String> {
    let mut out = Vec::new();
    for case in tx_cases() {
        let mut sponsored_json = Vec::new();
        let mut rlps = Vec::new();
        for (signer, chain, address, nonce) in &case.sponsored {
            let (_, rlp) = sign_auth(&keys[*signer], chain, address, *nonce)?;
            sponsored_json.push(json!({"signerIndex": signer, "chainId": chain, "address": address, "nonce": nonce.to_string(), "castRlp": rlp}));
            rlps.push(rlp);
        }
        let args = mktx_args(&case, &keys[case.signer], &rlps)?;
        let raw = run_cast(&args, None)?;
        let decoded = decode_tx(&raw)?;
        let self_auths: Vec<Value> = case
            .self_auths
            .iter()
            .map(|(chain, address)| json!({"chainId": chain, "address": address}))
            .collect();
        out.push(json!({
            "name": case.name,
            "signerIndex": case.signer,
            "envelope": {"format": "keysmith/unsigned-tx@1", "tx": case.tx, "selfAuthorizations": self_auths},
            "sponsoredAuthorizations": sponsored_json,
            "cast": {
                "command": redact(&args),
                "raw": raw,
                "signer": s(&decoded, "signer"),
                "hash": s(&decoded, "hash"),
            }
        }));
    }
    Ok(out)
}

fn authorizations(keys: &[String]) -> Result<Vec<Value>, String> {
    let cases: [(&str, usize, &str, &str, u64); 4] = [
        ("chain-1", 0, "1", DELEGATE, 5),
        ("anvil-chain", 1, "31337", OTHER_DELEGATE, 42),
        ("any-chain-zero", 2, "0", DELEGATE, 0),
        (
            "large-nonce",
            0,
            "8453",
            DELEGATE,
            18_446_744_073_709_551_614,
        ),
    ];
    let mut out = Vec::new();
    for (name, signer, chain, address, nonce) in cases {
        let (command, rlp) = sign_auth(&keys[signer], chain, address, nonce)?;
        out.push(json!({"name": name, "signerIndex": signer, "chainId": chain, "address": address, "nonce": nonce.to_string(), "cast": {"command": command, "rlp": rlp}}));
    }
    Ok(out)
}

fn messages(keys: &[String]) -> Result<Vec<Value>, String> {
    let long = "Keysmith signs exactly the bytes you reviewed. ".repeat(6);
    let cases: Vec<(&str, usize, Value, String)> = vec![
        (
            "hello-world",
            0,
            json!({"utf8": "hello world"}),
            "hello world".into(),
        ),
        ("empty", 1, json!({"utf8": ""}), String::new()),
        (
            "unicode",
            2,
            json!({"utf8": "Keysmith \u{2713} \u{fc}n\u{ef}c\u{f6}d\u{e9}"}),
            "Keysmith \u{2713} \u{fc}n\u{ef}c\u{f6}d\u{e9}".into(),
        ),
        ("long-text", 0, json!({"utf8": long}), long.clone()),
        (
            "raw-bytes-hex",
            0,
            json!({"hex": "0xdeadbeef"}),
            "0xdeadbeef".into(),
        ),
    ];
    let mut out = Vec::new();
    for (name, signer, message, arg) in cases {
        let args: Vec<String> = vec![
            "wallet".into(),
            "sign".into(),
            arg,
            "--private-key".into(),
            keys[signer].clone(),
        ];
        let sig = run_cast(&args, None)?;
        out.push(json!({"name": name, "signerIndex": signer, "message": message, "cast": {"command": redact(&args), "signature": sig}}));
    }
    Ok(out)
}

fn typed_data(root: &Path, keys: &[String]) -> Result<Vec<Value>, String> {
    let dir = root.join("test-vectors").join("cast").join("typed-data");
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".json"))
        .collect();
    names.sort();
    let mut out = Vec::new();
    for (i, name) in names.iter().enumerate() {
        let signer = i % 3;
        let path = dir.join(name);
        let args: Vec<String> = vec![
            "wallet".into(),
            "sign".into(),
            "--data".into(),
            "--from-file".into(),
            path.display().to_string(),
            "--private-key".into(),
            keys[signer].clone(),
        ];
        let sig = run_cast(&args, None)?;
        let mut command = redact(&args);
        command[4] = format!("test-vectors/cast/typed-data/{name}");
        out.push(json!({"file": name, "signerIndex": signer, "cast": {"command": command, "signature": sig}}));
    }
    Ok(out)
}

fn addresses() -> Result<Vec<Value>, String> {
    let mut out = Vec::new();
    for index in 0..5usize {
        let pk = private_key(index)?;
        out.push(json!({"path": format!("m/44'/60'/0'/0/{index}"), "passphrase": "", "address": address_of(&pk)?}));
    }
    for (path, passphrase) in [
        ("m/44'/60'/0'/0/0", "keysmith"),
        ("m/44'/60'/1'/0/7", ""),
        ("m/44'/60'/0'/1/2147483647", ""),
    ] {
        let mut args = vec![
            "wallet",
            "private-key",
            "--mnemonic",
            MNEMONIC,
            "--mnemonic-derivation-path",
            path,
        ];
        if !passphrase.is_empty() {
            args.extend(["--mnemonic-passphrase", passphrase]);
        }
        let pk = cast(&args)?;
        out.push(json!({"path": path, "passphrase": passphrase, "address": address_of(&pk)?}));
    }
    Ok(out)
}

fn rlp_cases() -> Result<Vec<Value>, String> {
    let s55 = format!("\"0x{}\"", "ab".repeat(55));
    let s56 = format!("\"0x{}\"", "ab".repeat(56));
    let s1024 = format!("\"0x{}\"", "cd".repeat(1024));
    let list56 = format!("[\"0x{}\",\"0x\"]", "01".repeat(54));
    let inputs: Vec<(&str, String)> = vec![
        ("empty-string", "\"0x\"".into()),
        ("zero-byte", "\"0x00\"".into()),
        ("byte-7f", "\"0x7f\"".into()),
        ("byte-80", "\"0x80\"".into()),
        ("string-55", s55),
        ("string-56", s56),
        ("string-1024", s1024),
        ("empty-list", "[]".into()),
        ("set-theoretic-three", "[[],[[]],[[],[[]]]]".into()),
        ("list-payload-56", list56),
        (
            "mixed",
            "[\"0x01\",[\"0x\",\"0xdeadbeef\"],\"0x80\"]".into(),
        ),
    ];
    let mut out = Vec::new();
    for (name, input) in inputs {
        let encoded = cast(&["to-rlp", &input])?;
        let value: Value = serde_json::from_str(&input).map_err(|e| e.to_string())?;
        out.push(json!({"name": name, "value": value, "cast": {"encoded": encoded}}));
    }
    Ok(out)
}

fn keystore_path(root: &Path) -> PathBuf {
    root.join("test-vectors")
        .join("cast")
        .join("keystores")
        .join("cast-import.json")
}

fn regenerate_keystore(root: &Path, pk: &str) -> Result<(), String> {
    let tmp = std::env::temp_dir().join(format!("keysmith-xtask-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let tmp_str = tmp.display().to_string();
    let result = cast(&[
        "wallet",
        "import",
        "cast-import",
        "--keystore-dir",
        &tmp_str,
        "--private-key",
        pk,
        "--unsafe-password",
        KEYSTORE_PASSWORD,
    ])
    .and_then(|_| {
        let target = keystore_path(root);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        std::fs::copy(tmp.join("cast-import"), &target)
            .map(|_| ())
            .map_err(|e| e.to_string())
    });
    let _ = std::fs::remove_dir_all(&tmp);
    result
}

fn verify_keystore(root: &Path, expected_pk: &str) -> Result<(), String> {
    let path = keystore_path(root);
    let dir = path
        .parent()
        .ok_or("no keystore dir")?
        .display()
        .to_string();
    let out = cast(&[
        "wallet",
        "decrypt-keystore",
        "cast-import.json",
        "--keystore-dir",
        &dir,
        "--unsafe-password",
        KEYSTORE_PASSWORD,
    ])?;
    if !out
        .to_ascii_lowercase()
        .contains(&expected_pk.to_ascii_lowercase()[2..])
    {
        return Err("committed keystore does not decrypt (with cast) to the expected key".into());
    }
    Ok(())
}

/// Entry point.
pub fn run(root: &Path, check: bool) -> Result<String, String> {
    let version = cast(&["--version"])?;
    let version_line = version.lines().next().unwrap_or_default().to_owned();
    let keys: Vec<String> = (0..5).map(private_key).collect::<Result<_, _>>()?;
    let doc = json!({
        "generator": "cargo xtask regen-golden",
        "tool": version_line,
        "mnemonic": MNEMONIC,
        "note": "Keys are anvil's public test keys derived from `mnemonic` (m/44'/60'/0'/0/signerIndex). Never fund them.",
        "transactions": transactions(&keys)?,
        "authorizations": authorizations(&keys)?,
        "messages": messages(&keys)?,
        "typedData": typed_data(root, &keys)?,
        "addresses": addresses()?,
        "rlp": rlp_cases()?,
        "keystores": [{
            "file": "keystores/cast-import.json",
            "password": KEYSTORE_PASSWORD,
            "signerIndex": KEYSTORE_SIGNER,
            "address": address_of(&keys[KEYSTORE_SIGNER])?,
            "cast": {"command": ["wallet", "import", "cast-import", "--keystore-dir", "<tmp>", "--private-key", "<anvil test key>", "--unsafe-password", KEYSTORE_PASSWORD]}
        }]
    });
    let mut text = serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())?;
    text.push('\n');
    let path = root.join("test-vectors").join("cast").join("golden.json");
    if check {
        let committed =
            std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let committed: Value = serde_json::from_str(&committed).map_err(|e| e.to_string())?;
        let mut fresh = doc.clone();
        // The tool line may differ in build metadata only; everything else must match exactly.
        if let (Some(a), Some(b)) = (fresh.get_mut("tool"), committed.get("tool")) {
            *a = b.clone();
        }
        if fresh != committed {
            return Err(format!(
                "{} is stale: cast produces different vectors. Run `cargo xtask regen-golden`.",
                path.display()
            ));
        }
        verify_keystore(root, &keys[KEYSTORE_SIGNER])?;
        return Ok(format!(
            "golden vectors match {version_line}; committed keystore decrypts with cast\n"
        ));
    }
    std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
    regenerate_keystore(root, &keys[KEYSTORE_SIGNER])?;
    Ok(format!("wrote {} with {version_line}\n", path.display()))
}
