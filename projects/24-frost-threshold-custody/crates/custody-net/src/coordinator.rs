// SPDX-License-Identifier: MIT
//! The coordinator service: accepts authenticated participant connections on
//! local TCP and drives protocol sessions with per-phase deadlines.
//!
//! The coordinator is untrusted for key safety: it relays origin-signed
//! envelopes, cannot read sealed shares or make a dealer reveal one, cannot
//! make signers rotate the vault to a key they do not hold, and every blame it
//! reports carries the culprit's own signed messages. It is trusted for
//! liveness and, unless the signers' policies name an approver key, for
//! choosing which in-policy actions are requested.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use custody_protocol::{
    ParticipantId, Party, SessionId,
    envelope::{Outbound, Recipient, SignedEnvelope},
    identity::{PROTOCOL_VERSION, PartyKeys, Roster},
    intent::{Approval, CustodyAction, VaultDomain},
    keygen::{KeygenCoordinator, KeygenOutcome, group_key_bytes},
    local::{SignReport, select_signers},
    messages::{GroupKeyBytes, KeygenMode, KeygenStart, RepairStart, SignRequest},
    node::CoordinatorSession,
    repair::{RepairCoordinator, RepairOutcome},
    signing::{SigningCoordinator, SigningOutcome},
};
use frost_keccak::{SigningPackage, keys::PublicKeyPackage};
use rand_core::{OsRng, RngCore};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore, mpsc, watch};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::{Instant, timeout, timeout_at};
use tracing::{debug, info, warn};

use crate::error::NetError;
use crate::wire::{
    Frame, HANDSHAKE_DOMAIN, HANDSHAKE_MAX_FRAME_LEN, hello_transcript, read_json,
    read_json_limited, welcome_transcript, write_json,
};

/// Default capacity of the inbox and of each connection's outbound queue.
pub const QUEUE: usize = 1024;

/// Coordinator settings.
#[derive(Clone, Copy, Debug)]
pub struct CoordinatorConfig {
    /// Listening address; use port 0 to let the OS pick a free port.
    pub listen: SocketAddr,
    /// How long a protocol phase may wait for the slowest participant.
    pub phase_timeout: Duration,
    /// How long a connecting participant has to complete the handshake.
    pub handshake_timeout: Duration,
    /// Envelopes queued per connection. A participant that stops reading
    /// until its queue is full is disconnected (and then named unresponsive
    /// by the phase deadline) instead of blocking the session loop.
    pub outbound_queue: usize,
    /// Connections allowed to be in the handshake at once; further ones are
    /// closed immediately. `0` means twice the roster size plus two.
    pub max_pending_handshakes: usize,
}

impl Default for CoordinatorConfig {
    fn default() -> Self {
        Self {
            listen: SocketAddr::from(([127, 0, 0, 1], 0)),
            phase_timeout: Duration::from_secs(5),
            handshake_timeout: Duration::from_secs(5),
            outbound_queue: QUEUE,
            max_pending_handshakes: 0,
        }
    }
}

struct Inbound {
    from: ParticipantId,
    envelope: SignedEnvelope,
}

/// The coordinator's handle on one authenticated connection.
#[derive(Clone)]
struct Connection {
    tx: mpsc::Sender<SignedEnvelope>,
    /// Tells the connection task to close the socket.
    kill: Arc<Notify>,
}

type Connections = Mutex<HashMap<ParticipantId, Connection>>;

struct Shared {
    keys: PartyKeys,
    roster: Roster,
    config: CoordinatorConfig,
    connections: Connections,
    inbox: mpsc::Sender<Inbound>,
    /// Connection tasks currently alive (authenticated or not).
    live_tasks: AtomicUsize,
}

/// Decrements [`Shared::live_tasks`] when a connection task ends.
struct LiveTask(Arc<Shared>);

