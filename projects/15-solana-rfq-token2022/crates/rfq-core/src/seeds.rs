// SPDX-License-Identifier: MIT
//! PDA seed prefixes shared by both program implementations and the client.
//!
//! | Account | Seeds | Owner |
//! |---|---|---|
//! | `Config` | `["config"]` | RFQ program |
//! | `Maker` | `["maker", maker_owner]` | RFQ program |
//! | vault authority | `["vault_authority", maker_owner]` | none (signer-only PDA) |
//! | vault token account | `["vault", maker_owner, mint]` | token program |
//! | fee vault token account | `["fee_vault", mint]` | token program |
//! | `NoncePage` | `["nonces", maker_owner, page_le_u64]` | RFQ program |
//! | `QuoteFill` | `["fill", maker_owner, nonce_le_u64]` | RFQ program |

/// Seed of the global configuration PDA.
pub const CONFIG: &[u8] = b"config";
/// Seed prefix of per-maker registry PDAs.
pub const MAKER: &[u8] = b"maker";
/// Seed prefix of the per-maker PDA that owns every vault token account.
pub const VAULT_AUTHORITY: &[u8] = b"vault_authority";
/// Seed prefix of per-maker, per-mint vault token accounts.
pub const VAULT: &[u8] = b"vault";
/// Seed prefix of per-mint protocol fee vaults (owned by the config PDA).
pub const FEE_VAULT: &[u8] = b"fee_vault";
/// Seed prefix of per-maker nonce bitmap pages (256 nonces each).
pub const NONCE_PAGE: &[u8] = b"nonces";
/// Seed prefix of per-quote partial-fill trackers.
pub const QUOTE_FILL: &[u8] = b"fill";
