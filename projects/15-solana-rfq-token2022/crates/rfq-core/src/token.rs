// SPDX-License-Identifier: MIT
//! Zero-copy parsing of SPL Token / Token-2022 mints and token accounts,
//! including the two Token-2022 extensions settlement depends on.
//!
//! ```text
//! Mint:    [0..82]  base (authority, supply, decimals@44, is_initialized@45, freeze)
//! Account: [0..165] base (mint@0, owner@32, amount@64, state@108, ...)
//! Token-2022 with extensions: base, zero padding up to 165, account_type@165
//! (1 = mint, 2 = account), then TLV entries: type u16 | length u16 | value.
//! ```

use crate::{
    Pubkey, read_key, read_u16, read_u64,
    transfer_fee::{TRANSFER_FEE_CONFIG_LEN, TransferFeeConfig},
};

/// Length of a base mint.
pub const MINT_LEN: usize = 82;
/// Length of a base token account (and of the padded base of an extended mint).
pub const ACCOUNT_LEN: usize = 165;
/// Offset of the Token-2022 `AccountType` byte.
pub const ACCOUNT_TYPE_OFFSET: usize = ACCOUNT_LEN;
/// Length of a multisig account (never a mint or account).
pub const MULTISIG_LEN: usize = 355;

/// Token-2022 extension type ids used here.
pub mod ext {
    /// `TransferFeeConfig` (mint).
    pub const TRANSFER_FEE_CONFIG: u16 = 1;
    /// `TransferFeeAmount` (account).
    pub const TRANSFER_FEE_AMOUNT: u16 = 2;
    /// `TransferHook` (mint).
    pub const TRANSFER_HOOK: u16 = 14;
    /// `TransferHookAccount` (account).
    pub const TRANSFER_HOOK_ACCOUNT: u16 = 15;
}

/// Why an account failed to parse, mirroring the `ProgramError` Token-2022's
/// `StateWithExtensions::unpack` returns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenParseError {
    /// `ProgramError::InvalidAccountData`.
    InvalidAccountData,
    /// `ProgramError::UninitializedAccount`.
    UninitializedAccount,
}

const ACCOUNT_TYPE_MINT: u8 = 1;
const ACCOUNT_TYPE_ACCOUNT: u8 = 2;

/// `unpack_tlv_data`: an extended account has zero padding up to byte 165,
/// then the account-type byte of the right kind.
fn check_extended(data: &[u8], base_len: usize, account_type: u8) -> Result<(), TokenParseError> {
    if data.len() == base_len {
        return Ok(());
    }
    if data.len() <= ACCOUNT_LEN {
        return Err(TokenParseError::InvalidAccountData);
    }
    if data[base_len..ACCOUNT_LEN].iter().any(|b| *b != 0) {
        return Err(TokenParseError::InvalidAccountData);
    }
    if data[ACCOUNT_TYPE_OFFSET] != account_type {
        return Err(TokenParseError::InvalidAccountData);
    }
    Ok(())
}

/// `unpack_coption_key` / `unpack_coption_u64`: the 4-byte tag is 0 or 1.
fn coption_tag_ok(data: &[u8], at: usize) -> bool {
    matches!(data.get(at..at + 4), Some([0, 0, 0, 0] | [1, 0, 0, 0]))
}

/// Finds extension `ty` in the TLV area of an extended account.
fn find_extension(data: &[u8], ty: u16) -> Result<Option<&[u8]>, TokenParseError> {
    if data.len() <= ACCOUNT_LEN {
        return Ok(None);
    }
    let mut at = ACCOUNT_TYPE_OFFSET + 1;
    while at + 4 <= data.len() {
        let entry_ty = read_u16(data, at).ok_or(TokenParseError::InvalidAccountData)?;
        if entry_ty == 0 {
            break;
        }
        let len = usize::from(read_u16(data, at + 2).ok_or(TokenParseError::InvalidAccountData)?);
        let start = at + 4;
        let value = data
            .get(start..start + len)
            .ok_or(TokenParseError::InvalidAccountData)?;
        if entry_ty == ty {
            return Ok(Some(value));
        }
        at = start + len;
    }
    Ok(None)
}

