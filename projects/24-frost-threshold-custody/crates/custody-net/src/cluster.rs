// SPDX-License-Identifier: MIT
//! A coordinator plus `n` participants in one process, all over loopback TCP
//! with OS-assigned ports. Used by the integration tests, the end-to-end test
//! and the `frost-custody demo` command.

use std::collections::BTreeMap;
use std::time::Duration;

use custody_protocol::{
    ParticipantId,
    identity::GeneratedRoster,
    intent::{SignerPolicy, VaultDomain},
    node::ParticipantNode,
    signing::{SessionJournal, SignerState},
};
use rand_core::OsRng;

use crate::coordinator::{Coordinator, CoordinatorConfig};
use crate::error::NetError;
use crate::participant::{ParticipantConfig, ParticipantHandle, spawn_participant};

/// A running in-process deployment.
pub struct LocalCluster {
    /// The coordinator.
    pub coordinator: Coordinator,
    /// Participant services by id.
    pub participants: BTreeMap<ParticipantId, ParticipantHandle>,
}

impl LocalCluster {
    /// Generates a fresh roster of `n` participants pinned to `domain` and
    /// starts every service.
    pub async fn start(
        n: u16,
        domain: VaultDomain,
        phase_timeout: Duration,
    ) -> Result<Self, NetError> {
        let generated = GeneratedRoster::generate(n, &mut OsRng)?;
        Self::start_with(
            generated,
            domain,
            CoordinatorConfig {
                phase_timeout,
                ..CoordinatorConfig::default()
            },
        )
        .await
    }

    /// Starts every service for an existing generated roster.
    pub async fn start_with(
        generated: GeneratedRoster,
        domain: VaultDomain,
        config: CoordinatorConfig,
    ) -> Result<Self, NetError> {
        let roster = generated.roster.clone();
        let coordinator = Coordinator::bind(generated.coordinator, roster.clone(), config).await?;
        let mut participants = BTreeMap::new();
        for (id, keys) in generated.participants {
            let signer = SignerState::new(
                SignerPolicy::permissive(domain),
                SessionJournal::in_memory(),
            );
            let node = ParticipantNode::new(id, keys, roster.clone(), signer)?;
            let handle =
                spawn_participant(node, ParticipantConfig::new(coordinator.local_addr())).await?;
            participants.insert(id, handle);
        }
        let ids: Vec<_> = participants.keys().copied().collect();
        coordinator.wait_for(&ids, Duration::from_secs(5)).await?;
        Ok(Self {
            coordinator,
            participants,
        })
    }

    /// Participant ids, ascending.
    #[must_use]
    pub fn ids(&self) -> Vec<ParticipantId> {
        self.participants.keys().copied().collect()
    }

    /// Stops every participant, then the coordinator.
    pub async fn shutdown(self) -> Result<(), NetError> {
        for (_, handle) in self.participants {
            handle.stop().await?;
        }
        self.coordinator.shutdown().await;
        Ok(())
    }
}
