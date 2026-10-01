// SPDX-License-Identifier: MIT
//! The keeper loop: sync the book, snapshot the market, plan with `risk-math`, dry-run, execute, report.
//!
//! Failure handling:
//! - Each candidate is handled on its own: a dry-run revert, an unprofitable plan, an RPC error, a mined revert or a
//!   receipt that does not arrive within `receipt_timeout` is recorded in the tick report and the next candidate is
//!   still processed.
//! - The book is split into a confirmed part (blocks at least `confirmations` behind the head), committed one log
//!   chunk at a time together with the block cursor, and a tip overlay rebuilt from the unconfirmed blocks on every
//!   sync. A reorg of the unconfirmed blocks therefore never leaves stale events behind, and a failure half-way
//!   through a chunk never double-applies its events on retry. Reorgs deeper than `confirmations` are not handled.

use std::time::Duration;

use alloy::primitives::{Address, B256, I256, U256};
use alloy::providers::{PendingTransactionError, Provider, WatchTxError};
use alloy::rpc::types::Filter;
use risk_math::{LiquidationConfig, MarketState};
use serde::Serialize;
use thiserror::Error;
use tracing::{debug, info, warn};

use crate::bindings::{IFlashLiquidator, ILendingEngine, IOracle, MarketParams, Order};
use crate::book::{BookError, EngineEvent, PositionBook, decode, event_signatures};
use crate::strategy::{Candidate, find_candidates, flash_amount, gas_cost_in_loan};

/// Extra gas over `eth_estimateGas`, in basis points (plus a 50k constant), when sending a liquidation.
pub const GAS_HEADROOM_BPS: u64 = 2_500;

/// Static configuration of a keeper.
#[derive(Debug, Clone)]
pub struct KeeperConfig {
    /// Lending engine.
    pub engine: Address,
    /// `FlashLiquidator` owned by the keeper's signer.
    pub liquidator: Address,
    /// Swap venue the liquidator sells collateral through.
    pub venue: Address,
    /// Market to watch.
    pub market_id: B256,
    /// Price of 1 ETH in loan-token base units (converts gas into the profit currency).
    pub eth_price_in_loan: U256,
    /// Minimum profit after gas, in loan-token base units, for a liquidation to be sent.
    pub min_net_profit: U256,
    /// Extra flash-loan headroom over the simulated repayment, in basis points.
    pub flash_buffer_bps: u64,
    /// Block span of each `eth_getLogs` query.
    pub log_chunk_size: u64,
    /// First block to replay events from (the market's creation block or earlier).
    pub from_block: u64,
    /// Blocks behind the head after which events are committed to the confirmed book.
    pub confirmations: u64,
    /// How long to wait for a liquidation's receipt before reporting the candidate as failed and moving on.
    pub receipt_timeout: Duration,
}

