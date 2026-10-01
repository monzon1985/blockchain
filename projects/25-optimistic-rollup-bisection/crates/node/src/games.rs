// SPDX-License-Identifier: MIT
//! Playing bisection games: shared by the proposer (defender) and the challenger.

use std::collections::{BTreeMap, BTreeSet};

use alloy::{
    primitives::{Address, B256, U256},
    providers::{DynProvider, Provider},
    rpc::types::Filter,
    sol_types::SolEvent,
};
use rollup_l1::{Contracts, IDisputeGame, IOutputOracle, Outcome, Phase};
use rollup_stf::EpochTrace;
use tracing::{info, warn};

use crate::{
    error::Result,
    util::{l1_now, send},
};

/// Static facts about a game, from its `GameCreated` log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GameInfo {
    /// Game id.
    pub id: U256,
    /// Disputed proposal.
    pub proposal_id: U256,
    /// Disputed epoch.
    pub epoch: u64,
    /// Proposer.
    pub defender: Address,
    /// Challenger.
    pub challenger: Address,
    /// Hash of the L1-computed initial machine.
    pub initial_hash: B256,
}

/// Incrementally indexes `GameCreated` logs, optionally only those of one party. Resolved games are dropped with
/// [`GameIndex::remove`], so the index (and the per-tick work of the services that walk it) only covers games still
/// in play.
#[derive(Debug, Default)]
pub struct GameIndex {
    next_block: u64,
    party: Option<Address>,
    games: BTreeMap<U256, GameInfo>,
}

impl GameIndex {
    /// Index of every game, scanning from `start_block`.
    pub fn new(start_block: u64) -> Self {
        Self { next_block: start_block, party: None, games: BTreeMap::new() }
    }

    /// Index of the games `party` plays (as defender or challenger), scanning from `start_block`. Other games are
    /// never stored.
    pub fn for_party(start_block: u64, party: Address) -> Self {
        Self { next_block: start_block, party: Some(party), games: BTreeMap::new() }
    }

    /// Picks up newly created games.
    ///
    /// # Errors
    /// RPC or decoding failure.
    pub async fn sync(&mut self, provider: &DynProvider, contracts: &Contracts) -> Result<()> {
        let latest = provider.get_block_number().await?;
        if latest < self.next_block {
            return Ok(());
        }
        let filter = Filter::new()
            .address(contracts.deployment.game)
            .event_signature(IDisputeGame::GameCreated::SIGNATURE_HASH)
            .from_block(self.next_block)
            .to_block(latest);
        for log in provider.get_logs(&filter).await? {
            let ev = log.log_decode::<IDisputeGame::GameCreated>()?.inner.data;
            if self.party.is_some_and(|p| p != ev.defender && p != ev.challenger) {
                continue;
            }
            self.games.insert(
                ev.gameId,
                GameInfo {
                    id: ev.gameId,
                    proposal_id: ev.proposalId,
                    epoch: ev.epoch,
                    defender: ev.defender,
                    challenger: ev.challenger,
                    initial_hash: ev.initialHash,
                },
            );
        }
        self.next_block = latest + 1;
        Ok(())
    }

    /// Games in which `who` plays.
    pub fn involving(&self, who: Address) -> impl Iterator<Item = &GameInfo> {
        self.games.values().filter(move |g| g.defender == who || g.challenger == who)
    }

    /// All indexed games.
    pub fn all(&self) -> impl Iterator<Item = &GameInfo> {
        self.games.values()
    }

    /// Forgets a game (once it has resolved). Returns its info if it was indexed.
    pub fn remove(&mut self, id: U256) -> Option<GameInfo> {
        self.games.remove(&id)
    }

    /// Number of games still indexed.
    pub fn len(&self) -> usize {
        self.games.len()
    }

    /// Whether no game is indexed.
    pub fn is_empty(&self) -> bool {
        self.games.is_empty()
    }

