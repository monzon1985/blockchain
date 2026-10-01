// SPDX-License-Identifier: MIT
//! Challenger: re-derives every epoch from L1, disputes any output that disagrees with it, and plays the bisection
//! down to the single instruction the one-step verifier executes on L1.
//!
//! Like the proposer, each tick runs independent stages (derive, index games, scan outputs, play, claim credit): a
//! challenger that cannot afford a new challenge bond, or hits an RPC error while scanning, still plays the games it
//! already has open and collects what it has won.

use std::{collections::BTreeSet, time::Duration};

use alloy::{
    primitives::{Address, U256},
    providers::{DynProvider, Provider},
};
use rollup_l1::Contracts;
use tokio::sync::watch;
use tracing::{info, warn};

use crate::{
    chain::Chain,
    error::Result,
    games::{Conduct, GameIndex, claim_credit, game_state, is_resolved, play, proposal_at},
    util::{l1_now, send, stage, wait_or_stop},
};

/// Challenger settings.
#[derive(Debug, Clone)]
pub struct ChallengerConfig {
    /// Poll interval.
    pub poll: Duration,
}

/// Challenger state.
#[derive(Debug)]
pub struct Challenger {
    provider: DynProvider,
    contracts: Contracts,
    me: Address,
    chain: Chain,
    games: GameIndex,
    cfg: ChallengerConfig,
    challenged: BTreeSet<U256>,
    underfunded: bool,
}

impl Challenger {
    /// New challenger signing as `me`.
    pub fn new(provider: DynProvider, contracts: Contracts, me: Address, chain: Chain, cfg: ChallengerConfig) -> Self {
        let start = contracts.deployment.start_block;
        Self {
            provider,
            contracts,
            me,
            chain,
            games: GameIndex::for_party(start, me),
            cfg,
            challenged: BTreeSet::new(),
            underfunded: false,
        }
    }

    /// Indexes new games; every proposal this challenger ever disputed is remembered (also across restarts, since the
    /// index is rebuilt from `GameCreated` logs), so it never pays a second bond for the same proposal.
    async fn index_games(&mut self) -> Result<()> {
        self.games.sync(&self.provider, &self.contracts).await?;
        let mine: Vec<U256> =
            self.games.involving(self.me).filter(|g| g.challenger == self.me).map(|g| g.proposal_id).collect();
        self.challenged.extend(mine);
        Ok(())
    }

    async fn scan_outputs(&mut self) -> Result<()> {
        let first = self.contracts.oracle.lastFinalizedEpoch().call().await? + 1;
        let next = self.contracts.oracle.nextEpoch().call().await?;
        let window = self.contracts.oracle.CHALLENGE_WINDOW().call().await?;
        let bond = self.contracts.game.CHALLENGER_BOND().call().await?;
        let now = l1_now(&self.provider).await?;
        for epoch in first..next {
            let Some(derived) = self.chain.state_root_at(epoch) else { break };
            let Some((id, p)) = proposal_at(&self.contracts, epoch).await? else { break };
            if p.stateRoot == derived || self.challenged.contains(&id) {
                continue;
            }
            let parent_agrees = epoch == 1
                || proposal_at(&self.contracts, epoch - 1).await?.map(|(_, pp)| pp.stateRoot)
                    == self.chain.state_root_at(epoch - 1);
            if !parent_agrees {
                // An earlier output is already wrong; invalidating it orphans this one.
                continue;
            }
            if !self.contracts.oracle.isLive(id).call().await? {
                continue;
            }
            if now >= p.proposedAt + window {
                warn!(epoch, "invalid output is past its challenge window");
                continue;
            }
            let balance = self.provider.get_balance(self.me).await?;
            if balance < bond {
                if !self.underfunded {
                    warn!(epoch, %balance, %bond, "invalid output detected but the balance is below the challenger bond");
                }
                self.underfunded = true;
                return Ok(());
            }
            self.underfunded = false;
            warn!(epoch, claimed = %p.stateRoot, derived = %derived, "invalid output detected; challenging");
            send(self.contracts.game.challenge(epoch).value(bond), self.me).await?;
            self.challenged.insert(id);
        }
        Ok(())
    }

    async fn play_games(&mut self) -> Result<()> {
        let mine: Vec<_> = self.games.involving(self.me).filter(|g| g.challenger == self.me).copied().collect();
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
            // Without a trace `play` can still claim timeouts and cancel games on orphaned proposals.
            let trace = if info.epoch <= self.chain.head() {
                match self.chain.trace(info.epoch, None) {
                    Ok(t) => Some(t),
                    Err(e) => {
                        warn!(game = %info.id, error = %e, "no trace for the disputed epoch");
                        None
                    }
                }
            } else {
                None
            };
            if let Err(e) =
                play(&self.provider, &self.contracts, self.me, &info, &g, trace.as_deref(), Conduct::Honest).await
            {
                warn!(game = %info.id, error = %e, "challenge move failed");
            }
        }
        Ok(())
    }

    /// One iteration of the service loop: every stage runs even if an earlier one failed.
    ///
    /// # Errors
    /// Never: stage failures are logged (see [`Challenger::run`]). The `Result` is kept for API stability.
    pub async fn tick(&mut self) -> Result<()> {
        let provider = self.provider.clone();
        let contracts = self.contracts.clone();
        let synced =
            stage("challenger", "derive", async { self.chain.sync(&provider, &contracts).await.map(|_| ()) }).await;
        let indexed = stage("challenger", "index games", self.index_games()).await;
        if synced && indexed {
            // Scanning needs an up-to-date chain and the full list of our games (to never challenge twice).
            stage("challenger", "scan outputs", self.scan_outputs()).await;
        }
        stage("challenger", "play", self.play_games()).await;
        stage("challenger", "claim credit", async { claim_credit(&self.contracts, self.me).await.map(|_| ()) }).await;
        Ok(())
    }

    /// Runs until `shutdown` flips to `true`.
    ///
    /// # Errors
    /// Only unrecoverable setup errors; per-tick failures are logged and retried.
    pub async fn run(mut self, mut shutdown: watch::Receiver<bool>) -> Result<()> {
        info!(address = %self.me, "challenger started");
        loop {
            if let Err(e) = self.tick().await {
                warn!(error = %e, "challenger tick failed");
            }
            if wait_or_stop(self.cfg.poll, &mut shutdown).await {
                info!("challenger stopped");
                return Ok(());
            }
        }
    }
}
