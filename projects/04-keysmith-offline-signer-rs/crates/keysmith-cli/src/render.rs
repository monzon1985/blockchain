// SPDX-License-Identifier: MIT
//! Plain-text rendering for operators (stable layout, snapshot-tested).

use keysmith_core::authorization::{Authorization, Executor};
use keysmith_core::calldata::{self, Erc20Call};
use keysmith_core::eip712::{Eip712Error, Field, FieldValue, TypedData};
use keysmith_core::envelope::SigningPlan;
use keysmith_core::gas::{Finding, Severity};
use keysmith_core::report::TxReport;
use keysmith_core::units::{format_ether, format_gwei};
use keysmith_core::{Address, U256, eip191, hex};
use std::fmt::Write;

fn wei_with_gwei(v: u128) -> String {
    format!("{v} wei/gas ({} gwei)", format_gwei(&U256::from_u128(v)))
}

fn wei_with_ether(v: &U256) -> String {
    format!("{v} wei ({} ETH)", format_ether(v))
}

fn findings_block(out: &mut String, findings: &[Finding]) {
    if findings.is_empty() {
        let _ = writeln!(out, "{:<16}none", "findings");
        return;
    }
    for f in findings {
        let sev = match f.severity {
            Severity::Error => "ERROR",
            Severity::Warning => "warning",
        };
        let _ = writeln!(out, "{:<16}[{sev}] {}: {}", "finding", f.code, f.message);
    }
}

/// Renders a decode report.
pub fn decode_report(r: &TxReport) -> String {
    let mut out = String::new();
    let type_byte = r
        .tx_type
        .type_byte()
        .map_or_else(|| "untyped".to_owned(), |b| format!("0x{b:02x}"));
    let line = |out: &mut String, k: &str, v: String| {
        let _ = writeln!(out, "{k:<16}{v}");
    };
    line(&mut out, "type", format!("{} ({type_byte})", r.tx_type));
    line(&mut out, "hash", r.hash.clone());
    match (&r.signer, &r.signer_error) {
        (Some(s), _) => line(&mut out, "signer", s.to_checksum()),
        (None, Some(e)) => line(&mut out, "signer", format!("UNRECOVERABLE ({e})")),
        (None, None) => line(&mut out, "signer", "unknown".into()),
    }
    line(
        &mut out,
        "chain id",
        r.chain_id
            .map_or_else(|| "none (pre-EIP-155)".to_owned(), |c| c.to_string()),
    );
    line(&mut out, "nonce", r.nonce.to_string());
    match (&r.to, &r.contract_address) {
        (Some(to), _) => line(&mut out, "to", to.to_checksum()),
        (None, Some(created)) => line(&mut out, "to", format!("contract creation -> {created}")),
        (None, None) => line(&mut out, "to", "contract creation".into()),
    }
    line(&mut out, "value", wei_with_ether(&r.value));
    let selector = r
        .selector
        .as_ref()
        .map_or_else(String::new, |s| format!(", selector {s}"));
    line(
        &mut out,
        "input",
        format!("{} bytes{selector}", r.input_bytes),
    );
    line(&mut out, "gas limit", r.gas_limit.to_string());
    match r.fees.max_priority_fee_per_gas {
        Some(tip) => {
            line(&mut out, "max fee", wei_with_gwei(r.fees.max_fee_per_gas));
            line(&mut out, "max priority", wei_with_gwei(tip));
        }
        None => line(&mut out, "gas price", wei_with_gwei(r.fees.max_fee_per_gas)),
    }
    if let Some(p) = r.fees.effective_gas_price {
        line(&mut out, "effective price", wei_with_gwei(p));
    }
    line(&mut out, "max cost", wei_with_ether(&r.fees.max_total_cost));
    let g = &r.intrinsic_gas;
    line(
        &mut out,
        "intrinsic gas",
        format!(
            "{} = base {} + calldata {} + create {} + initcode {} + access list {} + authorizations {}",
            g.total, g.base, g.calldata, g.create, g.initcode, g.access_list, g.authorizations
        ),
    );
    line(
        &mut out,
        "calldata floor",
        format!(
            "{} (EIP-7623); minimum gas limit {}",
            g.floor, g.minimum_gas_limit
        ),
    );
    for item in &r.access_list {
        line(
            &mut out,
            "access list",
            format!(
                "{} ({} storage keys)",
                item.address,
                item.storage_keys.len()
            ),
        );
        for key in &item.storage_keys {
            line(&mut out, "", format!("  {}", hex::encode_prefixed(key)));
        }
    }
    for (i, a) in r.authorizations.iter().enumerate() {
        let who = match (&a.authority, &a.error) {
            (Some(x), _) => format!("authority {x}"),
            (None, Some(e)) => format!("INVALID ({e})"),
            (None, None) => "unknown authority".into(),
        };
        let chain = if a.chain_id.is_zero() {
            "0 (ANY chain)".to_owned()
        } else {
            a.chain_id.to_string()
        };
        line(
            &mut out,
            &format!("authorization {i}"),
            format!(
                "delegate {}, chain {chain}, nonce {}, {who}",
                a.address, a.nonce
            ),
        );
    }
    line(
        &mut out,
        "signature",
        format!(
            "yParity {}, r {:#x}, s {:#x}, low-s {}",
            u8::from(r.signature.y_parity),
            r.signature.r,
            r.signature.s,
            if r.signature.low_s { "yes" } else { "NO" }
        ),
    );
    findings_block(&mut out, &r.findings);
    out
}

