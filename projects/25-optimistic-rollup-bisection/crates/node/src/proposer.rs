// SPDX-License-Identifier: MIT
//! Proposer: posts bonded output roots for derived epochs, defends them, finalizes them, and collects bonds.
//!
//! With `malicious = true` it instead claims a fraudulent root for every epoch: the honest execution with a
//! 1,000-ETH mint to itself injected half-way through the trace ([`rollup_stf::Fault`]). It then defends that
//! claim with its self-consistent fake trace, so the bisection has to walk all the way down to the forged step.
//!
//! Each tick runs independent stages (derive, defend, finalize, recover bonds, claim credit, propose). A failing stage
//! is logged and never stops the others: in particular a proposer whose balance is locked up in bonds keeps
//! finalizing and collecting, which is exactly what gives it the balance to propose again.

use std::time::Duration;

use alloy::{
    primitives::{Address, B256, U256},
    providers::{DynProvider, Provider},
};
use rollup_l1::{Contracts, ProposalStatus};
use rollup_stf::{Fault, address_word};
use tokio::sync::watch;
use tracing::{info, warn};

use crate::{
    chain::Chain,
    error::Result,
    games::{Conduct, GameIndex, ProposalIndex, claim_credit, game_state, is_resolved, play, proposal_at},
    util::{l1_now, send, stage, wait_or_stop},
};

/// Amount a malicious proposer mints to itself.
pub const MALICIOUS_MINT: u128 = 1_000_000_000_000_000_000_000;

/// Proposer settings.
#[derive(Debug, Clone)]
pub struct ProposerConfig {
    /// Claim fraudulent roots.
    pub malicious: bool,
    /// Poll interval.
    pub poll: Duration,
    /// Stop proposing after this epoch (None = never).
    pub max_epoch: Option<u64>,
    /// Stop proposing after this many proposals (None = never); it keeps defending and finalizing.
    pub max_proposals: Option<u32>,
}

/// Proposer state.
#[derive(Debug)]
pub struct Proposer {
    provider: DynProvider,
    contracts: Contracts,
    me: Address,
    chain: Chain,
    games: GameIndex,
    proposals: ProposalIndex,
    cfg: ProposerConfig,
    proposals_made: u32,
    underfunded: bool,
}

impl Proposer {
    /// New proposer signing as `me`. Its own proposals are rediscovered from L1 logs, so bonds are recovered across
    /// restarts.
    pub fn new(provider: DynProvider, contracts: Contracts, me: Address, chain: Chain, cfg: ProposerConfig) -> Self {
        let start = contracts.deployment.start_block;
        Self {
            provider,
            contracts,
            me,
            chain,
            games: GameIndex::for_party(start, me),
            proposals: ProposalIndex::new(me, start),
            cfg,
            proposals_made: 0,
            underfunded: false,
        }
    }

    fn fault(&mut self, epoch: u64) -> Result<Option<Fault>> {
        if !self.cfg.malicious {
            return Ok(None);
        }
        let honest_steps = self.chain.trace(epoch, None)?.steps();
        Ok(Some(Fault {
            at_step: honest_steps / 2,
            beneficiary: address_word(self.me),
            amount: U256::from(MALICIOUS_MINT),
        }))
    }

    /// State root this proposer claims for `epoch`.
    fn claim(&mut self, epoch: u64) -> Result<Option<B256>> {
        match self.fault(epoch)? {
            Some(f) => Ok(Some(self.chain.trace(epoch, Some(f))?.final_commitment().stateRoot)),
            None => Ok(self.chain.state_root_at(epoch)),
        }
    }

    async fn propose_new(&mut self) -> Result<()> {
        let bond = self.contracts.oracle.PROPOSER_BOND().call().await?;
        loop {
            let next = self.contracts.oracle.nextEpoch().call().await?;
            if next > self.chain.head()
                || self.cfg.max_epoch.is_some_and(|m| next > m)
                || self.cfg.max_proposals.is_some_and(|m| self.proposals_made >= m)
            {
                return Ok(());
            }
            if !self.cfg.malicious && next > 1 {
                // Never build on a parent we disagree with: the challenger will remove it first.
                let parent = proposal_at(&self.contracts, next - 1).await?;
                if parent.map(|(_, p)| p.stateRoot) != self.chain.state_root_at(next - 1) {
                    return Ok(());
                }
            }
            // Bonds come back only after the challenge window; until then, wait instead of failing every tick.
            let balance = self.provider.get_balance(self.me).await?;
            if balance < bond {
                if !self.underfunded {
                    warn!(epoch = next, %balance, %bond, "balance below the proposer bond; waiting for bonds to return");
                }
                self.underfunded = true;
                return Ok(());
            }
            self.underfunded = false;
            let Some(root) = self.claim(next)? else { return Ok(()) };
            send(self.contracts.oracle.propose(next, root).value(bond), self.me).await?;
            self.proposals_made += 1;
            info!(epoch = next, root = %root, malicious = self.cfg.malicious, "proposed output");
        }
    }

