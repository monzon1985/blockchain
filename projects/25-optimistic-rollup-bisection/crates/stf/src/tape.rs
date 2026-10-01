// SPDX-License-Identifier: MIT
//! Input tape of an epoch: `[queueCount] ++ queueRecords ++ sequencedRecords`, exactly as `BatchInbox` hashes it.

use alloy_primitives::{B256, U256};
use rollup_vm::{Tape, VmError};

use crate::record::{RECORD_BYTES, RECORD_WORDS, Record};

/// Maximum sequenced transactions per batch (mirrors `BatchInbox.MAX_SEQUENCED_TXS`).
pub const MAX_SEQUENCED_TXS: usize = 64;
/// Maximum queue messages per batch (mirrors `BatchInbox.MAX_QUEUE_PER_BATCH`).
pub const MAX_QUEUE_PER_BATCH: usize = 32;

/// Builds the tape of an epoch.
///
/// # Errors
/// Only if the tape would exceed `u32::MAX` words, impossible for batches the inbox accepts.
pub fn build_tape(queue: &[Record], sequenced_tx_data: &[u8]) -> Result<Tape, VmError> {
    if !sequenced_tx_data.len().is_multiple_of(32) {
        return Err(VmError::TapeNotWordAligned(sequenced_tx_data.len()));
    }
    let mut words = Vec::with_capacity(1 + queue.len() * RECORD_WORDS + sequenced_tx_data.len() / 32);
    words.push(B256::from(U256::from(queue.len()).to_be_bytes::<32>()));
    for r in queue {
        words.extend_from_slice(&r.words());
    }
    words.extend(sequenced_tx_data.as_chunks::<32>().0.iter().map(|c| B256::from(*c)));
    Tape::new(words)
}

/// Concatenates sequenced records into `txData` as the sequencer posts it.
pub fn encode_tx_data(records: &[Record]) -> Vec<u8> {
    records.iter().flat_map(|r| r.encode()).collect()
}

/// Splits `txData` back into records (trailing partial records are ignored, as the STF does).
pub fn decode_tx_data(data: &[u8]) -> Vec<Record> {
    data.as_chunks::<RECORD_BYTES>()
        .0
        .iter()
        .filter_map(|chunk| {
            let words: Vec<B256> = chunk.as_chunks::<32>().0.iter().map(|c| B256::from(*c)).collect();
            Record::from_words(&words)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::keccak256;

    #[test]
    fn tape_layout_matches_the_inbox() {
        let q = [Record { kind: U256::from(1), amount: U256::from(5), ..Record::default() }];
        let s = [Record { kind: U256::from(4), nonce: U256::from(2), ..Record::default() }];
        let data = encode_tx_data(&s);
        let tape = build_tape(&q, &data).unwrap();
        assert_eq!(tape.size() as usize, 1 + 2 * RECORD_WORDS);
        let mut expected = U256::from(1).to_be_bytes::<32>().to_vec();
        expected.extend(q[0].encode());
        expected.extend(&data);
        assert_eq!(tape.root(), keccak256(&expected));
        assert_eq!(decode_tx_data(&data), s.to_vec());
    }

    #[test]
    fn misaligned_tx_data_is_rejected() {
        assert!(build_tape(&[], &[0u8; 33]).is_err());
    }
}
