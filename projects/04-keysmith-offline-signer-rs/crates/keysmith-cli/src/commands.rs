// SPDX-License-Identifier: MIT
//! Command implementations. Each returns the text to print on stdout; diagnostics go to stderr.
//!
//! Every signing command follows the same order: parse and validate the request, apply the
//! policy (refusing with exit code 3 on a violation), print the review to stderr, ask for the
//! operator's confirmation ([`confirm`]), and only then sign and write the output.

use crate::cli::{
    DecodeArgs, DeriveArgs, ExecutorArg, HashTypedDataArgs, KeystoreExportArgs, MessageInput,
    PermitArgs, PolicyArgs, SignArgs, SignAuthArgs, SignFormat, SignMessageArgs, SignTypedDataArgs,
    VerifyMessageArgs,
};
use crate::confirm::confirm;
use crate::error::CliError;
use crate::keysource::{load_key, load_mnemonic, read_password_file};
use crate::render;
use keysmith_core::authorization::{Authorization, Executor};
use keysmith_core::bip32::{DerivationPath, ExtendedPrivateKey, HARDENED, Network};
use keysmith_core::bip39::Mnemonic;
use keysmith_core::eip712::TypedData;
use keysmith_core::envelope::{self, SignedEnvelope, UnsignedEnvelope};
use keysmith_core::keystore::{self, KeystoreRandomness, ScryptParams};
use keysmith_core::permit::Permit;
use keysmith_core::policy::{Policy, Violation};
use keysmith_core::report;
use keysmith_core::tx::SignedTransaction;
use keysmith_core::units::parse_units;
use keysmith_core::{Address, PrivateKey, Signature, U256, eip191, hex};
use serde_json::json;
use std::io::{Read, Write};
use std::path::Path;
use zeroize::Zeroizing;

fn os_random<const N: usize>() -> Result<[u8; N], CliError> {
    let mut buf = [0u8; N];
    getrandom::fill(&mut buf)
        .map_err(|e| CliError::Core(format!("OS entropy unavailable: {e}")))?;
    Ok(buf)
}

fn read_input(path: &Path) -> Result<String, CliError> {
    if path.as_os_str() == "-" {
        let mut s = String::new();
        std::io::stdin()
            .read_to_string(&mut s)
            .map_err(|e| CliError::Input(format!("cannot read stdin: {e}")))?;
        return Ok(s);
    }
    std::fs::read_to_string(path).map_err(|e| CliError::io("input", path, &e))
}

/// Whether a file written by keysmith holds secret material.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Contents {
    /// A mnemonic or keystore: created owner-only (mode 0600 on Unix).
    Secret,
    /// Anything else (signed envelopes): default permissions.
    Public,
}

/// Creates `path` exclusively (never overwrites) and writes `contents`.
///
/// Secret files are created with mode 0600 on Unix, as `cast` and geth create keystores, so a
/// plaintext mnemonic is never world-readable for even a moment (a later `chmod` would leave
/// that window open). On Windows the file inherits the directory's ACL.
fn write_new_file(path: &Path, contents: &[u8], kind: Contents) -> Result<(), CliError> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    if kind == Contents::Secret {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    #[cfg(not(unix))]
    let _ = kind;
    let mut f = options
        .open(path)
        .map_err(|e| CliError::Input(format!("cannot create {}: {e}", path.display())))?;
    f.write_all(contents)
        .map_err(|e| CliError::Input(format!("cannot write {}: {e}", path.display())))
}

fn to_pretty(v: &impl serde::Serialize) -> Result<String, CliError> {
    serde_json::to_string_pretty(v).map_err(|e| CliError::Core(e.to_string()))
}

/// The kind of request a policy is applied to; it decides what the review says the built-in
/// default policy enforces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scope {
    /// `keysmith sign`.
    Transaction,
    /// `keysmith sign-auth`.
    Authorization,
    /// `keysmith sign-typed-data` and `keysmith permit`.
    TypedData,
}

