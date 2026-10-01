// SPDX-License-Identifier: MIT
//! Error type of the library. Every failure to load or interpret an input is reported with the offending value.

use thiserror::Error;

/// Everything that can go wrong while loading or analysing a layout or a selector set.
#[derive(Debug, Error)]
pub enum Error {
    /// A file could not be read.
    #[error("cannot read `{path}`: {source}")]
    Io {
        /// Path that failed.
        path: String,
        /// Underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// A file is not valid JSON for the expected schema.
    #[error("`{path}` is not a valid input: {source}")]
    Json {
        /// Path that failed.
        path: String,
        /// Underlying parse error.
        #[source]
        source: serde_json::Error,
    },
    /// A slot or a size is not a decimal or 0x-hex integer of at most 256 bits.
    #[error("invalid 256-bit integer `{0}`")]
    Integer(String),
    /// A size does not fit the 64-bit range the analysis supports.
    #[error("`{label}` occupies {bytes} bytes, more than the supported 2^64")]
    TooLarge {
        /// Variable label.
        label: String,
        /// Size as written in the layout.
        bytes: String,
    },
    /// A storage entry references a type that is missing from the `types` table.
    #[error("type `{ty}` referenced by `{label}` is missing from the types table")]
    UnknownType {
        /// Missing type key.
        ty: String,
        /// Variable that references it.
        label: String,
    },
    /// A namespace probe does not consist of exactly one struct variable.
    #[error("namespace `{id}`: the probe layout must hold exactly one struct variable, found {found} variable(s)")]
    BadProbe {
        /// Namespace id.
        id: String,
        /// Number of variables found.
        found: usize,
    },
    /// Raw `forge inspect` output was given without `--sequential-only`.
    #[error(
        "`{path}` is raw `forge inspect storageLayout` output: it lists sequential variables only, so ERC-7201 \
         namespaces (and a #6362-style move of state into them) are invisible. Use a snapshot built by \
         `node scripts/check-layouts.mjs`, or pass --sequential-only to check the sequential region alone"
    )]
    NamespacesUnknown {
        /// The raw input.
        path: String,
    },
    /// An `--allow` value is not `KIND:LABEL` or names an unknown kind.
    #[error("invalid --allow `{0}`: expected KIND:LABEL with a known kind, e.g. moved-to-namespace:_owner")]
    BadAllowance(String),
    /// A selector is not 4 bytes of hex.
    #[error("invalid selector `{selector}` for `{signature}`")]
    BadSelector {
        /// Function signature.
        signature: String,
        /// Selector as written.
        selector: String,
    },
}
