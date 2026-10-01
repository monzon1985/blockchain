// SPDX-License-Identifier: MIT
//! Plain-text rendering for operators (stable layout, snapshot-tested).

use keysmith_core::gas::{Finding, Severity};
use keysmith_core::report::TxReport;
use keysmith_core::tx::Transaction;
use keysmith_core::units::{format_ether, format_gwei};
use keysmith_core::{Address, U256, hex};
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

/// Renders the pre-signing review printed to stderr by `keysmith sign`.
pub fn sign_review(tx: &Transaction, signer: &Address, warnings: &[Finding]) -> String {
    let mut out = String::from("--- keysmith sign: review ---\n");
    let mut line = |k: &str, v: String| {
        let _ = writeln!(out, "{k:<16}{v}");
    };
    let chain = tx
        .chain_id()
        .map_or_else(|| "none (pre-EIP-155)".to_owned(), |c| c.to_string());
    line("type", format!("{} on chain {chain}", tx.tx_type()));
    line("from", signer.to_checksum());
    match tx.kind().to() {
        Some(to) => line("to", to.to_checksum()),
        None => line(
            "to",
            format!(
                "CONTRACT CREATION -> {}",
                tx.created_address(signer)
                    .map_or_else(String::new, |a| a.to_checksum())
            ),
        ),
    }
    line("value", wei_with_ether(&tx.value()));
    line("nonce", tx.nonce().to_string());
    line("input", format!("{} bytes", tx.input().len()));
    line("gas limit", tx.gas_limit().to_string());
    let fees = keysmith_core::gas::fee_summary(tx, None);
    line("fee cap", wei_with_gwei(fees.max_fee_per_gas));
    line("max cost", wei_with_ether(&fees.max_total_cost));
    for (i, a) in tx.authorization_list().iter().enumerate() {
        line(
            &format!("authorization {i}"),
            format!(
                "delegate {} on chain {} with nonce {}",
                a.address, a.chain_id, a.nonce
            ),
        );
    }
    findings_block(&mut out, warnings);
    out
}