    /// Whether any indexed game disputes `epoch`.
    pub fn disputes_epoch(&self, epoch: u64) -> bool {
        self.games.values().any(|g| g.epoch == epoch)
    }
}

/// Incrementally indexes one proposer's `OutputProposed` logs (the proposer is an indexed topic), so a restarted
/// service still knows every proposal whose bond it may have to recover.
#[derive(Debug)]
pub struct ProposalIndex {
    proposer: Address,
    next_block: u64,
    open: BTreeSet<U256>,
}

impl ProposalIndex {
    /// Index of `proposer`'s proposals, scanning from `start_block`.
    pub fn new(proposer: Address, start_block: u64) -> Self {
        Self { proposer, next_block: start_block, open: BTreeSet::new() }
    }

    /// Picks up the proposer's new proposals.
    ///
    /// # Errors
    /// RPC or decoding failure.
    pub async fn sync(&mut self, provider: &DynProvider, contracts: &Contracts) -> Result<()> {
        let latest = provider.get_block_number().await?;
        if latest < self.next_block {
            return Ok(());
        }
        let filter = Filter::new()
            .address(contracts.deployment.oracle)
            .event_signature(IOutputOracle::OutputProposed::SIGNATURE_HASH)
            .topic3(self.proposer.into_word())
            .from_block(self.next_block)
            .to_block(latest);
        for log in provider.get_logs(&filter).await? {
            let ev = log.log_decode::<IOutputOracle::OutputProposed>()?.inner.data;
            if ev.proposer == self.proposer {
                self.open.insert(ev.proposalId);
            }
        }
        self.next_block = latest + 1;
        Ok(())
    }

    /// Proposals whose bond has not been settled yet, as far as this index knows.
    pub fn open(&self) -> Vec<U256> {
        self.open.iter().copied().collect()
    }

    /// Marks a proposal as settled (finalized, invalidated, or its orphaned bond reclaimed).
    pub fn close(&mut self, id: U256) {
        self.open.remove(&id);
    }
}

/// How a party behaves.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Conduct {
    /// Plays its trace and calls the one-step proof when it would win.
    Honest,
    /// Plays its (fraudulent) trace but never volunteers a one-step proof.
    Dishonest,
}

/// What a call to [`play`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Nothing to do (not our turn, or resolved).
    Idle,
    /// Revealed the final state.
    CommittedEnd,
    /// Posted a midpoint.
    Bisected(u64),
    /// Chose a half.
    Chose(bool),
    /// Executed the one-step proof.
    Stepped(u64),
    /// Claimed the opponent's timeout.
    ClaimedTimeout,
    /// Cancelled a game whose proposal left the canonical chain.
    Cancelled,
}

/// Current on-chain state of a game.
///
/// # Errors
/// RPC failure.
pub async fn game_state(contracts: &Contracts, id: U256) -> Result<IDisputeGame::Game> {
    Ok(contracts.game.getGame(id).call().await?)
}