impl Scope {
    fn default_line(self) -> &'static str {
        match self {
            Scope::Transaction => {
                "default (no --policy file): denies contract creation, pre-EIP-155 legacy and \
                 chainId-0 delegations"
            }
            Scope::Authorization => "default (no --policy file): denies chainId-0 delegations",
            Scope::TypedData => {
                "default (no --policy file): no typed-data limits; restrict with allowedChainIds, \
                 allowedVerifyingContracts, allowedSpenders and maxPermitValue"
            }
        }
    }

    fn none_line(self) -> &'static str {
        match self {
            Scope::Transaction => "NONE (--no-policy): only consensus checks apply",
            Scope::Authorization | Scope::TypedData => "NONE (--no-policy)",
        }
    }
}

/// Resolves the policy of a signing command, with the line the review shows for it.
///
/// No flag means [`Policy::default`] (the empty policy), so its deny-by-default booleans hold
/// whether or not the operator wrote a policy file; `--no-policy` is the explicit escape hatch.
fn load_policy(args: &PolicyArgs, scope: Scope) -> Result<(Option<Policy>, String), CliError> {
    if let Some(path) = &args.policy {
        let policy = Policy::from_json_str(&read_input(path)?)?;
        return Ok((Some(policy), format!("{}", path.display())));
    }
    if args.no_policy {
        return Ok((None, scope.none_line().to_owned()));
    }
    Ok((Some(Policy::default()), scope.default_line().to_owned()))
}

fn refuse_violations(violations: &[Violation]) -> Result<(), CliError> {
    if violations.is_empty() {
        return Ok(());
    }
    let msg = violations
        .iter()
        .map(|v| format!("[{}] {}", v.rule, v.message))
        .collect::<Vec<_>>()
        .join("; ");
    Err(CliError::Refused(format!("policy violation: {msg}")))
}

/// Seconds since the Unix epoch from the offline machine's clock (for deadline warnings).
fn unix_now() -> Option<u64> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

/// `keysmith mnemonic new`.
pub fn mnemonic_new(words: usize, out: Option<&Path>) -> Result<String, CliError> {
    let bytes = match words {
        12 => 16,
        15 => 20,
        18 => 24,
        21 => 28,
        24 => 32,
        other => {
            return Err(CliError::Input(format!(
                "--words must be 12, 15, 18, 21 or 24 (got {other})"
            )));
        }
    };
    let entropy = Zeroizing::new(os_random::<32>()?);
    let mnemonic = Mnemonic::from_entropy(&entropy[..bytes])?;
    match out {
        Some(path) => {
            let mut text = Zeroizing::new(mnemonic.phrase().to_owned());
            text.push('\n');
            write_new_file(path, text.as_bytes(), Contents::Secret)?;
            eprintln!("wrote a {words}-word mnemonic to {}", path.display());
            Ok(String::new())
        }
        None => {
            eprintln!("WARNING: this phrase controls every derived key; write it down offline.");
            Ok(format!("{}\n", mnemonic.phrase()))
        }
    }
}

/// `keysmith mnemonic validate`.
pub fn mnemonic_validate(path: &Path) -> Result<String, CliError> {
    let m = load_mnemonic(path)?;
    Ok(format!(
        "valid BIP-39 mnemonic ({} words)\n",
        m.word_count()
    ))
}

