// SPDX-License-Identifier: MIT
//! Web3 Secret Storage Definition, version 3 (the geth / Foundry `keystore` JSON format).
//!
//! ```text
//! derived    = scrypt(password, salt, n, r, p, dklen = 32)       (or PBKDF2-HMAC-SHA256)
//! ciphertext = AES-128-CTR(key = derived[0..16], iv, secret)
//! mac        = keccak256(derived[16..32] ‖ ciphertext)
//! ```
//!
//! Import accepts `scrypt` and `pbkdf2` (hmac-sha256) keystores, including the capitalised
//! `Crypto` key some older wallets emit. Export always uses scrypt. KDF parameters come from an
//! untrusted file, so [`KdfLimits`] caps memory and work *before* anything is allocated: a
//! hostile keystore with `n = 2^30` is rejected instead of exhausting the air-gapped machine.
//! The MAC is compared in constant time and decrypted material lives in zeroising buffers.

use crate::address::Address;
use crate::hash::keccak256_concat;
use crate::hex;
use crate::keys::PrivateKey;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use ctr::cipher::{KeyIvInit, StreamCipher};
use serde::Deserialize;
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

type Aes128Ctr = ctr::Ctr128BE<aes::Aes128>;

/// Errors produced while reading or writing keystores. None of them contain key material.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum KeystoreError {
    /// Malformed JSON or missing fields.
    #[error("invalid keystore JSON: {0}")]
    InvalidJson(String),
    /// `version` is not 3.
    #[error("unsupported keystore version {0} (expected 3)")]
    UnsupportedVersion(u64),
    /// Cipher other than `aes-128-ctr`.
    #[error("unsupported cipher `{0}`")]
    UnsupportedCipher(String),
    /// KDF other than `scrypt` / `pbkdf2`.
    #[error("unsupported kdf `{0}`")]
    UnsupportedKdf(String),
    /// Invalid KDF parameters.
    #[error("invalid kdf parameters: {0}")]
    InvalidKdfParams(&'static str),
    /// KDF parameters exceed the configured limits.
    #[error("kdf parameters exceed limits: {0}")]
    KdfTooExpensive(String),
    /// MAC mismatch: wrong password or corrupted file.
    #[error("MAC mismatch: wrong password or corrupted keystore")]
    WrongPassword,
    /// The decrypted bytes are not a valid secp256k1 key.
    #[error("decrypted key is not a valid secp256k1 scalar")]
    InvalidKey,
    /// The `address` field disagrees with the decrypted key.
    #[error("keystore address field {declared} does not match the decrypted key {actual}")]
    AddressMismatch {
        /// Address declared in the file.
        declared: Address,
        /// Address of the decrypted key.
        actual: Address,
    },
}

/// scrypt cost parameters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScryptParams {
    /// log2(N).
    pub log_n: u8,
    /// Block size `r`.
    pub r: u32,
    /// Parallelism `p`.
    pub p: u32,
}

impl ScryptParams {
    /// geth `StandardScryptN = 1 << 18`, `StandardScryptP = 1` (256 MiB, ~1 s).
    pub const STANDARD: Self = Self {
        log_n: 18,
        r: 8,
        p: 1,
    };
    /// geth `LightScryptN = 1 << 12`, `LightScryptP = 6` (4 MiB; tests and constrained devices).
    pub const LIGHT: Self = Self {
        log_n: 12,
        r: 8,
        p: 6,
    };

    fn memory_bytes(&self) -> u128 {
        128 * u128::from(self.r) * (1u128 << self.log_n)
    }
}

/// Upper bounds applied to KDF parameters read from untrusted keystores.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KdfLimits {
    /// Maximum scrypt memory `128 * r * N` in bytes.
    pub max_scrypt_memory: u64,
    /// Maximum scrypt `p`.
    pub max_scrypt_p: u32,
    /// Maximum PBKDF2 iteration count.
    pub max_pbkdf2_iterations: u32,
}

impl Default for KdfLimits {
    /// 1 GiB of scrypt memory (N = 2^20 at r = 8), p <= 16, PBKDF2 <= 10^7 iterations.
    fn default() -> Self {
        Self {
            max_scrypt_memory: 1 << 30,
            max_scrypt_p: 16,
            max_pbkdf2_iterations: 10_000_000,
        }
    }
}

/// Caller-supplied randomness for [`encrypt`] (the core crate has no RNG).
#[derive(Clone)]
pub struct KeystoreRandomness {
    /// scrypt salt.
    pub salt: [u8; 32],
    /// AES-CTR initial counter block.
    pub iv: [u8; 16],
    /// Bytes for the version-4 UUID `id`.
    pub uuid: [u8; 16],
}

