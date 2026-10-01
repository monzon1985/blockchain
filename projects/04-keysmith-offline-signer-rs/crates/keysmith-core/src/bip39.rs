// SPDX-License-Identifier: MIT
//! BIP-39 mnemonic sentences (English wordlist) and seed derivation.
//!
//! * Entropy of 128-256 bits (multiples of 32) plus a SHA-256 checksum of `ENT/32` bits is
//!   split into 11-bit word indices.
//! * The seed is `PBKDF2-HMAC-SHA512(password = mnemonic, salt = "mnemonic" || NFKD(passphrase),
//!   2048 iterations, 64 bytes)`.
//!
//! Input words are matched case-insensitively and whitespace is collapsed, so the phrase is
//! normalised before hashing; errors name the word *position*, never the word itself.

use crate::hash::sha256;
use alloc::string::String;
use alloc::vec::Vec;
use core::fmt;
use unicode_normalization::UnicodeNormalization;
use zeroize::Zeroizing;

/// The official BIP-39 English wordlist (2048 words, sorted).
pub const ENGLISH_WORDLIST: &str = include_str!("bip39_english.txt");

/// PBKDF2 iteration count fixed by BIP-39.
pub const PBKDF2_ROUNDS: u32 = 2048;

/// Errors produced while generating or parsing mnemonics.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Bip39Error {
    /// Entropy length is not 16, 20, 24, 28 or 32 bytes.
    #[error("entropy must be 16, 20, 24, 28 or 32 bytes, got {0}")]
    InvalidEntropyLength(usize),
    /// Word count is not 12, 15, 18, 21 or 24.
    #[error("mnemonic must have 12, 15, 18, 21 or 24 words, got {0}")]
    InvalidWordCount(usize),
    /// A word is not in the English wordlist.
    #[error("word #{position} is not in the BIP-39 English wordlist")]
    UnknownWord {
        /// One-based position of the offending word.
        position: usize,
    },
    /// The checksum bits do not match the entropy.
    #[error("mnemonic checksum mismatch (a word is wrong or out of order)")]
    InvalidChecksum,
}

fn words() -> Vec<&'static str> {
    ENGLISH_WORDLIST
        .split('\n')
        .map(|w| w.trim_end_matches('\r'))
        .filter(|w| !w.is_empty())
        .collect()
}

/// A validated BIP-39 mnemonic. Phrase and entropy are zeroised on drop; `Debug` is redacted.
#[derive(Clone)]
pub struct Mnemonic {
    phrase: Zeroizing<String>,
    entropy: Zeroizing<Vec<u8>>,
}

/// A 64-byte BIP-39 seed. Zeroised on drop; `Debug` is redacted.
#[derive(Clone)]
pub struct Seed(Zeroizing<[u8; 64]>);

impl Seed {
    /// The raw seed bytes.
    pub fn as_bytes(&self) -> &[u8; 64] {
        &self.0
    }
}

impl fmt::Debug for Seed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Seed(<redacted>)")
    }
}

fn bit(bytes: &[u8], i: usize) -> bool {
    (bytes[i / 8] >> (7 - (i % 8))) & 1 == 1
}

impl Mnemonic {
    /// Encodes entropy (16, 20, 24, 28 or 32 bytes) as a mnemonic.
    pub fn from_entropy(entropy: &[u8]) -> Result<Self, Bip39Error> {
        if !matches!(entropy.len(), 16 | 20 | 24 | 28 | 32) {
            return Err(Bip39Error::InvalidEntropyLength(entropy.len()));
        }
        let list = words();
        let checksum = sha256(entropy)[0];
        let mut bits = Zeroizing::new(Vec::with_capacity(entropy.len() + 1));
        bits.extend_from_slice(entropy);
        bits.push(checksum);
        let total_bits = entropy.len() * 8 + entropy.len() / 4;
        let mut phrase = Zeroizing::new(String::new());
        for w in 0..total_bits / 11 {
            let mut index = 0usize;
            for b in 0..11 {
                index = (index << 1) | usize::from(bit(&bits, w * 11 + b));
            }
            if w > 0 {
                phrase.push(' ');
            }
            // index < 2^11 = list.len().
            phrase.push_str(list[index]);
        }
        Ok(Self {
            phrase,
            entropy: Zeroizing::new(entropy.to_vec()),
        })
    }

