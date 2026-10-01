// SPDX-License-Identifier: MIT
//! `layout-diff`: a storage-layout gate for upgradeable Solidity contracts.
//!
//! It reads `forge inspect <Contract> storageLayout --json` output extended with ERC-7201 namespaces (each described
//! by a probe contract compiled with Solidity's `layout at`, plus the slots the production accessors really use),
//! and answers three questions:
//!
//! - **diff**: can the new layout replace the old one behind the same proxy?
//! - **lint**: are the namespaces of one layout at their ERC-7201 slots, in the probe and in every accessor, and do
//!   no two regions overlap?
//! - **selectors**: can a set of facets be cut into one diamond without selector clashes?
//!
//! The rules are documented on [`diff`] and in the project's `docs/LAYOUT_DIFF.md`.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

pub mod diff;
pub mod erc7201;
pub mod error;
pub mod finding;
pub mod layout;
pub mod selectors;
pub mod types;

pub use diff::{diff_layouts, lint_layout};
pub use error::Error;
pub use finding::{Allowance, Finding, Kind, Report, Severity};
pub use layout::{Layout, Snapshot};
pub use selectors::{SelectorSet, check_selectors};
