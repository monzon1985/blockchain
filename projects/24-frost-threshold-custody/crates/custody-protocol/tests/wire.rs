// SPDX-License-Identifier: MIT
//! Encodings shared with other components: roster files, key files, message
//! serialisation, EIP-712 type strings (must match SchnorrVault.sol) and the
//! signer policy.
#![allow(clippy::unwrap_used, clippy::expect_used)]

mod common;

use alloy_primitives::{Address, U256, address};
use alloy_sol_types::SolStruct;
use common::*;
use custody_protocol::{
    Party, ProtocolError, SessionId,
    envelope::{Envelope, Recipient, SignedEnvelope},
    identity::{GeneratedRoster, PartyKeys, Roster, RosterEntry},
    intent::{
        CustodyAction, DailyLimitUpdate, GuardianUpdate, KeyRotation, SignerPolicy,
        WithdrawalIntent, rotation_to,
    },
    messages::{Message, SignRequest},
    node::ParticipantNode,
    signing::{SessionJournal, SignerState},
};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;

#[test]
fn eip712_type_strings_match_the_solidity_contract() {
    assert_eq!(
        WithdrawalIntent::eip712_encode_type(),
        "WithdrawalIntent(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    assert_eq!(
        KeyRotation::eip712_encode_type(),
        "KeyRotation(uint256 newPubKeyX,uint8 newPubKeyYParity,uint256 nonce,uint256 deadline)"
    );
    assert_eq!(
        DailyLimitUpdate::eip712_encode_type(),
        "DailyLimitUpdate(address token,uint256 newLimit,uint256 nonce,uint256 deadline)"
    );
    assert_eq!(
        GuardianUpdate::eip712_encode_type(),
        "GuardianUpdate(address newGuardian,uint256 nonce,uint256 deadline)"
    );
}

#[test]
fn digests_bind_every_field_and_the_domain() {
    let base = withdrawal(1, 10);
    let d = base.signing_hash(&DOMAIN);
    assert_ne!(d, withdrawal(2, 10).signing_hash(&DOMAIN));
    assert_ne!(d, withdrawal(1, 11).signing_hash(&DOMAIN));
    let mut other_chain = DOMAIN;
    other_chain.chain_id = 1;
    assert_ne!(d, base.signing_hash(&other_chain));
    let mut other_vault = DOMAIN;
    other_vault.vault = Address::ZERO;
    assert_ne!(d, base.signing_hash(&other_vault));
    assert_eq!(base.kind(), "withdrawal");
    assert_eq!(base.nonce(), U256::from(1));
}

#[test]
fn roster_files_round_trip_and_are_validated() {
    let mut rng = ChaCha20Rng::seed_from_u64(1);
    let generated = GeneratedRoster::generate(3, &mut rng).unwrap();
    let json = generated.roster.to_json().unwrap();
    let parsed = Roster::from_json(&json).unwrap();
    assert_eq!(parsed, generated.roster);
    assert_eq!(parsed.len(), 3);
    assert!(!parsed.is_empty());
    assert!(parsed.contains(p(2)) && !parsed.contains(p(4)));

    let bad_version = json.replace("frost-custody/v1", "frost-custody/v0");
    assert!(Roster::from_json(&bad_version).is_err());

    let coordinator = generated.coordinator.public();
    let a = PartyKeys::generate(&mut rng).public();
    let entry = |id, identity| RosterEntry {
        id: p(id),
        name: format!("s{id}"),
        identity,
    };
    assert!(matches!(
        Roster::new(
            coordinator,
            vec![
                entry(1, a),
                entry(1, PartyKeys::generate(&mut rng).public())
            ]
        ),
        Err(ProtocolError::InvalidParameters(_))
    ));
    assert!(
        Roster::new(coordinator, vec![entry(1, a), entry(2, a)]).is_err(),
        "key reuse"
    );
    assert!(
        Roster::new(coordinator, vec![entry(1, a)]).is_err(),
        "single participant"
    );
    assert!(
        Roster::new(coordinator, vec![entry(1, coordinator), entry(2, a)]).is_err(),
        "coordinator key reuse"
    );
    let mut weak = a;
    weak.signing_key = [0u8; 32];
    weak.signing_key[0] = 1; // the identity point: small order
    assert!(
        Roster::new(
            coordinator,
            vec![
                entry(1, weak),
                entry(2, PartyKeys::generate(&mut rng).public())
            ]
        )
        .is_err()
    );
}

