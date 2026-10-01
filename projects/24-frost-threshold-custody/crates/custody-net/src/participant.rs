// SPDX-License-Identifier: MIT
//! The participant service: one authenticated TCP connection to the
//! coordinator, feeding every envelope to a [`ParticipantNode`].

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use custody_protocol::{Party, node::ParticipantNode, signing::SESSION_TTL};
use rand_core::{OsRng, RngCore};
use tokio::net::TcpStream;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{Instant, timeout};
use tracing::{info, warn};

use crate::error::NetError;
use crate::wire::{
    Frame, HANDSHAKE_DOMAIN, HANDSHAKE_MAX_FRAME_LEN, hello_transcript, read_json,
    read_json_limited, welcome_transcript, write_json,
};

/// Participant settings.
#[derive(Clone, Copy, Debug)]
pub struct ParticipantConfig {
    /// Coordinator (or proxy) address.
    pub coordinator: SocketAddr,
    /// How long to keep retrying the initial connection.
    pub connect_timeout: Duration,
    /// How long the handshake may take.
    pub handshake_timeout: Duration,
    /// In-flight sessions older than this are dropped (and their secrets
    /// zeroised); checked every `session_ttl / 4`.
    pub session_ttl: Duration,
}

impl ParticipantConfig {
    /// Default timeouts for `coordinator`.
    #[must_use]
    pub fn new(coordinator: SocketAddr) -> Self {
        Self {
            coordinator,
            connect_timeout: Duration::from_secs(5),
            handshake_timeout: Duration::from_secs(5),
            session_ttl: SESSION_TTL,
        }
    }
}

/// Shared handle on a participant node.
pub type SharedNode = Arc<Mutex<ParticipantNode>>;

/// Locks a shared node, recovering from poisoning (the node's state is
/// updated atomically per message, so a panic cannot leave it half-written).
pub fn lock_node(node: &SharedNode) -> MutexGuard<'_, ParticipantNode> {
    node.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Aborts a background task when dropped.
struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// A running participant.
pub struct ParticipantHandle {
    node: SharedNode,
    shutdown: watch::Sender<bool>,
    task: JoinHandle<Result<(), NetError>>,
}

impl ParticipantHandle {
    /// The node (shares, journal) behind the service.
    #[must_use]
    pub fn node(&self) -> SharedNode {
        self.node.clone()
    }

    /// Waits until the service ends on its own (the coordinator closed the
    /// connection) or fails.
    pub async fn join(self) -> Result<(), NetError> {
        match self.task.await {
            Ok(result) => result,
            Err(e) => Err(NetError::Handshake(format!("participant task failed: {e}"))),
        }
    }

    /// Stops the service and waits for its task.
    pub async fn stop(self) -> Result<(), NetError> {
        let _ = self.shutdown.send(true);
        match self.task.await {
            Ok(result) => result,
            Err(e) if e.is_cancelled() => Ok(()),
            Err(e) => Err(NetError::Handshake(format!("participant task failed: {e}"))),
        }
    }
}

