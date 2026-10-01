// SPDX-License-Identifier: MIT
//! L1 -> L2 derivation: rebuilds every epoch's input tape from L1 logs alone and executes it with the VM program.
//!
//! Sources, both read with `eth_getLogs` from the deployment block onwards:
//! - `ForcedInclusionQueue.MessageEnqueued`: the L1 message queue (deposits and forced transactions);
//! - `BatchInbox.BatchAppended`: each epoch's queue range plus the sequenced transaction bytes.
//!
//! The reconstructed tape must hash to the `tapeHash` the inbox stored; any mismatch is a hard error. Every epoch is
//! executed by stepping the canonical VM program (the same one fraud proofs run), not by a shortcut, and cross-checked
//! against the native STF.
//!
//! # What is kept in memory
//!
//! A full L2 state is a sparse Merkle tree whose size grows with the number of accounts, so the chain never keeps one
//! per epoch. It keeps exactly two:
//!
//! - the **head** state (the pre-state of the next batch, and what account queries read);
//! - the **checkpoint**: the state after the latest epoch L1 has finalized (genesis before that), which withdrawal
//!   proofs are served against.
//!
//! Every epoch keeps its 32-byte state root. Epochs above the checkpoint can still be disputed, so they also keep their
//! input tape; the state before any of them is rebuilt on demand by re-applying those tapes natively from the
//! checkpoint. Once L1 finalizes an epoch, the checkpoint moves up, and the tapes and cached traces at or below it are
//! dropped (no game can be opened on a finalized epoch). Traces are also evicted when the game that needed them
//! resolves ([`Chain::evict_traces`]).

use std::{borrow::Cow, collections::HashMap, sync::Arc};

use alloy::{
    primitives::{Address, B256, Bytes, U256},
    providers::Provider,
    rpc::types::Filter,
    sol_types::SolEvent,
};
use rollup_l1::{Contracts, IBatchInbox, IForcedInclusionQueue};
use rollup_stf::{EpochTrace, Fault, Record, StateExt, Stf, WithdrawalEntry, address_word, build_tape, keys};
use rollup_vm::{SmtProof, SparseMerkleTree, Tape};
use serde::{Deserialize, Serialize};

use crate::error::{NodeError, Result};

/// One derived epoch.
#[derive(Debug, Clone)]
pub struct DerivedEpoch {
    /// Epoch number.
    pub epoch: u64,
    /// The input tape; `None` once the epoch is at or below the checkpoint (it can no longer be disputed).
    pub tape: Option<Arc<Tape>>,
    /// Posted through `forceBatch`.
    pub forced: bool,
    /// Queue range included.
    pub queue_range: (u64, u64),
    /// L1 block of the batch.
    pub l1_block: u64,
    /// State root after executing the epoch.
    pub state_root: B256,
    /// VM steps the epoch took.
    pub steps: u64,
    /// Withdrawals created in the epoch.
    pub withdrawals: Vec<WithdrawalEntry>,
}

/// Merkle proof of a withdrawal against an epoch's state root, as `Bridge.finalizeWithdrawal` expects it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WithdrawalProof {
    /// Epoch whose state root the proof is against.
    pub epoch: u64,
    /// That state root.
    pub state_root: B256,
    /// Withdrawal id.
    pub withdrawal_id: U256,
    /// L1 recipient.
    pub recipient: Address,
    /// Amount in wei.
    pub amount: U256,
    /// Proof bitmap.
    pub bitmap: U256,
    /// Non-zero siblings.
    pub siblings: Vec<B256>,
}

/// One `BatchAppended` log.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchLog {
    /// Epoch the batch created.
    pub epoch: u64,
    /// `keccak256` of the epoch's tape, as stored by the inbox.
    pub tape_hash: B256,
    /// Tape length in words.
    pub tape_size: u32,
    /// First queue message included.
    pub queue_start: u64,
    /// One past the last queue message included.
    pub queue_end: u64,
    /// Posted through `forceBatch`.
    pub forced: bool,
    /// Sequenced transaction bytes.
    pub tx_data: Bytes,
    /// L1 block of the log.
    pub l1_block: u64,
}

