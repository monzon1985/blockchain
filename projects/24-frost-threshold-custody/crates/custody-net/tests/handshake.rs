// SPDX-License-Identifier: MIT
//! Handshake and framing: impersonation, replayed challenges, unknown
//! parties, fake coordinators and oversized frames are all rejected.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use std::time::Duration;

use common::*;
use custody_net::{
    NetError,
    coordinator::{Coordinator, CoordinatorConfig},
    participant::{ParticipantConfig, spawn_participant},
    wire::{
        Frame, HANDSHAKE_DOMAIN, HANDSHAKE_MAX_FRAME_LEN, MAX_FRAME_LEN, hello_transcript,
        read_frame, read_frame_limited, read_json, welcome_transcript, write_frame, write_json,
    },
};
use custody_protocol::{
    ParticipantId,
    identity::{GeneratedRoster, PROTOCOL_VERSION, PartyKeys},
    intent::SignerPolicy,
    node::ParticipantNode,
    signing::{SessionJournal, SignerState},
};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};

async fn coordinator(seed: u64) -> (Coordinator, GeneratedRoster) {
    let mut rng = ChaCha20Rng::seed_from_u64(seed);
    let generated = GeneratedRoster::generate(3, &mut rng).unwrap();
    let coordinator_keys = generated
        .coordinator
        .to_key_file(custody_protocol::Party::Coordinator)
        .keys();
    let coordinator = Coordinator::bind(
        coordinator_keys,
        generated.roster.clone(),
        CoordinatorConfig::default(),
    )
    .await
    .unwrap();
    (coordinator, generated)
}

/// Performs the client side of the handshake by hand.
async fn raw_hello(
    addr: std::net::SocketAddr,
    claimed: ParticipantId,
    keys: &PartyKeys,
    tamper_nonce: bool,
) -> Result<Frame, NetError> {
    let mut stream = TcpStream::connect(addr).await?;
    let Frame::Challenge { server_nonce, .. } = read_json(&mut stream).await? else {
        panic!("expected challenge")
    };
    let mut echoed = server_nonce;
    if tamper_nonce {
        echoed[0] ^= 1;
    }
    let client_nonce = [7u8; 32];
    let signature = keys.sign(
        HANDSHAKE_DOMAIN,
        &hello_transcript(claimed, &echoed, &client_nonce),
    );
    write_json(
        &mut stream,
        &Frame::Hello {
            participant: claimed,
            server_nonce: echoed,
            client_nonce,
            signature,
        },
    )
    .await?;
    read_json(&mut stream).await
}

#[tokio::test]
async fn honest_hello_is_welcomed_with_a_coordinator_signature() {
    let (coordinator, generated) = coordinator(1).await;
    let keys = &generated.participants[&p(1)];
    let welcome = raw_hello(coordinator.local_addr(), p(1), keys, false)
        .await
        .unwrap();
    let Frame::Welcome {
        client_nonce,
        signature,
    } = welcome
    else {
        panic!("expected welcome")
    };
    assert_eq!(client_nonce, [7u8; 32]);
    // The signature binds the participant id and both nonces.
    assert!(
        generated
            .roster
            .verify(
                custody_protocol::Party::Coordinator,
                HANDSHAKE_DOMAIN,
                &welcome_transcript(p(2), &[0u8; 32], &client_nonce),
                &signature,
            )
            .is_err()
    );
    coordinator.shutdown().await;
}

#[tokio::test]
async fn impersonation_unknown_ids_and_stale_challenges_are_rejected() {
    let (coordinator, generated) = coordinator(2).await;
    let addr = coordinator.local_addr();
    // P3 claims to be P2.
    let err = raw_hello(addr, p(2), &generated.participants[&p(3)], false)
        .await
        .unwrap_err();
    assert!(matches!(err, NetError::Closed | NetError::Io(_)), "{err:?}");
    // Unknown participant id.
    let err = raw_hello(addr, p(9), &generated.participants[&p(1)], false)
        .await
        .unwrap_err();
    assert!(matches!(err, NetError::Closed | NetError::Io(_)), "{err:?}");
    // Echo of a different challenge (replayed hello).
    let err = raw_hello(addr, p(1), &generated.participants[&p(1)], true)
        .await
        .unwrap_err();
    assert!(matches!(err, NetError::Closed | NetError::Io(_)), "{err:?}");
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(coordinator.connected().is_empty());
    coordinator.shutdown().await;
}