fn format_uuid(bytes: [u8; 16]) -> String {
    let mut b = bytes;
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
    let h = hex::encode(&b);
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}

fn derive_scrypt(
    password: &[u8],
    salt: &[u8],
    p: &ScryptParams,
) -> Result<Zeroizing<[u8; 32]>, KeystoreError> {
    let params = scrypt::Params::new(p.log_n, p.r, p.p, 32)
        .map_err(|_| KeystoreError::InvalidKdfParams("scrypt parameters rejected"))?;
    let mut out = Zeroizing::new([0u8; 32]);
    scrypt::scrypt(password, salt, &params, out.as_mut())
        .map_err(|_| KeystoreError::InvalidKdfParams("scrypt output length"))?;
    Ok(out)
}

fn mac(derived: &[u8; 32], ciphertext: &[u8]) -> [u8; 32] {
    keccak256_concat(&[&derived[16..32], ciphertext])
}

fn aes_ctr(derived: &[u8; 32], iv: &[u8; 16], data: &mut [u8]) {
    let mut key = Zeroizing::new([0u8; 16]);
    key.copy_from_slice(&derived[..16]);
    let mut cipher = Aes128Ctr::new(key.as_ref().into(), iv.into());
    cipher.apply_keystream(data);
}

/// Encrypts `key` into a version-3 keystore JSON document (scrypt + AES-128-CTR).
pub fn encrypt(
    key: &PrivateKey,
    password: &[u8],
    params: ScryptParams,
    randomness: &KeystoreRandomness,
) -> Result<String, KeystoreError> {
    let derived = derive_scrypt(password, &randomness.salt, &params)?;
    let mut ciphertext = Zeroizing::new(*key.to_bytes());
    aes_ctr(&derived, &randomness.iv, ciphertext.as_mut());
    let mac = mac(&derived, ciphertext.as_ref());
    let doc = serde_json::json!({
        "version": 3,
        "id": format_uuid(randomness.uuid),
        "address": hex::encode(&key.address().0),
        "crypto": {
            "cipher": "aes-128-ctr",
            "cipherparams": { "iv": hex::encode(&randomness.iv) },
            "ciphertext": hex::encode(ciphertext.as_ref()),
            "kdf": "scrypt",
            "kdfparams": {
                "dklen": 32,
                "n": 1u64 << params.log_n,
                "p": params.p,
                "r": params.r,
                "salt": hex::encode(&randomness.salt)
            },
            "mac": hex::encode(&mac)
        }
    });
    serde_json::to_string_pretty(&doc).map_err(|e| KeystoreError::InvalidJson(e.to_string()))
}

#[derive(Deserialize)]
struct RawKeystore {
    version: u64,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    address: Option<String>,
    #[serde(alias = "Crypto")]
    crypto: RawCrypto,
}

#[derive(Deserialize)]
struct RawCrypto {
    cipher: String,
    cipherparams: RawCipherParams,
    ciphertext: String,
    kdf: String,
    kdfparams: serde_json::Value,
    mac: String,
}

#[derive(Deserialize)]
struct RawCipherParams {
    iv: String,
}

#[derive(Deserialize)]
struct RawScrypt {
    dklen: u32,
    n: u64,
    r: u32,
    p: u32,
    salt: String,
}

#[derive(Deserialize)]
struct RawPbkdf2 {
    dklen: u32,
    c: u32,
    prf: String,
    salt: String,
}

/// KDF description of a keystore, for display.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase", tag = "kdf")]
pub enum KdfInfo {
    /// scrypt.
    #[serde(rename = "scrypt")]
    Scrypt {
        /// CPU/memory cost N.
        n: u64,
        /// Block size.
        r: u32,
        /// Parallelism.
        p: u32,
    },
    /// PBKDF2-HMAC-SHA256.
    #[serde(rename = "pbkdf2")]
    Pbkdf2 {
        /// Iteration count.
        c: u32,
    },
}

/// Non-secret facts about a keystore file.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeystoreInfo {
    /// Declared address, if present.
    pub address: Option<Address>,
    /// UUID, if present.
    pub id: Option<String>,
    /// KDF and cost parameters.
    pub kdf: KdfInfo,
}

enum Kdf {
    Scrypt(ScryptParams, Vec<u8>),
    Pbkdf2(u32, Vec<u8>),
}

fn bad_hex(field: &'static str) -> impl Fn(hex::HexError) -> KeystoreError {
    move |_| KeystoreError::InvalidJson(format!("`{field}` is not valid hex"))
}

