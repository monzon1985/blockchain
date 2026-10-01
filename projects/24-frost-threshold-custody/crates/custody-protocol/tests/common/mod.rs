// SPDX-License-Identifier: MIT
//! Shared helpers for the custody-protocol integration tests.
#![allow(dead_code, clippy::unwrap_used, clippy::expect_used)]

use alloy_primitives::{Address, U256, address};
use custody_protocol::{
    ParticipantId, Party,
    envelope::{Envelope, SignedEnvelope},
    identity::{PartyKeys, Roster},
    intent::{CustodyAction, VaultDomain, WithdrawalIntent},
    keygen::{KeygenOutcome, group_key_bytes},
    local::{Interceptor, LocalNetwork},
    messages::GroupKeyBytes,
};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

/// Vault domain used across tests.
pub const DOMAIN: VaultDomain = VaultDomain {
    chain_id: 31_337,
    vault: address!("00000000000000000000000000000000f2057001"),
};

pub fn p(i: u16) -> ParticipantId {
    ParticipantId::new(i).unwrap()
}

pub fn ids(range: std::ops::RangeInclusive<u16>) -> Vec<ParticipantId> {
    range.map(p).collect()
}

pub fn network(n: u16, seed: u64) -> LocalNetwork<ChaCha20Rng> {
    LocalNetwork::new(n, DOMAIN, ChaCha20Rng::seed_from_u64(seed)).unwrap()
}

/// Runs an honest DKG and returns the group key.
pub fn dkg(net: &mut LocalNetwork<ChaCha20Rng>, t: u16, n: u16) -> GroupKeyBytes {
    match net.dkg(t, &ids(1..=n)).unwrap() {
        KeygenOutcome::Committed { public_key_package } => {
            group_key_bytes(&public_key_package).unwrap()
        }
        KeygenOutcome::Aborted(report) => panic!("DKG aborted: {report:?}"),
    }
}

pub fn withdrawal(nonce: u64, amount: u64) -> CustodyAction {
    CustodyAction::Withdrawal(WithdrawalIntent {
        to: address!("000000000000000000000000000000000000beef"),
        token: Address::ZERO,
        amount: U256::from(amount),
        nonce: U256::from(nonce),
        deadline: U256::from(4_102_444_800u64),
    })
}

/// What an [`Adversary`] does with an envelope.
pub enum Verdict {
    /// Deliver unchanged.
    Deliver,
    /// Drop it.
    Drop,
    /// Deliver the (mutated) envelope re-signed by the sender.
    Resign,
    /// Deliver the original, then the mutated envelope re-signed (equivocation).
    DeliverBoth,
}

/// A Byzantine sender: may drop, rewrite (and re-sign with its own key), or
/// equivocate. Messages that fail to authenticate are passed through.
pub struct Adversary<F>(pub F);

impl<F> Interceptor for Adversary<F>
where
    F: FnMut(Party, Party, &mut Envelope, &PartyKeys, &Roster) -> Verdict,
{
    fn intercept(
        &mut self,
        from: Party,
        to: Party,
        envelope: SignedEnvelope,
        sender_keys: &PartyKeys,
        roster: &Roster,
    ) -> Vec<SignedEnvelope> {
        let Ok(verified) = envelope.verify(roster) else {
            return vec![envelope];
        };
        let mut inner = verified.envelope;
        match (self.0)(from, to, &mut inner, sender_keys, roster) {
            Verdict::Deliver => vec![envelope],
            Verdict::Drop => Vec::new(),
            Verdict::Resign => vec![SignedEnvelope::sign(&inner, sender_keys).unwrap()],
            Verdict::DeliverBoth => {
                vec![envelope, SignedEnvelope::sign(&inner, sender_keys).unwrap()]
            }
        }
    }
}

pub fn boxed<F>(f: F) -> Option<Box<dyn Interceptor>>
where
    F: FnMut(Party, Party, &mut Envelope, &PartyKeys, &Roster) -> Verdict + 'static,
{
    Some(Box::new(Adversary(f)))
}