/// A parsed mint (legacy or Token-2022).
#[derive(Clone, Copy, Debug)]
pub struct MintView<'a> {
    data: &'a [u8],
}

impl<'a> MintView<'a> {
    /// Validates the layout exactly like `StateWithExtensions::<Mint>::unpack`,
    /// returning the same error in the same order (differentially tested).
    pub fn parse(data: &'a [u8]) -> Result<Self, TokenParseError> {
        let invalid = TokenParseError::InvalidAccountData;
        if data.len() < MINT_LEN || data.len() == MULTISIG_LEN {
            return Err(invalid);
        }
        // `Mint::unpack_from_slice`: mint_authority tag, is_initialized bool,
        // freeze_authority tag.
        if !coption_tag_ok(data, 0) || data[45] > 1 || !coption_tag_ok(data, 46) {
            return Err(invalid);
        }
        if data[45] == 0 {
            return Err(TokenParseError::UninitializedAccount);
        }
        check_extended(data, MINT_LEN, ACCOUNT_TYPE_MINT)?;
        Ok(Self { data })
    }

    /// Mint decimals.
    pub fn decimals(&self) -> u8 {
        self.data[44]
    }

    /// Raw value of extension `ty`, if present.
    pub fn extension(&self, ty: u16) -> Result<Option<&'a [u8]>, TokenParseError> {
        find_extension(self.data, ty)
    }

    /// The `TransferFeeConfig` extension, if present.
    pub fn transfer_fee_config(&self) -> Result<Option<TransferFeeConfig>, TokenParseError> {
        match self.extension(ext::TRANSFER_FEE_CONFIG)? {
            None => Ok(None),
            Some(v) if v.len() == TRANSFER_FEE_CONFIG_LEN => Ok(TransferFeeConfig::parse(v)),
            Some(_) => Err(TokenParseError::InvalidAccountData),
        }
    }

    /// The transfer-hook program id, if the extension is present and set.
    pub fn transfer_hook_program(&self) -> Result<Option<Pubkey>, TokenParseError> {
        match self.extension(ext::TRANSFER_HOOK)? {
            None => Ok(None),
            Some(v) if v.len() == 64 => {
                let pid = read_key(v, 32).ok_or(TokenParseError::InvalidAccountData)?;
                Ok((*pid != [0u8; 32]).then_some(*pid))
            }
            Some(_) => Err(TokenParseError::InvalidAccountData),
        }
    }
}

/// A parsed token account (legacy or Token-2022).
#[derive(Clone, Copy, Debug)]
pub struct TokenAccountView<'a> {
    data: &'a [u8],
    mint: &'a Pubkey,
    owner: &'a Pubkey,
    amount: u64,
}

impl<'a> TokenAccountView<'a> {
    /// Validates the layout exactly like `StateWithExtensions::<Account>::unpack`,
    /// returning the same error in the same order (differentially tested).
    pub fn parse(data: &'a [u8]) -> Result<Self, TokenParseError> {
        let invalid = TokenParseError::InvalidAccountData;
        if data.len() < ACCOUNT_LEN || data.len() == MULTISIG_LEN {
            return Err(invalid);
        }
        // `Account::unpack_from_slice`: delegate tag, state in 0..=2,
        // is_native tag, close_authority tag.
        if !coption_tag_ok(data, 72)
            || data[108] > 2
            || !coption_tag_ok(data, 109)
            || !coption_tag_ok(data, 129)
        {
            return Err(invalid);
        }
        if data[108] == 0 {
            return Err(TokenParseError::UninitializedAccount);
        }
        check_extended(data, ACCOUNT_LEN, ACCOUNT_TYPE_ACCOUNT)?;
        Ok(Self {
            data,
            mint: read_key(data, 0).ok_or(invalid)?,
            owner: read_key(data, 32).ok_or(invalid)?,
            amount: read_u64(data, 64).ok_or(invalid)?,
        })
    }

