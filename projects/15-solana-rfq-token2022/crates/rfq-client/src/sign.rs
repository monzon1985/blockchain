// SPDX-License-Identifier: MIT
//! Quote signing and the ed25519 precompile instruction.

use {
    crate::{ED25519_PROGRAM_ID, Pubkey},
    rfq_core::{Quote, ed25519},
    solana_instruction::Instruction,
    solana_keypair::Keypair,
    solana_signer::Signer,
};

/// The exact message a maker's quote signer signs for `program`.
pub fn quote_message(program: &Pubkey, quote: &Quote) -> [u8; Quote::MESSAGE_LEN] {
    quote.message(&program.to_bytes())
}

/// Signs `quote` for `program` with the maker's quote-signing key.
pub fn sign_quote(signer: &Keypair, program: &Pubkey, quote: &Quote) -> [u8; 64] {
    let sig = signer.sign_message(&quote_message(program, quote));
    let mut out = [0u8; 64];
    out.copy_from_slice(sig.as_ref());
    out
}

/// An `Ed25519SigVerify` instruction verifying `signature` over `message` by
/// `pubkey`, with every offset inline (the only layout `settle` accepts).
pub fn ed25519_instruction(pubkey: &Pubkey, signature: &[u8; 64], message: &[u8]) -> Instruction {
    let mut data = vec![0u8; ed25519::encoded_len(message.len())];
    // Cannot fail: the buffer is sized by `encoded_len` and quote messages are
    // far below the u16 limits.
    let written =
        ed25519::encode_single(&pubkey.to_bytes(), signature, message, &mut data).unwrap_or(0);
    data.truncate(written);
    Instruction {
        program_id: ED25519_PROGRAM_ID,
        accounts: vec![],
        data,
    }
}

/// Convenience: sign and wrap in one call.
pub fn signed_quote_instruction(signer: &Keypair, program: &Pubkey, quote: &Quote) -> Instruction {
    let sig = sign_quote(signer, program, quote);
    ed25519_instruction(&signer.pubkey(), &sig, &quote_message(program, quote))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn instruction_embeds_signer_and_message() {
        let kp = Keypair::new();
        let q = Quote {
            maker_amount: 1,
            taker_amount: 2,
            nonce: 3,
            ..Quote::default()
        };
        let program = crate::RFQ_PROGRAM_ID;
        let ix = signed_quote_instruction(&kp, &program, &q);
        assert_eq!(ix.program_id, ED25519_PROGRAM_ID);
        assert!(ix.accounts.is_empty());
        let msg = quote_message(&program, &q);
        assert_eq!(
            ed25519::verify_inline_single(&ix.data, &kp.pubkey().to_bytes(), |m| m == msg),
            Ok(())
        );
    }
}