impl BatchLog {
    /// From the decoded event and the block it was emitted in.
    pub fn new(ev: IBatchInbox::BatchAppended, l1_block: u64) -> Self {
        Self {
            epoch: ev.epoch.saturating_to::<u64>(),
            tape_hash: ev.tapeHash,
            tape_size: ev.tapeSize,
            queue_start: ev.queueStart,
            queue_end: ev.queueEnd,
            forced: ev.forced,
            tx_data: ev.txData,
            l1_block,
        }
    }
}

/// Everything one sync round read from L1. Fetching never touches the chain, so a service can do the RPC round-trips
/// without holding any lock on it.
#[derive(Debug, Clone)]
pub struct L1Update {
    next_block: u64,
    queue: Vec<(u64, Record)>,
    batches: Vec<BatchLog>,
    finalized: u64,
}

/// New epochs derived from an [`L1Update`], ready to be committed with [`Chain::commit`] (a cheap move).
#[derive(Debug)]
pub struct Derivation {
    next_block: u64,
    queue: Vec<Record>,
    epochs: Vec<DerivedEpoch>,
    head_state: Option<SparseMerkleTree>,
    checkpoint: Option<(u64, SparseMerkleTree)>,
}

impl L1Update {
    /// An update from already-decoded L1 data (offline replays and tests); [`Chain::fetch`] builds it from logs.
    pub fn new(next_block: u64, queue: Vec<(u64, Record)>, batches: Vec<BatchLog>, finalized: u64) -> Self {
        Self { next_block, queue, batches, finalized }
    }
}

impl Derivation {
    /// Number of new epochs.
    pub fn new_epochs(&self) -> u64 {
        self.epochs.len() as u64
    }
}

/// The L2 chain as derived from L1.
#[derive(Debug)]
pub struct Chain {
    stf: Stf,
    next_block: u64,
    queue: Vec<Record>,
    epochs: Vec<DerivedEpoch>,
    head_state: SparseMerkleTree,
    checkpoint: (u64, SparseMerkleTree),
    trace_cache: HashMap<(u64, Option<Fault>), Arc<EpochTrace>>,
}

impl Chain {
    /// Empty chain that will scan L1 from `start_block`.
    pub fn new(stf: Stf, start_block: u64) -> Self {
        Self {
            stf,
            next_block: start_block,
            queue: Vec::new(),
            epochs: Vec::new(),
            head_state: SparseMerkleTree::new(),
            checkpoint: (0, SparseMerkleTree::new()),
            trace_cache: HashMap::new(),
        }
    }

    /// The STF.
    pub fn stf(&self) -> &Stf {
        &self.stf
    }

    /// Latest derived epoch (0 = genesis only).
    pub fn head(&self) -> u64 {
        self.epochs.len() as u64
    }

    /// First L1 block the next sync will read.
    pub fn next_block(&self) -> u64 {
        self.next_block
    }

    /// Epoch whose full state is kept as the checkpoint (the latest L1-finalized epoch, 0 before any).
    pub fn checkpoint_epoch(&self) -> u64 {
        self.checkpoint.0
    }

    /// Number of cached traces (for tests and metrics).
    pub fn cached_traces(&self) -> usize {
        self.trace_cache.len()
    }

    /// Number of epochs that still keep their input tape (those above the checkpoint).
    pub fn retained_tapes(&self) -> usize {
        self.epochs.iter().filter(|e| e.tape.is_some()).count()
    }

    /// All queue messages seen so far.
    pub fn queue(&self) -> &[Record] {
        &self.queue
    }

    /// Queue messages consumed by derived batches.
    pub fn queue_cursor(&self) -> u64 {
        self.epochs.last().map_or(0, |e| e.queue_range.1)
    }

    /// Derived epoch `e` (1-based).
    pub fn epoch(&self, e: u64) -> Option<&DerivedEpoch> {
        e.checked_sub(1).and_then(|i| self.epochs.get(usize::try_from(i).ok()?))
    }

