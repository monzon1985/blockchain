// SPDX-License-Identifier: MIT
//! Networked integration and chaos tests: real tokio services over loopback
//! TCP (OS-assigned ports). Faulty participants are placed behind a proxy
//! that drops, delays, corrupts or rewrites their messages; identifiable
//! aborts must name exactly the faulty participant, and retries must succeed.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::collections::BTreeSet;
use std::time::Duration;

use common::*;
use custody_net::{cluster::LocalCluster, participant::lock_node};
use custody_protocol::{
    blame::{BlameContext, Fault},
    keygen::{KeygenOutcome, group_key_bytes},
    messages::{GroupKeyBytes, Message},
    repair::RepairOutcome,
    signing::SigningOutcome,
};
use frost_keccak::evm;

async fn dkg(
    coordinator: &mut custody_net::coordinator::Coordinator,
    t: u16,
    ids: &[custody_protocol::ParticipantId],
) -> GroupKeyBytes {
    match coordinator.dkg(t, ids).await.unwrap() {
        KeygenOutcome::Committed { public_key_package } => {
            group_key_bytes(&public_key_package).unwrap()
        }
        KeygenOutcome::Aborted(report) => panic!("DKG aborted: {report:?}"),
    }
}

fn assert_onchain_valid(
    coordinator: &custody_net::coordinator::Coordinator,
    group_key: &GroupKeyBytes,
    action: &custody_protocol::intent::CustodyAction,
    outcome: &SigningOutcome,
) {
    let SigningOutcome::Signed { evm: sig, .. } = outcome else {
        panic!("not signed: {outcome:?}")
    };
    let key =
        evm::EvmGroupKey::from_verifying_key(coordinator.group(group_key).unwrap().verifying_key())
            .unwrap();
    assert!(evm::verify(&key, &action.signing_hash(&DOMAIN), sig));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn full_lifecycle_over_tcp() {
    let mut cluster = LocalCluster::start(5, DOMAIN, Duration::from_secs(5))
        .await
        .unwrap();
    let ids = cluster.ids();
    let group_key = dkg(&mut cluster.coordinator, 3, &ids).await;

    // Sign.
    let action = withdrawal(1);
    let report = cluster
        .coordinator
        .sign_with_retry(group_key, action.clone(), DOMAIN)
        .await
        .unwrap();
    assert!(report.failed_attempts.is_empty());
    assert_onchain_valid(&cluster.coordinator, &group_key, &action, &report.outcome);

    // Refresh: same group key, new shares.
    let before = *lock_node(&cluster.participants[&p(1)].node()).shares()[&group_key]
        .key_package
        .signing_share();
    assert!(matches!(
        cluster.coordinator.refresh(group_key, &ids).await.unwrap(),
        KeygenOutcome::Committed { .. }
    ));
    // Participants install the refreshed share when the commit certificate
    // arrives, which is asynchronous to the coordinator's return: poll.
    let node = cluster.participants[&p(1)].node();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let current = *lock_node(&node).shares()[&group_key]
            .key_package
            .signing_share();
        if current != before {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "refreshed share never installed"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    // Repair: P2 loses its share, P3..P5 restore it, P2 signs again.
    lock_node(&cluster.participants[&p(2)].node())
        .forget_share(&group_key)
        .unwrap();
    let repaired = cluster
        .coordinator
        .repair(group_key, p(2), &[p(3), p(4), p(5)])
        .await
        .unwrap();
    assert_eq!(repaired, RepairOutcome::Repaired { participant: p(2) });
    let action = withdrawal(2);
    let outcome = cluster
        .coordinator
        .sign(group_key, action.clone(), DOMAIN, &[p(1), p(2), p(3)])
        .await
        .unwrap();
    assert_onchain_valid(&cluster.coordinator, &group_key, &action, &outcome);
    cluster.shutdown().await.unwrap();
}

async fn chaos_signing(
    rules: Vec<Rule>,
    phase_timeout: Duration,
) -> (
    custody_protocol::local::SignReport,
    ChaosCluster,
    GroupKeyBytes,
) {
    let mut cluster = ChaosCluster::start(5, phase_timeout, vec![(p(1), rules)]).await;
    let ids = cluster.ids();
    let group_key = dkg(&mut cluster.coordinator, 3, &ids).await;
    let action = withdrawal(7);
    let report = cluster
        .coordinator
        .sign_with_retry(group_key, action.clone(), DOMAIN)
        .await
        .unwrap();
    assert_onchain_valid(&cluster.coordinator, &group_key, &action, &report.outcome);
    (report, cluster, group_key)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dropped_share_is_named_unresponsive_and_retry_succeeds() {
    let rules = vec![Rule {
        kind: "sign_share",
        fault: ProxyFault::Drop,
    }];
    let (report, cluster, _) = chaos_signing(rules, Duration::from_millis(1_500)).await;
    assert_eq!(report.failed_attempts.len(), 1);
    let failed = &report.failed_attempts[0];
    assert_eq!(failed.phase, "share");
    assert_eq!(failed.blame.len(), 1);
    assert_eq!(failed.blame[0].participant, p(1));
    assert!(matches!(failed.blame[0].fault, Fault::Unresponsive { .. }));
    let SigningOutcome::Signed { signers, .. } = &report.outcome else {
        unreachable!()
    };
    assert!(!signers.contains(&p(1)));
    cluster.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn delay_within_the_deadline_is_tolerated() {
    let rules = vec![Rule {
        kind: "sign_commitment",
        fault: ProxyFault::Delay(Duration::from_millis(250)),
    }];
    let (report, cluster, _) = chaos_signing(rules, Duration::from_secs(4)).await;
    assert!(
        report.failed_attempts.is_empty(),
        "{:?}",
        report.failed_attempts
    );
    let SigningOutcome::Signed { signers, .. } = &report.outcome else {
        unreachable!()
    };
    assert!(signers.contains(&p(1)));
    cluster.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn delay_beyond_the_deadline_is_named_unresponsive() {
    let rules = vec![Rule {
        kind: "sign_commitment",
        fault: ProxyFault::Delay(Duration::from_millis(3_000)),
    }];
    let (report, cluster, _) = chaos_signing(rules, Duration::from_millis(1_000)).await;
    assert_eq!(report.failed_attempts.len(), 1);
    assert_eq!(report.failed_attempts[0].phase, "commit");
    assert_eq!(report.failed_attempts[0].blame[0].participant, p(1));
    assert!(matches!(
        report.failed_attempts[0].blame[0].fault,
        Fault::Unresponsive { .. }
    ));
    cluster.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn corrupted_messages_are_rejected_and_cannot_frame_the_sender() {
    for fault in [ProxyFault::CorruptSignature, ProxyFault::Garble] {
        let rules = vec![Rule {
            kind: "sign_share",
            fault,
        }];
        let (report, cluster, _) = chaos_signing(rules, Duration::from_millis(1_500)).await;
        // A corrupted message never authenticates, so the only honest verdict
        // is a liveness fault: nothing signed by P1 proves misbehaviour.
        let failed = &report.failed_attempts[0];
        assert_eq!(failed.blame[0].participant, p(1));
        assert!(matches!(failed.blame[0].fault, Fault::Unresponsive { .. }));
        assert!(!failed.blame[0].fault.is_provable());
        cluster.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn byzantine_share_is_identified_with_evidence() {
    let rewrite = ProxyFault::rewrite(|env| {
        if let Message::SignShare(s) = &mut env.body {
            s.share = frost_keccak::round2::SignatureShare::deserialize(&[3u8; 32]).unwrap();
        }
    });
    let rules = vec![Rule {
        kind: "sign_share",
        fault: rewrite,
    }];
    let mut cluster = ChaosCluster::start(5, Duration::from_secs(3), vec![(p(1), rules)]).await;
    let ids = cluster.ids();
    let group_key = dkg(&mut cluster.coordinator, 3, &ids).await;
    let SigningOutcome::Aborted(report) = cluster
        .coordinator
        .sign(group_key, withdrawal(8), DOMAIN, &[p(1), p(2), p(3)])
        .await
        .unwrap()
    else {
        panic!("expected an identifiable abort");
    };
    assert_eq!(report.culprits(), BTreeSet::from([p(1)]));
    let package = cluster.coordinator.last_signing_package().unwrap().clone();
    let public = cluster.coordinator.group(&group_key).unwrap().clone();
    report.blame[0]
        .verify(&BlameContext {
            roster: cluster.coordinator.roster(),
            session: report.session,
            keygen_mode: None,
            signing: Some((&package, &public)),
        })
        .unwrap();
    // The retry without P1 succeeds.
    let action = withdrawal(9);
    let retry = cluster
        .coordinator
        .sign_with_retry(group_key, action.clone(), DOMAIN)
        .await
        .unwrap();
    assert_eq!(retry.failed_attempts.len(), 1);
    assert_eq!(retry.failed_attempts[0].culprits(), BTreeSet::from([p(1)]));
    assert_onchain_valid(&cluster.coordinator, &group_key, &action, &retry.outcome);
    cluster.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dkg_blames_a_dropped_round_one_and_a_byzantine_dealer() {
    // Silent dealer.
    let rules = vec![Rule {
        kind: "keygen_round1",
        fault: ProxyFault::Drop,
    }];
    let mut cluster =
        ChaosCluster::start(3, Duration::from_millis(1_500), vec![(p(2), rules)]).await;
    let ids = cluster.ids();
    let KeygenOutcome::Aborted(report) = cluster.coordinator.dkg(2, &ids).await.unwrap() else {
        panic!("expected abort")
    };
    assert_eq!(report.blame.len(), 1);
    assert_eq!(report.blame[0].participant, p(2));
    assert!(matches!(report.blame[0].fault, Fault::Unresponsive { .. }));
    cluster.shutdown().await;

    // Dealer that claims a wrong round-one digest (validly signed).
    let rewrite = ProxyFault::rewrite(|env| {
        if let Message::KeygenRound2(r2) = &mut env.body {
            r2.round1_digest = [0u8; 32];
        }
    });
    let rules = vec![Rule {
        kind: "keygen_round2",
        fault: rewrite,
    }];
    let mut cluster = ChaosCluster::start(4, Duration::from_secs(3), vec![(p(3), rules)]).await;
    let ids = cluster.ids();
    let KeygenOutcome::Aborted(report) = cluster.coordinator.dkg(3, &ids).await.unwrap() else {
        panic!("expected abort")
    };
    assert_eq!(report.culprits(), BTreeSet::from([p(3)]));
    assert!(matches!(
        report.blame[0].fault,
        Fault::InconsistentBroadcast { .. }
    ));
    cluster.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn disconnected_participants_are_skipped_by_retries() {
    let mut cluster = LocalCluster::start(4, DOMAIN, Duration::from_secs(2))
        .await
        .unwrap();
    let ids = cluster.ids();
    let group_key = dkg(&mut cluster.coordinator, 2, &ids).await;
    // P1 goes away; the coordinator notices the closed connection.
    let p1 = cluster.participants.remove(&p(1)).unwrap();
    p1.stop().await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while cluster.coordinator.connected().contains(&p(1)) {
        assert!(
            tokio::time::Instant::now() < deadline,
            "disconnect not observed"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        cluster
            .coordinator
            .wait_for(&[p(1)], Duration::from_millis(100))
            .await
            .is_err(),
        "waiting for a gone participant times out"
    );
    // Explicitly asking the gone participant fails as a liveness fault...
    let SigningOutcome::Aborted(report) = cluster
        .coordinator
        .sign(group_key, withdrawal(20), DOMAIN, &[p(1), p(2)])
        .await
        .unwrap()
    else {
        panic!("expected abort")
    };
    assert_eq!(report.blame[0].participant, p(1));
    // ...while retries only pick connected signers.
    let action = withdrawal(21);
    let retry = cluster
        .coordinator
        .sign_with_retry(group_key, action.clone(), DOMAIN)
        .await
        .unwrap();
    assert!(retry.failed_attempts.is_empty());
    assert_onchain_valid(&cluster.coordinator, &group_key, &action, &retry.outcome);
    // Re-registering the group (e.g. after a coordinator restart) is idempotent.
    let public = cluster.coordinator.group(&group_key).unwrap().clone();
    assert_eq!(
        cluster.coordinator.register_group(public).unwrap(),
        group_key
    );
    cluster.shutdown().await.unwrap();
}
