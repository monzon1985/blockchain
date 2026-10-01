// SPDX-License-Identifier: MIT
//! Sequencer and batcher: accepts signed L2 transactions over HTTP, orders them, and posts batches to the inbox.
//!
//! An honest sequencer includes queue messages as soon as it sees them. With `censor` set it models a censoring
//! operator: it drops transactions from (and stops including queue messages at the first message from) the listed
//! addresses. Once such a message is overdue, the inbox rejects its batches and anyone can post a `forceBatch`.
//!
//! The mempool is checked against the latest derived state: a transaction whose nonce the sender has already used
//! (for instance an included one copied from L1 calldata and resubmitted) is refused, and evicted if it becomes stale
//! while waiting. Batches take each sender's transactions in nonce order, so a sender's nonce `n + 1` submitted before
//! `n` waits for `n` instead of being posted and rejected by the STF.
//!
//! Derivation runs without blocking the API: L1 logs are fetched with no lock held, epochs are derived under a read
//! lock (API readers proceed), and only the final commit takes the write lock.

use std::{
    collections::{BTreeMap, HashMap},
    sync::Arc,
    time::Duration,
};

use alloy::{
    primitives::{Address, B256, U256},
    providers::DynProvider,
};
use rollup_l1::{Contracts, bindings};
use rollup_stf::{Kind, L2Tx, MAX_QUEUE_PER_BATCH, MAX_SEQUENCED_TXS, Record, StateExt, address_word, encode_tx_data};
use rollup_vm::{SparseMerkleTree, crypto::ecrecover};
use tokio::sync::{Mutex, RwLock, watch};
use tracing::{info, warn};

use crate::{
    chain::{Chain, word_to_address},
    error::Result,
    util::{send, wait_or_stop},
};

/// Sequencer settings.
#[derive(Debug, Clone)]
pub struct SequencerConfig {
    /// How often a batch is attempted.
    pub batch_interval: Duration,
    /// Addresses whose transactions and queue messages are censored.
    pub censor: Vec<Address>,
}

/// Why a submitted transaction was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TxRejection {
    /// Only signed transfers (4) and withdrawals (5) can be sequenced.
    #[error("kind {0} cannot be sequenced")]
    Kind(U256),
    /// The recipient word is not a 20-byte address, so the funds could never be spent or withdrawn.
    #[error("recipient {0:#x} is not an address")]
    NotAnAddress(U256),
    /// The signature does not recover to `from`.
    #[error("signature does not match sender")]
    Signature,
    /// The sender already used this nonce (the transaction was included, or replaced).
    #[error("stale nonce {got}: the sender's next nonce is {next}")]
    StaleNonce {
        /// Nonce of the transaction.
        got: U256,
        /// Sender's next nonce in the latest derived state.
        next: U256,
    },
    /// The nonce is so far ahead of the sender's next nonce that it could not be included for many batches.
    #[error("nonce {got} is too far ahead of the sender's next nonce {next}")]
    NonceTooFarAhead {
        /// Nonce of the transaction.
        got: U256,
        /// Sender's next nonce in the latest derived state.
        next: U256,
    },
    /// The mempool already holds this transaction.
    #[error("duplicate transaction")]
    Duplicate,
    /// The mempool is full.
    #[error("mempool full")]
    Full,
}

/// Shared sequencer state (read by the HTTP API).
#[derive(Debug)]
pub struct Sequencer {
    /// Derived chain.
    pub chain: RwLock<Chain>,
    domain: B256,
    mempool: Mutex<Vec<Record>>,
    cfg: SequencerConfig,
}

const MEMPOOL_LIMIT: usize = 10_000;

/// How far past the sender's next nonce a transaction may be (one full batch of its own transactions).
pub const MAX_NONCE_AHEAD: u64 = MAX_SEQUENCED_TXS as u64;

