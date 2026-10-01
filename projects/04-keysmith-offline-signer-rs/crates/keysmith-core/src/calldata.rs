// SPDX-License-Identifier: MIT
//! Recognition of well-known calldata for the operator review.
//!
//! The review of `keysmith sign` always prints the full calldata. On top of that, the three
//! ERC-20 calls an untrusted envelope author is most likely to swap
//! (`transfer` -> `approve(attacker, MAX)`) are decoded so the operator sees the recipient,
//! spender and amount instead of raw words. This is display only: a selector match says nothing
//! about whether the target contract really is an ERC-20 token, and the policy does not
//! constrain calldata.

use crate::address::Address;
use crate::u256::U256;

/// `transfer(address,uint256)`.
pub const TRANSFER: [u8; 4] = [0xa9, 0x05, 0x9c, 0xbb];
/// `approve(address,uint256)`.
pub const APPROVE: [u8; 4] = [0x09, 0x5e, 0xa7, 0xb3];
/// `transferFrom(address,address,uint256)`.
pub const TRANSFER_FROM: [u8; 4] = [0x23, 0xb8, 0x72, 0xdd];

/// A decoded ERC-20 call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Erc20Call {
    /// `transfer(to, amount)`.
    Transfer {
        /// Recipient.
        to: Address,
        /// Amount in token base units.
        amount: U256,
    },
    /// `approve(spender, amount)`.
    Approve {
        /// Account allowed to spend.
        spender: Address,
        /// Allowance in token base units (`2^256 - 1` = unlimited).
        amount: U256,
    },
    /// `transferFrom(from, to, amount)`.
    TransferFrom {
        /// Owner whose allowance is used.
        from: Address,
        /// Recipient.
        to: Address,
        /// Amount in token base units.
        amount: U256,
    },
}

/// The ERC-20 function a selector belongs to, if any.
pub fn erc20_signature(selector: &[u8]) -> Option<&'static str> {
    match selector {
        s if s == TRANSFER => Some("transfer(address,uint256)"),
        s if s == APPROVE => Some("approve(address,uint256)"),
        s if s == TRANSFER_FROM => Some("transferFrom(address,address,uint256)"),
        _ => None,
    }
}

fn word(args: &[u8], i: usize) -> Option<[u8; 32]> {
    args.get(32 * i..32 * (i + 1))?.try_into().ok()
}

fn address_word(args: &[u8], i: usize) -> Option<Address> {
    let w = word(args, i)?;
    // ABI encoding left-pads addresses with exactly 12 zero bytes.
    if w[..12].iter().any(|b| *b != 0) {
        return None;
    }
    let mut a = [0u8; 20];
    a.copy_from_slice(&w[12..]);
    Some(Address(a))
}

/// Decodes `input` as one of the ERC-20 calls above.
///
/// Returns `None` for any other selector, `Some(Err(signature))` when the selector matches
/// but the arguments are not a canonical ABI encoding (wrong length, dirty address padding),
/// and `Some(Ok(call))` otherwise.
pub fn decode_erc20(input: &[u8]) -> Option<Result<Erc20Call, &'static str>> {
    let selector = input.get(..4)?;
    let signature = erc20_signature(selector)?;
    let args = &input[4..];
    let words = if selector == TRANSFER_FROM { 3 } else { 2 };
    let decoded = (args.len() == 32 * words)
        .then(|| match words {
            3 => Some(Erc20Call::TransferFrom {
                from: address_word(args, 0)?,
                to: address_word(args, 1)?,
                amount: U256::from_be_bytes(word(args, 2)?),
            }),
            _ if selector == TRANSFER => Some(Erc20Call::Transfer {
                to: address_word(args, 0)?,
                amount: U256::from_be_bytes(word(args, 1)?),
            }),
            _ => Some(Erc20Call::Approve {
                spender: address_word(args, 0)?,
                amount: U256::from_be_bytes(word(args, 1)?),
            }),
        })
        .flatten();
    Some(decoded.ok_or(signature))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;
    use alloc::format;

    #[test]
    fn decodes_the_three_calls_and_rejects_sloppy_encodings() {
        let alice = "70997970c51812dc3a010c7d01b50e0d17dc79c8";
        let pad = "000000000000000000000000";
        let one_eth = "0000000000000000000000000000000000000000000000000de0b6b3a7640000";
        let max = "f".repeat(64);
        let transfer = hex::decode(&format!("0xa9059cbb{pad}{alice}{one_eth}")).unwrap();
        assert_eq!(
            decode_erc20(&transfer),
            Some(Ok(Erc20Call::Transfer {
                to: Address::parse(alice).unwrap(),
                amount: U256::from_u64(1_000_000_000_000_000_000)
            }))
        );
        let approve = hex::decode(&format!("0x095ea7b3{pad}{alice}{max}")).unwrap();
        assert_eq!(
            decode_erc20(&approve),
            Some(Ok(Erc20Call::Approve {
                spender: Address::parse(alice).unwrap(),
                amount: U256::MAX
            }))
        );
        let from = hex::decode(&format!("0x23b872dd{pad}{alice}{pad}{alice}{one_eth}")).unwrap();
        assert!(matches!(
            decode_erc20(&from),
            Some(Ok(Erc20Call::TransferFrom { .. }))
        ));
        // Wrong length, dirty padding: recognised but not decoded.
        assert_eq!(
            decode_erc20(&transfer[..67]),
            Some(Err("transfer(address,uint256)"))
        );
        let dirty = hex::decode(&format!("0xa9059cbb{}{alice}{one_eth}", "01".repeat(12))).unwrap();
        assert_eq!(decode_erc20(&dirty), Some(Err("transfer(address,uint256)")));
        // Anything else is not an ERC-20 call.
        assert_eq!(decode_erc20(&[0xde, 0xad, 0xbe, 0xef]), None);
        assert_eq!(decode_erc20(&[0xa9, 0x05]), None);
        assert_eq!(erc20_signature(&APPROVE), Some("approve(address,uint256)"));
    }
}
