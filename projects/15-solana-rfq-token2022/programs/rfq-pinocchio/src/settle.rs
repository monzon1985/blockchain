// SPDX-License-Identifier: MIT
//! The `settle` hot path, zero-copy.
//!
//! Validation reproduces, step for step, the code Anchor 1.2 generates for the
//! Anchor program's `Settle` accounts struct, so both programs return the same
//! error for the same input — including inputs with several faults at once,
//! where the *first* failing check decides the code:
//!
//! 0. instruction arguments (`InstructionDidNotDeserialize`);
//! 1. per-account deserialisation in field order: `Signer`, `Account<T>`
//!    (initialised, owner, discriminator, borsh), `InterfaceAccount<Mint>` /
//!    `InterfaceAccount<TokenAccount>` (owned by SPL Token or Token-2022,
//!    unpackable), `Interface<TokenInterface>` and `Program<System>` (exact
//!    program id, executable);
//! 2. the `init_if_needed` field `quote_fill`: canonical-bump seeds, then
//!    `create_account` — or, when the address was pre-funded, top-up +
//!    `allocate` + `assign` — then the space / owner / rent-exempt checks;
//! 3. the duplicate-mutable-account check over the mutable fields Anchor
//!    serialises (`rfq_core::layout::settle_accounts::DUPLICATE_CHECKED`);
//! 4. every other field's constraints in field order, each in Anchor's
//!    linearised order (seeds → mut → address → token/mint constraints);
//!    stored-bump seeds use `create_program_address`, exactly like Anchor's
//!    `seeds = [..], bump = account.bump`;
//! 5. the handler: the same checks, effects and CPIs as `rfq::settle::handler`.

use {
    crate::token,
    pinocchio::{
        AccountView, Address,
        cpi::{Seed, Signer},
        error::ProgramError,
        sysvars::{Sysvar, clock::Clock, rent::Rent},
    },
    rfq_core::{
        Pubkey, Quote, RfqError, anchor_codes as ac, ed25519,
        ids::{self, ED25519_PROGRAM},
        ix_sysvar,
        layout::{self, SettleArgs, SettledEvent, disc, settle_accounts as at},
        math::{SettleInputs, compute_settlement},
        nonce, seeds,
        token::{MintView, TokenAccountView, TokenParseError},
    },
};

/// Which signature check to run.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SigMode {
    /// Strict introspection of the preceding ed25519 instruction.
    Strict,
    /// "Some ed25519 instruction exists" — vulnerable by design.
    #[cfg(feature = "naive-v1")]
    NaiveV1,
}

type R = Result<(), ProgramError>;

#[inline(always)]
const fn custom(code: u32) -> ProgramError {
    ProgramError::Custom(code)
}

#[inline(always)]
fn err(e: RfqError) -> ProgramError {
    custom(e.code())
}

#[inline(always)]
fn is_system(address: &Address) -> bool {
    address.as_array() == &ids::SYSTEM_PROGRAM
}

// ---------------------------------------------------------------------------
// Phase 1: Anchor's per-type `try_accounts` deserialisation.
// ---------------------------------------------------------------------------

/// `Account<T>::try_from` for a fixed-size account of this program: not
/// uninitialised, owned by the program, matching discriminator, and long
/// enough for borsh (whose `bool` only accepts 0 / 1).
fn deserialize_program_account(
    account: &AccountView,
    program: &Address,
    discriminator: &[u8; 8],
    len: usize,
    bools: &[usize],
) -> R {
    if is_system(account.owner()) && account.lamports() == 0 {
        return Err(custom(ac::ACCOUNT_NOT_INITIALIZED));
    }
    if account.owner() != program {
        return Err(custom(ac::ACCOUNT_OWNED_BY_WRONG_PROGRAM));
    }
    let data = account.try_borrow()?;
    layout::check_discriminator(&data, discriminator).map_err(custom)?;
    if data.len() < len || bools.iter().any(|&i| data[i] > 1) {
        return Err(custom(ac::ACCOUNT_DID_NOT_DESERIALIZE));
    }
    Ok(())
}

