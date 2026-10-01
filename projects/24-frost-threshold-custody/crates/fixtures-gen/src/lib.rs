// SPDX-License-Identifier: MIT
//! Deterministic generation of the cross-language differential fixtures.
//!
//! Two groups are created with the real Pedersen DKG (in-memory network,
//! seeded ChaCha20), then the real two-round FROST signing protocol signs:
//!
//! * raw 32-byte messages for the `SchnorrSecp256k1` library cases (valid and
//!   tampered: `address(R)`, `z`, message, key parity, zero/out-of-range fields);
//! * an ordered vault scenario of EIP-712 intents (valid ETH and ERC-20
//!   withdrawals, a replayed nonce, tampered signatures, a foreign group, a
//!   limit breach, an expired intent, a key rotation with proof of possession,
//!   and withdrawals by the new and the stale key).
//!
//! The Foundry tests replay every case and must reach exactly the recorded
//! verdict. `fixtures-gen --check` fails if the committed file drifts.

use std::collections::BTreeSet;

use alloy_primitives::{Address, U256, address};
use custody_protocol::{
    ParticipantId, ProtocolError,
    intent::{
        CustodyAction, DailyLimitUpdate, GuardianUpdate, VaultDomain, WithdrawalIntent, rotation_to,
    },
    keygen::{KeygenOutcome, group_key_bytes},
    local::LocalNetwork,
    messages::GroupKeyBytes,
    signing::SigningOutcome,
};
use frost_keccak::evm::{self, EvmGroupKey, EvmSignature, SECP256K1_ORDER};
use k256::{Scalar, elliptic_curve::PrimeField};
use rand_chacha::ChaCha20Rng;
use rand_core::{RngCore, SeedableRng};
use serde_json::{Value, json};

/// Seed of the fixture RNG (DKG randomness, nonces, messages).
pub const SEED: u64 = 0x2024_f205_7c05;
/// Chain id the Foundry tests run on.
pub const CHAIN_ID: u64 = 31_337;
/// Address the Foundry test deploys the vault to (`deployCodeTo`).
pub const VAULT: Address = address!("00000000000000000000000000000000f2057001");
/// Address of the mock ERC-20 in the Foundry test.
pub const TOKEN: Address = address!("00000000000000000000000000000000f2057002");
/// Withdrawal recipient.
pub const RECIPIENT: Address = address!("000000000000000000000000000000000000beef");
/// Block timestamp the Foundry test warps to before replaying the scenario.
pub const NOW: u64 = 1_800_000_000;
/// Deadline of every non-expired intent.
pub const DEADLINE: u64 = 1_900_000_000;
/// Threshold and size of both groups.
pub const THRESHOLD: u16 = 3;
/// Number of participants.
pub const PARTICIPANTS: u16 = 5;

const ETHER: u128 = 1_000_000_000_000_000_000;

/// Fixture generation failures.
#[derive(Debug)]
pub struct FixtureError(pub String);

impl std::fmt::Display for FixtureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for FixtureError {}

impl From<ProtocolError> for FixtureError {
    fn from(e: ProtocolError) -> Self {
        Self(e.to_string())
    }
}

impl From<evm::EvmError> for FixtureError {
    fn from(e: evm::EvmError) -> Self {
        Self(e.to_string())
    }
}

