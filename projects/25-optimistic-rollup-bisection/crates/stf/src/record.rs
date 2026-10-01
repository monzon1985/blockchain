// SPDX-License-Identifier: MIT
//! Tape records and signed L2 transactions.

use alloy_primitives::{Address, B256, U256, keccak256};
use k256::ecdsa::SigningKey;
use serde::{Deserialize, Serialize};

use rollup_vm::smt::hash_pair;

/// Words per record.
pub const RECORD_WORDS: usize = 8;
/// Bytes per record.
pub const RECORD_BYTES: usize = RECORD_WORDS * 32;

/// Record kinds. 1-3 are only honoured when they come from the L1 queue; 4-5 only when sequenced and signed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum Kind {
    /// L1 deposit: credits `to`.
    Deposit = 1,
    /// L1-forced transfer from the L1 sender.
    ForcedTransfer = 2,
    /// L1-forced withdrawal from the L1 sender to L1 address `to`.
    ForcedWithdrawal = 3,
    /// Signed L2 transfer.
    Transfer = 4,
    /// Signed L2 withdrawal to L1 address `to`.
    Withdrawal = 5,
}

impl Kind {
    /// Decodes a kind word.
    pub fn from_word(w: U256) -> Option<Self> {
        if w > U256::from(5u8) {
            return None;
        }
        match w.to::<u64>() {
            1 => Some(Self::Deposit),
            2 => Some(Self::ForcedTransfer),
            3 => Some(Self::ForcedWithdrawal),
            4 => Some(Self::Transfer),
            5 => Some(Self::Withdrawal),
            _ => None,
        }
    }
}

/// One 8-word record, the unit of the input tape.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Record {
    /// Kind word (see [`Kind`]); other values are skipped by the STF.
    pub kind: U256,
    /// Sender word.
    pub from: U256,
    /// Recipient word.
    pub to: U256,
    /// Amount in wei.
    pub amount: U256,
    /// Sender nonce (signed records only).
    pub nonce: U256,
    /// Signature `v` (27/28).
    pub v: U256,
    /// Signature `r`.
    pub r: U256,
    /// Signature `s`.
    pub s: U256,
}

impl Record {
    /// Words in tape order.
    pub fn words(&self) -> [B256; RECORD_WORDS] {
        [self.kind, self.from, self.to, self.amount, self.nonce, self.v, self.r, self.s]
            .map(|x| B256::from(x.to_be_bytes::<32>()))
    }

    /// Record from 8 words.
    pub fn from_words(w: &[B256]) -> Option<Self> {
        let n = |i: usize| w.get(i).map(|x| U256::from_be_bytes(x.0));
        Some(Self { kind: n(0)?, from: n(1)?, to: n(2)?, amount: n(3)?, nonce: n(4)?, v: n(5)?, r: n(6)?, s: n(7)? })
    }

    /// 256-byte encoding (identical to `abi.encode(record)` for the static Solidity struct).
    pub fn encode(&self) -> Vec<u8> {
        self.words().iter().flat_map(|w| w.0).collect()
    }

    /// `keccak256(abi.encode(record))`, as chained into the L1 queue accumulator.
    pub fn hash(&self) -> B256 {
        keccak256(self.encode())
    }

    /// Record for an L1 queue message.
    pub fn queue(kind: Kind, from: Address, to: Address, amount: U256) -> Self {
        Self { kind: U256::from(kind as u8), from: address_word(from), to: address_word(to), amount, ..Self::default() }
    }
}

/// Address as a right-aligned word.
pub fn address_word(a: Address) -> U256 {
    U256::from_be_slice(a.as_slice())
}

/// Folds records into the queue accumulator: `acc' = keccak256(acc ++ keccak256(abi.encode(record)))`.
pub fn accumulate(start: B256, records: &[Record]) -> B256 {
    records.iter().fold(start, |acc, r| hash_pair(acc, r.hash()))
}