/// `keysmith derive`.
pub fn derive(args: &DeriveArgs) -> Result<String, CliError> {
    let mnemonic = load_mnemonic(&args.mnemonic_file)?;
    let passphrase = match &args.passphrase_file {
        Some(p) => read_password_file(p, "passphrase")?,
        None => Zeroizing::new(String::new()),
    };
    let master = ExtendedPrivateKey::from_seed(&mnemonic.to_seed(&passphrase))?;
    let account = master.derive_path(&DerivationPath::parse("m/44'/60'/0'")?)?;
    let external = account.derive_child(0)?;
    let end = args
        .start
        .checked_add(args.count)
        .filter(|e| *e <= HARDENED)
        .ok_or_else(|| CliError::Input("--start + --count exceeds 2^31".into()))?;
    let mut rows = Vec::new();
    for index in args.start..end {
        let key = external.derive_child(index)?;
        rows.push((
            format!("m/44'/60'/0'/0/{index}"),
            key.private_key().address(),
        ));
    }
    let xpub = args
        .xpub
        .then(|| account.public().to_extended_string(Network::Mainnet));
    if args.json {
        let accounts: Vec<_> = rows
            .iter()
            .map(|(p, a)| json!({"path": p, "address": a}))
            .collect();
        return Ok(format!(
            "{}\n",
            to_pretty(&json!({"accounts": accounts, "accountXpub": xpub}))?
        ));
    }
    let mut out = String::new();
    for (path, address) in &rows {
        out.push_str(&format!("{path:<24}{address}\n"));
    }
    if let Some(x) = xpub {
        out.push_str(&format!("account xpub (m/44'/60'/0'): {x}\n"));
    }
    Ok(out)
}

/// `keysmith address`.
pub fn address(key: &PrivateKey) -> String {
    format!("{}\n", key.address())
}

/// `keysmith keystore export`.
pub fn keystore_export(args: &KeystoreExportArgs) -> Result<String, CliError> {
    let key = load_key(&args.key)?;
    let password = read_password_file(&args.new_password_file, "new password")?;
    if password.is_empty() {
        return Err(CliError::Input(
            "refusing to export with an empty password".into(),
        ));
    }
    let randomness = KeystoreRandomness {
        salt: os_random()?,
        iv: os_random()?,
        uuid: os_random()?,
    };
    let params = ScryptParams {
        log_n: args.scrypt_log_n,
        ..ScryptParams::STANDARD
    };
    let json = keystore::encrypt(&key, password.as_bytes(), params, &randomness)?;
    write_new_file(&args.out, json.as_bytes(), Contents::Secret)?;
    Ok(format!("{}\n", key.address()))
}

/// `keysmith keystore inspect`.
pub fn keystore_inspect(path: &Path) -> Result<String, CliError> {
    let info = keystore::inspect(&read_input(path)?)?;
    Ok(format!("{}\n", to_pretty(&info)?))
}

/// `keysmith sign`: validate and policy-check the envelope, print the review, confirm, sign.
pub fn sign(args: &SignArgs) -> Result<String, CliError> {
    let env = UnsignedEnvelope::from_json_str(&read_input(&args.envelope)?)?;
    let (policy, policy_line) = load_policy(&args.policy, Scope::Transaction)?;
    let key = load_key(&args.key)?;
    let plan = envelope::plan_envelope(&env, &key, policy.as_ref())?;
    eprint!("{}", render::sign_review(&plan, &policy_line));
    confirm(args.confirm.yes)?;
    let outcome = plan.sign(&key)?;
    let text = match args.format {
        SignFormat::Json => format!("{}\n", to_pretty(&outcome.envelope)?),
        SignFormat::Raw => format!("{}\n", outcome.envelope.raw),
    };
    match &args.out {
        Some(path) => {
            write_new_file(path, text.as_bytes(), Contents::Public)?;
            Ok(format!("{}\n", outcome.envelope.hash))
        }
        None => Ok(text),
    }
}

