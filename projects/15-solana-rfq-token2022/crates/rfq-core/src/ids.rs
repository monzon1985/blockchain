// SPDX-License-Identifier: MIT
//! Well-known program and sysvar addresses as raw bytes.
//!
//! Every constant is checked against its base58 form and against the canonical
//! SDK constant in this module's tests.

use crate::Pubkey;

/// `11111111111111111111111111111111` — the System program.
pub const SYSTEM_PROGRAM: Pubkey = [0; 32];

/// `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA` — SPL Token.
pub const TOKEN_PROGRAM: Pubkey = [
    6, 221, 246, 225, 215, 101, 161, 147, 217, 203, 225, 70, 206, 235, 121, 172, 28, 180, 133, 237,
    95, 91, 55, 145, 58, 140, 245, 133, 126, 255, 0, 169,
];

/// `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb` — SPL Token-2022.
pub const TOKEN_2022_PROGRAM: Pubkey = [
    6, 221, 246, 225, 238, 117, 143, 222, 24, 66, 93, 188, 228, 108, 205, 218, 182, 26, 252, 77,
    131, 185, 13, 39, 254, 189, 249, 40, 216, 161, 139, 252,
];

/// `Ed25519SigVerify111111111111111111111111111` — the ed25519 precompile.
pub const ED25519_PROGRAM: Pubkey = [
    3, 125, 70, 214, 124, 147, 251, 190, 18, 249, 66, 143, 131, 141, 64, 255, 5, 112, 116, 73, 39,
    244, 138, 100, 252, 202, 112, 68, 128, 0, 0, 0,
];

/// `Sysvar1nstructions1111111111111111111111111` — the instructions sysvar.
pub const INSTRUCTIONS_SYSVAR: Pubkey = [
    6, 167, 213, 23, 24, 123, 209, 102, 53, 218, 212, 4, 85, 253, 194, 192, 193, 36, 198, 143, 33,
    86, 117, 165, 219, 186, 203, 95, 8, 0, 0, 0,
];

/// `RFQU3KiXMzdvdjrxx369DDnBx7jhGaJkCdPDvmrcJCk` — the Anchor RFQ program.
pub const RFQ_PROGRAM: Pubkey = [
    6, 54, 58, 11, 151, 223, 45, 177, 255, 18, 59, 68, 93, 217, 143, 125, 151, 221, 125, 215, 89,
    113, 119, 60, 233, 115, 82, 134, 224, 233, 136, 85,
];

/// `RFPK8mcExbXUku6ikQ4HS4rLQDy1XJpASxmqg2EyLnv` — the Pinocchio settle program.
pub const RFQ_PINOCCHIO_PROGRAM: Pubkey = [
    6, 54, 52, 73, 203, 49, 129, 31, 254, 51, 66, 179, 217, 84, 116, 40, 78, 218, 68, 49, 54, 229,
    157, 85, 3, 128, 164, 43, 178, 187, 230, 3,
];

/// `RFQNaiveV1Exp1oitDemo1111111111111111111111` — the Anchor program built
/// with the deliberately vulnerable `naive-v1` feature. The exploit artefact
/// lives at its own address so it can never be mistaken for the production
/// program (whose default build does not contain `settle_naive_v1`).
pub const RFQ_NAIVE_PROGRAM: Pubkey = [
    6, 54, 57, 147, 89, 249, 99, 146, 187, 183, 40, 138, 21, 229, 94, 205, 115, 254, 178, 16, 191,
    182, 80, 43, 167, 139, 173, 149, 126, 128, 0, 0,
];

/// `RFPNaiveV1Exp1oitDemo1111111111111111111111` — the Pinocchio program built
/// with the `naive-v1` feature (exploit artefact, see [`RFQ_NAIVE_PROGRAM`]).
pub const RFQ_PINOCCHIO_NAIVE_PROGRAM: Pubkey = [
    6, 54, 52, 149, 187, 255, 135, 154, 217, 40, 83, 84, 154, 64, 190, 106, 178, 98, 105, 42, 150,
    191, 160, 183, 247, 42, 140, 149, 126, 128, 0, 0,
];

/// `HookikRw7r4TWeG9qC8AnE9c3uVYQea8bpt6yqdxXvSW` — the in-repo allowlist transfer hook.
pub const TEST_HOOK_PROGRAM: Pubkey = [
    249, 184, 146, 157, 160, 228, 89, 197, 85, 189, 192, 121, 51, 140, 56, 218, 118, 254, 94, 172,
    25, 220, 158, 93, 169, 159, 213, 59, 235, 11, 238, 219,
];

/// Returns `true` for the two SPL token programs this protocol settles through.
#[inline(always)]
pub fn is_token_program(key: &Pubkey) -> bool {
    *key == TOKEN_PROGRAM || *key == TOKEN_2022_PROGRAM
}

#[cfg(test)]
mod tests {
    use {super::*, solana_pubkey::Pubkey as SdkPubkey, std::str::FromStr};

    fn b58(s: &str) -> Pubkey {
        SdkPubkey::from_str(s).expect("valid base58").to_bytes()
    }

    #[test]
    fn constants_match_base58() {
        assert_eq!(SYSTEM_PROGRAM, b58("11111111111111111111111111111111"));
        assert_eq!(
            TOKEN_PROGRAM,
            b58("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
        );
        assert_eq!(
            TOKEN_2022_PROGRAM,
            b58("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")
        );
        assert_eq!(
            ED25519_PROGRAM,
            b58("Ed25519SigVerify111111111111111111111111111")
        );
        assert_eq!(
            INSTRUCTIONS_SYSVAR,
            b58("Sysvar1nstructions1111111111111111111111111")
        );
        assert_eq!(
            RFQ_PROGRAM,
            b58("RFQU3KiXMzdvdjrxx369DDnBx7jhGaJkCdPDvmrcJCk")
        );
        assert_eq!(
            RFQ_PINOCCHIO_PROGRAM,
            b58("RFPK8mcExbXUku6ikQ4HS4rLQDy1XJpASxmqg2EyLnv")
        );
        assert_eq!(
            TEST_HOOK_PROGRAM,
            b58("HookikRw7r4TWeG9qC8AnE9c3uVYQea8bpt6yqdxXvSW")
        );
        assert_eq!(
            RFQ_NAIVE_PROGRAM,
            b58("RFQNaiveV1Exp1oitDemo1111111111111111111111")
        );
        assert_eq!(
            RFQ_PINOCCHIO_NAIVE_PROGRAM,
            b58("RFPNaiveV1Exp1oitDemo1111111111111111111111")
        );
    }

    #[test]
    fn constants_match_sdk() {
        assert_eq!(TOKEN_2022_PROGRAM, spl_token_2022_interface::ID.to_bytes());
        assert_eq!(
            ED25519_PROGRAM,
            solana_sdk_ids::ed25519_program::ID.to_bytes()
        );
        assert_eq!(
            INSTRUCTIONS_SYSVAR,
            solana_instructions_sysvar::ID.to_bytes()
        );
    }

    #[test]
    fn token_program_predicate() {
        assert!(is_token_program(&TOKEN_PROGRAM));
        assert!(is_token_program(&TOKEN_2022_PROGRAM));
        assert!(!is_token_program(&SYSTEM_PROGRAM));
        assert!(!is_token_program(&RFQ_PROGRAM));
        assert!(!is_token_program(&TEST_HOOK_PROGRAM));
    }
}
