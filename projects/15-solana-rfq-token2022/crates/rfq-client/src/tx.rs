// SPDX-License-Identifier: MIT
//! Transactions: compute budget, address lookup tables and v0 messages.
//!
//! A settlement touches 17 fixed accounts plus up to a dozen transfer-hook
//! extras, and carries a 320-byte ed25519 instruction and 192 bytes of
//! `settle` data. As a legacy transaction that exceeds the 1232-byte packet
//! limit for hooked mints; a v0 transaction that loads the non-signer accounts
//! from an address lookup table shrinks every such key from 32 bytes to 1.

use {
    crate::{ClientError, Pubkey, ix::SettleAccounts},
    solana_compute_budget_interface::ComputeBudgetInstruction,
    solana_hash::Hash,
    solana_instruction::{AccountMeta, Instruction},
    solana_keypair::Keypair,
    solana_message::{AddressLookupTableAccount, Message, VersionedMessage, v0},
    solana_transaction::versioned::VersionedTransaction,
};

pub use solana_address_lookup_table_interface::instruction::{
    create_lookup_table, extend_lookup_table,
};

/// Maximum serialized transaction size (one IPv6 MTU minus headers).
pub const PACKET_DATA_SIZE: usize = 1232;

/// `SetComputeUnitLimit(units)`.
pub fn compute_unit_limit(units: u32) -> Instruction {
    ComputeBudgetInstruction::set_compute_unit_limit(units)
}

/// Every non-signer account of a settlement worth putting in a lookup table
/// (the derived PDAs, mints, vaults, programs and the hook extras).
pub fn settle_lookup_addresses(
    program: &Pubkey,
    accounts: &SettleAccounts,
    nonce: u64,
    remaining: &[AccountMeta],
) -> Vec<Pubkey> {
    let mut keys: Vec<Pubkey> = accounts
        .metas(program, nonce)
        .into_iter()
        .filter(|m| !m.is_signer)
        .map(|m| m.pubkey)
        .collect();
    keys.extend(remaining.iter().filter(|m| !m.is_signer).map(|m| m.pubkey));
    keys.push(*program);
    let mut out: Vec<Pubkey> = Vec::with_capacity(keys.len());
    for k in keys {
        if !out.contains(&k) {
            out.push(k);
        }
    }
    out
}

/// Compiles and signs a v0 transaction against `tables`.
pub fn v0_transaction(
    payer: &Keypair,
    extra_signers: &[&Keypair],
    instructions: &[Instruction],
    tables: &[AddressLookupTableAccount],
    recent_blockhash: Hash,
) -> Result<VersionedTransaction, ClientError> {
    let message =
        v0::Message::try_compile(&payer_pubkey(payer), instructions, tables, recent_blockhash)
            .map_err(|e| ClientError::Compile(e.to_string()))?;
    let mut signers: Vec<&Keypair> = vec![payer];
    signers.extend_from_slice(extra_signers);
    VersionedTransaction::try_new(VersionedMessage::V0(message), &signers)
        .map_err(|e| ClientError::Signing(e.to_string()))
}

/// Compiles and signs a legacy transaction (for size comparisons).
pub fn legacy_transaction(
    payer: &Keypair,
    extra_signers: &[&Keypair],
    instructions: &[Instruction],
    recent_blockhash: Hash,
) -> Result<VersionedTransaction, ClientError> {
    let message =
        Message::new_with_blockhash(instructions, Some(&payer_pubkey(payer)), &recent_blockhash);
    let mut signers: Vec<&Keypair> = vec![payer];
    signers.extend_from_slice(extra_signers);
    VersionedTransaction::try_new(VersionedMessage::Legacy(message), &signers)
        .map_err(|e| ClientError::Signing(e.to_string()))
}

/// Wire size of a transaction: `shortvec(#sigs) || sigs || message`.
pub fn serialized_len(tx: &VersionedTransaction) -> usize {
    let sigs = tx.signatures.len();
    let shortvec = if sigs < 0x80 { 1 } else { 2 };
    shortvec + 64 * sigs + tx.message.serialize().len()
}

fn payer_pubkey(payer: &Keypair) -> Pubkey {
    use solana_signer::Signer;
    payer.pubkey()
}