/// What an `InterfaceAccount` slot holds.
#[derive(Clone, Copy)]
enum TokenState {
    Mint,
    Account,
}

/// The `ProgramError` Token-2022's `StateWithExtensions::unpack` returns, which
/// Anchor's `InterfaceAccount` propagates unchanged.
fn token_parse_error(e: TokenParseError) -> ProgramError {
    match e {
        TokenParseError::InvalidAccountData => ProgramError::InvalidAccountData,
        TokenParseError::UninitializedAccount => ProgramError::UninitializedAccount,
    }
}

/// `InterfaceAccount<Mint | TokenAccount>::try_from`.
fn deserialize_token_state(account: &AccountView, kind: TokenState) -> R {
    if is_system(account.owner()) && account.lamports() == 0 {
        return Err(custom(ac::ACCOUNT_NOT_INITIALIZED));
    }
    if !ids::is_token_program(account.owner().as_array()) {
        return Err(custom(ac::ACCOUNT_OWNED_BY_WRONG_PROGRAM));
    }
    let data = account.try_borrow()?;
    match kind {
        TokenState::Mint => MintView::parse(&data).map(|_| ()),
        TokenState::Account => TokenAccountView::parse(&data).map(|_| ()),
    }
    .map_err(token_parse_error)
}

/// `Interface<TokenInterface>::try_from`: SPL Token or Token-2022, executable.
///
/// This is what stops a caller from substituting an arbitrary program for the
/// token program: every token CPI below is signed by the vault-authority PDA,
/// so an unchecked program id would let any program act as the maker's vault
/// authority.
fn check_token_program(account: &AccountView) -> R {
    if !ids::is_token_program(account.address().as_array()) {
        return Err(custom(ac::INVALID_PROGRAM_ID));
    }
    if !account.executable() {
        return Err(custom(ac::INVALID_PROGRAM_EXECUTABLE));
    }
    Ok(())
}