    /// State after epoch `e`: borrowed for the head and the checkpoint, rebuilt from the checkpoint for any epoch in
    /// between, and `None` for epochs below the checkpoint (pruned) or not derived yet.
    ///
    /// # Errors
    /// A rebuilt state whose root differs from the one derivation recorded (an internal inconsistency).
    pub fn state_at(&self, e: u64) -> Result<Option<Cow<'_, SparseMerkleTree>>> {
        let (cp, cp_state) = (self.checkpoint.0, &self.checkpoint.1);
        if e == self.head() {
            return Ok(Some(Cow::Borrowed(&self.head_state)));
        }
        if e == cp {
            return Ok(Some(Cow::Borrowed(cp_state)));
        }
        if e < cp || e > self.head() {
            return Ok(None);
        }
        let mut state = cp_state.clone();
        self.replay(&mut state, cp, e)?;
        Ok(Some(Cow::Owned(state)))
    }

    /// Re-applies the retained tapes of epochs `from + 1 ..= to` to `state` with the native STF, checking every root.
    fn replay(&self, state: &mut SparseMerkleTree, from: u64, to: u64) -> Result<()> {
        for e in from + 1..=to {
            let epoch = self.epoch(e).ok_or_else(|| unknown(e))?;
            let tape = epoch.tape.as_ref().ok_or_else(|| pruned(e))?;
            rollup_stf::apply_tape(state, tape.words(), self.stf.domain());
            if state.root() != epoch.state_root {
                return Err(NodeError::Derivation(format!("epoch {e}: replayed state root differs from derivation")));
            }
        }
        Ok(())
    }

    /// State root after epoch `e` (kept for every epoch; the empty-tree root for genesis).
    pub fn state_root_at(&self, e: u64) -> Option<B256> {
        if e == 0 { Some(SparseMerkleTree::new().root()) } else { self.epoch(e).map(|d| d.state_root) }
    }

    /// Latest state.
    pub fn latest_state(&self) -> &SparseMerkleTree {
        &self.head_state
    }

    /// Balance and next nonce of an account in the latest derived state.
    pub fn account(&self, a: Address) -> (U256, U256) {
        let s = self.latest_state();
        (s.balance(address_word(a)), s.nonce(address_word(a)))
    }

    /// Execution trace of epoch `e` from the canonical pre-state, optionally with a fault injected. Cached until the
    /// epoch finalizes or [`Chain::evict_traces`] is called for it.
    ///
    /// # Errors
    /// Unknown epoch, an epoch at or below the checkpoint (finalized: it can no longer be disputed), or the program
    /// not halting (impossible for inbox-accepted batches).
    pub fn trace(&mut self, e: u64, fault: Option<Fault>) -> Result<Arc<EpochTrace>> {
        let key = (e, fault);
        if let Some(t) = self.trace_cache.get(&key) {
            return Ok(Arc::clone(t));
        }
        if e <= self.checkpoint.0 {
            return Err(pruned(e));
        }
        let tape = self.epoch(e).and_then(|d| d.tape.clone()).ok_or_else(|| unknown(e))?;
        let pre = self.state_at(e - 1)?.ok_or_else(|| pruned(e - 1))?.into_owned();
        let trace = Arc::new(EpochTrace::new(&self.stf, self.stf.initial_machine(pre, tape), fault)?);
        self.trace_cache.insert(key, Arc::clone(&trace));
        Ok(trace)
    }

    /// Drops every cached trace of epoch `e` (called once the games that needed them have resolved).
    pub fn evict_traces(&mut self, e: u64) {
        self.trace_cache.retain(|(epoch, _), _| *epoch != e);
    }

    /// Proof of withdrawal `id` against the state after epoch `e`. When that state has been pruned (`e` is below the
    /// checkpoint), the proof is served against the checkpoint instead: a later finalized epoch, where the withdrawal
    /// still exists (the STF never deletes one), so it is equally valid on L1. `WithdrawalProof::epoch` says which.
    ///
    /// # Errors
    /// Unknown epoch or withdrawal, or a recipient word that is not an L1 address (such a withdrawal can never be paid
    /// by `Bridge.finalizeWithdrawal`, which takes an `address`).
    pub fn withdrawal_proof(&self, e: u64, id: U256) -> Result<WithdrawalProof> {
        if e > self.head() {
            return Err(unknown(e));
        }
        let entry = self
            .epochs
            .iter()
            .take(usize::try_from(e).unwrap_or(usize::MAX))
            .flat_map(|d| d.withdrawals.iter())
            .find(|w| w.id == id)
            .ok_or_else(|| NodeError::Derivation(format!("withdrawal {id} does not exist at epoch {e}")))?;
        let recipient = word_to_address(entry.recipient).ok_or_else(|| {
            NodeError::Derivation(format!(
                "withdrawal {id}: recipient word {:#x} is not an L1 address",
                entry.recipient
            ))
        })?;
        let proof_epoch = e.max(self.checkpoint.0);
        let state = self.state_at(proof_epoch)?.ok_or_else(|| pruned(proof_epoch))?;
        let SmtProof { bitmap, siblings } = state.proof(keys::withdrawal_key(id));
        Ok(WithdrawalProof {
            epoch: proof_epoch,
            state_root: state.root(),
            withdrawal_id: id,
            recipient,
            amount: entry.amount,
            bitmap,
            siblings,
        })
    }

    /// Reads new logs and the finalized epoch from L1, starting at block `from` (see [`Chain::next_block`]).
    ///
    /// # Errors
    /// RPC or log-decoding failures.
    pub async fn fetch<P: Provider>(from: u64, provider: &P, contracts: &Contracts) -> Result<L1Update> {
        let finalized = contracts.oracle.lastFinalizedEpoch().call().await?;
        let latest = provider.get_block_number().await?;
        if latest < from {
            return Ok(L1Update { next_block: from, queue: Vec::new(), batches: Vec::new(), finalized });
        }
        let range = |addr: Address, sig: B256| {
            Filter::new().address(addr).event_signature(sig).from_block(from).to_block(latest)
        };
        let queue_logs = provider
            .get_logs(&range(contracts.deployment.queue, IForcedInclusionQueue::MessageEnqueued::SIGNATURE_HASH))
            .await?;
        let batch_logs =
            provider.get_logs(&range(contracts.deployment.inbox, IBatchInbox::BatchAppended::SIGNATURE_HASH)).await?;
        let mut queue = Vec::with_capacity(queue_logs.len());
        for log in &queue_logs {
            let ev = log.log_decode::<IForcedInclusionQueue::MessageEnqueued>()?.inner.data;
            queue.push((ev.index.to::<u64>(), ev.record.into()));
        }
        let mut batches = Vec::with_capacity(batch_logs.len());
        for log in &batch_logs {
            let l1_block = log.block_number.unwrap_or_default();
            batches.push(BatchLog::new(log.log_decode::<IBatchInbox::BatchAppended>()?.inner.data, l1_block));
        }
        Ok(L1Update { next_block: latest + 1, queue, batches, finalized })
    }

    /// Derives the epochs in `update` without modifying the chain (CPU-heavy: every epoch is stepped through the VM).
    ///
    /// # Errors
    /// Inconsistent L1 data (queue or epoch gaps, a tape that does not match its L1 hash, VM and native STF
    /// disagreeing).
    pub fn derive(&self, update: &L1Update) -> Result<Derivation> {
        let mut queue = Vec::with_capacity(update.queue.len());
        for (index, record) in &update.queue {
            let expected = (self.queue.len() + queue.len()) as u64;
            if *index != expected {
                return Err(NodeError::Derivation(format!("queue gap: got index {index}, expected {expected}")));
            }
            queue.push(*record);
        }
        let queue_slice = |start: u64, end: u64| -> Option<Vec<Record>> {
            let (start, end) = (usize::try_from(start).ok()?, usize::try_from(end).ok()?);
            let all_len = self.queue.len() + queue.len();
            (start <= end && end <= all_len).then(|| {
                (start..end)
                    .map(|i| self.queue.get(i).copied().unwrap_or_else(|| queue[i - self.queue.len()]))
                    .collect()
            })
        };

        let new_head = self.head() + update.batches.len() as u64;
        let target = update.finalized.min(new_head);
        let mut checkpoint = None;
        if target > self.checkpoint.0 && target <= self.head() {
            // Finalization caught up with epochs derived earlier: rebuild the new checkpoint from the old one.
            let mut state = self.checkpoint.1.clone();
            self.replay(&mut state, self.checkpoint.0, target)?;
            checkpoint = Some((target, state));
        }

        let mut epochs: Vec<DerivedEpoch> = Vec::with_capacity(update.batches.len());
        let mut state: Option<SparseMerkleTree> = None;
        for ev in &update.batches {
            let epoch = ev.epoch;
            let expected = self.head() + epochs.len() as u64 + 1;
            if epoch != expected {
                return Err(NodeError::Derivation(format!("epoch gap: got {epoch}, expected {expected}")));
            }
            let (start, end) = (ev.queue_start, ev.queue_end);
            let records = queue_slice(start, end)
                .ok_or_else(|| NodeError::Derivation(format!("epoch {epoch}: queue range {start}..{end} not seen")))?;
            let tape = build_tape(&records, &ev.tx_data)?;
            if tape.root() != ev.tape_hash || tape.size() != ev.tape_size {
                return Err(NodeError::Derivation(format!("epoch {epoch}: reconstructed tape does not match L1")));
            }
            let tape = Arc::new(tape);
            let working = state.get_or_insert_with(|| self.head_state.clone());
            let execution = self.stf.execute_owned(working.clone(), Arc::clone(&tape))?;
            let report = rollup_stf::apply_tape(working, tape.words(), self.stf.domain());
            if working.root() != execution.post_state.root() {
                return Err(NodeError::Derivation(format!("epoch {epoch}: VM and native STF disagree")));
            }
            if epoch == target && target > self.checkpoint.0 {
                checkpoint = Some((target, working.clone()));
            }
            epochs.push(DerivedEpoch {
                epoch,
                tape: Some(tape),
                forced: ev.forced,
                queue_range: (start, end),
                l1_block: ev.l1_block,
                state_root: working.root(),
                steps: execution.steps,
                withdrawals: report.withdrawals,
            });
        }
        Ok(Derivation { next_block: update.next_block, queue, epochs, head_state: state, checkpoint })
    }

    /// Applies a [`Derivation`] computed by [`Chain::derive`] on this chain. Returns the number of new epochs.
    pub fn commit(&mut self, d: Derivation) -> u64 {
        let new = d.new_epochs();
        self.queue.extend(d.queue);
        self.epochs.extend(d.epochs);
        if let Some(s) = d.head_state {
            self.head_state = s;
        }
        if let Some(cp) = d.checkpoint {
            self.checkpoint = cp;
            let limit = usize::try_from(self.checkpoint.0).unwrap_or(usize::MAX);
            for epoch in self.epochs.iter_mut().take(limit) {
                epoch.tape = None;
            }
            let finalized = self.checkpoint.0;
            self.trace_cache.retain(|(epoch, _), _| *epoch > finalized);
        }
        self.next_block = self.next_block.max(d.next_block);
        new
    }

    /// Scans new L1 blocks and derives any new epochs: [`Chain::fetch`], [`Chain::derive`], [`Chain::commit`].
    /// Returns the number of new epochs.
    ///
    /// # Errors
    /// RPC failures or inconsistent L1 data.
    pub async fn sync<P: Provider>(&mut self, provider: &P, contracts: &Contracts) -> Result<u64> {
        let update = Self::fetch(self.next_block, provider, contracts).await?;
        let derivation = self.derive(&update)?;
        Ok(self.commit(derivation))
    }
}

