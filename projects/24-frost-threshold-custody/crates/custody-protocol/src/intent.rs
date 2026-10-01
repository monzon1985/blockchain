// SPDX-License-Identifier: MIT
//! EIP-712 custody actions, byte-for-byte compatible with `SchnorrVault.sol`.
//!
//! Signers never sign an opaque hash handed to them by the coordinator: they
//! receive the structured action, check it against their local
//! [`SignerPolicy`] (pinned vault, caps, allowlists and, if configured, an
//! operator's [`Approval`]) and compute the EIP-712 digest themselves.

use std::collections::BTreeSet;

use alloy_primitives::{Address, U256};
use alloy_sol_types::{Eip712Domain, SolStruct, sol};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};

use crate::error::ProtocolError;
use crate::identity::signing_input;
use crate::ids::hexbytes;

sol! {
    /// Moves `amount` of `token` (address(0) = ETH) to `to`.
    #[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
    struct WithdrawalIntent {
        address to;
        address token;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    /// Replaces the vault's group key (signed by the current and the new key).
    #[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
    struct KeyRotation {
        uint256 newPubKeyX;
        uint8 newPubKeyYParity;
        uint256 nonce;
        uint256 deadline;
    }

    /// Changes a token's daily limit.
    #[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
    struct DailyLimitUpdate {
        address token;
        uint256 newLimit;
        uint256 nonce;
        uint256 deadline;
    }

    /// Replaces the vault guardian.
    #[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
    struct GuardianUpdate {
        address newGuardian;
        uint256 nonce;
        uint256 deadline;
    }
}

/// EIP-712 domain name of the vault.
pub const VAULT_NAME: &str = "SchnorrVault";
/// EIP-712 domain version of the vault.
pub const VAULT_VERSION: &str = "1";

/// The vault instance a signature is bound to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VaultDomain {
    /// EIP-155 chain id.
    pub chain_id: u64,
    /// Vault contract address.
    pub vault: Address,
}

impl VaultDomain {
    /// The EIP-712 domain (`name`, `version`, `chainId`, `verifyingContract`).
    #[must_use]
    pub fn eip712(&self) -> Eip712Domain {
        Eip712Domain::new(
            Some(VAULT_NAME.into()),
            Some(VAULT_VERSION.into()),
            Some(U256::from(self.chain_id)),
            Some(self.vault),
            None,
        )
    }
}

/// Any action the group can authorise on the vault.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "intent", rename_all = "snake_case")]
pub enum CustodyAction {
    /// Withdrawal of funds.
    Withdrawal(WithdrawalIntent),
    /// Group key rotation.
    KeyRotation(KeyRotation),
    /// Daily limit change.
    DailyLimitUpdate(DailyLimitUpdate),
    /// Guardian replacement.
    GuardianUpdate(GuardianUpdate),
}

impl CustodyAction {
    /// The EIP-712 digest the vault verifies.
    #[must_use]
    pub fn signing_hash(&self, domain: &VaultDomain) -> [u8; 32] {
        let domain = domain.eip712();
        let hash = match self {
            Self::Withdrawal(i) => i.eip712_signing_hash(&domain),
            Self::KeyRotation(i) => i.eip712_signing_hash(&domain),
            Self::DailyLimitUpdate(i) => i.eip712_signing_hash(&domain),
            Self::GuardianUpdate(i) => i.eip712_signing_hash(&domain),
        };
        hash.0
    }

    /// The vault nonce the action consumes.
    #[must_use]
    pub fn nonce(&self) -> U256 {
        match self {
            Self::Withdrawal(i) => i.nonce,
            Self::KeyRotation(i) => i.nonce,
            Self::DailyLimitUpdate(i) => i.nonce,
            Self::GuardianUpdate(i) => i.nonce,
        }
    }

    /// Short label for logs.
    #[must_use]
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Withdrawal(_) => "withdrawal",
            Self::KeyRotation(_) => "key_rotation",
            Self::DailyLimitUpdate(_) => "daily_limit_update",
            Self::GuardianUpdate(_) => "guardian_update",
        }
    }
}

/// Domain separator of operator approvals.
pub const APPROVAL_DOMAIN: &[u8] = b"frost-custody/v1/approval";

/// An operator's ed25519 signature over the EIP-712 digest of an action.
///
/// The digest already binds the vault address and the chain id, so an
/// approval cannot be moved to another vault, chain, action or nonce.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Approval {
    /// ed25519 signature over `APPROVAL_DOMAIN || 0 || digest`.
    #[serde(with = "hexbytes")]
    pub signature: [u8; 64],
}

impl Approval {
    /// Approves `action` on `domain` with the operator's key.
    #[must_use]
    pub fn sign(key: &SigningKey, action: &CustodyAction, domain: &VaultDomain) -> Self {
        let message = signing_input(APPROVAL_DOMAIN, &action.signing_hash(domain));
        Self {
            signature: key.sign(&message).to_bytes(),
        }
    }

    /// Checks the approval against the operator's public key (strict ed25519).
    pub fn verify(
        &self,
        approver: &[u8; 32],
        action: &CustodyAction,
        domain: &VaultDomain,
    ) -> Result<(), ProtocolError> {
        let key = VerifyingKey::from_bytes(approver)
            .map_err(|_| ProtocolError::PolicyViolation("invalid approver key".into()))?;
        let message = signing_input(APPROVAL_DOMAIN, &action.signing_hash(domain));
        key.verify_strict(&message, &Signature::from_bytes(&self.signature))
            .map_err(|_| ProtocolError::PolicyViolation("approval does not verify".into()))
    }
}