/// Picks up to [`MAX_SEQUENCED_TXS`] transactions for the next batch. Senders take turns in order of first appearance
/// in the pool; each contributes only the contiguous run of nonces starting at its next nonce in `state` (a gap stops
/// that sender, and when two transactions share a nonce the one submitted first is taken).
pub fn select_batch(pool: &[Record], state: &SparseMerkleTree, censored: impl Fn(U256) -> bool) -> Vec<Record> {
    let mut senders: Vec<U256> = Vec::new();
    let mut by_sender: HashMap<U256, BTreeMap<U256, usize>> = HashMap::new();
    for (i, r) in pool.iter().enumerate() {
        if censored(r.from) {
            continue;
        }
        by_sender
            .entry(r.from)
            .or_insert_with(|| {
                senders.push(r.from);
                BTreeMap::new()
            })
            .entry(r.nonce)
            .or_insert(i);
    }
    let mut next: HashMap<U256, U256> = senders.iter().map(|s| (*s, state.nonce(*s))).collect();
    let mut batch = Vec::new();
    loop {
        let mut progress = false;
        for sender in &senders {
            if batch.len() >= MAX_SEQUENCED_TXS {
                return batch;
            }
            let (Some(nonce), Some(txs)) = (next.get_mut(sender), by_sender.get(sender)) else { continue };
            if let Some(r) = txs.get(nonce).and_then(|i| pool.get(*i)) {
                batch.push(*r);
                *nonce += U256::from(1u8);
                progress = true;
            }
        }
        if !progress {
            return batch;
        }
    }
}

impl Sequencer {
    /// New sequencer over a (possibly empty) derived chain.
    pub fn new(chain: Chain, cfg: SequencerConfig) -> Arc<Self> {
        let domain = chain.stf().domain();
        Arc::new(Self { chain: RwLock::new(chain), domain, mempool: Mutex::new(Vec::new()), cfg })
    }

    /// Validates and queues a signed transaction; returns its digest.
    ///
    /// # Errors
    /// See [`TxRejection`].
    pub async fn submit(&self, record: Record) -> Result<B256, TxRejection> {
        let kind = match Kind::from_word(record.kind) {
            Some(k @ (Kind::Transfer | Kind::Withdrawal)) => k,
            _ => return Err(TxRejection::Kind(record.kind)),
        };
        if word_to_address(record.to).is_none() {
            return Err(TxRejection::NotAnAddress(record.to));
        }
        let digest = L2Tx::digest_of(kind, record.from, record.to, record.amount, record.nonce, self.domain);
        let signer = ecrecover(digest, record.v, B256::from(record.r), B256::from(record.s));
        if signer.is_zero() || U256::from_be_bytes(signer.0) != record.from {
            return Err(TxRejection::Signature);
        }
        let next = self.chain.read().await.latest_state().nonce(record.from);
        if record.nonce < next {
            return Err(TxRejection::StaleNonce { got: record.nonce, next });
        }
        if record.nonce > next.saturating_add(U256::from(MAX_NONCE_AHEAD)) {
            return Err(TxRejection::NonceTooFarAhead { got: record.nonce, next });
        }
        let mut pool = self.mempool.lock().await;
        if pool.contains(&record) {
            return Err(TxRejection::Duplicate);
        }
        if pool.len() >= MEMPOOL_LIMIT {
            return Err(TxRejection::Full);
        }
        pool.push(record);
        Ok(digest)
    }

    /// Transactions waiting for a batch.
    pub async fn mempool_len(&self) -> usize {
        self.mempool.lock().await.len()
    }

    fn censored(&self, word: U256) -> bool {
        self.cfg.censor.iter().any(|a| address_word(*a) == word)
    }

    /// Brings the chain up to date without blocking API readers for the RPC round-trips or the VM execution.
    ///
    /// # Errors
    /// RPC failures or inconsistent L1 data.
    pub async fn sync(&self, provider: &DynProvider, contracts: &Contracts) -> Result<u64> {
        let from = self.chain.read().await.next_block();
        let update = Chain::fetch(from, provider, contracts).await?;
        let derivation = self.chain.read().await.derive(&update)?;
        Ok(self.chain.write().await.commit(derivation))
    }

