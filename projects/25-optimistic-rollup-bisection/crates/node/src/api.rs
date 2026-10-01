// SPDX-License-Identifier: MIT
//! HTTP API of the sequencer.
//!
//! | Method | Path | Body / result |
//! |---|---|---|
//! | `POST` | `/tx` | a signed [`Record`] (kind 4 or 5) -> `{ "digest": .. }` |
//! | `GET` | `/account/{address}` | balance and next nonce in the latest derived state |
//! | `GET` | `/withdrawal/{epoch}/{id}` | Merkle proof of a withdrawal against the state after `epoch` |
//! | `GET` | `/status` | derived head, queue length and cursor, mempool size |

use std::sync::Arc;

use alloy::primitives::{Address, B256, U256};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
};
use rollup_stf::Record;
use serde::{Deserialize, Serialize};
use tokio::{net::TcpListener, sync::watch};

use crate::{chain::WithdrawalProof, sequencer::Sequencer};

/// `POST /tx` response.
#[derive(Debug, Serialize, Deserialize)]
pub struct SubmitResponse {
    /// Digest the sender signed.
    pub digest: B256,
}

/// `GET /account/{address}` response.
#[derive(Debug, Serialize, Deserialize)]
pub struct AccountResponse {
    /// Balance in wei.
    pub balance: U256,
    /// Next nonce.
    pub nonce: U256,
    /// Epoch of the state queried.
    pub epoch: u64,
}

/// `GET /status` response.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusResponse {
    /// Latest derived epoch.
    pub head: u64,
    /// Queue messages seen.
    pub queue_length: usize,
    /// Queue messages consumed.
    pub queue_cursor: u64,
    /// Transactions waiting.
    pub mempool: usize,
}

/// Error body.
#[derive(Debug, Serialize, Deserialize)]
pub struct ApiError {
    /// Human-readable reason.
    pub error: String,
}

type ApiResult<T> = Result<Json<T>, (StatusCode, Json<ApiError>)>;

fn err(code: StatusCode, e: impl ToString) -> (StatusCode, Json<ApiError>) {
    (code, Json(ApiError { error: e.to_string() }))
}

async fn submit(State(s): State<Arc<Sequencer>>, Json(record): Json<Record>) -> ApiResult<SubmitResponse> {
    s.submit(record).await.map(|digest| Json(SubmitResponse { digest })).map_err(|e| err(StatusCode::BAD_REQUEST, e))
}

async fn account(State(s): State<Arc<Sequencer>>, Path(address): Path<Address>) -> ApiResult<AccountResponse> {
    let chain = s.chain.read().await;
    let (balance, nonce) = chain.account(address);
    Ok(Json(AccountResponse { balance, nonce, epoch: chain.head() }))
}

async fn withdrawal(
    State(s): State<Arc<Sequencer>>,
    Path((epoch, id)): Path<(u64, u64)>,
) -> ApiResult<WithdrawalProof> {
    let chain = s.chain.read().await;
    chain.withdrawal_proof(epoch, U256::from(id)).map(Json).map_err(|e| err(StatusCode::NOT_FOUND, e))
}

async fn status(State(s): State<Arc<Sequencer>>) -> ApiResult<StatusResponse> {
    let mempool = s.mempool_len().await;
    let chain = s.chain.read().await;
    Ok(Json(StatusResponse {
        head: chain.head(),
        queue_length: chain.queue().len(),
        queue_cursor: chain.queue_cursor(),
        mempool,
    }))
}

/// The API router.
pub fn router(state: Arc<Sequencer>) -> Router {
    Router::new()
        .route("/tx", post(submit))
        .route("/account/{address}", get(account))
        .route("/withdrawal/{epoch}/{id}", get(withdrawal))
        .route("/status", get(status))
        .with_state(state)
}

/// Serves the API on an already-bound listener until `shutdown` flips.
///
/// # Errors
/// Server I/O failure.
pub async fn serve(
    listener: TcpListener,
    state: Arc<Sequencer>,
    mut shutdown: watch::Receiver<bool>,
) -> std::io::Result<()> {
    axum::serve(listener, router(state))
        .with_graceful_shutdown(async move {
            while !*shutdown.borrow() {
                if shutdown.changed().await.is_err() {
                    break;
                }
            }
        })
        .await
}