    /// Parses and validates a phrase (case-insensitive, any whitespace between words).
    pub fn parse(phrase: &str) -> Result<Self, Bip39Error> {
        let list = words();
        let input: Vec<&str> = phrase.split_whitespace().collect();
        let count = input.len();
        if !matches!(count, 12 | 15 | 18 | 21 | 24) {
            return Err(Bip39Error::InvalidWordCount(count));
        }
        let mut indices = Zeroizing::new(Vec::with_capacity(count));
        let mut normalized = Zeroizing::new(String::new());
        for (i, raw) in input.iter().enumerate() {
            let word = Zeroizing::new(raw.to_ascii_lowercase());
            let index = list
                .binary_search(&word.as_str())
                .map_err(|_| Bip39Error::UnknownWord { position: i + 1 })?;
            indices.push(index);
            if i > 0 {
                normalized.push(' ');
            }
            normalized.push_str(list[index]);
        }
        let total_bits = count * 11;
        let checksum_bits = total_bits / 33;
        let entropy_bytes = (total_bits - checksum_bits) / 8;
        let mut buf = Zeroizing::new(alloc::vec![0u8; entropy_bytes + 1]);
        for (w, index) in indices.iter().enumerate() {
            for b in 0..11 {
                if (index >> (10 - b)) & 1 == 1 {
                    let pos = w * 11 + b;
                    buf[pos / 8] |= 1 << (7 - (pos % 8));
                }
            }
        }
        let entropy = Zeroizing::new(buf[..entropy_bytes].to_vec());
        let expected = sha256(&entropy)[0] >> (8 - checksum_bits);
        let actual = buf[entropy_bytes] >> (8 - checksum_bits);
        if expected != actual {
            return Err(Bip39Error::InvalidChecksum);
        }
        Ok(Self {
            phrase: normalized,
            entropy,
        })
    }

    /// The normalised phrase (lowercase, single spaces).
    pub fn phrase(&self) -> &str {
        &self.phrase
    }

    /// Number of words.
    pub fn word_count(&self) -> usize {
        self.phrase.split(' ').count()
    }

    /// The entropy the phrase encodes.
    pub fn entropy(&self) -> &[u8] {
        &self.entropy
    }

    /// Derives the 64-byte seed. The passphrase is NFKD-normalised as BIP-39 requires.
    pub fn to_seed(&self, passphrase: &str) -> Seed {
        let mut salt = Zeroizing::new(String::from("mnemonic"));
        salt.extend(passphrase.nfkd());
        let mut seed = Zeroizing::new([0u8; 64]);
        pbkdf2::pbkdf2_hmac::<sha2::Sha512>(
            self.phrase.as_bytes(),
            salt.as_bytes(),
            PBKDF2_ROUNDS,
            seed.as_mut(),
        );
        Seed(seed)
    }
}

impl fmt::Debug for Mnemonic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Mnemonic({} words, <redacted>)", self.word_count())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;
    use alloc::format;

    #[test]
    fn wordlist_is_the_official_one() {
        let list = words();
        assert_eq!(list.len(), 2048);
        assert!(
            list.windows(2).all(|w| w[0] < w[1]),
            "wordlist must be sorted"
        );
        // SHA-256 of the canonical english.txt from bitcoin/bips.
        assert_eq!(
            hex::encode(&sha256(ENGLISH_WORDLIST.replace('\r', "").as_bytes())),
            "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"
        );
    }

    #[test]
    fn rejects_bad_phrases_without_echoing_words() {
        let good = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        assert!(Mnemonic::parse(good).is_ok());
        assert!(Mnemonic::parse(&good.to_uppercase().replace(' ', "\t  ")).is_ok());
        assert_eq!(
            Mnemonic::parse("abandon abandon").map(|_| ()),
            Err(Bip39Error::InvalidWordCount(2))
        );
        let typo = good.replace("about", "aboutt");
        let err = Mnemonic::parse(&typo).unwrap_err();
        assert_eq!(err, Bip39Error::UnknownWord { position: 12 });
        assert!(!format!("{err}").contains("aboutt"));
        let bad_checksum = good.replace("about", "abandon");
        assert_eq!(
            Mnemonic::parse(&bad_checksum).map(|_| ()),
            Err(Bip39Error::InvalidChecksum)
        );
        assert_eq!(
            Mnemonic::from_entropy(&[0u8; 15]).map(|_| ()),
            Err(Bip39Error::InvalidEntropyLength(15))
        );
    }

    #[test]
    fn debug_is_redacted() {
        let m = Mnemonic::from_entropy(&[0x7f; 16]).unwrap();
        let d = format!("{m:?} {:?}", m.to_seed(""));
        assert!(d.contains("12 words"));
        assert!(!d.contains("legal"));
        assert!(d.contains("Seed(<redacted>)"));
    }
}