/// Errors of the keeper loop.
#[derive(Debug, Error)]
pub enum KeeperError {
    /// A contract call failed.
    #[error("contract call failed: {0}")]
    Contract(#[from] alloy::contract::Error),
    /// The RPC transport failed.
    #[error("rpc error: {0}")]
    Rpc(#[from] alloy::transports::TransportError),
    /// Waiting for a transaction failed.
    #[error("pending transaction error: {0}")]
    Pending(#[from] alloy::providers::PendingTransactionError),
    /// The event stream disagrees with the book.
    #[error(transparent)]
    Book(#[from] BookError),
    /// The engine has no market with this id.
    #[error("market {0} does not exist")]
    UnknownMarket(B256),
    /// A liquidation transaction was mined but reverted.
    #[error("liquidation transaction {0} reverted")]
    Reverted(B256),
    /// A liquidation transaction was sent but no receipt arrived within the timeout.
    #[error("no receipt for liquidation transaction {0} within {1:?}")]
    Timeout(B256, Duration),
    /// A mined liquidation did not emit the expected event.
    #[error("transaction {0} did not emit {1}")]
    MissingEvent(B256, &'static str),
}

/// Market state and oracle price at one point in time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Snapshot {
    /// Totals with interest accrued to the latest block.
    pub market: MarketState,
    /// Oracle price (1e36 scale).
    pub price: U256,
}

/// A liquidation the keeper executed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ExecutionReport {
    /// Liquidated borrower.
    pub borrower: Address,
    /// Health factor at planning time (WAD).
    #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
    pub health: U256,
    /// Whether the planned liquidation was a closeout (all collateral seized).
    pub closeout: bool,
    /// Collateral seized.
    #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
    pub seized_assets: U256,
    /// Loan tokens repaid to the engine.
    #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
    pub repaid_assets: U256,
    /// Loan tokens received for the collateral.
    #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
    pub proceeds: U256,
    /// Debt the engine wrote off (closeouts only).
    #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
    pub bad_debt_assets: U256,
    /// Profit in loan tokens before gas (sent to the keeper by the contract).
    #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
    pub profit: U256,
    /// Gas used by the transaction.
    pub gas_used: u64,
    /// Effective gas price paid (wei).
    pub effective_gas_price: u128,
    /// Gas cost converted into loan-token base units.
    #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
    pub gas_cost_in_loan: U256,
    /// Profit after gas, in loan-token base units.
    pub net_profit: I256,
    /// Transaction hash.
    pub tx_hash: B256,
}

/// Why a candidate was not executed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum SkipReason {
    /// The dry run reverted (e.g. the venue cannot absorb the collateral or the flash loan cannot be funded).
    SimulationReverted(String),
    /// Simulated profit does not cover gas plus the minimum.
    Unprofitable {
        /// Simulated profit before gas.
        #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
        profit: U256,
        /// Estimated gas cost in loan units.
        #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
        gas_cost_in_loan: U256,
        /// The configured minimum profit after gas.
        #[serde(serialize_with = "risk_math::vectors::dec::serialize")]
        min_net_profit: U256,
    },
    /// The dry run succeeded but execution failed: gas estimation or sending failed, the transaction reverted when
    /// mined, or no receipt arrived within the timeout (the transaction may still be mined later; its events are
    /// then picked up by the next sync).
    ExecutionFailed(String),
}

/// Outcome of one keeper iteration.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct TickReport {
    /// Positions found liquidatable.
    pub candidates: usize,
    /// Liquidations executed.
    pub executed: Vec<ExecutionReport>,
    /// Candidates left alone, with the reason.
    pub skipped: Vec<(Address, SkipReason)>,
}

/// A liquidation keeper for one market.
#[derive(Debug)]
pub struct Keeper<P> {
    provider: P,
    config: KeeperConfig,
    params: MarketParams,
    risk: LiquidationConfig,
    /// Positions as of block `next_block - 1`, which is at least `confirmations` blocks deep.
    confirmed: PositionBook,
    /// `confirmed` plus the events of the unconfirmed blocks, rebuilt on every sync.
    tip: PositionBook,
    next_block: u64,
}

impl<P: Provider + Clone> Keeper<P> {
    /// Loads the market definition and its liquidation schedule from the engine.
    pub async fn new(provider: P, config: KeeperConfig) -> Result<Self, KeeperError> {
        let engine = ILendingEngine::new(config.engine, provider.clone());
        let params = engine.idToMarketParams(config.market_id).call().await?;
        if params.loanToken == Address::ZERO {
            return Err(KeeperError::UnknownMarket(config.market_id));
        }
        let schedule = engine.liquidationConfig(params.lltv).call().await?;
        let risk = LiquidationConfig {
            lltv: params.lltv,
            max_bonus: U256::from(schedule.maxBonus),
            bonus_slope: U256::from(schedule.bonusSlope),
        };
        let next_block = config.from_block;
        Ok(Self {
            provider,
            config,
            params,
            risk,
            confirmed: PositionBook::new(),
            tip: PositionBook::new(),
            next_block,
        })
    }

    /// The event-sourced book at the latest synced block (confirmed events plus the unconfirmed tail).
    pub fn book(&self) -> &PositionBook {
        &self.tip
    }

    /// The part of the book that is at least `confirmations` blocks deep.
    pub fn confirmed_book(&self) -> &PositionBook {
        &self.confirmed
    }

    /// The watched market's parameters.
    pub fn market_params(&self) -> &MarketParams {
        &self.params
    }

