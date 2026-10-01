// SPDX-License-Identifier: MIT
//! Typed HTTP client for the sequencer API (used by the CLI and the end-to-end tests).

use alloy::primitives::{Address, B256};
use rollup_stf::Record;
use serde::de::DeserializeOwned;

use crate::{
    api::{AccountResponse, ApiError, StatusResponse, SubmitResponse},
    chain::WithdrawalProof,
};

/// Client for one sequencer.
#[derive(Debug, Clone)]
pub struct SequencerClient {
    base: String,
    http: reqwest::Client,
}

async fn decode<T: DeserializeOwned>(resp: reqwest::Response) -> anyhow::Result<T> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp.json::<T>().await?);
    }
    let body: ApiError = resp.json().await.unwrap_or(ApiError { error: status.to_string() });
    anyhow::bail!("sequencer returned {status}: {}", body.error)
}

impl SequencerClient {
    /// Client for `base` (e.g. `http://127.0.0.1:43127`).
    pub fn new(base: impl Into<String>) -> Self {
        Self { base: base.into().trim_end_matches('/').to_owned(), http: reqwest::Client::new() }
    }

    /// Submits a signed transaction.
    ///
    /// # Errors
    /// Transport errors or a rejection by the sequencer.
    pub async fn submit(&self, record: &Record) -> anyhow::Result<B256> {
        let resp = self.http.post(format!("{}/tx", self.base)).json(record).send().await?;
        Ok(decode::<SubmitResponse>(resp).await?.digest)
    }

    /// Balance and nonce of an account.
    ///
    /// # Errors
    /// Transport errors.
    pub async fn account(&self, a: Address) -> anyhow::Result<AccountResponse> {
        decode(self.http.get(format!("{}/account/{a}", self.base)).send().await?).await
    }

    /// Proof of withdrawal `id` against the state after `epoch`.
    ///
    /// # Errors
    /// Transport errors or unknown withdrawal.
    pub async fn withdrawal_proof(&self, epoch: u64, id: u64) -> anyhow::Result<WithdrawalProof> {
        decode(self.http.get(format!("{}/withdrawal/{epoch}/{id}", self.base)).send().await?).await
    }

    /// Sequencer status.
    ///
    /// # Errors
    /// Transport errors.
    pub async fn status(&self) -> anyhow::Result<StatusResponse> {
        decode(self.http.get(format!("{}/status", self.base)).send().await?).await
    }
}
