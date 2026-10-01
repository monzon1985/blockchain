// SPDX-License-Identifier: MIT
//! Sequencer HTTP API over a real socket (no L1 needed: submissions and queries only touch local state).
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, missing_docs)]

use std::{sync::Arc, time::Duration};

use alloy::{
    primitives::{Address, U256},
    signers::local::PrivateKeySigner,
};
use rollup_node::{Chain, Sequencer, SequencerClient, SequencerConfig, api, wallet};
use rollup_stf::{Kind, Stf};
use tokio::{net::TcpListener, sync::watch};

async fn start() -> (SequencerClient, watch::Sender<bool>, Stf) {
    let stf = Stf::new(901);
    let sequencer = Sequencer::new(
        Chain::new(stf.clone(), 0),
        SequencerConfig { batch_interval: Duration::from_secs(1), censor: vec![] },
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = watch::channel(false);
    tokio::spawn(api::serve(listener, Arc::clone(&sequencer), rx));
    (SequencerClient::new(url), tx, stf)
}

#[tokio::test]
async fn accepts_valid_signed_transactions_once() {
    let (client, stop, stf) = start().await;
    let signer = PrivateKeySigner::random();
    let record =
        wallet::sign_tx(&signer, Kind::Transfer, Address::repeat_byte(2), U256::from(5), U256::ZERO, stf.domain())
            .unwrap();
    let digest = client.submit(&record).await.unwrap();
    assert_eq!(
        digest,
        rollup_stf::L2Tx::digest_of(Kind::Transfer, record.from, record.to, record.amount, record.nonce, stf.domain())
    );
    let dup = client.submit(&record).await.unwrap_err().to_string();
    assert!(dup.contains("duplicate"), "{dup}");
    let status = client.status().await.unwrap();
    assert_eq!((status.head, status.mempool, status.queue_length), (0, 1, 0));
    stop.send(true).unwrap();
}

#[tokio::test]
async fn rejects_forged_and_unsequenceable_records() {
    let (client, stop, stf) = start().await;
    let signer = PrivateKeySigner::random();
    let mut record =
        wallet::sign_tx(&signer, Kind::Withdrawal, Address::repeat_byte(3), U256::from(1), U256::ZERO, stf.domain())
            .unwrap();
    record.amount = U256::from(1_000); // no longer what was signed
    let e = client.submit(&record).await.unwrap_err().to_string();
    assert!(e.contains("signature"), "{e}");

    let mut deposit = record;
    deposit.kind = U256::from(Kind::Deposit as u8); // only the L1 queue may carry deposits
    let e = client.submit(&deposit).await.unwrap_err().to_string();
    assert!(e.contains("cannot be sequenced"), "{e}");

    // Signed for another chain: the domain separator differs, so the signature does not match.
    let other = Stf::new(902);
    let foreign =
        wallet::sign_tx(&signer, Kind::Transfer, Address::repeat_byte(3), U256::from(1), U256::ZERO, other.domain())
            .unwrap();
    assert!(client.submit(&foreign).await.is_err());
    stop.send(true).unwrap();
}

#[tokio::test]
async fn queries_on_an_empty_chain() {
    let (client, stop, _) = start().await;
    let a = client.account(Address::repeat_byte(9)).await.unwrap();
    assert_eq!((a.balance, a.nonce, a.epoch), (U256::ZERO, U256::ZERO, 0));
    let e = client.withdrawal_proof(1, 0).await.unwrap_err().to_string();
    assert!(e.contains("404"), "{e}");
    stop.send(true).unwrap();
}