/// `keysmith sign-auth`.
pub fn sign_auth(args: &SignAuthArgs) -> Result<String, CliError> {
    let chain_id = U256::parse(&args.chain_id)?;
    let address = Address::parse(&args.address)?;
    let executor = match args.executor {
        ExecutorArg::Sponsor => Executor::Sponsor,
        ExecutorArg::SelfExecuting => Executor::SelfExecuting,
    };
    let nonce = executor
        .authorization_nonce(args.nonce)
        .ok_or_else(|| CliError::Input("nonce + 1 overflows".into()))?;
    let auth = Authorization {
        chain_id,
        address,
        nonce,
    };
    let (policy, policy_line) = load_policy(&args.policy, Scope::Authorization)?;
    if let Some(policy) = &policy {
        refuse_violations(&policy.check_authorization(&auth))?;
    }
    let key = load_key(&args.key)?;
    eprint!(
        "{}",
        render::auth_review(&auth, &key.address(), executor, args.nonce, &policy_line)
    );
    confirm(args.confirm.yes)?;
    let signed = auth.sign(&key)?;
    if args.json {
        return Ok(format!(
            "{}\n",
            to_pretty(&json!({
                "authority": key.address(),
                "executor": executor,
                "authorization": signed,
                "rlp": hex::encode_prefixed(&signed.encode()),
            }))?
        ));
    }
    Ok(format!("{}\n", hex::encode_prefixed(&signed.encode())))
}

fn message_bytes(input: &MessageInput) -> Result<Vec<u8>, CliError> {
    if let Some(m) = &input.message {
        return Ok(m.as_bytes().to_vec());
    }
    if let Some(p) = &input.message_file {
        return std::fs::read(p).map_err(|e| CliError::io("message", p, &e));
    }
    if let Some(h) = &input.hex {
        return Ok(hex::decode(h)?);
    }
    Err(CliError::Input("no message given".into()))
}

/// `keysmith sign-message`.
///
/// There is no policy for EIP-191 messages: `personal_sign` has no chain id, contract or
/// amount to constrain. The review shows the exact bytes (escaped) and the digest.
pub fn sign_message(args: &SignMessageArgs) -> Result<String, CliError> {
    let message = message_bytes(&args.input)?;
    let key = load_key(&args.key)?;
    eprint!("{}", render::message_review(&message, &key.address()));
    confirm(args.confirm.yes)?;
    let sig = eip191::sign_personal_message(&key, &message)?;
    Ok(format!("{}\n", hex::encode_prefixed(&sig.to_rsv_bytes())))
}

/// `keysmith verify-message`.
pub fn verify_message(args: &VerifyMessageArgs) -> Result<String, CliError> {
    let message = message_bytes(&args.input)?;
    let expected = Address::parse(&args.address)?;
    let sig = Signature::from_rsv_bytes(&hex::decode(&args.signature)?)?;
    let recovered = eip191::recover_personal_message(&message, &sig)?;
    if recovered != expected {
        return Err(CliError::Input(format!(
            "signature is by {recovered}, not {expected}"
        )));
    }
    Ok(format!("valid signature by {recovered}\n"))
}

fn load_typed_data(path: &Path) -> Result<TypedData, CliError> {
    Ok(TypedData::from_json_str(&read_input(path)?)?)
}

/// `keysmith hash-typed-data`.
pub fn hash_typed_data(args: &HashTypedDataArgs) -> Result<String, CliError> {
    let td = load_typed_data(&args.file)?;
    let message_hash = td.message_hash()?.map(|h| hex::encode_prefixed(&h));
    Ok(format!(
        "{}\n",
        to_pretty(&json!({
            "primaryType": td.primary_type(),
            "encodeType": td.encode_type(td.primary_type())?,
            "domainSeparator": hex::encode_prefixed(&td.domain_separator()?),
            "messageHash": message_hash,
            "digest": hex::encode_prefixed(&td.signing_hash()?),
        }))?
    ))
}