    /// Replays engine events up to the latest block. Returns the number of events applied, counting the unconfirmed
    /// tail (which is replayed again on every sync).
    ///
    /// Blocks at least `confirmations` deep are committed to the confirmed book one log chunk at a time: each chunk is
    /// applied to a copy and the copy replaces the book together with the block cursor, so an error part-way through
    /// a chunk leaves both untouched and the retry re-reads the whole chunk. The newer blocks are replayed onto a copy
    /// of the confirmed book on every call, so events from a reorged tail never stay in the book.
    pub async fn sync(&mut self) -> Result<u64, KeeperError> {
        let latest = self.provider.get_block_number().await?;
        let safe = latest.saturating_sub(self.config.confirmations);
        let chunk = self.config.log_chunk_size.max(1);
        let mut applied = 0;
        while self.next_block <= safe {
            let to = safe.min(self.next_block.saturating_add(chunk - 1));
            let (staged, n) = self.confirmed.staged(self.events(self.next_block, to).await?)?;
            self.confirmed = staged;
            self.next_block = to + 1;
            applied += n;
        }
        let mut tail = Vec::new();
        let mut from = self.next_block;
        while from <= latest {
            let to = latest.min(from.saturating_add(chunk - 1));
            tail.extend(self.events(from, to).await?);
            from = to + 1;
        }
        let (tip, n) = self.confirmed.staged(tail)?;
        self.tip = tip;
        applied += n;
        if applied > 0 {
            debug!(applied, next_block = self.next_block, latest, "book synced");
        }
        Ok(applied)
    }

    /// The watched market's position-changing events in blocks `from..=to`, in log order.
    async fn events(&self, from: u64, to: u64) -> Result<Vec<EngineEvent>, KeeperError> {
        let filter = Filter::new()
            .address(self.config.engine)
            .event_signature(event_signatures())
            .topic1(self.config.market_id)
            .from_block(from)
            .to_block(to);
        let logs = self.provider.get_logs(&filter).await?;
        Ok(logs.iter().filter_map(|log| decode(log, self.config.market_id)).collect())
    }

    /// Reads market totals (interest accrued to now) and the oracle price.
    pub async fn snapshot(&self) -> Result<Snapshot, KeeperError> {
        let engine = ILendingEngine::new(self.config.engine, self.provider.clone());
        let balances = engine.expectedMarketBalances(self.params.clone()).call().await?;
        let price = IOracle::new(self.params.oracle, self.provider.clone()).price().call().await?;
        Ok(Snapshot {
            market: MarketState {
                total_supply_assets: balances.totalSupplyAssets,
                total_supply_shares: balances.totalSupplyShares,
                total_borrow_assets: balances.totalBorrowAssets,
                total_borrow_shares: balances.totalBorrowShares,
            },
            price,
        })
    }

    /// One iteration: sync, plan every liquidatable position, dry-run and execute the profitable ones.
    ///
    /// Only the sync and the market snapshot can fail the whole tick; every per-candidate failure is recorded in
    /// [`TickReport::skipped`] and the remaining candidates are still processed.
    pub async fn tick(&mut self) -> Result<TickReport, KeeperError> {
        self.sync().await?;
        let snapshot = self.snapshot().await?;
        let candidates = find_candidates(&self.tip, &snapshot.market, snapshot.price, &self.risk);
        let mut report = TickReport { candidates: candidates.len(), ..TickReport::default() };
        for candidate in candidates {
            match self.execute(&candidate).await {
                Ok(execution) => {
                    info!(
                        borrower = %execution.borrower,
                        closeout = execution.closeout,
                        profit = %execution.profit,
                        net_profit = %execution.net_profit,
                        "liquidated"
                    );
                    report.executed.push(execution);
                }
                Err(reason) => {
                    warn!(borrower = %candidate.borrower, ?reason, "skipped");
                    report.skipped.push((candidate.borrower, reason));
                }
            }
        }
        // Fold our own liquidations back into the book.
        self.sync().await?;
        Ok(report)
    }

    fn order(&self, candidate: &Candidate) -> Order {
        let (seized, repaid_shares) = candidate.plan.input.as_call_args();
        Order {
            marketParams: self.params.clone(),
            borrower: candidate.borrower,
            seizedAssets: seized,
            repaidShares: repaid_shares,
            venue: self.config.venue,
            minAmountOut: U256::ZERO,
        }
    }