impl Drop for LiveTask {
    fn drop(&mut self) {
        self.0.live_tasks.fetch_sub(1, Ordering::SeqCst);
    }
}

/// A running coordinator.
pub struct Coordinator {
    shared: Arc<Shared>,
    inbox: mpsc::Receiver<Inbound>,
    local_addr: SocketAddr,
    groups: BTreeMap<GroupKeyBytes, PublicKeyPackage>,
    last_signing_package: Option<SigningPackage>,
    shutdown: watch::Sender<bool>,
    accept: JoinHandle<()>,
}

impl Coordinator {
    /// Binds the listener and starts accepting participants.
    pub async fn bind(
        keys: PartyKeys,
        roster: Roster,
        config: CoordinatorConfig,
    ) -> Result<Self, NetError> {
        if keys.public()
            != roster
                .identity(Party::Coordinator)
                .map_err(custody_protocol::ProtocolError::from)?
        {
            return Err(NetError::Handshake(
                "coordinator keys do not match the roster".into(),
            ));
        }
        let listener = TcpListener::bind(config.listen).await?;
        let local_addr = listener.local_addr()?;
        let (inbox_tx, inbox) = mpsc::channel(QUEUE);
        let (shutdown, shutdown_rx) = watch::channel(false);
        let max_pending = if config.max_pending_handshakes == 0 {
            2 * roster.len() + 2
        } else {
            config.max_pending_handshakes
        };
        let shared = Arc::new(Shared {
            keys,
            roster,
            config,
            connections: Mutex::new(HashMap::new()),
            inbox: inbox_tx,
            live_tasks: AtomicUsize::new(0),
        });
        let handshakes = Arc::new(Semaphore::new(max_pending));
        let accept = tokio::spawn(accept_loop(
            listener,
            shared.clone(),
            handshakes,
            shutdown_rx,
        ));
        info!(%local_addr, "coordinator listening");
        Ok(Self {
            shared,
            inbox,
            local_addr,
            groups: BTreeMap::new(),
            last_signing_package: None,
            shutdown,
            accept,
        })
    }

    /// Address the coordinator listens on (with the OS-assigned port).
    #[must_use]
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Participants with an authenticated connection.
    #[must_use]
    pub fn connected(&self) -> BTreeSet<ParticipantId> {
        lock(&self.shared.connections).keys().copied().collect()
    }

    /// Connection tasks currently alive (authenticated or still in the
    /// handshake). Finished tasks are reaped, so this returns to the number of
    /// connected participants once stray connections close.
    #[must_use]
    pub fn live_connection_tasks(&self) -> usize {
        self.shared.live_tasks.load(Ordering::SeqCst)
    }