    /// The account's mint.
    pub fn mint(&self) -> &'a Pubkey {
        self.mint
    }

    /// The account's owner (transfer authority).
    pub fn owner(&self) -> &'a Pubkey {
        self.owner
    }

    /// Token balance.
    pub fn amount(&self) -> u64 {
        self.amount
    }

    /// Raw value of extension `ty`, if present.
    pub fn extension(&self, ty: u16) -> Result<Option<&'a [u8]>, TokenParseError> {
        find_extension(self.data, ty)
    }
}

#[cfg(test)]
mod tests {
    use {
        super::*,
        proptest::prelude::*,
        solana_program_option::COption,
        solana_program_pack::Pack,
        solana_pubkey::Pubkey as SdkPubkey,
        spl_token_2022_interface::{
            extension::{
                BaseStateWithExtensions, BaseStateWithExtensionsMut, ExtensionType,
                StateWithExtensions, StateWithExtensionsMut,
                transfer_fee::{TransferFee as SplFee, TransferFeeConfig as SplCfg},
                transfer_hook::TransferHook,
            },
            state::{Account, AccountState, Mint},
        },
        std::{vec, vec::Vec},
    };

    fn mint_with(
        fee: Option<(u16, u64, u16, u64, u64)>,
        hook: Option<[u8; 32]>,
        decimals: u8,
    ) -> Vec<u8> {
        let mut types = Vec::new();
        if fee.is_some() {
            types.push(ExtensionType::TransferFeeConfig);
        }
        if hook.is_some() {
            types.push(ExtensionType::TransferHook);
        }
        let len = ExtensionType::try_calculate_account_len::<Mint>(&types).expect("len");
        let mut data = vec![0u8; len];
        let mut state =
            StateWithExtensionsMut::<Mint>::unpack_uninitialized(&mut data).expect("unpack");
        if let Some((obps, omax, nbps, nmax, nepoch)) = fee {
            let cfg = state.init_extension::<SplCfg>(true).expect("fee ext");
            cfg.older_transfer_fee = SplFee {
                epoch: 0.into(),
                maximum_fee: omax.into(),
                transfer_fee_basis_points: obps.into(),
            };
            cfg.newer_transfer_fee = SplFee {
                epoch: nepoch.into(),
                maximum_fee: nmax.into(),
                transfer_fee_basis_points: nbps.into(),
            };
        }
        if let Some(pid) = hook {
            let h = state
                .init_extension::<TransferHook>(true)
                .expect("hook ext");
            h.program_id = Some(SdkPubkey::new_from_array(pid))
                .try_into()
                .expect("nonzero");
        }
        state.base = Mint {
            mint_authority: COption::Some(SdkPubkey::new_unique()),
            supply: 0,
            decimals,
            is_initialized: true,
            freeze_authority: COption::None,
        };
        state.pack_base();
        state.init_account_type().expect("account type");
        data
    }