fn hex0x(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

fn word(value: U256) -> String {
    hex0x(&value.to_be_bytes::<32>())
}

fn domain() -> VaultDomain {
    VaultDomain {
        chain_id: CHAIN_ID,
        vault: VAULT,
    }
}

fn p(i: u16) -> Result<ParticipantId, FixtureError> {
    Ok(ParticipantId::new(i)?)
}

struct Group {
    key: GroupKeyBytes,
    evm: EvmGroupKey,
}

fn dkg(net: &mut LocalNetwork<ChaCha20Rng>) -> Result<Group, FixtureError> {
    let ids = net.participants();
    match net.dkg(THRESHOLD, &ids)? {
        KeygenOutcome::Committed { public_key_package } => Ok(Group {
            key: group_key_bytes(&public_key_package)?,
            evm: EvmGroupKey::from_verifying_key(public_key_package.verifying_key())?,
        }),
        KeygenOutcome::Aborted(report) => Err(FixtureError(format!("DKG aborted: {report:?}"))),
    }
}

/// Threshold-signs `action` (for the vault domain) with participants 1..=t.
fn sign(
    net: &mut LocalNetwork<ChaCha20Rng>,
    group: &Group,
    action: &CustodyAction,
) -> Result<EvmSignature, FixtureError> {
    let signers = (1..=THRESHOLD).map(p).collect::<Result<Vec<_>, _>>()?;
    match net.sign(group.key, action.clone(), domain(), &signers)? {
        SigningOutcome::Signed {
            evm, signers: used, ..
        } => {
            debug_assert_eq!(used, signers.iter().copied().collect::<BTreeSet<_>>());
            Ok(evm)
        }
        SigningOutcome::Aborted(report) => {
            Err(FixtureError(format!("signing aborted: {report:?}")))
        }
    }
}

/// Signs a raw 32-byte message (not an EIP-712 intent) with the DKG shares of
/// participants 1..=t through frost-core's round-one/round-two/aggregate API.
/// Participant nodes only sign structured intents they can check, so raw
/// messages for the library-level cases bypass the node layer.
fn sign_raw(
    net: &mut LocalNetwork<ChaCha20Rng>,
    group: &Group,
    message: &[u8; 32],
) -> Result<EvmSignature, FixtureError> {
    let signers: Vec<ParticipantId> = (1..=THRESHOLD).map(p).collect::<Result<_, _>>()?;
    let mut nonces = std::collections::BTreeMap::new();
    let mut commitments = std::collections::BTreeMap::new();
    for id in &signers {
        let material = net
            .node(*id)?
            .shares()
            .get(&group.key)
            .ok_or_else(|| FixtureError("missing share".into()))?
            .clone();
        let (n, c) = frost_keccak::round1::commit(material.key_package.signing_share(), net.rng());
        nonces.insert(*id, (n, material));
        commitments.insert(id.identifier(), c);
    }
    let package = frost_keccak::SigningPackage::new(commitments, message);
    let mut shares = std::collections::BTreeMap::new();
    let mut public = None;
    for (id, (n, material)) in &nonces {
        shares.insert(
            id.identifier(),
            frost_keccak::round2::sign(&package, n, &material.key_package)
                .map_err(ProtocolError::from)?,
        );
        public = Some(material.public_key_package.clone());
    }
    let public = public.ok_or_else(|| FixtureError("no signers".into()))?;
    let signature =
        frost_keccak::aggregate(&package, &shares, &public).map_err(ProtocolError::from)?;
    Ok(EvmSignature::from_signature(&signature)?)
}

fn add_one(z: &[u8; 32]) -> Result<[u8; 32], FixtureError> {
    let s = Option::<Scalar>::from(Scalar::from_repr((*z).into()))
        .ok_or_else(|| FixtureError("z".into()))?;
    Ok((s + Scalar::ONE).to_bytes().into())
}

fn verifier_case(name: &str, key: &EvmGroupKey, message: &[u8; 32], sig: &EvmSignature) -> Value {
    let valid = evm::verify(key, message, sig);
    let mut case = json!({
        "name": name,
        "pubKeyX": hex0x(&key.x),
        "pubKeyYParity": key.y_parity,
        "msgHash": hex0x(message),
        "rAddr": hex0x(&sig.r_address),
        "z": hex0x(&sig.z),
        "valid": valid,
    });
    if valid {
        let e = evm::challenge_scalar(&sig.r_address, key, message);
        case["challenge"] = json!(hex0x(&e.to_bytes()));
    }
    case
}

fn withdrawal_case(
    name: &str,
    intent: &WithdrawalIntent,
    sig: &EvmSignature,
    expect: &str,
) -> Value {
    let digest = CustodyAction::Withdrawal(intent.clone()).signing_hash(&domain());
    json!({
        "name": name,
        "to": hex0x(intent.to.as_slice()),
        "token": hex0x(intent.token.as_slice()),
        "amount": word(intent.amount),
        "nonce": word(intent.nonce),
        "deadline": word(intent.deadline),
        "digest": hex0x(&digest),
        "rAddr": hex0x(&sig.r_address),
        "z": hex0x(&sig.z),
        "expect": expect,
    })
}

fn intent(
    to: Address,
    token: Address,
    amount: u128,
    nonce: u64,
    deadline: u64,
) -> WithdrawalIntent {
    WithdrawalIntent {
        to,
        token,
        amount: U256::from(amount),
        nonce: U256::from(nonce),
        deadline: U256::from(deadline),
    }
}

/// Builds the fixture document.
pub fn generate() -> Result<Value, FixtureError> {
    let mut net = LocalNetwork::new(PARTICIPANTS, domain(), ChaCha20Rng::seed_from_u64(SEED))?;
    let current = dkg(&mut net)?;
    let next = dkg(&mut net)?;

    // --- library-level cases -------------------------------------------------
    let mut verifier = Vec::new();
    for i in 0..4 {
        let mut message = [0u8; 32];
        net.rng().fill_bytes(&mut message);
        let sig = sign_raw(&mut net, &current, &message)?;
        verifier.push(verifier_case(
            &format!("valid_{i}"),
            &current.evm,
            &message,
            &sig,
        ));
    }
    let mut message = [0u8; 32];
    net.rng().fill_bytes(&mut message);
    let sig = sign_raw(&mut net, &current, &message)?;
    let mut r_flipped = sig;
    r_flipped.r_address[19] ^= 1;
    let mut other_message = message;
    other_message[31] ^= 1;
    let flipped_parity = EvmGroupKey {
        y_parity: current.evm.y_parity ^ 1,
        ..current.evm
    };
    let x_order = EvmGroupKey {
        x: SECP256K1_ORDER,
        ..current.evm
    };
    verifier.push(verifier_case(
        "tampered_r",
        &current.evm,
        &message,
        &r_flipped,
    ));
    verifier.push(verifier_case(
        "tampered_z",
        &current.evm,
        &message,
        &EvmSignature {
            z: add_one(&sig.z)?,
            ..sig
        },
    ));
    verifier.push(verifier_case(
        "wrong_message",
        &current.evm,
        &other_message,
        &sig,
    ));
    verifier.push(verifier_case(
        "wrong_key_parity",
        &flipped_parity,
        &message,
        &sig,
    ));
    verifier.push(verifier_case("other_group_key", &next.evm, &message, &sig));
    verifier.push(verifier_case(
        "zero_z",
        &current.evm,
        &message,
        &EvmSignature {
            z: [0u8; 32],
            ..sig
        },
    ));
    verifier.push(verifier_case(
        "z_equals_order",
        &current.evm,
        &message,
        &EvmSignature {
            z: SECP256K1_ORDER,
            ..sig
        },
    ));
    verifier.push(verifier_case(
        "zero_r_address",
        &current.evm,
        &message,
        &EvmSignature {
            r_address: [0u8; 20],
            ..sig
        },
    ));
    verifier.push(verifier_case(
        "key_x_equals_order",
        &x_order,
        &message,
        &sig,
    ));

    // --- vault scenario before rotation ---------------------------------------
    let mut before = Vec::new();
    let eth = Address::ZERO;
    let w1 = intent(RECIPIENT, eth, ETHER, 1, DEADLINE);
    let s1 = sign(&mut net, &current, &CustodyAction::Withdrawal(w1.clone()))?;
    before.push(withdrawal_case("valid_eth", &w1, &s1, "ok"));
    before.push(withdrawal_case(
        "replayed_nonce",
        &w1,
        &s1,
        "NonceAlreadyUsed",
    ));

    let w2 = intent(RECIPIENT, eth, ETHER / 2, 2, DEADLINE);
    let s2 = sign(&mut net, &current, &CustodyAction::Withdrawal(w2.clone()))?;
    let mut s2_r = s2;
    s2_r.r_address[0] ^= 0x80;
    before.push(withdrawal_case(
        "tampered_r",
        &w2,
        &s2_r,
        "InvalidSignature",
    ));
    before.push(withdrawal_case(
        "tampered_z",
        &w2,
        &EvmSignature {
            z: add_one(&s2.z)?,
            ..s2
        },
        "InvalidSignature",
    ));
    let w2_edited = intent(RECIPIENT, eth, ETHER, 2, DEADLINE);
    before.push(withdrawal_case(
        "wrong_message",
        &w2_edited,
        &s2,
        "InvalidSignature",
    ));

    let w3 = intent(RECIPIENT, TOKEN, 250_000, 3, DEADLINE);
    let s3 = sign(&mut net, &current, &CustodyAction::Withdrawal(w3.clone()))?;
    before.push(withdrawal_case("valid_token", &w3, &s3, "ok"));

    let w4 = intent(RECIPIENT, eth, ETHER / 4, 4, DEADLINE);
    let s4 = sign(&mut net, &next, &CustodyAction::Withdrawal(w4.clone()))?;
    before.push(withdrawal_case(
        "signed_by_foreign_group",
        &w4,
        &s4,
        "InvalidSignature",
    ));

    let w5 = intent(RECIPIENT, eth, 9 * ETHER / 2, 5, DEADLINE);
    let s5 = sign(&mut net, &current, &CustodyAction::Withdrawal(w5.clone()))?;
    before.push(withdrawal_case(
        "over_daily_limit",
        &w5,
        &s5,
        "DailyLimitExceeded",
    ));

    let w6 = intent(RECIPIENT, eth, 1, 6, NOW - 1);
    let s6 = sign(&mut net, &current, &CustodyAction::Withdrawal(w6.clone()))?;
    before.push(withdrawal_case("expired", &w6, &s6, "IntentExpired"));

    // --- rotation (current key authorises, new key proves possession) ---------
    let rotation = rotation_to(&next.evm, U256::from(10), U256::from(DEADLINE));
    let rotation_action = CustodyAction::KeyRotation(rotation.clone());
    let by_current = sign(&mut net, &current, &rotation_action)?;
    let by_next = sign(&mut net, &next, &rotation_action)?;

    // --- after rotation --------------------------------------------------------
    let mut after = Vec::new();
    let w11 = intent(RECIPIENT, eth, ETHER, 11, DEADLINE);
    let s11 = sign(&mut net, &next, &CustodyAction::Withdrawal(w11.clone()))?;
    after.push(withdrawal_case("new_group_withdrawal", &w11, &s11, "ok"));
    let w12 = intent(RECIPIENT, eth, ETHER, 12, DEADLINE);
    let s12 = sign(&mut net, &current, &CustodyAction::Withdrawal(w12.clone()))?;
    after.push(withdrawal_case(
        "stale_group_withdrawal",
        &w12,
        &s12,
        "InvalidSignature",
    ));

    let limit = DailyLimitUpdate {
        token: eth,
        newLimit: U256::from(ETHER),
        nonce: U256::from(20),
        deadline: U256::from(DEADLINE),
    };
    let limit_action = CustodyAction::DailyLimitUpdate(limit.clone());
    let limit_sig = sign(&mut net, &next, &limit_action)?;
    let guardian = GuardianUpdate {
        newGuardian: address!("000000000000000000000000000000000000cafe"),
        nonce: U256::from(21),
        deadline: U256::from(DEADLINE),
    };
    let guardian_action = CustodyAction::GuardianUpdate(guardian.clone());
    let guardian_sig = sign(&mut net, &next, &guardian_action)?;

    Ok(json!({
        "description": "Generated by `cargo run -p fixtures-gen`; do not edit. Signatures come from a real Pedersen DKG and two-round FROST signing (FROST(secp256k1, KECCAK-256)).",
        "seed": format!("{SEED:#x}"),
        "chainId": CHAIN_ID,
        "vault": hex0x(VAULT.as_slice()),
        "token": hex0x(TOKEN.as_slice()),
        "recipient": hex0x(RECIPIENT.as_slice()),
        "now": NOW,
        "threshold": THRESHOLD,
        "participants": PARTICIPANTS,
        "limits": { "eth": word(U256::from(5 * ETHER)), "token": word(U256::from(500_000u64)) },
        "group": { "pubKeyX": hex0x(&current.evm.x), "pubKeyYParity": current.evm.y_parity, "compressed": hex0x(&current.key) },
        "nextGroup": { "pubKeyX": hex0x(&next.evm.x), "pubKeyYParity": next.evm.y_parity, "compressed": hex0x(&next.key) },
        "verifierCaseCount": verifier.len(),
        "verifierCases": verifier,
        "beforeRotationCount": before.len(),
        "beforeRotation": before,
        "rotation": {
            "newPubKeyX": word(rotation.newPubKeyX),
            "newPubKeyYParity": rotation.newPubKeyYParity,
            "nonce": word(rotation.nonce),
            "deadline": word(rotation.deadline),
            "digest": hex0x(&rotation_action.signing_hash(&domain())),
            "currentKey": { "rAddr": hex0x(&by_current.r_address), "z": hex0x(&by_current.z) },
            "newKey": { "rAddr": hex0x(&by_next.r_address), "z": hex0x(&by_next.z) },
        },
        "afterRotationCount": after.len(),
        "afterRotation": after,
        "dailyLimitUpdate": {
            "token": hex0x(limit.token.as_slice()),
            "newLimit": word(limit.newLimit),
            "nonce": word(limit.nonce),
            "deadline": word(limit.deadline),
            "digest": hex0x(&limit_action.signing_hash(&domain())),
            "rAddr": hex0x(&limit_sig.r_address),
            "z": hex0x(&limit_sig.z),
        },
        "guardianUpdate": {
            "newGuardian": hex0x(guardian.newGuardian.as_slice()),
            "nonce": word(guardian.nonce),
            "deadline": word(guardian.deadline),
            "digest": hex0x(&guardian_action.signing_hash(&domain())),
            "rAddr": hex0x(&guardian_sig.r_address),
            "z": hex0x(&guardian_sig.z),
        },
    }))
}

/// Renders the fixtures exactly as they are committed (pretty JSON, LF, final newline).
pub fn render() -> Result<String, FixtureError> {
    let value = generate()?;
    let mut text = serde_json::to_string_pretty(&value).map_err(|e| FixtureError(e.to_string()))?;
    text.push('\n');
    Ok(text)
}