    /// Waits until every participant in `ids` is connected.
    pub async fn wait_for(&self, ids: &[ParticipantId], limit: Duration) -> Result<(), NetError> {
        let deadline = Instant::now() + limit;
        loop {
            let connected = self.connected();
            if ids.iter().all(|p| connected.contains(p)) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(NetError::Timeout(format!(
                    "participants {ids:?} to connect"
                )));
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// Public data of a group created or refreshed through this coordinator.
    pub fn group(&self, group_key: &GroupKeyBytes) -> Option<&PublicKeyPackage> {
        self.groups.get(group_key)
    }

    /// Registers a group's public data (e.g. after a restart).
    pub fn register_group(&mut self, public: PublicKeyPackage) -> Result<GroupKeyBytes, NetError> {
        let key = group_key_bytes(&public)?;
        self.groups.insert(key, public);
        Ok(key)
    }

    /// Signing package of the most recent signing attempt.
    #[must_use]
    pub fn last_signing_package(&self) -> Option<&SigningPackage> {
        self.last_signing_package.as_ref()
    }

    /// The roster.
    #[must_use]
    pub fn roster(&self) -> &Roster {
        &self.shared.roster
    }

    /// Queues envelopes for their participants without ever waiting: the
    /// session loop must keep running so that phase deadlines fire. A
    /// participant whose queue is full has stopped reading; it is
    /// disconnected and its messages are dropped, so the phase deadline names
    /// it unresponsive.
    fn dispatch(&self, outs: Vec<Outbound>) -> Result<(), NetError> {
        for out in outs {
            let Recipient::Participant(to) = out.to else {
                continue;
            };
            let envelope = out.sign(Party::Coordinator, &self.shared.keys)?;
            let connection = lock(&self.shared.connections).get(&to).cloned();
            let Some(connection) = connection else {
                warn!(%to, "participant not connected; message dropped");
                continue;
            };
            match connection.tx.try_send(envelope) {
                Ok(()) => {}
                Err(TrySendError::Full(_)) => {
                    warn!(%to, "participant is not reading; disconnecting it");
                    disconnect(&self.shared, to, &connection);
                }
                Err(TrySendError::Closed(_)) => {
                    warn!(%to, "connection closed while sending");
                }
            }
        }
        Ok(())
    }

    /// Runs a session to completion. A phase deadline restarts whenever a new
    /// phase begins; when it expires, the session blames the silent parties.
    async fn run(
        &mut self,
        session: &mut CoordinatorSession,
        initial: Vec<Outbound>,
    ) -> Result<(), NetError> {
        let phase_timeout = self.shared.config.phase_timeout;
        self.dispatch(initial)?;
        let mut awaiting = session.awaiting();
        let mut deadline = Instant::now() + phase_timeout;
        while !session.is_done() {
            let outs = match timeout_at(deadline, self.inbox.recv()).await {
                Ok(Some(inbound)) => match inbound.envelope.verify(&self.shared.roster) {
                    Ok(verified) => session.handle(&verified),
                    Err(e) => {
                        warn!(from = %inbound.from, error = %e, "dropping unauthenticated envelope");
                        Vec::new()
                    }
                },
                Ok(None) => return Err(NetError::Stopped),
                Err(_) => {
                    debug!(awaiting = ?session.awaiting(), "phase deadline expired");
                    session.on_timeout()
                }
            };
            self.dispatch(outs)?;
            let now = session.awaiting();
            if !now.is_subset(&awaiting) {
                deadline = Instant::now() + phase_timeout;
            }
            awaiting = now;
        }
        Ok(())
    }

    async fn keygen(
        &mut self,
        start: KeygenStart,
        previous: Option<PublicKeyPackage>,
    ) -> Result<KeygenOutcome, NetError> {
        let session = SessionId::random(&mut OsRng);
        let (state, initial) =
            KeygenCoordinator::new(session, start, self.shared.roster.clone(), previous)?;
        let mut state = CoordinatorSession::Keygen(state);
        self.run(&mut state, initial).await?;
        let CoordinatorSession::Keygen(state) = state else {
            return Err(NetError::Stopped);
        };
        let outcome = state.outcome().cloned().ok_or(NetError::Stopped)?;
        if let KeygenOutcome::Committed { public_key_package } = &outcome {
            self.register_group(public_key_package.clone())?;
        }
        Ok(outcome)
    }

    /// Runs a Pedersen DKG.
    pub async fn dkg(
        &mut self,
        threshold: u16,
        participants: &[ParticipantId],
    ) -> Result<KeygenOutcome, NetError> {
        info!(threshold, n = participants.len(), "starting DKG");
        self.keygen(
            KeygenStart {
                mode: KeygenMode::Fresh,
                threshold,
                participants: participants.to_vec(),
            },
            None,
        )
        .await
    }

    /// Proactively refreshes a group's shares (group key unchanged).
    pub async fn refresh(
        &mut self,
        group_key: GroupKeyBytes,
        participants: &[ParticipantId],
    ) -> Result<KeygenOutcome, NetError> {
        let previous = self
            .groups
            .get(&group_key)
            .cloned()
            .ok_or(custody_protocol::ProtocolError::NoKeyShare)?;
        let threshold =
            previous
                .min_signers()
                .ok_or(custody_protocol::ProtocolError::InvalidParameters(
                    "unknown threshold".into(),
                ))?;
        info!(threshold, n = participants.len(), "starting refresh");
        self.keygen(
            KeygenStart {
                mode: KeygenMode::Refresh { group_key },
                threshold,
                participants: participants.to_vec(),
            },
            Some(previous),
        )
        .await
    }

    /// One signing attempt with an explicit signer set.
    pub async fn sign(
        &mut self,
        group_key: GroupKeyBytes,
        action: CustodyAction,
        domain: VaultDomain,
        signers: &[ParticipantId],
    ) -> Result<SigningOutcome, NetError> {
        self.sign_approved(group_key, action, domain, signers, None)
            .await
    }

    /// One signing attempt carrying an operator approval (required by
    /// signers whose policy names an approver).
    pub async fn sign_approved(
        &mut self,
        group_key: GroupKeyBytes,
        action: CustodyAction,
        domain: VaultDomain,
        signers: &[ParticipantId],
        approval: Option<Approval>,
    ) -> Result<SigningOutcome, NetError> {
        let public = self
            .groups
            .get(&group_key)
            .cloned()
            .ok_or(custody_protocol::ProtocolError::NoKeyShare)?;
        let session = SessionId::random(&mut OsRng);
        let (state, initial) = SigningCoordinator::new(
            session,
            SignRequest {
                group_key,
                action,
                domain,
                signers: signers.to_vec(),
                approval,
            },
            public,
        )?;
        let mut state = CoordinatorSession::Signing(state);
        self.run(&mut state, initial).await?;
        let CoordinatorSession::Signing(state) = state else {
            return Err(NetError::Stopped);
        };
        self.last_signing_package = state.signing_package().cloned();
        state.outcome().cloned().ok_or(NetError::Stopped)
    }

    /// Signs with retries, excluding every participant named in a failed
    /// attempt, and preferring connected participants.
    pub async fn sign_with_retry(
        &mut self,
        group_key: GroupKeyBytes,
        action: CustodyAction,
        domain: VaultDomain,
    ) -> Result<SignReport, NetError> {
        self.sign_with_retry_approved(group_key, action, domain, None)
            .await
    }

    /// [`Self::sign_with_retry`] carrying an operator approval.
    pub async fn sign_with_retry_approved(
        &mut self,
        group_key: GroupKeyBytes,
        action: CustodyAction,
        domain: VaultDomain,
        approval: Option<Approval>,
    ) -> Result<SignReport, NetError> {
        let public = self
            .groups
            .get(&group_key)
            .cloned()
            .ok_or(custody_protocol::ProtocolError::NoKeyShare)?;
        let mut excluded = BTreeSet::new();
        let mut failed_attempts = Vec::new();
        loop {
            let candidates: Vec<_> = self.connected().into_iter().collect();
            let Some(signers) = select_signers(&public, candidates, &excluded) else {
                let outcome = failed_attempts
                    .last()
                    .cloned()
                    .map(SigningOutcome::Aborted)
                    .ok_or_else(|| NetError::Timeout("not enough connected signers".into()))?;
                return Ok(SignReport {
                    outcome,
                    failed_attempts,
                });
            };
            match self
                .sign_approved(group_key, action.clone(), domain, &signers, approval)
                .await?
            {
                SigningOutcome::Aborted(report) => {
                    warn!(culprits = ?report.culprits(), excluded = ?report.excluded(), "signing attempt failed; retrying");
                    excluded.extend(report.excluded());
                    failed_attempts.push(report);
                }
                signed => {
                    return Ok(SignReport {
                        outcome: signed,
                        failed_attempts,
                    });
                }
            }
        }
    }

    /// Repairs a lost share with the given helpers.
    pub async fn repair(
        &mut self,
        group_key: GroupKeyBytes,
        lost: ParticipantId,
        helpers: &[ParticipantId],
    ) -> Result<RepairOutcome, NetError> {
        let public = self
            .groups
            .get(&group_key)
            .cloned()
            .ok_or(custody_protocol::ProtocolError::NoKeyShare)?;
        let session = SessionId::random(&mut OsRng);
        let (state, initial) = RepairCoordinator::new(
            session,
            RepairStart {
                group_key,
                lost,
                helpers: helpers.to_vec(),
            },
            &public,
        )?;
        let mut state = CoordinatorSession::Repair(state);
        self.run(&mut state, initial).await?;
        let CoordinatorSession::Repair(state) = state else {
            return Err(NetError::Stopped);
        };
        state.outcome().cloned().ok_or(NetError::Stopped)
    }

    /// Stops accepting connections and closes every participant connection.
    pub async fn shutdown(self) {
        let _ = self.shutdown.send(true);
        lock(&self.shared.connections).clear();
        let _ = self.accept.await;
    }
}

fn lock(
    connections: &Connections,
) -> std::sync::MutexGuard<'_, HashMap<ParticipantId, Connection>> {
    connections
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Removes `connection` (if it is still the registered one) and closes it.
fn disconnect(shared: &Shared, participant: ParticipantId, connection: &Connection) {
    let mut connections = lock(&shared.connections);
    if connections
        .get(&participant)
        .is_some_and(|c| c.tx.same_channel(&connection.tx))
    {
        connections.remove(&participant);
    }
    connection.kill.notify_one();
}

/// Accepts connections. Every connection runs in a [`JoinSet`] that is reaped
/// as tasks finish, and at most `handshakes` connections may be
/// unauthenticated at once (each can only make the coordinator read a
/// handshake frame of at most [`HANDSHAKE_MAX_FRAME_LEN`] bytes).
async fn accept_loop(
    listener: TcpListener,
    shared: Arc<Shared>,
    handshakes: Arc<Semaphore>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut tasks = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    let Ok(permit) = handshakes.clone().try_acquire_owned() else {
                        warn!(%peer, "too many pending handshakes; closing the connection");
                        drop(stream);
                        continue;
                    };
                    shared.live_tasks.fetch_add(1, Ordering::SeqCst);
                    let live = LiveTask(shared.clone());
                    let shared = shared.clone();
                    let shutdown = shutdown.clone();
                    tasks.spawn(async move {
                        let _live = live;
                        if let Err(e) = serve_connection(stream, shared, permit, shutdown).await {
                            debug!(%peer, error = %e, "connection ended");
                        }
                    });
                }
                Err(e) => warn!(error = %e, "accept failed"),
            },
            Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
            _ = shutdown.changed() => break,
        }
    }
    tasks.shutdown().await;
}

