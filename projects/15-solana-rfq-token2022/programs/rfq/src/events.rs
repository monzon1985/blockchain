// SPDX-License-Identifier: MIT
//! Events. Every state-changing instruction emits one.

use anchor_lang::prelude::*;

/// The config was created.
#[event]
pub struct ConfigInitialized {
    /// Initial admin (the upgrade authority).
    pub admin: Pubkey,
    /// Initial protocol fee.
    pub fee_bps: u16,
}

/// The protocol fee changed.
#[event]
pub struct FeeUpdated {
    /// Previous fee.
    pub old_bps: u16,
    /// New fee.
    pub new_bps: u16,
}

/// Settlement was paused or resumed.
#[event]
pub struct PausedSet {
    /// New pause state.
    pub paused: bool,
}

/// An admin transfer was proposed.
#[event]
pub struct AdminProposed {
    /// Current admin.
    pub admin: Pubkey,
    /// Proposed admin.
    pub pending_admin: Pubkey,
}

/// An admin transfer completed.
#[event]
pub struct AdminAccepted {
    /// Previous admin.
    pub old_admin: Pubkey,
    /// New admin.
    pub new_admin: Pubkey,
}

/// A fee vault was created.
#[event]
pub struct FeeVaultCreated {
    /// Mint of the vault.
    pub mint: Pubkey,
    /// Vault address.
    pub vault: Pubkey,
}

/// Protocol fees were withdrawn.
#[event]
pub struct FeesWithdrawn {
    /// Mint withdrawn.
    pub mint: Pubkey,
    /// Destination token account.
    pub destination: Pubkey,
    /// Gross amount sent.
    pub amount: u64,
}

/// A maker registered.
#[event]
pub struct MakerRegistered {
    /// Maker owner.
    pub owner: Pubkey,
    /// Quote-signing key.
    pub quote_signer: Pubkey,
}

/// A maker rotated its quote-signing key.
#[event]
pub struct QuoteSignerRotated {
    /// Maker owner.
    pub owner: Pubkey,
    /// Previous key.
    pub old_signer: Pubkey,
    /// New key.
    pub new_signer: Pubkey,
}

/// A maker was activated or deactivated.
#[event]
pub struct MakerActiveSet {
    /// Maker owner.
    pub owner: Pubkey,
    /// New state.
    pub active: bool,
}

/// A maker cancelled every quote below a nonce.
#[event]
pub struct MinNonceBumped {
    /// Maker owner.
    pub owner: Pubkey,
    /// New minimum nonce.
    pub min_nonce: u64,
}

/// A maker cancelled quotes on a nonce page.
#[event]
pub struct NoncesCancelled {
    /// Maker owner.
    pub owner: Pubkey,
    /// Page index.
    pub page: u64,
    /// Bits set by this call.
    pub mask: [u8; 32],
}

/// A nonce page was created.
#[event]
pub struct NoncePageCreated {
    /// Maker owner.
    pub owner: Pubkey,
    /// Page index.
    pub page: u64,
}

/// A maker vault was created.
#[event]
pub struct VaultCreated {
    /// Maker owner.
    pub owner: Pubkey,
    /// Mint of the vault.
    pub mint: Pubkey,
    /// Vault address.
    pub vault: Pubkey,
}

/// Tokens moved into a maker vault.
#[event]
pub struct Deposited {
    /// Maker owner.
    pub owner: Pubkey,
    /// Mint.
    pub mint: Pubkey,
    /// Gross amount sent.
    pub amount: u64,
}

/// Tokens moved out of a maker vault.
#[event]
pub struct Withdrawn {
    /// Maker owner.
    pub owner: Pubkey,
    /// Mint.
    pub mint: Pubkey,
    /// Gross amount sent.
    pub amount: u64,
}

/// A quote was (partially) filled. Layout pinned by `rfq_core::layout::SettledEvent`.
#[event]
pub struct Settled {
    /// Maker owner.
    pub maker: Pubkey,
    /// Taker.
    pub taker: Pubkey,
    /// Quote nonce.
    pub nonce: u64,
    /// Gross `maker_mint` taken from the maker vault.
    pub fill_amount: u64,
    /// Gross `taker_mint` sent by the taker.
    pub taker_gross_in: u64,
    /// `taker_mint` credited to the maker vault.
    pub maker_net_in: u64,
    /// `maker_mint` credited to the taker.
    pub taker_net_out: u64,
    /// `maker_mint` sent to the fee vault.
    pub protocol_fee: u64,
    /// Cumulative fill after this settlement.
    pub filled_total: u64,
}

/// A dead quote's fill tracker was closed and its rent refunded.
#[event]
pub struct QuoteFillClosed {
    /// Maker owner.
    pub maker: Pubkey,
    /// Quote nonce.
    pub nonce: u64,
    /// Taker that paid the tracker's rent (and received the refund).
    pub payer: Pubkey,
    /// Cumulative fill the quote reached.
    pub filled: u64,
}