    async fn defend(&mut self) -> Result<()> {
        self.games.sync(&self.provider, &self.contracts).await?;
        let conduct = if self.cfg.malicious { Conduct::Dishonest } else { Conduct::Honest };
        let mine: Vec<_> = self.games.involving(self.me).filter(|g| g.defender == self.me).copied().collect();
        for info in mine {
            // Read the game first: resolved games are dropped before any trace is computed for them.
            let g = match game_state(&self.contracts, info.id).await {
                Ok(g) => g,
                Err(e) => {
                    warn!(game = %info.id, error = %e, "could not read game");
                    continue;
                }
            };
            if is_resolved(&g) {
                self.games.remove(info.id);
                if !self.games.disputes_epoch(info.epoch) {
                    self.chain.evict_traces(info.epoch);
                }
                continue;
            }
            let trace = if info.epoch <= self.chain.head() {
                match self.fault(info.epoch).and_then(|f| self.chain.trace(info.epoch, f)) {
                    Ok(t) => Some(t),
                    Err(e) => {
                        warn!(game = %info.id, error = %e, "no trace for the disputed epoch");
                        None
                    }
                }
            } else {
                None
            };
            if let Err(e) = play(&self.provider, &self.contracts, self.me, &info, &g, trace.as_deref(), conduct).await {
                warn!(game = %info.id, error = %e, "defence move failed");
            }
        }
        Ok(())
    }

    /// Finalizes every epoch that is ready (anyone may; the proposer does it for its own bonds).
    async fn finalize_ready(&mut self) -> Result<()> {
        let window = self.contracts.oracle.CHALLENGE_WINDOW().call().await?;
        let now = l1_now(&self.provider).await?;
        loop {
            let e = self.contracts.oracle.lastFinalizedEpoch().call().await? + 1;
            let Some((_, p)) = proposal_at(&self.contracts, e).await? else { return Ok(()) };
            let ready = ProposalStatus::from_u8(p.status) == ProposalStatus::Proposed
                && e < self.contracts.oracle.nextEpoch().call().await?
                && p.activeGames == 0
                && now >= p.proposedAt + window;
            if !ready {
                return Ok(());
            }
            send(self.contracts.oracle.finalize(e), self.me).await?;
            info!(epoch = e, "finalized output");
        }
    }

    /// Reclaims the bonds of this proposer's proposals that an earlier invalidation orphaned.
    async fn recover_bonds(&mut self) -> Result<()> {
        self.proposals.sync(&self.provider, &self.contracts).await?;
        for id in self.proposals.open() {
            let p = self.contracts.oracle.getProposal(id).call().await?;
            match ProposalStatus::from_u8(p.status) {
                ProposalStatus::Proposed if !self.contracts.oracle.isLive(id).call().await? => {
                    match send(self.contracts.oracle.reclaimOrphanedBond(id), self.me).await {
                        Ok(_) => {
                            info!(proposal = %id, epoch = p.epoch, "reclaimed orphaned bond");
                            self.proposals.close(id);
                        }
                        Err(e) => warn!(proposal = %id, error = %e, "could not reclaim orphaned bond"),
                    }
                }
                ProposalStatus::Finalized | ProposalStatus::Invalidated | ProposalStatus::Orphaned => {
                    self.proposals.close(id);
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// One iteration of the service loop: every stage runs even if an earlier one failed.
    ///
    /// # Errors
    /// Never: stage failures are logged (see [`Proposer::run`]). The `Result` is kept for API stability.
    pub async fn tick(&mut self) -> Result<()> {
        let provider = self.provider.clone();
        let contracts = self.contracts.clone();
        let synced =
            stage("proposer", "derive", async { self.chain.sync(&provider, &contracts).await.map(|_| ()) }).await;
        stage("proposer", "defend", self.defend()).await;
        stage("proposer", "finalize", self.finalize_ready()).await;
        stage("proposer", "recover bonds", self.recover_bonds()).await;
        stage("proposer", "claim credit", async { claim_credit(&self.contracts, self.me).await.map(|_| ()) }).await;
        if synced {
            stage("proposer", "propose", self.propose_new()).await;
        }
        Ok(())
    }

    /// Runs until `shutdown` flips to `true`.
    ///
    /// # Errors
    /// Only unrecoverable setup errors; per-tick failures are logged and retried.
    pub async fn run(mut self, mut shutdown: watch::Receiver<bool>) -> Result<()> {
        info!(address = %self.me, malicious = self.cfg.malicious, "proposer started");
        loop {
            if let Err(e) = self.tick().await {
                warn!(error = %e, "proposer tick failed");
            }
            if wait_or_stop(self.cfg.poll, &mut shutdown).await {
                info!("proposer stopped");
                return Ok(());
            }
        }
    }
}