/// Quotes untrusted text for display.
///
/// Printable ASCII passes through, quotes and backslashes are escaped, and every other
/// character (line breaks, ANSI escape sequences, other control characters, bidirectional
/// overrides, any non-ASCII) is shown as `\u{..}`. Text from an envelope or a typed-data file
/// therefore cannot fake review lines, recolour the terminal or hide what follows it.
pub fn quote_untrusted(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            ' '..='~' => out.push(c),
            other => {
                let _ = write!(out, "\\u{{{:x}}}", u32::from(other));
            }
        }
    }
    out.push('"');
    out
}

fn line(out: &mut String, k: &str, v: impl std::fmt::Display) {
    let _ = writeln!(out, "{k:<16}{v}");
}

/// Hex dump for review: the 4-byte selector of a call on its own line, then one 32-byte ABI
/// word per line (initcode is cut into 32-byte rows the same way).
fn hex_rows(out: &mut String, label: &str, data: &[u8], selector_first: bool) {
    if data.is_empty() {
        line(out, label, "0x (empty)");
        return;
    }
    let (head, rest) = if selector_first && data.len() >= 4 {
        data.split_at(4)
    } else {
        data.split_at(0)
    };
    let mut rows: Vec<&[u8]> = Vec::new();
    if !head.is_empty() {
        rows.push(head);
    }
    rows.extend(rest.chunks(32));
    for (i, row) in rows.iter().enumerate() {
        if i == 0 {
            line(out, label, format!("0x{}", hex::encode(row)));
        } else {
            line(out, "", format!("  {}", hex::encode(row)));
        }
    }
}

fn amount(v: &U256) -> String {
    if *v == U256::MAX {
        format!("{v} (2^256-1: UNLIMITED)")
    } else {
        format!("{v}")
    }
}

fn erc20_line(out: &mut String, input: &[u8]) {
    let Some(decoded) = calldata::decode_erc20(input) else {
        return;
    };
    let text = match decoded {
        Ok(Erc20Call::Transfer { to, amount: a }) => {
            format!("transfer {} base units to {to}", amount(&a))
        }
        Ok(Erc20Call::Approve { spender, amount: a }) => {
            format!("APPROVE {spender} to spend {} base units", amount(&a))
        }
        Ok(Erc20Call::TransferFrom {
            from,
            to,
            amount: a,
        }) => {
            format!("transferFrom {from} to {to}, {} base units", amount(&a))
        }
        Err(signature) => {
            format!("selector of {signature}, but the arguments are not a canonical ABI encoding")
        }
    };
    line(out, "ERC-20 call", text);
}