/// Makes at most one move for `me` in `info`, whose current on-chain state is `g` (see [`game_state`]; callers read it
/// first so that resolved games are skipped before any trace is computed), using `trace` as its view of the epoch.
///
/// # Errors
/// RPC failures or reverted moves.
pub async fn play(
    provider: &DynProvider,
    contracts: &Contracts,
    me: Address,
    info: &GameInfo,
    g: &IDisputeGame::Game,
    trace: Option<&EpochTrace>,
    conduct: Conduct,
) -> Result<Action> {
    let phase = Phase::from_u8(g.phase);
    if matches!(phase, Phase::Resolved | Phase::None) {
        return Ok(Action::Idle);
    }
    let defender_turn = matches!(phase, Phase::AwaitingEnd | Phase::AwaitingMid);
    let now = l1_now(provider).await?;
    let deadline = contracts.game.deadline(info.id).call().await?.to::<u64>();
    let id = info.id;

    // Anyone may claim a timeout; each party only claims its opponent's.
    if now > deadline {
        let opponent_timed_out = (me == g.challenger && defender_turn) || (me == g.defender && !defender_turn);
        if opponent_timed_out {
            send(contracts.game.claimTimeout(id), me).await?;
            info!(game = %id, "claimed timeout");
            return Ok(Action::ClaimedTimeout);
        }
        return Ok(Action::Idle);
    }
    if me == g.challenger && !contracts.oracle.isLive(g.proposalId).call().await? {
        send(contracts.game.cancel(id), me).await?;
        return Ok(Action::Cancelled);
    }
    let Some(trace) = trace else {
        warn!(game = %id, epoch = info.epoch, "no trace for this epoch; cannot play");
        return Ok(Action::Idle);
    };
    if trace.hash_at(0) != info.initial_hash {
        warn!(game = %id, "our pre-state differs from the game's; cannot play");
        return Ok(Action::Idle);
    }
    let mid = g.lo + (g.hi - g.lo) / 2;

    match (phase, me == g.defender, me == g.challenger) {
        (Phase::AwaitingEnd, true, _) => {
            send(contracts.game.commitEnd(id, trace.final_commitment().into()), me).await?;
            info!(game = %id, "committed final state");
            Ok(Action::CommittedEnd)
        }
        (Phase::AwaitingMid, true, _) => {
            send(contracts.game.bisect(id, trace.hash_at(mid)), me).await?;
            info!(game = %id, lo = g.lo, hi = g.hi, mid, "bisected");
            Ok(Action::Bisected(mid))
        }
        (Phase::AwaitingChoice, _, true) => {
            let agree = g.midHash == trace.hash_at(mid);
            send(contracts.game.choose(id, agree), me).await?;
            info!(game = %id, mid, agree, "chose half");
            Ok(Action::Chose(agree))
        }
        (Phase::AwaitingStep, is_defender, is_challenger) => {
            let consistent = trace.hash_at(g.lo) == g.loHash;
            let we_win = if is_challenger { trace.hash_at(g.hi) != g.hiHash } else { trace.hash_at(g.hi) == g.hiHash };
            let volunteer = is_challenger || (is_defender && conduct == Conduct::Honest);
            if !(consistent && we_win && volunteer) {
                return Ok(Action::Idle);
            }
            let (pre, proof) = trace.proof_at(g.lo)?;
            send(contracts.game.step(id, pre.into(), proof.into()), me).await?;
            info!(game = %id, step = g.lo, "executed one-step proof on L1");
            Ok(Action::Stepped(g.lo))
        }
        _ => Ok(Action::Idle),
    }
}

/// Final outcome of a game, if resolved.
///
/// # Errors
/// RPC failure.
pub async fn outcome(contracts: &Contracts, id: U256) -> Result<Option<Outcome>> {
    let g = game_state(contracts, id).await?;
    Ok(is_resolved(&g).then(|| Outcome::from_u8(g.outcome)))
}

/// Whether a game is over.
pub fn is_resolved(g: &IDisputeGame::Game) -> bool {
    Phase::from_u8(g.phase) == Phase::Resolved
}

/// Withdraws `me`'s credit from the oracle if there is any. Returns the amount claimed.
///
/// # Errors
/// RPC failure or a reverted claim.
pub async fn claim_credit(contracts: &Contracts, me: Address) -> Result<U256> {
    let credit = contracts.oracle.credit(me).call().await?;
    if credit.is_zero() {
        return Ok(U256::ZERO);
    }
    send(contracts.oracle.claimCredit(), me).await?;
    info!(amount = %credit, "claimed credit");
    Ok(credit)
}

/// Current proposal of `epoch`, if any.
///
/// # Errors
/// RPC failure.
pub async fn proposal_at(contracts: &Contracts, epoch: u64) -> Result<Option<(U256, IOutputOracle::Proposal)>> {
    let id = contracts.oracle.proposalIdAt(epoch).call().await?;
    if id.is_zero() {
        return Ok(None);
    }
    Ok(Some((id, contracts.oracle.getProposal(id).call().await?)))
}
