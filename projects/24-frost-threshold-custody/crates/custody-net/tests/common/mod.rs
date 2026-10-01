// SPDX-License-Identifier: MIT
//! Chaos tooling for the network tests: a TCP proxy that sits between one
//! participant and the coordinator and drops, delays, corrupts or (holding
//! the participant's keys, i.e. playing a Byzantine participant) rewrites the
//! participant's protocol messages.
#![allow(dead_code, clippy::unwrap_used, clippy::expect_used)]

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use alloy_primitives::{Address, U256, address};
use custody_net::{
    coordinator::{Coordinator, CoordinatorConfig},
    participant::{ParticipantConfig, ParticipantHandle, spawn_participant},
    wire::{Frame, read_frame, write_frame},
};
use custody_protocol::{
    ParticipantId,
    envelope::{Envelope, SignedEnvelope},
    identity::{GeneratedRoster, PartyKeys},
    intent::{CustodyAction, SignerPolicy, VaultDomain, WithdrawalIntent},
    node::ParticipantNode,
    signing::{SessionJournal, SignerState},
};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

pub const DOMAIN: VaultDomain = VaultDomain {
    chain_id: 31_337,
    vault: address!("00000000000000000000000000000000f2057001"),
};

pub fn p(i: u16) -> ParticipantId {
    ParticipantId::new(i).unwrap()
}

pub fn withdrawal(nonce: u64) -> CustodyAction {
    CustodyAction::Withdrawal(WithdrawalIntent {
        to: address!("000000000000000000000000000000000000beef"),
        token: Address::ZERO,
        amount: U256::from(1_000u64),
        nonce: U256::from(nonce),
        deadline: U256::from(4_102_444_800u64),
    })
}

/// What the proxy does to a matching participant → coordinator message.
pub enum ProxyFault {
    /// Never forward it.
    Drop,
    /// Forward it after a delay.
    Delay(Duration),
    /// Flip one bit of the origin signature (transport corruption).
    CorruptSignature,
    /// Replace the frame with bytes that are not JSON.
    Garble,
    /// Rewrite the envelope and re-sign it with the participant's own key.
    Rewrite(Box<dyn FnMut(&mut Envelope) + Send>),
}

impl ProxyFault {
    /// Boxes a rewrite closure.
    pub fn rewrite(f: impl FnMut(&mut Envelope) + Send + 'static) -> Self {
        Self::Rewrite(Box::new(f))
    }
}

/// A fault applied to messages of one kind (see `Message::kind`).
pub struct Rule {
    pub kind: &'static str,
    pub fault: ProxyFault,
}

/// A one-connection proxy between a participant and the coordinator.
pub struct ChaosProxy {
    pub addr: SocketAddr,
    task: JoinHandle<()>,
}

impl ChaosProxy {
    pub async fn start(upstream: SocketAddr, rules: Vec<Rule>, keys: PartyKeys) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let rules = Arc::new(Mutex::new(rules));
        let task = tokio::spawn(async move {
            let Ok((client, _)) = listener.accept().await else {
                return;
            };
            let Ok(server) = TcpStream::connect(upstream).await else {
                return;
            };
            let (mut client_rd, mut client_wr) = client.into_split();
            let (mut server_rd, mut server_wr) = server.into_split();
            let down = tokio::spawn(async move {
                while let Ok(frame) = read_frame(&mut server_rd).await {
                    if write_frame(&mut client_wr, &frame).await.is_err() {
                        break;
                    }
                }
            });
            while let Ok(bytes) = read_frame(&mut client_rd).await {
                let forwarded = match serde_json::from_slice::<Frame>(&bytes) {
                    Ok(Frame::Envelope(signed)) => apply(&rules, &keys, signed).await,
                    _ => Some(bytes),
                };
                if let Some(out) = forwarded
                    && write_frame(&mut server_wr, &out).await.is_err()
                {
                    break;
                }
            }
            down.abort();
        });
        Self { addr, task }
    }
}

impl Drop for ChaosProxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn apply(
    rules: &Arc<Mutex<Vec<Rule>>>,
    keys: &PartyKeys,
    mut signed: SignedEnvelope,
) -> Option<Vec<u8>> {
    let mut envelope: Envelope = serde_json::from_str(&signed.payload).ok()?;
    let kind = envelope.body.kind();
    let mut delay = None;
    {
        let mut rules = rules.lock().unwrap();
        if let Some(rule) = rules.iter_mut().find(|r| r.kind == kind) {
            match &mut rule.fault {
                ProxyFault::Drop => return None,
                ProxyFault::Delay(d) => delay = Some(*d),
                ProxyFault::CorruptSignature => signed.signature[0] ^= 1,
                ProxyFault::Garble => return Some(b"\x00not json".to_vec()),
                ProxyFault::Rewrite(f) => {
                    f(&mut envelope);
                    signed = SignedEnvelope::sign(&envelope, keys).unwrap();
                }
            }
        }
    }
    if let Some(d) = delay {
        tokio::time::sleep(d).await;
    }
    Some(serde_json::to_vec(&Frame::Envelope(signed)).unwrap())
}

/// A coordinator and `n` participants, where the participants listed in
/// `faulty` connect through a [`ChaosProxy`] with the given rules.
pub struct ChaosCluster {
    pub coordinator: Coordinator,
    pub participants: Vec<(ParticipantId, ParticipantHandle)>,
    pub proxies: Vec<ChaosProxy>,
}

impl ChaosCluster {
    pub async fn start(
        n: u16,
        phase_timeout: Duration,
        mut faulty: Vec<(ParticipantId, Vec<Rule>)>,
    ) -> Self {
        let generated = GeneratedRoster::generate(n, &mut rand_core::OsRng).unwrap();
        let roster = generated.roster.clone();
        let coordinator = Coordinator::bind(
            generated.coordinator,
            roster.clone(),
            CoordinatorConfig {
                phase_timeout,
                ..CoordinatorConfig::default()
            },
        )
        .await
        .unwrap();
        let mut participants = Vec::new();
        let mut proxies = Vec::new();
        for (id, keys) in generated.participants {
            let mut target = coordinator.local_addr();
            if let Some(pos) = faulty.iter().position(|(f, _)| *f == id) {
                let (_, rules) = faulty.remove(pos);
                let copy = keys
                    .to_key_file(custody_protocol::Party::Participant(id))
                    .keys();
                let proxy = ChaosProxy::start(coordinator.local_addr(), rules, copy).await;
                target = proxy.addr;
                proxies.push(proxy);
            }
            let signer = SignerState::new(
                SignerPolicy::permissive(DOMAIN),
                SessionJournal::in_memory(),
            );
            let node = ParticipantNode::new(id, keys, roster.clone(), signer).unwrap();
            participants.push((
                id,
                spawn_participant(node, ParticipantConfig::new(target))
                    .await
                    .unwrap(),
            ));
        }
        let ids: Vec<_> = participants.iter().map(|(id, _)| *id).collect();
        coordinator
            .wait_for(&ids, Duration::from_secs(5))
            .await
            .unwrap();
        Self {
            coordinator,
            participants,
            proxies,
        }
    }

    pub fn ids(&self) -> Vec<ParticipantId> {
        self.participants.iter().map(|(id, _)| *id).collect()
    }

    pub async fn shutdown(self) {
        for (_, handle) in self.participants {
            handle.stop().await.unwrap();
        }
        self.coordinator.shutdown().await;
        drop(self.proxies);
    }
}
