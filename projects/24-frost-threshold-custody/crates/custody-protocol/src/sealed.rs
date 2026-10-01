// SPDX-License-Identifier: MIT
//! End-to-end encryption of secret protocol material (DKG shares, repair
//! deltas and sigmas) between participants, relayed by the untrusted
//! coordinator.
//!
//! Construction (ECIES-style, one fresh ephemeral key per box):
//!
//! ```text
//! eph        ← X25519 random
//! shared     = X25519(eph, recipient)                 (must be contributory)
//! key        = HKDF-SHA256(ikm = shared, salt = eph_pub || recipient_pub, info = aad)
//! ciphertext = ChaCha20-Poly1305(key, nonce = 0^96, plaintext, aad)
//! aad        = "frost-custody/v1/sealed" || 0 || purpose || 0 || session || from || to
//! ```
//!
//! The all-zero nonce is safe because every key is used for exactly one
//! message (the ephemeral secret is sampled per box and dropped). Binding the
//! session, sender, recipient and purpose into the AAD prevents a box from
//! being replayed into another session or re-addressed by the relay.

use chacha20poly1305::{
    ChaCha20Poly1305, Key, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use hkdf::Hkdf;
use rand_core::{CryptoRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey, StaticSecret};
use zeroize::Zeroizing;

use crate::error::SealError;
use crate::ids::{ParticipantId, Party, SessionId, hexbytes, hexvec};

const SEAL_DOMAIN: &[u8] = b"frost-custody/v1/sealed";

/// What a sealed box is bound to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SealContext<'a> {
    /// Protocol session.
    pub session: SessionId,
    /// Sender.
    pub from: Party,
    /// Recipient.
    pub to: ParticipantId,
    /// Purpose label, e.g. `"dkg-share"`.
    pub purpose: &'a str,
}

impl SealContext<'_> {
    fn aad(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(96);
        out.extend_from_slice(SEAL_DOMAIN);
        out.push(0);
        out.extend_from_slice(self.purpose.as_bytes());
        out.push(0);
        out.extend_from_slice(&self.session.0);
        match self.from {
            Party::Coordinator => out.extend_from_slice(&[0, 0, 0]),
            Party::Participant(p) => {
                out.push(1);
                out.extend_from_slice(&p.get().to_be_bytes());
            }
        }
        out.extend_from_slice(&self.to.get().to_be_bytes());
        out
    }
}

/// An encrypted payload for exactly one recipient.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SealedBox {
    /// Sender's ephemeral X25519 public key.
    #[serde(with = "hexbytes")]
    pub ephemeral_key: [u8; 32],
    /// ChaCha20-Poly1305 ciphertext including the 16-byte tag.
    #[serde(with = "hexvec")]
    pub ciphertext: Vec<u8>,
}

fn derive_key(
    shared: &[u8; 32],
    ephemeral: &PublicKey,
    recipient: &PublicKey,
    aad: &[u8],
) -> Zeroizing<[u8; 32]> {
    let mut salt = [0u8; 64];
    salt[..32].copy_from_slice(ephemeral.as_bytes());
    salt[32..].copy_from_slice(recipient.as_bytes());
    let hk = Hkdf::<Sha256>::new(Some(&salt), shared);
    let mut okm = Zeroizing::new([0u8; 32]);
    // 32 bytes is far below HKDF-SHA256's 8160-byte output limit.
    #[allow(clippy::expect_used)]
    hk.expand(aad, okm.as_mut())
        .expect("32-byte HKDF output is always valid");
    okm
}

/// Encrypts `plaintext` to `recipient` under `context`.
pub fn seal<R: RngCore + CryptoRng>(
    rng: &mut R,
    recipient: &PublicKey,
    context: &SealContext<'_>,
    plaintext: &[u8],
) -> Result<SealedBox, SealError> {
    let ephemeral = EphemeralSecret::random_from_rng(rng);
    let ephemeral_public = PublicKey::from(&ephemeral);
    let shared = ephemeral.diffie_hellman(recipient);
    if !shared.was_contributory() {
        return Err(SealError::NonContributory);
    }
    let aad = context.aad();
    let key = derive_key(shared.as_bytes(), &ephemeral_public, recipient, &aad);
    let cipher = ChaCha20Poly1305::new(&Key::from(*key));
    let ciphertext = cipher
        .encrypt(
            &Nonce::default(),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| SealError::Authentication)?;
    Ok(SealedBox {
        ephemeral_key: ephemeral_public.to_bytes(),
        ciphertext,
    })
}

/// Decrypts a box addressed to the holder of `secret`.
pub fn open(
    secret: &StaticSecret,
    context: &SealContext<'_>,
    sealed: &SealedBox,
) -> Result<Zeroizing<Vec<u8>>, SealError> {
    let ephemeral_public = PublicKey::from(sealed.ephemeral_key);
    let recipient_public = PublicKey::from(secret);
    let shared = secret.diffie_hellman(&ephemeral_public);
    if !shared.was_contributory() {
        return Err(SealError::NonContributory);
    }
    let aad = context.aad();
    let key = derive_key(
        shared.as_bytes(),
        &ephemeral_public,
        &recipient_public,
        &aad,
    );
    let cipher = ChaCha20Poly1305::new(&Key::from(*key));
    cipher
        .decrypt(
            &Nonce::default(),
            Payload {
                msg: &sealed.ciphertext,
                aad: &aad,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| SealError::Authentication)
}