/// A signer's local rules. The coordinator cannot override them.
///
/// Every field except `domain` is optional. With `approver` set, the signer
/// takes part only in actions that an operator key, independent of the
/// coordinator, signed off; without it, whoever runs the coordinator decides
/// which in-policy actions are requested (threat model, T4).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignerPolicy {
    /// Only this vault on this chain may be targeted.
    pub domain: VaultDomain,
    /// Upper bound on a single withdrawal, if any.
    pub max_withdrawal: Option<U256>,
    /// Whether this signer takes part in key rotations.
    pub allow_key_rotation: bool,
    /// ed25519 key of an operator whose [`Approval`] every request must carry.
    #[serde(default, with = "hex_option")]
    pub approver: Option<[u8; 32]>,
    /// Withdrawals may only pay these recipients, if set.
    #[serde(default)]
    pub allowed_recipients: Option<BTreeSet<Address>>,
    /// Upper bound on a daily limit the signer agrees to set, if any.
    #[serde(default)]
    pub max_daily_limit: Option<U256>,
    /// Guardian replacements may only name these addresses, if set.
    #[serde(default)]
    pub allowed_guardians: Option<BTreeSet<Address>>,
}

impl SignerPolicy {
    /// A policy pinned to `domain` with no other restriction and no approver:
    /// the coordinator's operator decides what is signed within the vault's
    /// on-chain limits. Used by the demos and tests.
    #[must_use]
    pub fn permissive(domain: VaultDomain) -> Self {
        Self {
            domain,
            max_withdrawal: None,
            allow_key_rotation: true,
            approver: None,
            allowed_recipients: None,
            max_daily_limit: None,
            allowed_guardians: None,
        }
    }

    /// Checks an action against the policy. The rule that depends on the key
    /// shares a signer holds (the rotation target) is enforced by
    /// [`crate::signing::SignerState`].
    pub fn check(
        &self,
        action: &CustodyAction,
        domain: &VaultDomain,
        approval: Option<&Approval>,
    ) -> Result<(), ProtocolError> {
        if *domain != self.domain {
            return Err(ProtocolError::PolicyViolation(format!(
                "domain {}@{} is not the pinned vault {}@{}",
                domain.vault, domain.chain_id, self.domain.vault, self.domain.chain_id
            )));
        }
        match action {
            CustodyAction::Withdrawal(w) => {
                if w.to == Address::ZERO {
                    return Err(ProtocolError::PolicyViolation(
                        "withdrawal to address(0)".into(),
                    ));
                }
                if w.amount.is_zero() {
                    return Err(ProtocolError::PolicyViolation(
                        "zero-amount withdrawal".into(),
                    ));
                }
                if let Some(max) = self.max_withdrawal
                    && w.amount > max
                {
                    return Err(ProtocolError::PolicyViolation(format!(
                        "amount {} exceeds the per-signer cap {max}",
                        w.amount
                    )));
                }
                if let Some(allowed) = &self.allowed_recipients
                    && !allowed.contains(&w.to)
                {
                    return Err(ProtocolError::PolicyViolation(format!(
                        "recipient {} is not on the allowlist",
                        w.to
                    )));
                }
            }
            CustodyAction::KeyRotation(r) => {
                if !self.allow_key_rotation {
                    return Err(ProtocolError::PolicyViolation(
                        "key rotation disabled for this signer".into(),
                    ));
                }
                let x: [u8; 32] = r.newPubKeyX.to_be_bytes();
                if r.newPubKeyYParity > 1 || !frost_keccak::evm::is_valid_scalar_word(&x) {
                    return Err(ProtocolError::PolicyViolation(
                        "rotation target is not an ecrecover-compatible key".into(),
                    ));
                }
            }
            CustodyAction::DailyLimitUpdate(u) => {
                if let Some(max) = self.max_daily_limit
                    && u.newLimit > max
                {
                    return Err(ProtocolError::PolicyViolation(format!(
                        "daily limit {} exceeds the per-signer cap {max}",
                        u.newLimit
                    )));
                }
            }
            CustodyAction::GuardianUpdate(g) => {
                if g.newGuardian == Address::ZERO {
                    return Err(ProtocolError::PolicyViolation(
                        "guardian cannot be address(0)".into(),
                    ));
                }
                if let Some(allowed) = &self.allowed_guardians
                    && !allowed.contains(&g.newGuardian)
                {
                    return Err(ProtocolError::PolicyViolation(format!(
                        "guardian {} is not on the allowlist",
                        g.newGuardian
                    )));
                }
            }
        }
        if let Some(approver) = &self.approver {
            approval
                .ok_or_else(|| {
                    ProtocolError::PolicyViolation(
                        "the request carries no operator approval".into(),
                    )
                })?
                .verify(approver, action, domain)?;
        }
        Ok(())
    }
}

/// Serde for an optional 32-byte key as a `0x` hex string (or `null`).
mod hex_option {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Option<[u8; 32]>, s: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(bytes) => crate::ids::hexbytes::serialize(bytes, s),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<[u8; 32]>, D::Error> {
        #[derive(Deserialize)]
        struct Wrapped(#[serde(with = "crate::ids::hexbytes")] [u8; 32]);
        Ok(Option::<Wrapped>::deserialize(d)?.map(|Wrapped(bytes)| bytes))
    }
}

/// Builds the rotation intent that moves the vault to `new_key`.
#[must_use]
pub fn rotation_to(
    new_key: &frost_keccak::evm::EvmGroupKey,
    nonce: U256,
    deadline: U256,
) -> KeyRotation {
    KeyRotation {
        newPubKeyX: U256::from_be_bytes(new_key.x),
        newPubKeyYParity: new_key.y_parity,
        nonce,
        deadline,
    }
}