#[test]
fn participant_id_zero_is_rejected() {
    assert!(custody_protocol::ParticipantId::new(0).is_err());
    assert!(serde_json::from_str::<custody_protocol::ParticipantId>("0").is_err());
    assert_eq!(
        serde_json::from_str::<custody_protocol::ParticipantId>("7")
            .unwrap()
            .get(),
        7
    );
}

#[test]
fn key_files_restore_identical_keys() {
    let mut rng = ChaCha20Rng::seed_from_u64(2);
    let keys = PartyKeys::generate(&mut rng);
    let file = keys.to_key_file(Party::Participant(p(1)));
    let json = serde_json::to_string(&file).unwrap();
    let restored: custody_protocol::identity::KeyFile = serde_json::from_str(&json).unwrap();
    assert_eq!(restored.keys().public(), keys.public());
    assert!(
        !format!("{restored:?}").contains(&hex::encode(file.signing_secret)),
        "Debug must not leak secrets"
    );
    assert!(!format!("{keys:?}").contains("signing_secret"));
}

#[test]
fn messages_round_trip_through_signed_envelopes() {
    let mut rng = ChaCha20Rng::seed_from_u64(3);
    let generated = GeneratedRoster::generate(2, &mut rng).unwrap();
    let body = Message::SignRequest(SignRequest {
        group_key: [2u8; 33],
        action: withdrawal(5, 6),
        domain: DOMAIN,
        signers: vec![p(1), p(2)],
        approval: None,
    });
    let envelope = Envelope::new(
        SessionId::random(&mut rng),
        Party::Coordinator,
        Recipient::Participant(p(1)),
        body,
    );
    let signed = SignedEnvelope::sign(&envelope, &generated.coordinator).unwrap();
    let wire = serde_json::to_string(&signed).unwrap();
    let back: SignedEnvelope = serde_json::from_str(&wire).unwrap();
    let verified = back.verify(&generated.roster).unwrap();
    assert_eq!(verified.envelope, envelope);
    assert_eq!(verified.from(), Party::Coordinator);
    assert!(verified.participant().is_err());
    assert_eq!(back.digest(), signed.digest());
}

#[test]
fn nodes_refuse_keys_that_do_not_match_the_roster() {
    let mut rng = ChaCha20Rng::seed_from_u64(4);
    let generated = GeneratedRoster::generate(2, &mut rng).unwrap();
    let signer = SignerState::new(
        SignerPolicy::permissive(DOMAIN),
        SessionJournal::in_memory(),
    );
    assert!(
        ParticipantNode::new(
            p(1),
            PartyKeys::generate(&mut rng),
            generated.roster,
            signer
        )
        .is_err()
    );
}

