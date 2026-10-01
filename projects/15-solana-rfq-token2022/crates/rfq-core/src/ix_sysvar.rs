// SPDX-License-Identifier: MIT
//! Zero-copy reader for the instructions sysvar
//! (`Sysvar1nstructions1111111111111111111111111`).
//!
//! The idiomatic `load_instruction_at_checked` deserialises an owned
//! `Instruction` (heap-allocating its account list and data); this reader
//! returns borrowed slices into the sysvar account instead.
//!
//! ```text
//! [0..2]              num_instructions (u16 LE)
//! [2..2+2N]           byte offset of each instruction (u16 LE)
//! instruction i @ off:  num_accounts (u16) | num_accounts × (flags u8, pubkey 32)
//!                       | program_id (32) | data_len (u16) | data
//! [len-2..len]        index of the currently executing instruction (u16 LE)
//! ```

use crate::{Pubkey, RfqError, read_key, read_u16};

const ACCOUNT_META_LEN: usize = 33;

/// A borrowed view of one serialised instruction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IntrospectedInstruction<'a> {
    /// Program the instruction invokes.
    pub program_id: &'a Pubkey,
    /// Instruction data.
    pub data: &'a [u8],
    /// Number of account metas.
    pub num_accounts: usize,
}

/// Number of top-level instructions in the transaction.
pub fn num_instructions(sysvar: &[u8]) -> Result<u16, RfqError> {
    read_u16(sysvar, 0).ok_or(RfqError::MalformedInstructionsSysvar)
}

/// Index of the instruction currently executing.
pub fn current_index(sysvar: &[u8]) -> Result<u16, RfqError> {
    let at = sysvar
        .len()
        .checked_sub(2)
        .ok_or(RfqError::MalformedInstructionsSysvar)?;
    read_u16(sysvar, at).ok_or(RfqError::MalformedInstructionsSysvar)
}

/// The instruction at `index`.
pub fn instruction_at(sysvar: &[u8], index: u16) -> Result<IntrospectedInstruction<'_>, RfqError> {
    let err = RfqError::MalformedInstructionsSysvar;
    if index >= num_instructions(sysvar)? {
        return Err(err);
    }
    let start = usize::from(read_u16(sysvar, 2 + usize::from(index) * 2).ok_or(err)?);
    let num_accounts = usize::from(read_u16(sysvar, start).ok_or(err)?);
    let pid_at = num_accounts
        .checked_mul(ACCOUNT_META_LEN)
        .and_then(|n| n.checked_add(start + 2))
        .ok_or(err)?;
    let program_id = read_key(sysvar, pid_at).ok_or(err)?;
    let data_len = usize::from(read_u16(sysvar, pid_at + 32).ok_or(err)?);
    let data_at = pid_at + 34;
    let data = sysvar
        .get(data_at..data_at.checked_add(data_len).ok_or(err)?)
        .ok_or(err)?;
    Ok(IntrospectedInstruction {
        program_id,
        data,
        num_accounts,
    })
}

/// `true` if *any* top-level instruction targets `program` — the only check
/// `settle_naive_v1` performs (and the root cause of its exploit).
pub fn any_instruction_for(sysvar: &[u8], program: &Pubkey) -> Result<bool, RfqError> {
    for i in 0..num_instructions(sysvar)? {
        if instruction_at(sysvar, i)?.program_id == program {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use {
        super::*,
        proptest::prelude::*,
        solana_instruction::{AccountMeta, BorrowedAccountMeta, BorrowedInstruction, Instruction},
        solana_instructions_sysvar::construct_instructions_data,
        solana_pubkey::Pubkey as SdkPubkey,
        std::vec::Vec,
    };

    fn arb_ix() -> impl Strategy<Value = Instruction> {
        (
            any::<[u8; 32]>(),
            proptest::collection::vec((any::<[u8; 32]>(), any::<bool>(), any::<bool>()), 0..6),
            proptest::collection::vec(any::<u8>(), 0..300),
        )
            .prop_map(|(pid, metas, data)| Instruction {
                program_id: SdkPubkey::new_from_array(pid),
                accounts: metas
                    .into_iter()
                    .map(|(k, s, w)| AccountMeta {
                        pubkey: SdkPubkey::new_from_array(k),
                        is_signer: s,
                        is_writable: w,
                    })
                    .collect(),
                data,
            })
    }

    fn serialize(ixs: &[Instruction], current: u16) -> Vec<u8> {
        let borrowed: Vec<BorrowedInstruction> = ixs
            .iter()
            .map(|ix| BorrowedInstruction {
                program_id: &ix.program_id,
                accounts: ix
                    .accounts
                    .iter()
                    .map(|m| BorrowedAccountMeta {
                        pubkey: &m.pubkey,
                        is_signer: m.is_signer,
                        is_writable: m.is_writable,
                    })
                    .collect(),
                data: &ix.data,
            })
            .collect();
        let mut data = construct_instructions_data(&borrowed);
        let n = data.len();
        data[n - 2..].copy_from_slice(&current.to_le_bytes());
        data
    }

    proptest! {
        /// Differential: the zero-copy reader sees exactly what the SDK serialised.
        #[test]
        fn reads_sdk_serialisation(ixs in proptest::collection::vec(arb_ix(), 1..6), cur in any::<u16>()) {
            let data = serialize(&ixs, cur);
            prop_assert_eq!(num_instructions(&data), Ok(ixs.len() as u16));
            prop_assert_eq!(current_index(&data), Ok(cur));
            for (i, ix) in ixs.iter().enumerate() {
                let got = instruction_at(&data, i as u16).expect("valid");
                prop_assert_eq!(got.program_id, &ix.program_id.to_bytes());
                prop_assert_eq!(got.data, ix.data.as_slice());
                prop_assert_eq!(got.num_accounts, ix.accounts.len());
            }
            prop_assert_eq!(instruction_at(&data, ixs.len() as u16), Err(RfqError::MalformedInstructionsSysvar));
        }

        /// The naive scan finds a program iff some instruction targets it.
        #[test]
        fn scan_agrees_with_model(ixs in proptest::collection::vec(arb_ix(), 1..6), probe in any::<[u8; 32]>()) {
            let data = serialize(&ixs, 0);
            let expected = ixs.iter().any(|ix| ix.program_id.to_bytes() == probe);
            prop_assert_eq!(any_instruction_for(&data, &probe), Ok(expected));
            let first = ixs[0].program_id.to_bytes();
            prop_assert_eq!(any_instruction_for(&data, &first), Ok(true));
        }

        /// Arbitrary bytes never panic.
        #[test]
        fn total_on_garbage(data in proptest::collection::vec(any::<u8>(), 0..128), idx in any::<u16>()) {
            let _ = instruction_at(&data, idx);
            let _ = current_index(&data);
            let _ = any_instruction_for(&data, &[0; 32]);
        }
    }

    #[test]
    fn empty_and_tiny_inputs() {
        assert_eq!(
            num_instructions(&[]),
            Err(RfqError::MalformedInstructionsSysvar)
        );
        assert_eq!(
            current_index(&[1]),
            Err(RfqError::MalformedInstructionsSysvar)
        );
        assert_eq!(
            instruction_at(&[1, 0], 0),
            Err(RfqError::MalformedInstructionsSysvar)
        );
    }
}