async fn handshake(stream: &mut TcpStream, shared: &Shared) -> Result<ParticipantId, NetError> {
    let mut server_nonce = [0u8; 32];
    OsRng.fill_bytes(&mut server_nonce);
    write_json(
        stream,
        &Frame::Challenge {
            protocol: PROTOCOL_VERSION.to_owned(),
            server_nonce,
        },
    )
    .await?;
    let hello: Frame = timeout(
        shared.config.handshake_timeout,
        read_json_limited(stream, HANDSHAKE_MAX_FRAME_LEN),
    )
    .await
    .map_err(|_| NetError::Timeout("hello".into()))??;
    let Frame::Hello {
        participant,
        server_nonce: echoed,
        client_nonce,
        signature,
    } = hello
    else {
        return Err(NetError::Handshake("expected hello".into()));
    };
    if echoed != server_nonce {
        return Err(NetError::Handshake("stale challenge".into()));
    }
    shared
        .roster
        .verify(
            Party::Participant(participant),
            HANDSHAKE_DOMAIN,
            &hello_transcript(participant, &server_nonce, &client_nonce),
            &signature,
        )
        .map_err(|e| NetError::Handshake(e.to_string()))?;
    let signature = shared.keys.sign(
        HANDSHAKE_DOMAIN,
        &welcome_transcript(participant, &server_nonce, &client_nonce),
    );
    write_json(
        stream,
        &Frame::Welcome {
            client_nonce,
            signature,
        },
    )
    .await?;
    Ok(participant)
}