fn parse(json: &str) -> Result<(RawKeystore, Kdf), KeystoreError> {
    let raw: RawKeystore =
        serde_json::from_str(json).map_err(|e| KeystoreError::InvalidJson(e.to_string()))?;
    if raw.version != 3 {
        return Err(KeystoreError::UnsupportedVersion(raw.version));
    }
    if raw.crypto.cipher != "aes-128-ctr" {
        return Err(KeystoreError::UnsupportedCipher(raw.crypto.cipher.clone()));
    }
    let kdf = match raw.crypto.kdf.as_str() {
        "scrypt" => {
            let s: RawScrypt = serde_json::from_value(raw.crypto.kdfparams.clone())
                .map_err(|e| KeystoreError::InvalidJson(e.to_string()))?;
            if s.dklen != 32 {
                return Err(KeystoreError::InvalidKdfParams("dklen must be 32"));
            }
            if s.n < 2 || !s.n.is_power_of_two() {
                return Err(KeystoreError::InvalidKdfParams(
                    "scrypt n must be a power of two >= 2",
                ));
            }
            // n is a power of two below 2^64, so trailing_zeros < 64 fits in u8.
            let params = ScryptParams {
                log_n: s.n.trailing_zeros() as u8,
                r: s.r,
                p: s.p,
            };
            if s.r == 0 || s.p == 0 {
                return Err(KeystoreError::InvalidKdfParams(
                    "scrypt r and p must be positive",
                ));
            }
            Kdf::Scrypt(params, hex::decode(&s.salt).map_err(bad_hex("salt"))?)
        }
        "pbkdf2" => {
            let p: RawPbkdf2 = serde_json::from_value(raw.crypto.kdfparams.clone())
                .map_err(|e| KeystoreError::InvalidJson(e.to_string()))?;
            if p.dklen != 32 {
                return Err(KeystoreError::InvalidKdfParams("dklen must be 32"));
            }
            if p.prf != "hmac-sha256" {
                return Err(KeystoreError::UnsupportedKdf(format!("pbkdf2/{}", p.prf)));
            }
            if p.c == 0 {
                return Err(KeystoreError::InvalidKdfParams("pbkdf2 c must be positive"));
            }
            Kdf::Pbkdf2(p.c, hex::decode(&p.salt).map_err(bad_hex("salt"))?)
        }
        other => return Err(KeystoreError::UnsupportedKdf(other.to_string())),
    };
    Ok((raw, kdf))
}

fn declared_address(raw: &RawKeystore) -> Result<Option<Address>, KeystoreError> {
    raw.address
        .as_deref()
        .map(|a| {
            Address::parse(a)
                .map_err(|_| KeystoreError::InvalidJson("`address` is not an address".into()))
        })
        .transpose()
}

/// Reads the non-secret metadata of a keystore (no password needed).
pub fn inspect(json: &str) -> Result<KeystoreInfo, KeystoreError> {
    let (raw, kdf) = parse(json)?;
    let kdf = match kdf {
        Kdf::Scrypt(p, _) => KdfInfo::Scrypt {
            n: 1u64 << p.log_n,
            r: p.r,
            p: p.p,
        },
        Kdf::Pbkdf2(c, _) => KdfInfo::Pbkdf2 { c },
    };
    Ok(KeystoreInfo {
        address: declared_address(&raw)?,
        id: raw.id,
        kdf,
    })
}