    /// Syncs, then posts one batch if there is anything to post. Returns the new epoch, if any.
    ///
    /// # Errors
    /// RPC failures and reverted submissions (e.g. `ForcedInclusionViolated` for a censoring sequencer).
    pub async fn tick(&self, provider: &DynProvider, contracts: &Contracts, me: Address) -> Result<Option<u64>> {
        self.sync(provider, contracts).await?;
        let (pending, txs) = {
            let chain = self.chain.read().await;
            let pending: Vec<Record> = chain
                .queue()
                .iter()
                .skip(usize::try_from(chain.queue_cursor()).unwrap_or(usize::MAX))
                .take(MAX_QUEUE_PER_BATCH)
                .take_while(|r| !self.censored(r.from))
                .copied()
                .collect();
            let state = chain.latest_state();
            let mut pool = self.mempool.lock().await;
            let before = pool.len();
            pool.retain(|r| r.nonce >= state.nonce(r.from));
            if pool.len() < before {
                info!(evicted = before - pool.len(), "evicted transactions with stale nonces");
            }
            (pending, select_batch(&pool, state, |w| self.censored(w)))
        };
        if pending.is_empty() && txs.is_empty() {
            return Ok(None);
        }
        let queue_records: Vec<bindings::Record> = pending.iter().map(|r| (*r).into()).collect();
        let call = contracts.inbox.submitBatch(encode_tx_data(&txs).into(), queue_records);
        send(call, me).await?;
        self.mempool.lock().await.retain(|r| !txs.contains(r));
        let epoch = contracts.inbox.batchCount().call().await?.to::<u64>();
        info!(epoch, queue = pending.len(), txs = txs.len(), "posted batch");
        Ok(Some(epoch))
    }