/// Renders the review `keysmith sign` prints to stderr **before** asking for confirmation and
/// signing: every field that is signed (the full calldata, access list and authorizations with
/// their recovered authorities), the policy in force, the envelope's note (labelled untrusted)
/// and the findings.
pub fn sign_review(plan: &SigningPlan, policy: &str) -> String {
    let tx = &plan.tx;
    let signer = &plan.signer;
    let mut out =
        String::from("--- keysmith sign: review (nothing is signed until you confirm) ---\n");
    let chain = tx
        .chain_id()
        .map_or_else(|| "none (pre-EIP-155)".to_owned(), |c| c.to_string());
    line(
        &mut out,
        "type",
        format!("{} on chain {chain}", tx.tx_type()),
    );
    line(&mut out, "from", signer.to_checksum());
    let to = tx.kind().to();
    match to {
        Some(to) => line(&mut out, "to", to.to_checksum()),
        None => line(
            &mut out,
            "to",
            format!(
                "CONTRACT CREATION -> {}",
                tx.created_address(signer)
                    .map_or_else(String::new, |a| a.to_checksum())
            ),
        ),
    }
    line(&mut out, "value", wei_with_ether(&tx.value()));
    line(&mut out, "nonce", tx.nonce().to_string());
    line(&mut out, "gas limit", tx.gas_limit().to_string());
    let fees = keysmith_core::gas::fee_summary(tx, None);
    line(&mut out, "fee cap", wei_with_gwei(fees.max_fee_per_gas));
    if let Some(tip) = fees.max_priority_fee_per_gas {
        line(&mut out, "priority fee", wei_with_gwei(tip));
    }
    line(&mut out, "max cost", wei_with_ether(&fees.max_total_cost));
    let input = tx.input();
    let is_call = to.is_some();
    let summary = match (is_call, input.get(..4)) {
        (false, _) => format!("{} bytes of initcode", input.len()),
        (true, Some(sel)) => {
            let known = calldata::erc20_signature(sel)
                .map_or_else(String::new, |s| format!(" = ERC-20 {s}"));
            format!(
                "{} bytes, selector 0x{}{known}",
                input.len(),
                hex::encode(sel)
            )
        }
        (true, None) => format!("{} bytes", input.len()),
    };
    line(&mut out, "input", summary);
    if is_call {
        erc20_line(&mut out, input);
    }
    if !input.is_empty() {
        hex_rows(
            &mut out,
            if is_call { "calldata" } else { "initcode" },
            input,
            is_call,
        );
    }
    for item in tx.access_list() {
        line(
            &mut out,
            "access list",
            format!(
                "{} ({} storage keys)",
                item.address,
                item.storage_keys.len()
            ),
        );
        for key in &item.storage_keys {
            line(&mut out, "", format!("  {}", hex::encode_prefixed(key)));
        }
    }
    for (i, a) in tx.authorization_list().iter().enumerate() {
        let chain = if a.chain_id.is_zero() {
            "0 (ANY chain)".to_owned()
        } else {
            a.chain_id.to_string()
        };
        let who = match a.recover_authority() {
            Ok(x) if x == *signer => format!("authority {x} (the signer)"),
            Ok(x) => format!("authority {x}"),
            Err(e) => format!("INVALID SIGNATURE ({e})"),
        };
        line(
            &mut out,
            &format!("authorization {i}"),
            format!(
                "delegate {} on chain {chain} with nonce {}, {who}",
                a.address, a.nonce
            ),
        );
    }
    line(&mut out, "policy", policy);
    if let Some(note) = &plan.note {
        line(
            &mut out,
            "note",
            format!(
                "UNTRUSTED text from the envelope author, not a description of what is signed: {}",
                quote_untrusted(note)
            ),
        );
    }
    findings_block(&mut out, &plan.warnings);
    out
}

fn field_value(v: &FieldValue) -> String {
    match v {
        FieldValue::Uint(n) => n.to_string(),
        FieldValue::Int {
            negative: true,
            magnitude,
        } => format!("-{magnitude}"),
        FieldValue::Int { magnitude, .. } => magnitude.to_string(),
        FieldValue::Bool(b) => b.to_string(),
        FieldValue::Address(a) => a.to_checksum(),
        FieldValue::Bytes(b) => hex::encode_prefixed(b),
        FieldValue::Text(t) => quote_untrusted(t),
        FieldValue::EmptyArray => "[] (empty array)".to_owned(),
    }
}

fn fields_block(out: &mut String, title: String, fields: &[Field]) {
    let _ = writeln!(out, "{title}");
    if fields.is_empty() {
        let _ = writeln!(out, "  (no members)");
    }
    for f in fields {
        let _ = writeln!(out, "  {} ({}): {}", f.path, f.ty, field_value(&f.value));
    }
}