#[tokio::test]
async fn oversized_frames_close_the_connection() {
    let (coordinator, _) = coordinator(3).await;
    let mut stream = TcpStream::connect(coordinator.local_addr()).await.unwrap();
    let _challenge = read_frame(&mut stream).await.unwrap();
    stream
        .write_u32(u32::try_from(MAX_FRAME_LEN + 1).unwrap())
        .await
        .unwrap();
    stream.flush().await.unwrap();
    let err = read_frame(&mut stream).await.unwrap_err();
    assert!(matches!(err, NetError::Closed | NetError::Io(_)), "{err:?}");
    coordinator.shutdown().await;
}

/// Before authentication the coordinator reads at most a 4 KiB frame: a
/// peer announcing more is disconnected without the buffer being allocated.
#[tokio::test]
async fn unauthenticated_peers_cannot_announce_large_frames() {
    let (coordinator, _) = coordinator(6).await;
    let mut stream = TcpStream::connect(coordinator.local_addr()).await.unwrap();
    let _challenge = read_frame(&mut stream).await.unwrap();
    stream
        .write_u32(u32::try_from(HANDSHAKE_MAX_FRAME_LEN + 1).unwrap())
        .await
        .unwrap();
    stream.flush().await.unwrap();
    // Closed at once (well before the 5 s handshake timeout).
    let err = tokio::time::timeout(Duration::from_secs(2), read_frame(&mut stream))
        .await
        .expect("the connection is closed immediately")
        .unwrap_err();
    assert!(matches!(err, NetError::Closed | NetError::Io(_)), "{err:?}");
    coordinator.shutdown().await;
}

