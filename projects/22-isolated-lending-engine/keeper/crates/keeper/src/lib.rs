// SPDX-License-Identifier: MIT
//! Liquidation keeper for the isolated lending engine.
//!
//! Pipeline, per iteration:
//! 1. [`book`]: replay `SupplyCollateral`, `WithdrawCollateral`, `Borrow`, `Repay` and `Liquidate` events of one
//!    market into an exact copy of every borrower's position;
//! 2. snapshot the market totals (`expectedMarketBalances`, interest included) and the oracle price;
//! 3. [`strategy`]: compute every health factor and the largest valid liquidation with `risk-math`, the bit-exact
//!    port of the contract arithmetic;
//! 4. [`keeper`]: dry-run each liquidation through the `FlashLiquidator` (`eth_call`), compare the exact profit
//!    with the gas cost plus the configured minimum, send the profitable ones with that sum as an on-chain profit
//!    floor, wait a bounded time for each receipt, and report net profit after gas. A failure on one candidate is
//!    recorded and never stops the others.

pub mod bindings;
pub mod book;
pub mod keeper;
pub mod strategy;

pub use keeper::{ExecutionReport, Keeper, KeeperConfig, KeeperError, SkipReason, Snapshot, TickReport};