    proptest! {
        /// Differential: our extension reader agrees with Token-2022's.
        #[test]
        fn mint_extensions_match_token_2022(
            with_fee in any::<bool>(),
            fee in (0u16..=10_000, any::<u64>(), 0u16..=10_000, any::<u64>(), any::<u64>()),
            hook in proptest::option::of(any::<[u8; 32]>()),
            decimals in any::<u8>(),
            epoch in any::<u64>(),
        ) {
            let hook = hook.filter(|h| *h != [0u8; 32]);
            let data = mint_with(with_fee.then_some(fee), hook, decimals);
            let ours = MintView::parse(&data).expect("valid mint");
            let spl = StateWithExtensions::<Mint>::unpack(&data).expect("valid mint");
            prop_assert_eq!(ours.decimals(), spl.base.decimals);
            let spl_fee = spl.get_extension::<SplCfg>().ok();
            let our_fee = ours.transfer_fee_config().expect("parses");
            prop_assert_eq!(spl_fee.is_some(), our_fee.is_some());
            if let (Some(s), Some(o)) = (spl_fee, our_fee) {
                let se = s.get_epoch_fee(epoch);
                let oe = o.epoch_fee(epoch);
                prop_assert_eq!(u64::from(se.epoch), oe.epoch);
                prop_assert_eq!(u64::from(se.maximum_fee), oe.maximum_fee);
                prop_assert_eq!(u16::from(se.transfer_fee_basis_points), oe.basis_points);
            }
            let spl_hook = spl_token_2022_interface::extension::transfer_hook::get_program_id(&spl)
                .map(|p| p.to_bytes());
            prop_assert_eq!(ours.transfer_hook_program().expect("parses"), spl_hook);
        }

        /// Differential: on structured garbage (lengths around every boundary,
        /// tags / flags / padding / account-type bytes valid or not), both
        /// parsers accept exactly what `StateWithExtensions::unpack` accepts
        /// and fail with the same `ProgramError`.
        #[test]
        fn parse_errors_match_token_2022(
            len_pick in 0usize..8,
            extra in 0usize..120,
            mut data in proptest::collection::vec(any::<u8>(), 400),
            fix in any::<[bool; 6]>(),
            flag in 0u8..4,
        ) {
            let len = match len_pick {
                0 => extra,
                1 => MINT_LEN,
                2 => ACCOUNT_LEN,
                3 => MULTISIG_LEN,
                4 | 5 => ACCOUNT_LEN + 1 + extra,
                6 => MINT_LEN + extra.min(ACCOUNT_LEN - MINT_LEN),
                _ => ACCOUNT_LEN - 1,
            };
            data.truncate(len);
            let set_tag = |d: &mut Vec<u8>, at: usize, ok: bool| {
                if ok && d.len() >= at + 4 {
                    d[at..at + 4].copy_from_slice(&[u8::from(at.is_multiple_of(2)), 0, 0, 0]);
                }
            };
            // Mint fields.
            set_tag(&mut data, 0, fix[0]);
            set_tag(&mut data, 46, fix[1]);
            if data.len() > 45 && fix[2] {
                data[45] = flag % 2;
            }
            // Account fields.
            set_tag(&mut data, 72, fix[0]);
            set_tag(&mut data, 109, fix[1]);
            set_tag(&mut data, 129, fix[1]);
            if data.len() > 108 && fix[2] {
                data[108] = flag % 3;
            }
            // Extension padding and account type.
            if data.len() > ACCOUNT_LEN {
                if fix[3] {
                    data[MINT_LEN..ACCOUNT_LEN].fill(0);
                }
                if fix[4] {
                    data[ACCOUNT_TYPE_OFFSET] = flag % 3;
                }
            }
            let map = |e: solana_program_error::ProgramError| match e {
                solana_program_error::ProgramError::InvalidAccountData => {
                    TokenParseError::InvalidAccountData
                }
                solana_program_error::ProgramError::UninitializedAccount => {
                    TokenParseError::UninitializedAccount
                }
                other => panic!("unexpected {other:?}"),
            };
            prop_assert_eq!(
                MintView::parse(&data).err(),
                StateWithExtensions::<Mint>::unpack(&data).err().map(map)
            );
            prop_assert_eq!(
                TokenAccountView::parse(&data).err(),
                StateWithExtensions::<Account>::unpack(&data).err().map(map)
            );
        }

        /// Arbitrary bytes never panic.
        #[test]
        fn total_on_garbage(data in proptest::collection::vec(any::<u8>(), 0..400)) {
            if let Ok(m) = MintView::parse(&data) {
                let _ = m.transfer_fee_config();
                let _ = m.transfer_hook_program();
            }
            if let Ok(a) = TokenAccountView::parse(&data) {
                let _ = a.extension(ext::TRANSFER_HOOK_ACCOUNT);
            }
        }
    }