async fn serve_connection(
    mut stream: TcpStream,
    shared: Arc<Shared>,
    handshake_permit: OwnedSemaphorePermit,
    mut shutdown: watch::Receiver<bool>,
) -> Result<(), NetError> {
    stream.set_nodelay(true)?;
    let participant = handshake(&mut stream, &shared).await?;
    drop(handshake_permit);
    info!(%participant, "participant authenticated");
    let (mut reader, mut writer) = stream.into_split();
    let (tx, mut rx) = mpsc::channel::<SignedEnvelope>(shared.config.outbound_queue.max(1));
    let connection = Connection {
        tx,
        kill: Arc::new(Notify::new()),
    };
    lock(&shared.connections).insert(participant, connection.clone());

    let writer_task = tokio::spawn(async move {
        while let Some(envelope) = rx.recv().await {
            if write_json(&mut writer, &Frame::Envelope(envelope))
                .await
                .is_err()
            {
                break;
            }
        }
    });

    let result = loop {
        tokio::select! {
            frame = read_json::<_, Frame>(&mut reader) => match frame {
                Ok(Frame::Envelope(envelope)) => {
                    if shared.inbox.send(Inbound { from: participant, envelope }).await.is_err() {
                        break Ok(());
                    }
                }
                Ok(other) => {
                    warn!(%participant, frame = ?std::mem::discriminant(&other), "unexpected frame");
                }
                Err(NetError::Malformed(e)) => {
                    warn!(%participant, error = %e, "dropping malformed frame");
                }
                Err(e) => break Err(e),
            },
            () = connection.kill.notified() => break Ok(()),
            _ = shutdown.changed() => break Ok(()),
        }
    };

    disconnect(&shared, participant, &connection);
    drop(connection);
    writer_task.abort();
    let _ = writer_task.await;
    result
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use custody_protocol::identity::GeneratedRoster;
    use custody_protocol::messages::{Message, Refused};

    /// A participant whose outbound queue is full (it stopped reading) never
    /// blocks the session loop: dispatch returns at once, drops the message
    /// and disconnects the participant.
    #[tokio::test]
    async fn dispatch_never_waits_for_a_participant_that_stopped_reading() {
        let generated = GeneratedRoster::generate(2, &mut OsRng).unwrap();
        let coordinator = Coordinator::bind(
            generated.coordinator,
            generated.roster,
            CoordinatorConfig::default(),
        )
        .await
        .unwrap();
        let p1 = ParticipantId::new(1).unwrap();
        let (tx, _stalled_rx) = mpsc::channel(1);
        let connection = Connection {
            tx,
            kill: Arc::new(Notify::new()),
        };
        lock(&coordinator.shared.connections).insert(p1, connection.clone());
        let outs: Vec<Outbound> = (0..3)
            .map(|i| Outbound {
                to: Recipient::Participant(p1),
                session: SessionId([i; 16]),
                body: Message::Refused(Refused {
                    refused: "x".into(),
                    reason: "y".into(),
                }),
            })
            .collect();
        tokio::time::timeout(Duration::from_secs(1), async { coordinator.dispatch(outs) })
            .await
            .expect("dispatch must not block")
            .unwrap();
        assert!(
            coordinator.connected().is_empty(),
            "stalled participant is dropped"
        );
        tokio::time::timeout(Duration::from_secs(1), connection.kill.notified())
            .await
            .expect("the connection task is told to close");
        coordinator.shutdown().await;
    }
}