    /// Batching loop; runs until `shutdown` flips.
    ///
    /// # Errors
    /// Never for per-tick failures (logged and retried).
    pub async fn run(
        self: Arc<Self>,
        provider: DynProvider,
        contracts: Contracts,
        me: Address,
        mut shutdown: watch::Receiver<bool>,
    ) -> Result<()> {
        info!(address = %me, censoring = ?self.cfg.censor, "sequencer started");
        loop {
            if let Err(e) = self.tick(&provider, &contracts, me).await {
                warn!(error = %e, "batch submission failed");
            }
            if wait_or_stop(self.cfg.batch_interval, &mut shutdown).await {
                info!("sequencer stopped");
                return Ok(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::signers::{SignerSync, local::PrivateKeySigner};
    use rollup_stf::{Stf, build_tape, keys};

    use crate::{
        chain::{BatchLog, L1Update},
        wallet::sign_tx,
    };

    fn tx(s: &PrivateKeySigner, nonce: u64) -> Record {
        sign_tx(s, Kind::Transfer, Address::repeat_byte(9), U256::from(1), U256::from(nonce), Stf::new(901).domain())
            .unwrap()
    }

    #[test]
    fn batches_follow_nonce_order_and_stop_at_gaps() {
        let (a, b) = (PrivateKeySigner::random(), PrivateKeySigner::random());
        let mut state = SparseMerkleTree::new();
        state.insert(keys::nonce_key_of(b.address()), keys::word_u64(5));
        // a: 1 before 0 (reordered), 3 after a gap; b: 4 is stale, 5 and 6 fine, then a duplicate of 6.
        let mut b6_again = tx(&b, 6);
        b6_again.amount = U256::from(2);
        let pool = vec![tx(&a, 1), tx(&b, 4), tx(&b, 6), tx(&a, 0), tx(&a, 3), tx(&b, 5), b6_again];
        let batch = select_batch(&pool, &state, |_| false);
        let got: Vec<(Address, u64)> = batch
            .iter()
            .map(|r| (if r.from == address_word(a.address()) { a.address() } else { b.address() }, r.nonce.to::<u64>()))
            .collect();
        assert_eq!(got, vec![(a.address(), 0), (b.address(), 5), (a.address(), 1), (b.address(), 6)]);
        assert_eq!(batch[3].amount, U256::from(1), "the first submitted transaction for a nonce wins");
        assert!(
            select_batch(&pool, &state, |w| w == address_word(a.address()))
                .iter()
                .all(|r| r.from != address_word(a.address()))
        );
    }

    /// Admission checks against the derived state: an included transaction cannot be resubmitted (it would only cost
    /// the sequencer L1 gas and fail the STF's nonce check), far-future nonces and non-address recipients are refused.
    #[tokio::test]
    async fn submissions_are_checked_against_the_derived_state() {
        let stf = Stf::new(901);
        let alice = PrivateKeySigner::random();
        let deposit = Record::queue(Kind::Deposit, Address::ZERO, alice.address(), U256::from(100));
        let included = tx(&alice, 0);
        let data = encode_tx_data(&[included]);
        let tape = build_tape(&[deposit], &data).unwrap();
        let log = BatchLog {
            epoch: 1,
            tape_hash: tape.root(),
            tape_size: tape.size(),
            queue_start: 0,
            queue_end: 1,
            forced: false,
            tx_data: data.into(),
            l1_block: 1,
        };
        let mut chain = Chain::new(stf.clone(), 0);
        let d = chain.derive(&L1Update::new(2, vec![(0, deposit)], vec![log], 0)).unwrap();
        chain.commit(d);
        let seq = Sequencer::new(chain, SequencerConfig { batch_interval: Duration::from_secs(1), censor: vec![] });

        assert_eq!(
            seq.submit(included).await,
            Err(TxRejection::StaleNonce { got: U256::ZERO, next: U256::from(1) }),
            "an included transaction copied from L1 calldata"
        );
        assert!(seq.submit(tx(&alice, 1)).await.is_ok());
        assert!(seq.submit(tx(&alice, 1 + MAX_NONCE_AHEAD)).await.is_ok());
        assert!(matches!(seq.submit(tx(&alice, 2 + MAX_NONCE_AHEAD)).await, Err(TxRejection::NonceTooFarAhead { .. })));

        let mut bad = tx(&alice, 2);
        bad.to = U256::from(1) << 160u32;
        let digest = L2Tx::digest_of(Kind::Transfer, bad.from, bad.to, bad.amount, bad.nonce, stf.domain());
        let sig = alice.sign_hash_sync(&digest).unwrap();
        (bad.v, bad.r, bad.s) = (U256::from(27 + u8::from(sig.v())), sig.r(), sig.s());
        assert_eq!(seq.submit(bad).await, Err(TxRejection::NotAnAddress(bad.to)));
        assert_eq!(seq.mempool_len().await, 2);
    }

    /// Derivation holds only a read lock on the chain (the write lock is taken for the final commit), so the API keeps
    /// accepting transactions and answering queries while a batch is being derived.
    #[tokio::test]
    async fn submissions_proceed_while_derivation_reads_the_chain() {
        let seq = Sequencer::new(
            Chain::new(Stf::new(901), 0),
            SequencerConfig { batch_interval: Duration::from_secs(1), censor: vec![] },
        );
        let deriving = seq.chain.read().await; // what `Sequencer::sync` holds while it derives
        let alice = PrivateKeySigner::random();
        let submitted = tokio::time::timeout(Duration::from_secs(5), seq.submit(tx(&alice, 0))).await;
        assert!(matches!(submitted, Ok(Ok(_))), "submit must not wait for derivation");
        drop(deriving);
        assert_eq!(seq.mempool_len().await, 1);
    }

    #[test]
    fn batches_are_capped() {
        let a = PrivateKeySigner::random();
        let pool: Vec<Record> = (0..100).map(|n| tx(&a, n)).collect();
        assert_eq!(select_batch(&pool, &SparseMerkleTree::new(), |_| false).len(), MAX_SEQUENCED_TXS);
    }
}