    /// Dry-runs the flash liquidation, and sends it if the simulated profit covers gas plus the minimum.
    async fn execute(&self, candidate: &Candidate) -> Result<ExecutionReport, SkipReason> {
        let liquidator = IFlashLiquidator::new(self.config.liquidator, self.provider.clone());
        let order = self.order(candidate);
        let flash = flash_amount(&candidate.plan, self.config.flash_buffer_bps);

        let dry_run = liquidator.liquidate(order.clone(), flash, U256::ZERO);
        let simulated_profit = dry_run.call().await.map_err(|e| SkipReason::SimulationReverted(e.to_string()))?;
        let failed = |e: KeeperError| SkipReason::ExecutionFailed(e.to_string());
        let gas = dry_run.estimate_gas().await.map_err(|e| failed(e.into()))?;
        let gas_price = self.provider.get_gas_price().await.map_err(|e| failed(e.into()))?;
        let estimated_gas_cost =
            gas_cost_in_loan(U256::from(gas) * U256::from(gas_price), self.config.eth_price_in_loan);
        let floor = estimated_gas_cost + self.config.min_net_profit;
        if simulated_profit < floor {
            return Err(SkipReason::Unprofitable {
                profit: simulated_profit,
                gas_cost_in_loan: estimated_gas_cost,
                min_net_profit: self.config.min_net_profit,
            });
        }
        self.submit(candidate, order, flash, floor, gas, gas_price).await.map_err(failed)
    }

    /// Sends the liquidation with an on-chain profit floor (estimated gas plus the configured minimum: the
    /// transaction reverts rather than land below it) and waits at most `receipt_timeout` for the receipt.
    ///
    /// Fees are priced from the same `eth_gasPrice` the profitability check used (fee cap twice that, which absorbs
    /// several blocks of base-fee growth), rather than from fee history, so the check and the bid agree.
    async fn submit(
        &self,
        candidate: &Candidate,
        order: Order,
        flash: U256,
        floor: U256,
        gas: u64,
        gas_price: u128,
    ) -> Result<ExecutionReport, KeeperError> {
        let liquidator = IFlashLiquidator::new(self.config.liquidator, self.provider.clone());
        let tip = self.provider.get_max_priority_fee_per_gas().await?.min(gas_price);
        // The gas limit gets headroom because the estimate runs against the pending block: if interest accrual is due
        // when the transaction is mined, the IRM takes its (more expensive) adaptation path.
        let gas_limit = gas + gas * GAS_HEADROOM_BPS / 10_000 + 50_000;
        let pending = liquidator
            .liquidate(order, flash, floor)
            .gas(gas_limit)
            .max_fee_per_gas(gas_price.saturating_mul(2))
            .max_priority_fee_per_gas(tip)
            .send()
            .await?;
        let sent = *pending.tx_hash();
        let receipt = match pending.with_timeout(Some(self.config.receipt_timeout)).get_receipt().await {
            Ok(receipt) => receipt,
            Err(PendingTransactionError::TxWatcher(WatchTxError::Timeout)) => {
                return Err(KeeperError::Timeout(sent, self.config.receipt_timeout));
            }
            Err(e) => return Err(e.into()),
        };
        let tx_hash = receipt.transaction_hash;
        if !receipt.status() {
            return Err(KeeperError::Reverted(tx_hash));
        }
        let liquidation = receipt
            .decoded_log::<IFlashLiquidator::Liquidation>()
            .ok_or(KeeperError::MissingEvent(tx_hash, "Liquidation"))?
            .data;
        let engine_event = receipt
            .decoded_log::<ILendingEngine::Liquidate>()
            .ok_or(KeeperError::MissingEvent(tx_hash, "Liquidate"))?
            .data;
        let gas_cost_wei = U256::from(receipt.gas_used) * U256::from(receipt.effective_gas_price);
        let gas_cost = gas_cost_in_loan(gas_cost_wei, self.config.eth_price_in_loan);
        Ok(ExecutionReport {
            borrower: candidate.borrower,
            health: candidate.health,
            closeout: candidate.plan.outcome.position.collateral.is_zero(),
            seized_assets: liquidation.seizedAssets,
            repaid_assets: liquidation.repaidAssets,
            proceeds: liquidation.proceeds,
            bad_debt_assets: engine_event.badDebtAssets,
            profit: liquidation.profit,
            gas_used: receipt.gas_used,
            effective_gas_price: receipt.effective_gas_price,
            gas_cost_in_loan: gas_cost,
            net_profit: I256::from_raw(liquidation.profit) - I256::from_raw(gas_cost),
            tx_hash,
        })
    }
}