async fn connect(config: &ParticipantConfig) -> Result<TcpStream, NetError> {
    let deadline = Instant::now() + config.connect_timeout;
    loop {
        match TcpStream::connect(config.coordinator).await {
            Ok(stream) => return Ok(stream),
            Err(e) if Instant::now() < deadline => {
                warn!(error = %e, "coordinator not reachable yet; retrying");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Err(e) => return Err(e.into()),
        }
    }
}

async fn handshake(
    stream: &mut TcpStream,
    node: &SharedNode,
    config: &ParticipantConfig,
) -> Result<(), NetError> {
    let challenge: Frame = timeout(
        config.handshake_timeout,
        read_json_limited(stream, HANDSHAKE_MAX_FRAME_LEN),
    )
    .await
    .map_err(|_| NetError::Timeout("challenge".into()))??;
    let Frame::Challenge {
        protocol,
        server_nonce,
    } = challenge
    else {
        return Err(NetError::Handshake("expected challenge".into()));
    };
    if protocol != custody_protocol::identity::PROTOCOL_VERSION {
        return Err(NetError::Handshake(format!(
            "unsupported protocol {protocol}"
        )));
    }
    let mut client_nonce = [0u8; 32];
    OsRng.fill_bytes(&mut client_nonce);
    let (me, hello) = {
        let node = lock_node(node);
        let me = node.id();
        let signature = node.keys().sign(
            HANDSHAKE_DOMAIN,
            &hello_transcript(me, &server_nonce, &client_nonce),
        );
        (
            me,
            Frame::Hello {
                participant: me,
                server_nonce,
                client_nonce,
                signature,
            },
        )
    };
    write_json(stream, &hello).await?;
    let welcome: Frame = timeout(
        config.handshake_timeout,
        read_json_limited(stream, HANDSHAKE_MAX_FRAME_LEN),
    )
    .await
    .map_err(|_| NetError::Timeout("welcome".into()))??;
    let Frame::Welcome {
        client_nonce: echoed,
        signature,
    } = welcome
    else {
        return Err(NetError::Handshake("expected welcome".into()));
    };
    if echoed != client_nonce {
        return Err(NetError::Handshake("stale welcome".into()));
    }
    lock_node(node)
        .roster()
        .verify(
            Party::Coordinator,
            HANDSHAKE_DOMAIN,
            &welcome_transcript(me, &server_nonce, &client_nonce),
            &signature,
        )
        .map_err(|e| NetError::Handshake(e.to_string()))?;
    Ok(())
}

/// Connects to the coordinator, authenticates both ends, and serves protocol
/// messages until stopped. Returns once the handshake has succeeded.
pub async fn spawn_participant(
    node: ParticipantNode,
    config: ParticipantConfig,
) -> Result<ParticipantHandle, NetError> {
    spawn_shared(Arc::new(Mutex::new(node)), config).await
}

/// [`spawn_participant`] for a node the caller keeps a handle on, so that a
/// failed connection attempt can be retried (for example at a new address)
/// without losing the node.
pub async fn spawn_shared(
    node: SharedNode,
    config: ParticipantConfig,
) -> Result<ParticipantHandle, NetError> {
    let mut stream = connect(&config).await?;
    stream.set_nodelay(true)?;
    handshake(&mut stream, &node, &config).await?;
    let me = lock_node(&node).id();
    info!(%me, coordinator = %config.coordinator, "connected");
    let (shutdown, mut shutdown_rx) = watch::channel(false);
    let served = node.clone();
    // Expiry runs in its own task: `read_json` is not cancel-safe, so no
    // other branch may interrupt a frame read in the loop below.
    let ttl = config.session_ttl;
    let swept = node.clone();
    let sweeper = AbortOnDrop(tokio::spawn(async move {
        let mut sweep = tokio::time::interval((ttl / 4).max(Duration::from_millis(10)));
        sweep.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            sweep.tick().await;
            lock_node(&swept).expire_sessions(ttl);
        }
    }));
    let task = tokio::spawn(async move {
        let _sweeper = sweeper;
        let (mut reader, mut writer) = stream.into_split();
        loop {
            // Only `shutdown` can interrupt a read, and it ends the loop.
            tokio::select! {
                frame = read_json::<_, Frame>(&mut reader) => match frame {
                    Ok(Frame::Envelope(envelope)) => {
                        let replies = lock_node(&served).handle(&envelope, &mut OsRng);
                        for reply in replies {
                            write_json(&mut writer, &Frame::Envelope(reply)).await?;
                        }
                    }
                    Ok(_) => warn!(%me, "unexpected frame after handshake"),
                    Err(NetError::Malformed(e)) => warn!(%me, error = %e, "dropping malformed frame"),
                    Err(NetError::Closed) => return Ok(()),
                    Err(e) => return Err(e),
                },
                _ = shutdown_rx.changed() => return Ok(()),
            }
        }
    });
    Ok(ParticipantHandle {
        node,
        shutdown,
        task,
    })
}