/// `Program<System>::try_from`.
fn check_system_program(account: &AccountView) -> R {
    if !is_system(account.address()) {
        return Err(custom(ac::INVALID_PROGRAM_ID));
    }
    if !account.executable() {
        return Err(custom(ac::INVALID_PROGRAM_EXECUTABLE));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Phases 2-4: constraints.
// ---------------------------------------------------------------------------

/// `seeds = [..], bump = <stored bump>`: `create_program_address(seeds ++
/// [bump])` must equal the account's address (Anchor's exact check).
fn expect_pda(account: &AccountView, seed_list: &[&[u8]], bump: u8, program: &Address) -> R {
    let bump = [bump];
    let mut all: [&[u8]; 4] = [&[]; 4];
    let n = seed_list.len();
    if n >= all.len() {
        return Err(custom(ac::CONSTRAINT_SEEDS));
    }
    all[..n].copy_from_slice(seed_list);
    all[n] = &bump;
    match Address::create_program_address(&all[..=n], program) {
        Ok(expected) if account.address() == &expected => Ok(()),
        _ => Err(custom(ac::CONSTRAINT_SEEDS)),
    }
}

/// `#[account(mut)]`.
#[inline(always)]
fn expect_writable(account: &AccountView) -> R {
    if account.is_writable() {
        Ok(())
    } else {
        Err(custom(ac::CONSTRAINT_MUT))
    }
}

/// `#[account(mut, token::authority = .., token::mint = .., token::token_program = ..)]`,
/// checked in Anchor's order: mut, authority, mint, token program.
fn check_token_account(
    account: &AccountView,
    authority: Option<&Address>,
    mint: &Address,
    token_program: &Address,
) -> R {
    expect_writable(account)?;
    {
        let data = account.try_borrow()?;
        let ta = TokenAccountView::parse(&data).map_err(token_parse_error)?;
        if let Some(authority) = authority
            && ta.owner() != authority.as_array()
        {
            return Err(custom(ac::CONSTRAINT_TOKEN_OWNER));
        }
        if ta.mint() != mint.as_array() {
            return Err(custom(ac::CONSTRAINT_TOKEN_MINT));
        }
    }
    if account.owner() != token_program {
        return Err(custom(ac::CONSTRAINT_TOKEN_TOKEN_PROGRAM));
    }
    Ok(())
}

/// `#[account(address = quote.mint @ MintMismatch, mint::token_program = ..)]`.
fn check_mint(account: &AccountView, expected: &Pubkey, token_program: &Address) -> R {
    if account.address().as_array() != expected {
        return Err(err(RfqError::MintMismatch));
    }
    if account.owner() != token_program {
        return Err(custom(ac::CONSTRAINT_MINT_TOKEN_PROGRAM));
    }
    Ok(())
}

/// The `init_if_needed` creation step of the `QuoteFill` PDA, identical to
/// Anchor's: `create_account` when the address holds no lamports; otherwise
/// (someone pre-funded the predictable address) top it up to the rent-exempt
/// minimum, then `allocate` and `assign` signed by the PDA. A plain
/// `create_account` would fail on a pre-funded address, which would let anyone
/// block a quote by sending lamports to its tracker address.
fn init_quote_fill(
    payer: &AccountView,
    quote_fill: &AccountView,
    program_id: &Address,
    maker: &Pubkey,
    nonce_le: &[u8; 8],
    bump: u8,
    rent: &Rent,
) -> R {
    use pinocchio_system::instructions::{Allocate, Assign, CreateAccount, Transfer};
    let bump = [bump];
    let seed_arr = [
        Seed::from(seeds::QUOTE_FILL),
        Seed::from(&maker[..]),
        Seed::from(&nonce_le[..]),
        Seed::from(&bump[..]),
    ];
    let signer = [Signer::from(&seed_arr[..])];
    let space = layout::quote_fill::LEN;
    let minimum = rent.try_minimum_balance(space)?;
    let current = quote_fill.lamports();
    if current == 0 {
        return CreateAccount {
            from: payer,
            to: quote_fill,
            lamports: minimum,
            space: space as u64,
            owner: program_id,
        }
        .invoke_signed(&signer);
    }
    if payer.address() == quote_fill.address() {
        return Err(custom(ac::TRYING_TO_INIT_PAYER_AS_PROGRAM_ACCOUNT));
    }
    let required = minimum.max(1).saturating_sub(current);
    if required > 0 {
        Transfer {
            from: payer,
            to: quote_fill,
            lamports: required,
        }
        .invoke()?;
    }
    Allocate {
        account: quote_fill,
        space: space as u64,
    }
    .invoke_signed(&signer)?;
    Assign {
        account: quote_fill,
        owner: program_id,
    }
    .invoke_signed(&signer)
}

// ---------------------------------------------------------------------------
// The handler.
// ---------------------------------------------------------------------------

/// Settlement handler shared by `settle` and `settle_naive_v1`.
pub fn handler(
    program_id: &Address,
    accounts: &mut [AccountView],
    args_data: &[u8],
    mode: SigMode,
) -> R {
    // --- 0. Arguments ---------------------------------------------------------
    let args = SettleArgs::decode(args_data).ok_or(custom(ac::INSTRUCTION_DID_NOT_DESERIALIZE))?;
    let quote: Quote = args.quote;

    let accs: &[AccountView] = accounts;
    let get = |i: usize| accs.get(i).ok_or(custom(ac::ACCOUNT_NOT_ENOUGH_KEYS));

    // --- 1. Deserialisation, in field order ---------------------------------
    let taker = get(at::TAKER)?;
    if !taker.is_signer() {
        return Err(custom(ac::ACCOUNT_NOT_SIGNER));
    }
    let config = get(at::CONFIG)?;
    deserialize_program_account(
        config,
        program_id,
        &disc::CONFIG,
        layout::config::LEN,
        &[layout::config::PAUSED],
    )?;
    let maker = get(at::MAKER)?;
    deserialize_program_account(
        maker,
        program_id,
        &disc::MAKER,
        layout::maker::LEN,
        &[layout::maker::ACTIVE],
    )?;
    let vault_authority = get(at::VAULT_AUTHORITY)?;
    let nonce_page = get(at::NONCE_PAGE)?;
    deserialize_program_account(
        nonce_page,
        program_id,
        &disc::NONCE_PAGE,
        layout::nonce_page::LEN,
        &[],
    )?;
    let quote_fill = get(at::QUOTE_FILL)?;
    let maker_mint = get(at::MAKER_MINT)?;
    deserialize_token_state(maker_mint, TokenState::Mint)?;
    let taker_mint = get(at::TAKER_MINT)?;
    deserialize_token_state(taker_mint, TokenState::Mint)?;
    let maker_vault_out = get(at::MAKER_VAULT_OUT)?;
    deserialize_token_state(maker_vault_out, TokenState::Account)?;
    let maker_vault_in = get(at::MAKER_VAULT_IN)?;
    deserialize_token_state(maker_vault_in, TokenState::Account)?;
    let taker_src = get(at::TAKER_SRC)?;
    deserialize_token_state(taker_src, TokenState::Account)?;
    let taker_dst = get(at::TAKER_DST)?;
    deserialize_token_state(taker_dst, TokenState::Account)?;
    let fee_vault = get(at::FEE_VAULT)?;
    deserialize_token_state(fee_vault, TokenState::Account)?;
    let maker_token_program = get(at::MAKER_TOKEN_PROGRAM)?;
    check_token_program(maker_token_program)?;
    let taker_token_program = get(at::TAKER_TOKEN_PROGRAM)?;
    check_token_program(taker_token_program)?;
    check_system_program(get(at::SYSTEM_PROGRAM)?)?;
    let instructions = get(at::INSTRUCTIONS)?;

    // --- 2. `init_if_needed` quote_fill --------------------------------------
    let nonce_le = quote.nonce.to_le_bytes();
    let (fill_pda, fill_bump) =
        Address::find_program_address(&[seeds::QUOTE_FILL, &quote.maker, &nonce_le], program_id);
    if quote_fill.address() != &fill_pda {
        return Err(custom(ac::CONSTRAINT_SEEDS));
    }
    let rent = Rent::get()?;
    if is_system(quote_fill.owner()) {
        init_quote_fill(
            taker,
            quote_fill,
            program_id,
            &quote.maker,
            &nonce_le,
            fill_bump,
            &rent,
        )?;
    } else {
        deserialize_program_account(
            quote_fill,
            program_id,
            &disc::QUOTE_FILL,
            layout::quote_fill::LEN,
            &[],
        )?;
    }
    if quote_fill.data_len() != layout::quote_fill::LEN {
        return Err(custom(ac::CONSTRAINT_SPACE));
    }
    if quote_fill.owner() != program_id {
        return Err(custom(ac::CONSTRAINT_OWNER));
    }
    if quote_fill.lamports() < rent.try_minimum_balance(layout::quote_fill::LEN)? {
        return Err(custom(ac::CONSTRAINT_RENT_EXEMPT));
    }

    // --- 3. Duplicate mutable accounts --------------------------------------
    let mutable_keys = at::DUPLICATE_CHECKED.map(|i| accs[i].address().as_array());
    if layout::first_duplicate(&mutable_keys).is_some() {
        return Err(custom(ac::CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT));
    }

    // --- 4. Field constraints, in field order --------------------------------
    expect_writable(taker)?;
    let (fee_bps, paused, config_bump) = {
        let d = config.try_borrow()?;
        (
            u16::from_le_bytes([d[layout::config::FEE_BPS], d[layout::config::FEE_BPS + 1]]),
            d[layout::config::PAUSED] != 0,
            d[layout::config::BUMP],
        )
    };
    expect_pda(config, &[seeds::CONFIG], config_bump, program_id)?;

    let mut quote_signer = [0u8; 32];
    let (min_nonce, active, maker_bump, va_bump) = {
        let d = maker.try_borrow()?;
        quote_signer
            .copy_from_slice(&d[layout::maker::QUOTE_SIGNER..layout::maker::QUOTE_SIGNER + 32]);
        let mut mn = [0u8; 8];
        mn.copy_from_slice(&d[layout::maker::MIN_NONCE..layout::maker::MIN_NONCE + 8]);
        (
            u64::from_le_bytes(mn),
            d[layout::maker::ACTIVE] != 0,
            d[layout::maker::BUMP],
            d[layout::maker::VAULT_AUTHORITY_BUMP],
        )
    };
    expect_pda(maker, &[seeds::MAKER, &quote.maker], maker_bump, program_id)?;
    expect_pda(
        vault_authority,
        &[seeds::VAULT_AUTHORITY, &quote.maker],
        va_bump,
        program_id,
    )?;

    let page_le = nonce::page_index(quote.nonce).to_le_bytes();
    let np_bump = nonce_page.try_borrow()?[layout::nonce_page::BUMP];
    expect_pda(
        nonce_page,
        &[seeds::NONCE_PAGE, &quote.maker, &page_le],
        np_bump,
        program_id,
    )?;
    expect_writable(nonce_page)?;

    check_mint(maker_mint, &quote.maker_mint, maker_token_program.address())?;
    check_mint(taker_mint, &quote.taker_mint, taker_token_program.address())?;
    check_token_account(
        maker_vault_out,
        Some(vault_authority.address()),
        maker_mint.address(),
        maker_token_program.address(),
    )?;
    check_token_account(
        maker_vault_in,
        Some(vault_authority.address()),
        taker_mint.address(),
        taker_token_program.address(),
    )?;
    check_token_account(
        taker_src,
        Some(taker.address()),
        taker_mint.address(),
        taker_token_program.address(),
    )?;
    check_token_account(
        taker_dst,
        None,
        maker_mint.address(),
        maker_token_program.address(),
    )?;
    check_token_account(
        fee_vault,
        Some(config.address()),
        maker_mint.address(),
        maker_token_program.address(),
    )?;
    if instructions.address().as_array() != &ids::INSTRUCTIONS_SYSVAR {
        return Err(custom(ac::CONSTRAINT_ADDRESS));
    }

    // --- 5. Handler checks (same order as `rfq::settle::handler`) ------------
    if paused {
        return Err(err(RfqError::Paused));
    }
    quote.validate().map_err(err)?;
    if !active {
        return Err(err(RfqError::MakerInactive));
    }
    let clock = Clock::get()?;
    if clock.unix_timestamp > quote.expiry {
        return Err(err(RfqError::QuoteExpired));
    }
    if !quote.is_open() && &quote.taker != taker.address().as_array() {
        return Err(err(RfqError::TakerNotAllowed));
    }
    if quote.nonce < min_nonce {
        return Err(err(RfqError::NonceCancelled));
    }
    {
        let d = nonce_page.try_borrow()?;
        let mut bits = [0u8; 32];
        bits.copy_from_slice(&d[layout::nonce_page::BITS..layout::nonce_page::BITS + 32]);
        if nonce::is_used(&bits, quote.nonce) {
            return Err(err(RfqError::NonceAlreadyUsed));
        }
    }

    let message = quote.message(program_id.as_array());
    verify_signature(instructions, &quote_signer, &message, mode)?;
    let quote_hash = solana_sha256_hasher::hashv(&[&message]).to_bytes();

    // A brand-new tracker reads `filled == 0`; an existing one must belong to
    // this exact quote.
    let (filled_before, payer_is_taker) = {
        let d = quote_fill.try_borrow()?;
        let mut f = [0u8; 8];
        f.copy_from_slice(&d[layout::quote_fill::FILLED..layout::quote_fill::FILLED + 8]);
        let filled = u64::from_le_bytes(f);
        if filled == 0 {
            (0, true)
        } else {
            if d[layout::quote_fill::QUOTE_HASH..layout::quote_fill::QUOTE_HASH + 32] != quote_hash
            {
                return Err(err(RfqError::QuoteMismatch));
            }
            let payer = &d[layout::quote_fill::PAYER..layout::quote_fill::PAYER + 32];
            (filled, payer == taker.address().as_array())
        }
    };

    let maker_mint_dec = mint_decimals(maker_mint)?;
    let taker_mint_dec = mint_decimals(taker_mint)?;
    let s = compute_settlement(&SettleInputs {
        maker_amount: quote.maker_amount,
        taker_amount: quote.taker_amount,
        filled_before,
        fill: args.fill_amount,
        protocol_fee_bps: fee_bps,
        maker_mint_fee: token::epoch_transfer_fee(maker_mint, clock.epoch)?,
        taker_mint_fee: token::epoch_transfer_fee(taker_mint, clock.epoch)?,
        min_out: args.min_out,
        max_in: args.max_in,
    })
    .map_err(err)?;
    let taker_key = taker.address().to_bytes();
    // All shared account references end here; the rest mutates the slice.

    // --- Effects (persisted before any CPI) ----------------------------------
    {
        let mut d = accounts[at::QUOTE_FILL].try_borrow_mut()?;
        if filled_before == 0 {
            d[..8].copy_from_slice(&disc::QUOTE_FILL);
            d[layout::quote_fill::MAKER..layout::quote_fill::MAKER + 32]
                .copy_from_slice(&quote.maker);
            d[layout::quote_fill::NONCE..layout::quote_fill::NONCE + 8].copy_from_slice(&nonce_le);
            d[layout::quote_fill::QUOTE_HASH..layout::quote_fill::QUOTE_HASH + 32]
                .copy_from_slice(&quote_hash);
            d[layout::quote_fill::BUMP] = fill_bump;
            d[layout::quote_fill::PAYER..layout::quote_fill::PAYER + 32]
                .copy_from_slice(&taker_key);
        }
        d[layout::quote_fill::FILLED..layout::quote_fill::FILLED + 8]
            .copy_from_slice(&s.filled_after.to_le_bytes());
    }
    if s.completes {
        let mut d = accounts[at::NONCE_PAGE].try_borrow_mut()?;
        let mut bits = [0u8; 32];
        bits.copy_from_slice(&d[layout::nonce_page::BITS..layout::nonce_page::BITS + 32]);
        nonce::mark_used(&mut bits, quote.nonce);
        d[layout::nonce_page::BITS..layout::nonce_page::BITS + 32].copy_from_slice(&bits);
    }

    // --- Interactions --------------------------------------------------------
    // The token programs were validated in phase 1, so the vault-authority
    // signature below can only ever reach SPL Token / Token-2022.
    let va_bump = [va_bump];
    let seeds_arr = [
        Seed::from(seeds::VAULT_AUTHORITY),
        Seed::from(&quote.maker[..]),
        Seed::from(&va_bump[..]),
    ];
    let vault_signer = Signer::from(&seeds_arr[..]);
    let remaining = accounts.get(at::FIXED..).unwrap_or(&[]);

    token::transfer_checked_with_hook(
        &accounts[at::TAKER_TOKEN_PROGRAM],
        &accounts[at::TAKER_SRC],
        &accounts[at::TAKER_MINT],
        &accounts[at::MAKER_VAULT_IN],
        &accounts[at::TAKER],
        remaining,
        s.taker_gross_in,
        taker_mint_dec,
        &[],
    )?;
    token::transfer_checked_with_hook(
        &accounts[at::MAKER_TOKEN_PROGRAM],
        &accounts[at::MAKER_VAULT_OUT],
        &accounts[at::MAKER_MINT],
        &accounts[at::TAKER_DST],
        &accounts[at::VAULT_AUTHORITY],
        remaining,
        s.taker_gross_out,
        maker_mint_dec,
        core::slice::from_ref(&vault_signer),
    )?;
    token::transfer_checked_with_hook(
        &accounts[at::MAKER_TOKEN_PROGRAM],
        &accounts[at::MAKER_VAULT_OUT],
        &accounts[at::MAKER_MINT],
        &accounts[at::FEE_VAULT],
        &accounts[at::VAULT_AUTHORITY],
        remaining,
        s.protocol_fee,
        maker_mint_dec,
        core::slice::from_ref(&vault_signer),
    )?;

    emit_settled(&SettledEvent {
        maker: quote.maker,
        taker: taker_key,
        nonce: quote.nonce,
        fill_amount: args.fill_amount,
        taker_gross_in: s.taker_gross_in,
        maker_net_in: s.maker_net_in,
        taker_net_out: s.taker_net_out,
        protocol_fee: s.protocol_fee,
        filled_total: s.filled_after,
    });

    // An exhausted quote's tracker is closed right away when the taker that
    // paid its rent completes it; otherwise `close_quote_fill` (Anchor program)
    // later refunds the recorded payer. The set nonce bit guards replay.
    if s.completes && payer_is_taker {
        let refunded = accounts[at::QUOTE_FILL].lamports();
        let new_taker_lamports = accounts[at::TAKER]
            .lamports()
            .checked_add(refunded)
            .ok_or(ProgramError::ArithmeticOverflow)?;
        accounts[at::TAKER].set_lamports(new_taker_lamports);
        accounts[at::QUOTE_FILL].set_lamports(0);
        accounts[at::QUOTE_FILL].close()?;
    }
    Ok(())
}

fn verify_signature(
    instructions: &AccountView,
    signer: &[u8; 32],
    message: &[u8],
    mode: SigMode,
) -> R {
    let data = instructions.try_borrow()?;
    match mode {
        SigMode::Strict => {
            let current = ix_sysvar::current_index(&data).map_err(err)?;
            if current == 0 {
                return Err(err(RfqError::MissingSignatureInstruction));
            }
            let ix = ix_sysvar::instruction_at(&data, current - 1).map_err(err)?;
            if *ix.program_id != ED25519_PROGRAM {
                return Err(err(RfqError::NotEd25519Instruction));
            }
            ed25519::verify_inline_single(ix.data, signer, |m| m == message).map_err(err)
        }
        #[cfg(feature = "naive-v1")]
        SigMode::NaiveV1 => {
            if ix_sysvar::any_instruction_for(&data, &ED25519_PROGRAM).map_err(err)? {
                Ok(())
            } else {
                Err(err(RfqError::MissingSignatureInstruction))
            }
        }
    }
}

fn mint_decimals(mint: &AccountView) -> Result<u8, ProgramError> {
    let d = mint.try_borrow()?;
    MintView::parse(&d)
        .map(|m| m.decimals())
        .map_err(token_parse_error)
}

#[cfg(target_os = "solana")]
fn emit_settled(event: &SettledEvent) {
    let bytes = event.encode();
    let slices: [&[u8]; 1] = [&bytes];
    // SAFETY: `sol_log_data` takes a pointer to an array of `(ptr, len)` pairs
    // and its length. A `&[u8]` is exactly a `(ptr: *const u8, len: usize)`
    // fat pointer, so `[&[u8]; 1]` has the layout the syscall reads (the same
    // cast `solana_program::log::sol_log_data` performs); `bytes` and `slices`
    // live on this stack frame for the whole call, and the syscall only reads.
    unsafe {
        pinocchio::syscalls::sol_log_data(slices.as_ptr() as *const u8, slices.len() as u64);
    }
}

#[cfg(not(target_os = "solana"))]
fn emit_settled(event: &SettledEvent) {
    // Host builds exist only for linting / unit tests; nothing to log to.
    let _ = event.encode();
}