/// `keysmith sign-typed-data`.
pub fn sign_typed_data(args: &SignTypedDataArgs) -> Result<String, CliError> {
    let td = load_typed_data(&args.file)?;
    // Hashing validates the whole document (types, values, depth) before anything else.
    let digest = td.signing_hash()?;
    let (policy, policy_line) = load_policy(&args.policy, Scope::TypedData)?;
    if let Some(policy) = &policy {
        refuse_violations(&policy.check_typed_data(&td)?)?;
    }
    let key = load_key(&args.key)?;
    let findings = td.review_findings(unix_now())?;
    eprint!(
        "{}",
        render::typed_data_review(
            "sign-typed-data",
            &td,
            &key.address(),
            &digest,
            &findings,
            &policy_line
        )?
    );
    confirm(args.confirm.yes)?;
    let sig = key.sign_hash(&digest)?;
    let packed = hex::encode_prefixed(&sig.to_rsv_bytes());
    if args.json {
        return Ok(format!(
            "{}\n",
            to_pretty(&json!({
                "signer": key.address(),
                "digest": hex::encode_prefixed(&digest),
                "signature": packed,
                "v": 27 + u8::from(sig.y_parity),
                "r": hex::encode_prefixed(&sig.r.to_be_bytes()),
                "s": hex::encode_prefixed(&sig.s.to_be_bytes()),
            }))?
        ));
    }
    Ok(format!("{packed}\n"))
}

/// `keysmith permit`: an ERC-2612 permit, reviewed and policy-checked as the equivalent typed
/// data.
pub fn permit(args: &PermitArgs) -> Result<String, CliError> {
    let (policy, policy_line) = load_policy(&args.policy, Scope::TypedData)?;
    let key = load_key(&args.key)?;
    let permit = Permit {
        token_name: args.name.clone(),
        token_version: args.version.clone(),
        chain_id: U256::parse(&args.chain_id)?,
        token: Address::parse(&args.token)?,
        owner: key.address(),
        spender: Address::parse(&args.spender)?,
        value: parse_units(&args.value)?,
        nonce: U256::parse(&args.nonce)?,
        deadline: U256::parse(&args.deadline)?,
    };
    let td = permit.typed_data()?;
    if let Some(policy) = &policy {
        refuse_violations(&policy.check_typed_data(&td)?)?;
    }
    let findings = td.review_findings(unix_now())?;
    eprint!(
        "{}",
        render::typed_data_review(
            "permit",
            &td,
            &key.address(),
            &permit.signing_hash(),
            &findings,
            &policy_line
        )?
    );
    confirm(args.confirm.yes)?;
    let signed = permit.sign(&key)?;
    let packed = hex::encode_prefixed(&signed.signature.to_rsv_bytes());
    if args.json {
        return Ok(format!(
            "{}\n",
            to_pretty(&json!({
                "owner": permit.owner,
                "spender": permit.spender,
                "value": permit.value,
                "nonce": permit.nonce,
                "deadline": permit.deadline,
                "digest": hex::encode_prefixed(&signed.digest),
                "v": signed.v(),
                "r": hex::encode_prefixed(&signed.signature.r.to_be_bytes()),
                "s": hex::encode_prefixed(&signed.signature.s.to_be_bytes()),
                "signature": packed,
            }))?
        ));
    }
    Ok(format!("{packed}\n"))
}

/// `keysmith decode`.
pub fn decode(args: &DecodeArgs) -> Result<String, CliError> {
    let text = match (&args.raw, &args.file) {
        (Some(raw), _) => raw.clone(),
        (None, Some(path)) => read_input(path)?,
        (None, None) => return Err(CliError::Input("give a raw transaction or --file".into())),
    };
    let trimmed = text.trim();
    let raw_hex = if trimmed.starts_with('{') {
        SignedEnvelope::from_json_str(trimmed)?.raw
    } else {
        trimmed.to_owned()
    };
    let signed = SignedTransaction::decode(&hex::decode(&raw_hex)?)?;
    let base_fee = args
        .base_fee
        .as_deref()
        .map(|b| {
            parse_units(b)?
                .to_u128()
                .ok_or_else(|| CliError::Input("--base-fee does not fit in u128".into()))
        })
        .transpose()?;
    let r = report::report(&signed, base_fee);
    if args.json {
        return Ok(format!("{}\n", to_pretty(&r)?));
    }
    Ok(render::decode_report(&r))
}