/// Decrypts a version-3 keystore.
pub fn decrypt(
    json: &str,
    password: &[u8],
    limits: &KdfLimits,
) -> Result<PrivateKey, KeystoreError> {
    let (raw, kdf) = parse(json)?;
    let iv: [u8; 16] = hex::decode_array(&raw.crypto.cipherparams.iv).map_err(bad_hex("iv"))?;
    let ciphertext =
        Zeroizing::new(hex::decode(&raw.crypto.ciphertext).map_err(bad_hex("ciphertext"))?);
    if ciphertext.len() != 32 {
        return Err(KeystoreError::InvalidJson(
            "ciphertext must be 32 bytes".into(),
        ));
    }
    let expected_mac: [u8; 32] = hex::decode_array(&raw.crypto.mac).map_err(bad_hex("mac"))?;
    let derived = match kdf {
        Kdf::Scrypt(params, salt) => {
            let memory = params.memory_bytes();
            if memory > u128::from(limits.max_scrypt_memory) {
                return Err(KeystoreError::KdfTooExpensive(format!(
                    "scrypt needs {memory} bytes, limit {}",
                    limits.max_scrypt_memory
                )));
            }
            if params.p > limits.max_scrypt_p {
                return Err(KeystoreError::KdfTooExpensive(format!(
                    "scrypt p = {}, limit {}",
                    params.p, limits.max_scrypt_p
                )));
            }
            derive_scrypt(password, &salt, &params)?
        }
        Kdf::Pbkdf2(c, salt) => {
            if c > limits.max_pbkdf2_iterations {
                return Err(KeystoreError::KdfTooExpensive(format!(
                    "pbkdf2 c = {c}, limit {}",
                    limits.max_pbkdf2_iterations
                )));
            }
            let mut out = Zeroizing::new([0u8; 32]);
            pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password, &salt, c, out.as_mut());
            out
        }
    };
    let actual_mac = mac(&derived, &ciphertext);
    if !bool::from(actual_mac.ct_eq(&expected_mac)) {
        return Err(KeystoreError::WrongPassword);
    }
    let mut secret = Zeroizing::new([0u8; 32]);
    secret.copy_from_slice(&ciphertext);
    aes_ctr(&derived, &iv, secret.as_mut());
    let key = PrivateKey::from_bytes(&secret).map_err(|_| KeystoreError::InvalidKey)?;
    if let Some(declared) = declared_address(&raw)? {
        let actual = key.address();
        if declared != actual {
            return Err(KeystoreError::AddressMismatch { declared, actual });
        }
    }
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test vectors from the Web3 Secret Storage Definition (password "testpassword").
    const SPEC_PBKDF2: &str = r#"{
        "crypto": {
            "cipher": "aes-128-ctr",
            "cipherparams": {"iv": "6087dab2f9fdbbfaddc31a909735c1e6"},
            "ciphertext": "5318b4d5bcd28de64ee5559e671353e16f075ecae9f99c7a79a38af5f869aa46",
            "kdf": "pbkdf2",
            "kdfparams": {"c": 262144, "dklen": 32, "prf": "hmac-sha256",
                          "salt": "ae3cd4e7013836a3df6bd7241b12db061dbe2c6785853cce422d148a624ce0bd"},
            "mac": "517ead924a9d0dc3124507e3393d175ce3ff7c1e96529c6c555ce9e51205e9b2"
        },
        "id": "3198bc9c-6672-5ab3-d995-4942343ae5b6",
        "version": 3
    }"#;

    const SPEC_SCRYPT: &str = r#"{
        "crypto": {
            "cipher": "aes-128-ctr",
            "cipherparams": {"iv": "740770fce12ce862af21264dab25f1da"},
            "ciphertext": "dd8a1132cf57db67c038c6763afe2cbe6ea1949a86abc5843f8ca656ebbb1ea2",
            "kdf": "scrypt",
            "kdfparams": {"dklen": 32, "n": 262144, "p": 1, "r": 8,
                          "salt": "25710c2ccd7c610b24d068af83b959b7a0e5f40641f0c82daeb1345766191034"},
            "mac": "337aeb86505d2d0bb620effe57f18381377d67d76dac1090626aa5cd20886a7c"
        },
        "id": "3198bc9c-6672-5ab3-d995-4942343ae5b6",
        "version": 3
    }"#;

    const SPEC_KEY: &str = "7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d";

    #[test]
    fn specification_pbkdf2_vector() {
        let limits = KdfLimits::default();
        let k = decrypt(SPEC_PBKDF2, b"testpassword", &limits).unwrap();
        assert_eq!(hex::encode(k.to_bytes().as_ref()), SPEC_KEY);
        assert_eq!(
            decrypt(SPEC_PBKDF2, b"wrong", &limits).map(|_| ()),
            Err(KeystoreError::WrongPassword)
        );
        // Some older wallets capitalise the `Crypto` key.
        let capitalised = SPEC_PBKDF2.replace("\"crypto\"", "\"Crypto\"");
        assert!(decrypt(&capitalised, b"testpassword", &limits).is_ok());
    }

    /// Known answer for the scrypt KDF with the spec's salt and parameters (N = 2^18, r = 8,
    /// p = 1), computed independently with OpenSSL (`hashlib.scrypt`, Python 3.12).
    #[test]
    fn scrypt_kdf_known_answer() {
        let salt = hex::decode("25710c2ccd7c610b24d068af83b959b7a0e5f40641f0c82daeb1345766191034")
            .unwrap();
        let derived = derive_scrypt(b"testpassword", &salt, &ScryptParams::STANDARD).unwrap();
        assert_eq!(
            hex::encode(derived.as_ref()),
            "b4130dc81619f55f01a84b16c68f54fc0a166a2ca5903d9b24d2262dbd0420ec"
        );
    }

    /// The published scrypt vector lists derived key 7446f59e... and a MAC consistent with it,
    /// but scrypt over its stated salt and parameters yields b4130dc8... (see the known-answer
    /// test above; OpenSSL agrees). The file therefore fails its MAC check here exactly as it
    /// does in `cast wallet decrypt-keystore` 1.8.3 ("Mac Mismatch").
    #[test]
    fn published_scrypt_vector_is_internally_inconsistent() {
        assert_eq!(
            decrypt(SPEC_SCRYPT, b"testpassword", &KdfLimits::default()).map(|_| ()),
            Err(KeystoreError::WrongPassword)
        );
    }

    fn rnd() -> KeystoreRandomness {
        KeystoreRandomness {
            salt: [1; 32],
            iv: [2; 16],
            uuid: [3; 16],
        }
    }

    #[test]
    fn round_trip_inspect_and_tamper() {
        let key = PrivateKey::from_bytes(&[9; 32]).unwrap();
        let json = encrypt(&key, b"pw", ScryptParams::LIGHT, &rnd()).unwrap();
        assert!(!json.contains(&hex::encode(key.to_bytes().as_ref())));
        let back = decrypt(&json, b"pw", &KdfLimits::default()).unwrap();
        assert_eq!(back.address(), key.address());
        let info = inspect(&json).unwrap();
        assert_eq!(info.address, Some(key.address()));
        assert_eq!(
            info.kdf,
            KdfInfo::Scrypt {
                n: 4096,
                r: 8,
                p: 6
            }
        );
        assert_eq!(
            info.id.as_deref(),
            Some("03030303-0303-4303-8303-030303030303")
        );
        // Tampered address field is detected after decryption.
        let other = PrivateKey::from_bytes(&[8; 32]).unwrap();
        let tampered = json.replace(
            &hex::encode(&key.address().0),
            &hex::encode(&other.address().0),
        );
        assert!(matches!(
            decrypt(&tampered, b"pw", &KdfLimits::default()),
            Err(KeystoreError::AddressMismatch { .. })
        ));
    }

    #[test]
    fn hostile_parameters_are_rejected_before_work() {
        let key = PrivateKey::from_bytes(&[9; 32]).unwrap();
        let json = encrypt(&key, b"pw", ScryptParams::LIGHT, &rnd()).unwrap();
        let huge = json.replace("\"n\": 4096", "\"n\": 1073741824");
        assert!(matches!(
            decrypt(&huge, b"pw", &KdfLimits::default()),
            Err(KeystoreError::KdfTooExpensive(_))
        ));
        let p = json.replace("\"p\": 6", "\"p\": 64");
        assert!(matches!(
            decrypt(&p, b"pw", &KdfLimits::default()),
            Err(KeystoreError::KdfTooExpensive(_))
        ));
        let not_pow2 = json.replace("\"n\": 4096", "\"n\": 4095");
        assert!(matches!(
            decrypt(&not_pow2, b"pw", &KdfLimits::default()),
            Err(KeystoreError::InvalidKdfParams(_))
        ));
        let dklen = json.replace("\"dklen\": 32", "\"dklen\": 16");
        assert!(matches!(
            decrypt(&dklen, b"pw", &KdfLimits::default()),
            Err(KeystoreError::InvalidKdfParams(_))
        ));
        let pb = SPEC_PBKDF2.replace("262144", "20000000");
        assert!(matches!(
            decrypt(&pb, b"testpassword", &KdfLimits::default()),
            Err(KeystoreError::KdfTooExpensive(_))
        ));
        let prf = SPEC_PBKDF2.replace("hmac-sha256", "hmac-sha512");
        assert!(matches!(
            decrypt(&prf, b"testpassword", &KdfLimits::default()),
            Err(KeystoreError::UnsupportedKdf(_))
        ));
        assert!(matches!(
            decrypt(
                &json.replace("aes-128-ctr", "aes-256-gcm"),
                b"pw",
                &KdfLimits::default()
            ),
            Err(KeystoreError::UnsupportedCipher(_))
        ));
        assert!(matches!(
            decrypt(
                &json.replace("\"version\": 3", "\"version\": 4"),
                b"pw",
                &KdfLimits::default()
            ),
            Err(KeystoreError::UnsupportedVersion(4))
        ));
        assert!(matches!(
            decrypt(
                &json.replace("\"kdf\": \"scrypt\"", "\"kdf\": \"argon2\""),
                b"pw",
                &KdfLimits::default()
            ),
            Err(KeystoreError::UnsupportedKdf(_))
        ));
        assert!(matches!(
            decrypt("{}", b"pw", &KdfLimits::default()),
            Err(KeystoreError::InvalidJson(_))
        ));
    }
}