/// Renders the review of an EIP-712 document (`keysmith sign-typed-data` and `keysmith
/// permit`), printed before confirmation: every hashed domain and message leaf, the digest,
/// the policy in force and the warnings.
pub fn typed_data_review(
    command: &str,
    td: &TypedData,
    signer: &Address,
    digest: &[u8; 32],
    findings: &[Finding],
    policy: &str,
) -> Result<String, Eip712Error> {
    let mut out =
        format!("--- keysmith {command}: review (nothing is signed until you confirm) ---\n");
    line(&mut out, "signer", signer.to_checksum());
    line(&mut out, "primary type", td.primary_type());
    fields_block(
        &mut out,
        "domain (hashed into the domain separator)".to_owned(),
        &td.domain_fields()?,
    );
    if td.primary_type() != "EIP712Domain" {
        fields_block(
            &mut out,
            "message (every leaf is hashed; quoted strings are untrusted text, shown escaped)"
                .to_owned(),
            &td.message_fields()?,
        );
    }
    line(&mut out, "digest", hex::encode_prefixed(digest));
    line(&mut out, "policy", policy);
    findings_block(&mut out, findings);
    Ok(out)
}

/// Renders the review of `keysmith sign-auth`, printed before confirmation.
pub fn auth_review(
    auth: &Authorization,
    authority: &Address,
    executor: Executor,
    account_nonce: u64,
    policy: &str,
) -> String {
    let mut out =
        String::from("--- keysmith sign-auth: review (nothing is signed until you confirm) ---\n");
    line(
        &mut out,
        "authority",
        format!("{authority} (the signing key)"),
    );
    line(&mut out, "delegate", auth.address.to_checksum());
    if auth.is_any_chain() {
        line(&mut out, "chain id", "0 (ANY chain)");
    } else {
        line(&mut out, "chain id", auth.chain_id.to_string());
    }
    let rule = match executor {
        Executor::Sponsor => format!("executor sponsor: the current account nonce {account_nonce}"),
        Executor::SelfExecuting => {
            format!("executor self: the current account nonce {account_nonce} + 1")
        }
    };
    line(&mut out, "nonce", format!("{} ({rule})", auth.nonce));
    line(&mut out, "policy", policy);
    if auth.is_any_chain() {
        let _ = writeln!(
            out,
            "WARNING: chainId 0 makes this delegation valid on EVERY EVM chain; anyone can replay it \
             wherever your nonce matches."
        );
    }
    out
}

/// Renders the review of `keysmith sign-message`, printed before confirmation.
pub fn message_review(message: &[u8], signer: &Address) -> String {
    let mut out = String::from(
        "--- keysmith sign-message: review (nothing is signed until you confirm) ---\n",
    );
    line(&mut out, "signer", signer.to_checksum());
    match std::str::from_utf8(message) {
        Ok(text) => line(
            &mut out,
            "message",
            format!(
                "{} bytes of UTF-8 (untrusted, shown escaped): {}",
                message.len(),
                quote_untrusted(text)
            ),
        ),
        Err(_) => line(
            &mut out,
            "message",
            format!(
                "{} bytes, not UTF-8: {}",
                message.len(),
                hex::encode_prefixed(message)
            ),
        ),
    }
    line(
        &mut out,
        "digest",
        format!(
            "{} (EIP-191 personal_sign)",
            hex::encode_prefixed(&eip191::personal_message_hash(message))
        ),
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn untrusted_text_cannot_forge_review_lines() {
        assert_eq!(quote_untrusted("pay alice 1 USDC"), "\"pay alice 1 USDC\"");
        // A newline followed by a fake "findings none" line, an ANSI colour code and a
        // right-to-left override all stay on one visibly escaped line.
        let hostile = "ok\nfindings        none\u{1b}[32m\u{202e}\"\\é";
        let shown = quote_untrusted(hostile);
        assert_eq!(
            shown,
            "\"ok\\u{a}findings        none\\u{1b}[32m\\u{202e}\\\"\\\\\\u{e9}\""
        );
        assert!(!shown.contains('\n') && !shown.contains('\u{1b}'));
    }

    #[test]
    fn calldata_rows_put_the_selector_first() {
        let mut out = String::new();
        let mut data = vec![0xa9, 0x05, 0x9c, 0xbb];
        data.extend_from_slice(&[0x11; 40]);
        hex_rows(&mut out, "calldata", &data, true);
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], format!("{:<16}0xa9059cbb", "calldata"));
        assert_eq!(lines[1], format!("{:<16}  {}", "", "11".repeat(32)));
        assert_eq!(lines[2], format!("{:<16}  {}", "", "11".repeat(8)));
        let mut init = String::new();
        hex_rows(&mut init, "initcode", &[0x60; 3], false);
        assert_eq!(init, format!("{:<16}0x606060\n", "initcode"));
    }
}