    #[test]
    fn legacy_mint_and_account() {
        let mut mint = vec![0u8; Mint::LEN];
        Mint {
            mint_authority: COption::None,
            supply: 5,
            decimals: 6,
            is_initialized: true,
            freeze_authority: COption::None,
        }
        .pack_into_slice(&mut mint);
        let m = MintView::parse(&mint).expect("legacy mint");
        assert_eq!(m.decimals(), 6);
        assert_eq!(m.transfer_fee_config(), Ok(None));
        assert_eq!(m.transfer_hook_program(), Ok(None));

        let (mk, ow) = (SdkPubkey::new_unique(), SdkPubkey::new_unique());
        let mut acc = vec![0u8; Account::LEN];
        Account {
            mint: mk,
            owner: ow,
            amount: 77,
            state: AccountState::Initialized,
            ..Account::default()
        }
        .pack_into_slice(&mut acc);
        let a = TokenAccountView::parse(&acc).expect("legacy account");
        assert_eq!(a.mint(), &mk.to_bytes());
        assert_eq!(a.owner(), &ow.to_bytes());
        assert_eq!(a.amount(), 77);
    }

    #[test]
    fn extended_account_matches_token_2022() {
        let len = ExtensionType::try_calculate_account_len::<Account>(&[
            ExtensionType::TransferFeeAmount,
            ExtensionType::TransferHookAccount,
        ])
        .expect("len");
        let mut data = vec![0u8; len];
        let mut state =
            StateWithExtensionsMut::<Account>::unpack_uninitialized(&mut data).expect("unpack");
        state
            .init_extension::<spl_token_2022_interface::extension::transfer_fee::TransferFeeAmount>(
                true,
            )
            .expect("ext");
        state.init_extension::<spl_token_2022_interface::extension::transfer_hook::TransferHookAccount>(true).expect("ext");
        state.base = Account {
            amount: 9,
            state: AccountState::Frozen,
            ..Account::default()
        };
        state.pack_base();
        state.init_account_type().expect("type");
        let a = TokenAccountView::parse(&data).expect("valid");
        assert_eq!(a.amount(), 9);
        assert_eq!(
            a.extension(ext::TRANSFER_HOOK_ACCOUNT)
                .expect("ok")
                .map(|v| v.len()),
            Some(1)
        );
        assert_eq!(
            a.extension(ext::TRANSFER_FEE_AMOUNT)
                .expect("ok")
                .map(|v| v.len()),
            Some(8)
        );
        assert!(a.extension(ext::TRANSFER_HOOK).expect("ok").is_none());
    }

    #[test]
    fn rejections() {
        assert_eq!(
            MintView::parse(&[0u8; 10]).err(),
            Some(TokenParseError::InvalidAccountData)
        );
        let mut m = vec![0u8; MINT_LEN];
        assert_eq!(
            MintView::parse(&m).err(),
            Some(TokenParseError::UninitializedAccount)
        );
        m[45] = 1;
        assert!(MintView::parse(&m).is_ok());
        // Extended mint with the account-type byte of a token account.
        let mut ext = vec![0u8; ACCOUNT_LEN + 1];
        ext[45] = 1;
        ext[ACCOUNT_TYPE_OFFSET] = ACCOUNT_TYPE_ACCOUNT;
        assert_eq!(
            MintView::parse(&ext).err(),
            Some(TokenParseError::InvalidAccountData)
        );
        // Multisig-sized data is never a mint.
        let mut ms = vec![0u8; MULTISIG_LEN];
        ms[45] = 1;
        assert_eq!(
            MintView::parse(&ms).err(),
            Some(TokenParseError::InvalidAccountData)
        );
        // Uninitialised and invalid-state token accounts.
        let mut acc = vec![0u8; ACCOUNT_LEN];
        assert_eq!(
            TokenAccountView::parse(&acc).err(),
            Some(TokenParseError::UninitializedAccount)
        );
        acc[108] = 3;
        assert_eq!(
            TokenAccountView::parse(&acc).err(),
            Some(TokenParseError::InvalidAccountData)
        );
        // TLV entry whose length runs past the end.
        let mut bad = vec![0u8; ACCOUNT_LEN + 1 + 4];
        bad[45] = 1;
        bad[ACCOUNT_TYPE_OFFSET] = ACCOUNT_TYPE_MINT;
        bad[166..168].copy_from_slice(&1u16.to_le_bytes());
        bad[168..170].copy_from_slice(&200u16.to_le_bytes());
        let m = MintView::parse(&bad).expect("header ok");
        assert_eq!(
            m.transfer_fee_config(),
            Err(TokenParseError::InvalidAccountData)
        );
    }
}
