// SPDX-License-Identifier: MIT
//! Event-sourced position book for one market.
//!
//! The book replays the engine's events for a market id and keeps every borrower's collateral and debt shares,
//! exactly as the contract stores them. Market totals are not event-sourced (interest accrues without events for
//! each block), so they are read from `expectedMarketBalances` when health is evaluated.

use std::collections::BTreeMap;

use alloy::primitives::{Address, B256, U256};
use alloy::rpc::types::Log;
use alloy::sol_types::SolEvent;
use risk_math::PositionState;
use thiserror::Error;

use crate::bindings::ILendingEngine;

/// A position-changing engine event, reduced to what the book needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineEvent {
    /// Collateral posted for `on_behalf`.
    SupplyCollateral {
        /// Credited account.
        on_behalf: Address,
        /// Collateral amount.
        assets: U256,
    },
    /// Collateral withdrawn from `on_behalf`.
    WithdrawCollateral {
        /// Debited account.
        on_behalf: Address,
        /// Collateral amount.
        assets: U256,
    },
    /// Debt shares minted to `on_behalf`.
    Borrow {
        /// Borrower.
        on_behalf: Address,
        /// Debt shares minted.
        shares: U256,
    },
    /// Debt shares burned from `on_behalf`.
    Repay {
        /// Borrower.
        on_behalf: Address,
        /// Debt shares burned.
        shares: U256,
    },
    /// A liquidation of `borrower`.
    Liquidate {
        /// Liquidated account.
        borrower: Address,
        /// Debt shares repaid by the liquidator.
        repaid_shares: U256,
        /// Collateral seized.
        seized_assets: U256,
        /// Debt shares written off as bad debt.
        bad_debt_shares: U256,
    },
}

/// The event stream is inconsistent with the book (a missed or duplicated log).
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BookError {
    /// An event removed more than the book holds.
    #[error("event for {account} removes {removed} but the book holds {held} ({field})")]
    Underflow {
        /// The account.
        account: Address,
        /// Which field underflowed.
        field: &'static str,
        /// Amount the event removes.
        removed: U256,
        /// Amount the book holds.
        held: U256,
    },
}

/// Decodes a raw log into an [`EngineEvent`] if it is one of the five position-changing events of `market_id`.
pub fn decode(log: &Log, market_id: B256) -> Option<EngineEvent> {
    let topics = log.topics();
    if topics.len() < 2 || topics[1] != market_id {
        return None;
    }
    match topics[0] {
        ILendingEngine::SupplyCollateral::SIGNATURE_HASH => {
            let e = log.log_decode::<ILendingEngine::SupplyCollateral>().ok()?.inner.data;
            Some(EngineEvent::SupplyCollateral { on_behalf: e.onBehalf, assets: e.assets })
        }
        ILendingEngine::WithdrawCollateral::SIGNATURE_HASH => {
            let e = log.log_decode::<ILendingEngine::WithdrawCollateral>().ok()?.inner.data;
            Some(EngineEvent::WithdrawCollateral { on_behalf: e.onBehalf, assets: e.assets })
        }
        ILendingEngine::Borrow::SIGNATURE_HASH => {
            let e = log.log_decode::<ILendingEngine::Borrow>().ok()?.inner.data;
            Some(EngineEvent::Borrow { on_behalf: e.onBehalf, shares: e.shares })
        }
        ILendingEngine::Repay::SIGNATURE_HASH => {
            let e = log.log_decode::<ILendingEngine::Repay>().ok()?.inner.data;
            Some(EngineEvent::Repay { on_behalf: e.onBehalf, shares: e.shares })
        }
        ILendingEngine::Liquidate::SIGNATURE_HASH => {
            let e = log.log_decode::<ILendingEngine::Liquidate>().ok()?.inner.data;
            Some(EngineEvent::Liquidate {
                borrower: e.borrower,
                repaid_shares: e.repaidShares,
                seized_assets: e.seizedAssets,
                bad_debt_shares: e.badDebtShares,
            })
        }
        _ => None,
    }
}

/// Topic-0 hashes of the events the book consumes (for log filters).
pub fn event_signatures() -> Vec<B256> {
    vec![
        ILendingEngine::SupplyCollateral::SIGNATURE_HASH,
        ILendingEngine::WithdrawCollateral::SIGNATURE_HASH,
        ILendingEngine::Borrow::SIGNATURE_HASH,
        ILendingEngine::Repay::SIGNATURE_HASH,
        ILendingEngine::Liquidate::SIGNATURE_HASH,
    ]
}

/// Borrower positions of one market, rebuilt from events.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PositionBook {
    positions: BTreeMap<Address, PositionState>,
    events_applied: u64,
}

fn sub(held: U256, removed: U256, account: Address, field: &'static str) -> Result<U256, BookError> {
    held.checked_sub(removed).ok_or(BookError::Underflow { account, field, removed, held })
}

impl PositionBook {
    /// An empty book.
    pub fn new() -> Self {
        Self::default()
    }