/// At most `max_pending_handshakes` connections may sit in the handshake;
/// further connections are closed at once, finished connection tasks are
/// reaped, and an honest participant still gets in once the slots free up.
#[tokio::test]
async fn pending_handshakes_are_capped_and_finished_tasks_reaped() {
    let mut rng = ChaCha20Rng::seed_from_u64(7);
    let generated = GeneratedRoster::generate(2, &mut rng).unwrap();
    let coordinator = Coordinator::bind(
        generated
            .coordinator
            .to_key_file(custody_protocol::Party::Coordinator)
            .keys(),
        generated.roster.clone(),
        CoordinatorConfig {
            max_pending_handshakes: 2,
            ..CoordinatorConfig::default()
        },
    )
    .await
    .unwrap();
    let addr = coordinator.local_addr();
    // Two silent peers hold both handshake slots.
    let mut silent = Vec::new();
    for _ in 0..2 {
        let mut s = TcpStream::connect(addr).await.unwrap();
        let _challenge = read_frame(&mut s).await.unwrap();
        silent.push(s);
    }
    assert_eq!(coordinator.live_connection_tasks(), 2);
    // A third connection is closed without a challenge.
    let mut third = TcpStream::connect(addr).await.unwrap();
    let err = tokio::time::timeout(Duration::from_secs(2), read_frame(&mut third))
        .await
        .expect("closed at once")
        .unwrap_err();
    assert!(matches!(err, NetError::Closed | NetError::Io(_)), "{err:?}");
    // The silent peers leave; their tasks end and are reaped.
    drop(silent);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while coordinator.live_connection_tasks() != 0 {
        assert!(tokio::time::Instant::now() < deadline, "tasks not reaped");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Stray connections come and go without leaving anything behind.
    for _ in 0..20 {
        let mut s = TcpStream::connect(addr).await.unwrap();
        let _ = read_frame_limited(&mut s, HANDSHAKE_MAX_FRAME_LEN).await;
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while coordinator.live_connection_tasks() != 0 {
        assert!(tokio::time::Instant::now() < deadline, "tasks not reaped");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // An honest participant still connects.
    let node = ParticipantNode::new(
        p(1),
        generated.participants[&p(1)]
            .to_key_file(custody_protocol::Party::Participant(p(1)))
            .keys(),
        generated.roster.clone(),
        SignerState::new(
            SignerPolicy::permissive(DOMAIN),
            SessionJournal::in_memory(),
        ),
    )
    .unwrap();
    let handle = spawn_participant(node, ParticipantConfig::new(addr))
        .await
        .unwrap();
    coordinator
        .wait_for(&[p(1)], Duration::from_secs(5))
        .await
        .unwrap();
    assert_eq!(coordinator.live_connection_tasks(), 1);
    handle.stop().await.unwrap();
    coordinator.shutdown().await;
}

#[tokio::test]
async fn framing_round_trips_and_enforces_limits() {
    let (mut a, mut b) = tokio::io::duplex(1 << 16);
    write_frame(&mut a, b"hello").await.unwrap();
    assert_eq!(read_frame(&mut b).await.unwrap(), b"hello");
    let too_big = vec![0u8; MAX_FRAME_LEN + 1];
    assert!(matches!(
        write_frame(&mut a, &too_big).await,
        Err(NetError::FrameTooLarge(_))
    ));
    write_frame(&mut a, b"not json").await.unwrap();
    assert!(matches!(
        read_json::<_, Frame>(&mut b).await,
        Err(NetError::Malformed(_))
    ));
    // A caller-supplied limit applies before anything is allocated.
    let (mut c, mut d) = tokio::io::duplex(1 << 10);
    write_frame(&mut c, &[b'x'; 100]).await.unwrap();
    assert!(matches!(
        read_frame_limited(&mut d, 99).await,
        Err(NetError::FrameTooLarge(100))
    ));
    // Truncated frame: length says 10, peer sends 3 bytes and hangs up.
    a.write_u32(10).await.unwrap();
    a.write_all(b"abc").await.unwrap();
    drop(a);
    assert!(matches!(read_frame(&mut b).await, Err(NetError::Closed)));
}

async fn fake_coordinator(protocol: &'static str, signer: PartyKeys) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let server_nonce = [1u8; 32];
        write_json(
            &mut stream,
            &Frame::Challenge {
                protocol: protocol.to_owned(),
                server_nonce,
            },
        )
        .await
        .unwrap();
        let Ok(Frame::Hello {
            participant,
            client_nonce,
            ..
        }) = read_json::<_, Frame>(&mut stream).await
        else {
            return;
        };
        let signature = signer.sign(
            HANDSHAKE_DOMAIN,
            &welcome_transcript(participant, &server_nonce, &client_nonce),
        );
        let _ = write_json(
            &mut stream,
            &Frame::Welcome {
                client_nonce,
                signature,
            },
        )
        .await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    });
    addr
}

#[tokio::test]
async fn participants_reject_fake_coordinators() {
    let mut rng = ChaCha20Rng::seed_from_u64(4);
    let generated = GeneratedRoster::generate(2, &mut rng).unwrap();
    let make_node = |keys: PartyKeys| {
        ParticipantNode::new(
            p(1),
            keys,
            generated.roster.clone(),
            SignerState::new(
                SignerPolicy::permissive(DOMAIN),
                SessionJournal::in_memory(),
            ),
        )
        .unwrap()
    };
    let p1 = || {
        generated.participants[&p(1)]
            .to_key_file(custody_protocol::Party::Participant(p(1)))
            .keys()
    };

    // Welcome signed by a key that is not the roster's coordinator.
    let impostor = PartyKeys::generate(&mut rng);
    let addr = fake_coordinator(PROTOCOL_VERSION, impostor).await;
    let err = spawn_participant(make_node(p1()), ParticipantConfig::new(addr))
        .await
        .err()
        .unwrap();
    assert!(matches!(err, NetError::Handshake(_)), "{err:?}");

    // Unsupported protocol version.
    let real = generated
        .coordinator
        .to_key_file(custody_protocol::Party::Coordinator)
        .keys();
    let addr = fake_coordinator("frost-custody/v0", real).await;
    let err = spawn_participant(make_node(p1()), ParticipantConfig::new(addr))
        .await
        .err()
        .unwrap();
    assert!(matches!(err, NetError::Handshake(_)), "{err:?}");
}

/// A coordinator that authenticates, opens a DKG and then goes silent leaves
/// secret state on the participant only until the session TTL expires.
#[tokio::test]
async fn abandoned_sessions_expire_in_the_participant_service() {
    use custody_protocol::{
        Party, SessionId,
        envelope::{Envelope, Recipient, SignedEnvelope},
        messages::{KeygenMode, KeygenStart, Message},
    };
    let mut rng = ChaCha20Rng::seed_from_u64(8);
    let generated = GeneratedRoster::generate(2, &mut rng).unwrap();
    let coordinator_keys = generated.coordinator.to_key_file(Party::Coordinator).keys();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let server_nonce = [5u8; 32];
        write_json(
            &mut stream,
            &Frame::Challenge {
                protocol: PROTOCOL_VERSION.to_owned(),
                server_nonce,
            },
        )
        .await
        .unwrap();
        let Ok(Frame::Hello {
            participant,
            client_nonce,
            ..
        }) = read_json::<_, Frame>(&mut stream).await
        else {
            return;
        };
        let signature = coordinator_keys.sign(
            HANDSHAKE_DOMAIN,
            &welcome_transcript(participant, &server_nonce, &client_nonce),
        );
        write_json(
            &mut stream,
            &Frame::Welcome {
                client_nonce,
                signature,
            },
        )
        .await
        .unwrap();
        let start = SignedEnvelope::sign(
            &Envelope::new(
                SessionId([4; 16]),
                Party::Coordinator,
                Recipient::Participant(participant),
                Message::KeygenStart(KeygenStart {
                    mode: KeygenMode::Fresh,
                    threshold: 2,
                    participants: vec![p(1), p(2)],
                }),
            ),
            &coordinator_keys,
        )
        .unwrap();
        write_json(&mut stream, &Frame::Envelope(start))
            .await
            .unwrap();
        // Take the round-one reply, then stay connected and silent.
        let _ = read_json::<_, Frame>(&mut stream).await;
        tokio::time::sleep(Duration::from_secs(30)).await;
    });
    let node = ParticipantNode::new(
        p(1),
        generated.participants[&p(1)]
            .to_key_file(Party::Participant(p(1)))
            .keys(),
        generated.roster.clone(),
        SignerState::new(
            SignerPolicy::permissive(DOMAIN),
            SessionJournal::in_memory(),
        ),
    )
    .unwrap();
    let handle = spawn_participant(
        node,
        ParticipantConfig {
            session_ttl: Duration::from_millis(200),
            ..ParticipantConfig::new(addr)
        },
    )
    .await
    .unwrap();
    let shared = handle.node();
    let keygen = || {
        custody_net::participant::lock_node(&shared)
            .pending_sessions()
            .keygen
    };
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while keygen() != 1 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "session never opened"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while keygen() != 0 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "session never expired"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // The id stays burned: the session cannot be reopened.
    assert!(
        custody_net::participant::lock_node(&shared)
            .signer()
            .journal()
            .contains(&SessionId([4; 16]))
    );
    handle.stop().await.unwrap();
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn coordinator_refuses_keys_that_do_not_match_the_roster() {
    let mut rng = ChaCha20Rng::seed_from_u64(5);
    let generated = GeneratedRoster::generate(2, &mut rng).unwrap();
    let wrong = PartyKeys::generate(&mut rng);
    let err = Coordinator::bind(wrong, generated.roster, CoordinatorConfig::default())
        .await
        .err()
        .unwrap();
    assert!(matches!(err, NetError::Handshake(_)));
}