/// Replay-protection domain mixed into every signed digest.
pub fn domain_separator(chain_id: u64) -> B256 {
    hash_pair(keccak256("MiniRollup.L2Transaction.v1"), B256::from(U256::from(chain_id)))
}

/// A signed-transaction payload before signing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct L2Tx {
    /// `Transfer` or `Withdrawal`.
    pub kind: Kind,
    /// Sender (must be the signer).
    pub from: Address,
    /// L2 recipient (transfer) or L1 recipient (withdrawal).
    pub to: Address,
    /// Amount in wei.
    pub amount: U256,
    /// Sender nonce.
    pub nonce: U256,
}

impl L2Tx {
    /// Digest the sender signs: `H(H(H(H(H(domain, kind), from), to), amount), nonce)` with `H(a, b) =
    /// keccak256(a ++ b)`. This is exactly what the VM program recomputes with five `HASH` instructions.
    pub fn digest(&self, domain: B256) -> B256 {
        let w = |x: U256| B256::from(x.to_be_bytes::<32>());
        let mut h = hash_pair(domain, w(U256::from(self.kind as u8)));
        for x in [address_word(self.from), address_word(self.to), self.amount, self.nonce] {
            h = hash_pair(h, w(x));
        }
        h
    }

    /// Record carrying this transaction and the signature `(v, r, s)`.
    pub fn with_signature(&self, v: u8, r: U256, s: U256) -> Record {
        Record {
            kind: U256::from(self.kind as u8),
            from: address_word(self.from),
            to: address_word(self.to),
            amount: self.amount,
            nonce: self.nonce,
            v: U256::from(v),
            r,
            s,
        }
    }

    /// Signs with a raw secp256k1 key (the digest is signed directly, no EIP-191 prefix).
    ///
    /// # Errors
    /// Propagates signing failures (practically unreachable for valid keys).
    pub fn sign(&self, key: &SigningKey, domain: B256) -> Result<Record, k256::ecdsa::Error> {
        let (sig, recid) = key.sign_prehash_recoverable(self.digest(domain).as_slice())?;
        let bytes = sig.to_bytes();
        Ok(self.with_signature(
            27 + recid.to_byte(),
            U256::from_be_slice(&bytes[..32]),
            U256::from_be_slice(&bytes[32..]),
        ))
    }
}

/// Address controlled by a raw secp256k1 key.
pub fn key_address(key: &SigningKey) -> Address {
    let point = key.verifying_key().to_encoded_point(false);
    Address::from_slice(&keccak256(&point.as_bytes()[1..])[12..])
}

#[cfg(test)]
mod tests {
    use super::*;
    use rollup_vm::crypto::ecrecover;

    #[test]
    fn signature_recovers_to_sender() {
        let key = SigningKey::from_slice(&[0x11; 32]).unwrap();
        let from = key_address(&key);
        let tx =
            L2Tx { kind: Kind::Transfer, from, to: Address::repeat_byte(2), amount: U256::from(5), nonce: U256::ZERO };
        let domain = domain_separator(901);
        let rec = tx.sign(&key, domain).unwrap();
        let signer = ecrecover(tx.digest(domain), rec.v, B256::from(rec.r), B256::from(rec.s));
        assert_eq!(U256::from_be_bytes(signer.0), address_word(from));
    }

    #[test]
    fn records_round_trip_through_words() {
        let r = Record { kind: U256::from(4), amount: U256::from(9), s: U256::MAX, ..Record::default() };
        assert_eq!(Record::from_words(&r.words()), Some(r));
        assert_eq!(r.encode().len(), RECORD_BYTES);
        assert_eq!(Record::from_words(&r.words()[..7]), None);
    }

    #[test]
    fn kinds_decode() {
        assert_eq!(Kind::from_word(U256::from(4)), Some(Kind::Transfer));
        assert_eq!(Kind::from_word(U256::ZERO), None);
        assert_eq!(Kind::from_word(U256::MAX), None);
    }

    #[test]
    fn domain_depends_on_chain_id() {
        assert_ne!(domain_separator(1), domain_separator(2));
    }
}