    /// Applies one event.
    pub fn apply(&mut self, event: EngineEvent) -> Result<(), BookError> {
        match event {
            EngineEvent::SupplyCollateral { on_behalf, assets } => {
                self.positions.entry(on_behalf).or_default().collateral += assets;
            }
            EngineEvent::WithdrawCollateral { on_behalf, assets } => {
                let p = self.positions.entry(on_behalf).or_default();
                p.collateral = sub(p.collateral, assets, on_behalf, "collateral")?;
            }
            EngineEvent::Borrow { on_behalf, shares } => {
                self.positions.entry(on_behalf).or_default().borrow_shares += shares;
            }
            EngineEvent::Repay { on_behalf, shares } => {
                let p = self.positions.entry(on_behalf).or_default();
                p.borrow_shares = sub(p.borrow_shares, shares, on_behalf, "borrowShares")?;
            }
            EngineEvent::Liquidate { borrower, repaid_shares, seized_assets, bad_debt_shares } => {
                let p = self.positions.entry(borrower).or_default();
                p.borrow_shares = sub(p.borrow_shares, repaid_shares + bad_debt_shares, borrower, "borrowShares")?;
                p.collateral = sub(p.collateral, seized_assets, borrower, "collateral")?;
            }
        }
        self.events_applied += 1;
        Ok(())
    }

    /// Applies `events` in order to a copy of the book and returns the copy with the number of events applied.
    ///
    /// On error the book itself is untouched, so a caller can commit a whole log chunk atomically (together with its
    /// block cursor) and retry it from scratch.
    pub fn staged<I: IntoIterator<Item = EngineEvent>>(&self, events: I) -> Result<(Self, u64), BookError> {
        let mut next = self.clone();
        let mut applied = 0;
        for event in events {
            next.apply(event)?;
            applied += 1;
        }
        Ok((next, applied))
    }

    /// Position of `account` (zero if unknown).
    pub fn position(&self, account: &Address) -> PositionState {
        self.positions.get(account).copied().unwrap_or_default()
    }

    /// Accounts that currently owe debt, in address order.
    pub fn borrowers(&self) -> impl Iterator<Item = (&Address, &PositionState)> {
        self.positions.iter().filter(|(_, p)| !p.borrow_shares.is_zero())
    }

    /// Every account the book has seen.
    pub fn accounts(&self) -> impl Iterator<Item = &Address> {
        self.positions.keys()
    }

    /// Number of events applied since creation.
    pub fn events_applied(&self) -> u64 {
        self.events_applied
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(n: u8) -> Address {
        Address::repeat_byte(n)
    }

    fn u(x: u64) -> U256 {
        U256::from(x)
    }

    #[test]
    fn replays_a_position_lifecycle() {
        let mut book = PositionBook::new();
        book.apply(EngineEvent::SupplyCollateral { on_behalf: a(1), assets: u(100) }).unwrap();
        book.apply(EngineEvent::Borrow { on_behalf: a(1), shares: u(80_000_000) }).unwrap();
        book.apply(EngineEvent::Repay { on_behalf: a(1), shares: u(30_000_000) }).unwrap();
        book.apply(EngineEvent::WithdrawCollateral { on_behalf: a(1), assets: u(10) }).unwrap();
        assert_eq!(book.position(&a(1)), PositionState { collateral: u(90), borrow_shares: u(50_000_000) });
        assert_eq!(book.borrowers().count(), 1);

        book.apply(EngineEvent::Liquidate {
            borrower: a(1),
            repaid_shares: u(40_000_000),
            seized_assets: u(90),
            bad_debt_shares: u(10_000_000),
        })
        .unwrap();
        assert_eq!(book.position(&a(1)), PositionState::default());
        assert_eq!(book.borrowers().count(), 0);
        assert_eq!(book.events_applied(), 5);
    }

    #[test]
    fn detects_inconsistent_streams() {
        let mut book = PositionBook::new();
        let err = book.apply(EngineEvent::Repay { on_behalf: a(2), shares: u(1) }).unwrap_err();
        assert_eq!(err, BookError::Underflow { account: a(2), field: "borrowShares", removed: u(1), held: u(0) });
    }

    #[test]
    fn staged_chunk_is_all_or_nothing() {
        let mut book = PositionBook::new();
        book.apply(EngineEvent::SupplyCollateral { on_behalf: a(1), assets: u(100) }).unwrap();
        let chunk = [
            EngineEvent::Borrow { on_behalf: a(1), shares: u(50) },
            EngineEvent::SupplyCollateral { on_behalf: a(2), assets: u(7) },
            // A missed log upstream: this repayment removes more than the book holds.
            EngineEvent::Repay { on_behalf: a(2), shares: u(1) },
        ];
        let before = book.clone();
        assert!(book.staged(chunk).is_err());
        assert_eq!(book, before, "a failed chunk leaves the book untouched");

        let (next, applied) = book.staged(chunk[..2].iter().copied()).unwrap();
        assert_eq!(applied, 2);
        assert_eq!(next.position(&a(1)), PositionState { collateral: u(100), borrow_shares: u(50) });
        assert_eq!(book, before, "staging never mutates the original");
    }

    #[test]
    fn five_distinct_event_signatures() {
        let mut sigs = event_signatures();
        sigs.sort();
        sigs.dedup();
        assert_eq!(sigs.len(), 5);
    }
}