#[test]
fn signer_policy_rules() {
    let policy = SignerPolicy::permissive(DOMAIN);
    let rotation = |x: U256, parity| {
        CustodyAction::KeyRotation(KeyRotation {
            newPubKeyX: x,
            newPubKeyYParity: parity,
            nonce: U256::from(1),
            deadline: U256::from(1),
        })
    };
    assert!(
        policy
            .check(&rotation(U256::from(5), 0), &DOMAIN, None)
            .is_ok()
    );
    assert!(
        policy
            .check(&rotation(U256::ZERO, 0), &DOMAIN, None)
            .is_err()
    );
    assert!(
        policy
            .check(&rotation(U256::MAX, 0), &DOMAIN, None)
            .is_err()
    );
    assert!(
        policy
            .check(&rotation(U256::from(5), 2), &DOMAIN, None)
            .is_err()
    );
    let mut no_rotation = policy.clone();
    no_rotation.allow_key_rotation = false;
    assert!(
        no_rotation
            .check(&rotation(U256::from(5), 0), &DOMAIN, None)
            .is_err()
    );

    let guardian = |g| {
        CustodyAction::GuardianUpdate(GuardianUpdate {
            newGuardian: g,
            nonce: U256::from(1),
            deadline: U256::from(1),
        })
    };
    assert!(
        policy
            .check(&guardian(Address::ZERO), &DOMAIN, None)
            .is_err()
    );
    assert!(
        policy
            .check(
                &guardian(address!("00000000000000000000000000000000000000aa")),
                &DOMAIN,
                None
            )
            .is_ok()
    );
    let limit = CustodyAction::DailyLimitUpdate(DailyLimitUpdate {
        token: Address::ZERO,
        newLimit: U256::from(1),
        nonce: U256::from(1),
        deadline: U256::from(1),
    });
    assert!(policy.check(&limit, &DOMAIN, None).is_ok());
    let zero_amount = CustodyAction::Withdrawal(WithdrawalIntent {
        to: address!("00000000000000000000000000000000000000aa"),
        token: Address::ZERO,
        amount: U256::ZERO,
        nonce: U256::from(1),
        deadline: U256::from(1),
    });
    assert!(policy.check(&zero_amount, &DOMAIN, None).is_err());

    // Optional allowlists and caps.
    let mut strict = policy.clone();
    let friend = address!("00000000000000000000000000000000000000aa");
    strict.allowed_recipients = Some([friend].into_iter().collect());
    strict.allowed_guardians = Some([friend].into_iter().collect());
    strict.max_daily_limit = Some(U256::from(10));
    let pay = |to| {
        CustodyAction::Withdrawal(WithdrawalIntent {
            to,
            token: Address::ZERO,
            amount: U256::from(1),
            nonce: U256::from(1),
            deadline: U256::from(1),
        })
    };
    let other = address!("00000000000000000000000000000000000000bb");
    assert!(strict.check(&pay(friend), &DOMAIN, None).is_ok());
    assert!(strict.check(&pay(other), &DOMAIN, None).is_err());
    assert!(strict.check(&guardian(friend), &DOMAIN, None).is_ok());
    assert!(strict.check(&guardian(other), &DOMAIN, None).is_err());
    let limit_to = |v: u64| {
        CustodyAction::DailyLimitUpdate(DailyLimitUpdate {
            token: Address::ZERO,
            newLimit: U256::from(v),
            nonce: U256::from(1),
            deadline: U256::from(1),
        })
    };
    assert!(strict.check(&limit_to(10), &DOMAIN, None).is_ok());
    assert!(strict.check(&limit_to(11), &DOMAIN, None).is_err());
    // The policy file format round-trips, approver key included.
    strict.approver = Some([7u8; 32]);
    let json = serde_json::to_string(&strict).unwrap();
    assert!(json.contains("\"approver\":\"0x0707"), "{json}");
    assert_eq!(serde_json::from_str::<SignerPolicy>(&json).unwrap(), strict);
    let legacy = r#"{"domain":{"chainId":31337,"vault":"0x00000000000000000000000000000000f2057001"},"maxWithdrawal":null,"allowKeyRotation":true}"#;
    assert_eq!(
        serde_json::from_str::<SignerPolicy>(legacy).unwrap(),
        policy
    );

    let key = frost_keccak::evm::EvmGroupKey {
        x: [1u8; 32],
        y_parity: 1,
    };
    let r = rotation_to(&key, U256::from(3), U256::from(4));
    assert_eq!(r.newPubKeyX, U256::from_be_bytes([1u8; 32]));
    assert_eq!(r.newPubKeyYParity, 1);
}