/// The address a word encodes, if its high 96 bits are zero.
pub fn word_to_address(w: U256) -> Option<Address> {
    (w >> 160u32).is_zero().then(|| Address::from_word(B256::from(w.to_be_bytes::<32>())))
}

fn unknown(e: u64) -> NodeError {
    NodeError::Derivation(format!("epoch {e} has not been derived"))
}

fn pruned(e: u64) -> NodeError {
    NodeError::Derivation(format!("epoch {e} is finalized on L1; its state and trace are no longer kept"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::signers::{SignerSync, local::PrivateKeySigner};
    use rollup_stf::{Kind, L2Tx, encode_tx_data};

    use crate::wallet::sign_tx;

    fn signer(i: u8) -> PrivateKeySigner {
        PrivateKeySigner::from_bytes(&B256::repeat_byte(i)).unwrap()
    }

    fn eth(x: u64) -> U256 {
        U256::from(x) * U256::from(10u64).pow(U256::from(18u64))
    }

    /// `BatchAppended` for `epoch` exactly as the inbox would emit it for these queue records and sequenced records.
    fn batch(epoch: u64, queue: &[Record], range: (u64, u64), seq: &[Record]) -> BatchLog {
        let data = encode_tx_data(seq);
        let tape = build_tape(queue, &data).unwrap();
        let ev = IBatchInbox::BatchAppended {
            epoch: U256::from(epoch),
            tapeHash: tape.root(),
            tapeSize: tape.size(),
            queueStart: range.0,
            queueEnd: range.1,
            forced: false,
            txData: Bytes::from(data),
        };
        BatchLog::new(ev, 1)
    }

    /// Feeds new queue messages, batches and the L1-finalized epoch through derive + commit.
    fn apply(chain: &mut Chain, queue: &[Record], batches: Vec<BatchLog>, finalized: u64) {
        let base = chain.queue().len() as u64;
        let update = L1Update {
            next_block: chain.next_block() + 1,
            queue: queue.iter().enumerate().map(|(i, r)| (base + i as u64, *r)).collect(),
            batches,
            finalized,
        };
        let d = chain.derive(&update).unwrap();
        chain.commit(d);
    }

    /// Ten epochs, each moving value around; finalization then advances. Only the head and checkpoint states are
    /// kept, every other state is rebuilt exactly, and tapes and traces at or below the checkpoint are dropped.
    #[test]
    fn keeps_two_states_and_prunes_what_finalization_settles() {
        let stf = Stf::new(901);
        let mut chain = Chain::new(stf.clone(), 0);
        let alice = signer(1);
        let a = alice.address();
        let mut roots = vec![chain.state_root_at(0).unwrap()];
        let mut reference = SparseMerkleTree::new();
        for e in 1..=10u64 {
            let deposit = Record::queue(Kind::Deposit, Address::ZERO, a, eth(1));
            let to = Address::repeat_byte(u8::try_from(e).unwrap());
            let transfer = sign_tx(&alice, Kind::Transfer, to, U256::from(e), U256::from(e - 1), stf.domain()).unwrap();
            let q = chain.queue().len() as u64;
            let ev = batch(e, &[deposit], (q, q + 1), &[transfer]);
            apply(&mut chain, &[deposit], vec![ev.clone()], 0);
            let tape = build_tape(&[deposit], &ev.tx_data).unwrap();
            rollup_stf::apply_tape(&mut reference, tape.words(), stf.domain());
            roots.push(reference.root());
        }
        assert_eq!(chain.head(), 10);
        for (e, root) in roots.iter().enumerate() {
            assert_eq!(chain.state_root_at(e as u64), Some(*root));
            assert_eq!(chain.state_at(e as u64).unwrap().unwrap().root(), *root, "rebuilt state of epoch {e}");
        }
        assert_eq!(chain.retained_tapes(), 10);

        // Disputes need traces; finalization then evicts them together with the tapes.
        chain.trace(3, None).unwrap();
        chain.trace(8, None).unwrap();
        assert_eq!(chain.cached_traces(), 2);
        apply(&mut chain, &[], vec![], 5);
        assert_eq!(chain.checkpoint_epoch(), 5);
        assert_eq!(chain.retained_tapes(), 5);
        assert_eq!(chain.cached_traces(), 1, "the trace of finalized epoch 3 is evicted");
        assert!(chain.state_at(4).unwrap().is_none(), "states below the checkpoint are pruned");
        assert_eq!(chain.state_at(5).unwrap().unwrap().root(), roots[5]);
        assert_eq!(chain.state_at(7).unwrap().unwrap().root(), roots[7]);
        assert!(chain.trace(5, None).is_err(), "a finalized epoch cannot be disputed");
        assert_eq!(chain.trace(6, None).unwrap().final_commitment().stateRoot, roots[6]);
        chain.evict_traces(8);
        assert_eq!(chain.cached_traces(), 1);

        // Finalization reported beyond what a node has derived is clamped to its head.
        apply(&mut chain, &[], vec![], 50);
        assert_eq!(chain.checkpoint_epoch(), 10);
        assert_eq!(chain.retained_tapes(), 0);
        assert_eq!(chain.cached_traces(), 0);
        assert_eq!(chain.account(a).0, eth(10) - U256::from(55));
    }

    /// When finalization lands on an epoch derived in the same round, the checkpoint is captured during derivation.
    #[test]
    fn checkpoint_can_land_on_a_newly_derived_epoch() {
        let mut chain = Chain::new(Stf::new(901), 0);
        let a = Address::repeat_byte(1);
        let deposits: Vec<Record> = (1..=3).map(|i| Record::queue(Kind::Deposit, Address::ZERO, a, eth(i))).collect();
        let evs: Vec<_> =
            (0..3u64).map(|i| batch(i + 1, &deposits[i as usize..=i as usize], (i, i + 1), &[])).collect();
        apply(&mut chain, &deposits, evs, 2);
        assert_eq!(chain.checkpoint_epoch(), 2);
        assert_eq!(chain.state_at(2).unwrap().unwrap().root(), chain.state_root_at(2).unwrap());
        assert_eq!(chain.retained_tapes(), 1);
        assert_eq!(chain.account(a).0, eth(6));
    }

    /// Withdrawal proofs are served against the checkpoint when the requested epoch was pruned, and are refused for a
    /// recipient word that is not an address (it could never be paid on L1).
    #[test]
    fn withdrawal_proofs_follow_the_checkpoint_and_refuse_non_addresses() {
        let stf = Stf::new(901);
        let mut chain = Chain::new(stf.clone(), 0);
        let alice = signer(3);
        let a = alice.address();
        let deposit = Record::queue(Kind::Deposit, Address::ZERO, a, eth(5));
        let good =
            sign_tx(&alice, Kind::Withdrawal, Address::repeat_byte(0x77), eth(1), U256::ZERO, stf.domain()).unwrap();
        // A raw record whose `to` has high bits set, correctly signed over that word: the STF debits Alice for it.
        let mut bad = good;
        bad.to = U256::MAX;
        bad.nonce = U256::from(1);
        let digest = L2Tx::digest_of(Kind::Withdrawal, bad.from, bad.to, bad.amount, bad.nonce, stf.domain());
        let sig = alice.sign_hash_sync(&digest).unwrap();
        (bad.v, bad.r, bad.s) = (U256::from(27 + u8::from(sig.v())), sig.r(), sig.s());

        apply(&mut chain, &[deposit], vec![batch(1, &[deposit], (0, 1), &[good, bad])], 0);
        apply(&mut chain, &[], vec![batch(2, &[], (1, 1), &[])], 0);
        assert_eq!(chain.account(a).0, eth(3), "both withdrawals were debited");

        let p = chain.withdrawal_proof(1, U256::ZERO).unwrap();
        assert_eq!((p.epoch, p.recipient, p.amount), (1, Address::repeat_byte(0x77), eth(1)));
        let e = chain.withdrawal_proof(1, U256::from(1)).unwrap_err().to_string();
        assert!(e.contains("not an L1 address"), "{e}");

        apply(&mut chain, &[], vec![], 2);
        let p = chain.withdrawal_proof(1, U256::ZERO).unwrap();
        assert_eq!(p.epoch, 2, "epoch 1 was pruned; the proof is against the checkpoint");
        assert_eq!(p.state_root, chain.state_root_at(2).unwrap());
        let leaf = keys::withdrawal_value(address_word(p.recipient), p.amount);
        let proof = SmtProof { bitmap: p.bitmap, siblings: p.siblings.clone() };
        assert_eq!(proof.compute_root(keys::withdrawal_key(U256::ZERO), leaf).unwrap(), p.state_root);
        assert!(chain.withdrawal_proof(3, U256::ZERO).is_err());
    }

    #[test]
    fn derivation_rejects_gaps_and_mismatched_tapes() {
        let mut chain = Chain::new(Stf::new(901), 0);
        let update = |queue: Vec<(u64, Record)>, batches| L1Update { next_block: 1, queue, batches, finalized: 0 };
        let e = chain.derive(&update(vec![(1, Record::default())], vec![])).unwrap_err().to_string();
        assert!(e.contains("queue gap"), "{e}");
        let mut ev = batch(2, &[], (0, 0), &[]);
        let e = chain.derive(&update(vec![], vec![ev.clone()])).unwrap_err().to_string();
        assert!(e.contains("epoch gap"), "{e}");
        ev.epoch = 1;
        ev.tape_hash = B256::repeat_byte(1);
        let e = chain.derive(&update(vec![], vec![ev.clone()])).unwrap_err().to_string();
        assert!(e.contains("does not match"), "{e}");
        ev.queue_end = 3;
        let e = chain.derive(&update(vec![], vec![ev])).unwrap_err().to_string();
        assert!(e.contains("not seen"), "{e}");
        assert_eq!(word_to_address(U256::from(1) << 160u32), None);
        assert_eq!(word_to_address(address_word(Address::repeat_byte(9))), Some(Address::repeat_byte(9)));
        chain.commit(Derivation { next_block: 7, queue: vec![], epochs: vec![], head_state: None, checkpoint: None });
        assert_eq!(chain.next_block(), 7);
    }
}
