// SPDX-License-Identifier: MIT
//! Per-maker nonce bitmaps: 256 nonces per `NoncePage` account.
//!
//! Nonce `n` lives in page `n / 256`, byte `(n % 256) / 8`, bit `n % 8`. A set
//! bit means the quote with that nonce is dead (fully filled or cancelled).
//! Using a bitmap instead of a per-quote "used" account keeps replay
//! protection at 1 bit of rent per quote and lets a maker cancel up to 256
//! outstanding quotes in a single instruction.

/// Nonces tracked by one page.
pub const NONCES_PER_PAGE: u64 = 256;
/// Bytes of bitmap per page.
pub const PAGE_BYTES: usize = 32;

/// Page index holding `nonce`.
#[inline(always)]
pub const fn page_index(nonce: u64) -> u64 {
    nonce / NONCES_PER_PAGE
}

#[inline(always)]
const fn locate(nonce: u64) -> (usize, u8) {
    let slot = (nonce % NONCES_PER_PAGE) as usize;
    (slot / 8, 1u8 << (slot % 8))
}

/// `true` if `nonce`'s bit is set in `bits` (the caller has checked the page).
#[inline(always)]
pub fn is_used(bits: &[u8; PAGE_BYTES], nonce: u64) -> bool {
    let (byte, mask) = locate(nonce);
    bits[byte] & mask != 0
}

/// Sets `nonce`'s bit in `bits`.
#[inline(always)]
pub fn mark_used(bits: &mut [u8; PAGE_BYTES], nonce: u64) {
    let (byte, mask) = locate(nonce);
    bits[byte] |= mask;
}

/// ORs a cancellation mask into the page (bulk cancel of up to 256 quotes).
#[inline(always)]
pub fn cancel_mask(bits: &mut [u8; PAGE_BYTES], mask: &[u8; PAGE_BYTES]) {
    for (b, m) in bits.iter_mut().zip(mask.iter()) {
        *b |= *m;
    }
}

#[cfg(test)]
mod tests {
    use {super::*, proptest::prelude::*, std::collections::BTreeSet};

    #[test]
    fn page_boundaries() {
        assert_eq!(page_index(0), 0);
        assert_eq!(page_index(255), 0);
        assert_eq!(page_index(256), 1);
        assert_eq!(page_index(u64::MAX), u64::MAX / 256);
    }

    #[test]
    fn first_and_last_bit() {
        let mut bits = [0u8; 32];
        mark_used(&mut bits, 0);
        mark_used(&mut bits, 255);
        assert_eq!(bits[0], 1);
        assert_eq!(bits[31], 0x80);
        assert!(is_used(&bits, 256)); // same slot as 0 in the next page's numbering
    }

    proptest! {
        /// A page behaves exactly like a set of slot numbers.
        #[test]
        fn bitmap_is_a_set(ops in proptest::collection::vec(any::<u64>(), 0..200), probe in any::<u64>()) {
            let mut bits = [0u8; 32];
            let mut model = BTreeSet::new();
            for n in &ops {
                mark_used(&mut bits, *n);
                model.insert(n % 256);
            }
            prop_assert_eq!(is_used(&bits, probe), model.contains(&(probe % 256)));
            let popcount: u32 = bits.iter().map(|b| b.count_ones()).sum();
            prop_assert_eq!(popcount as usize, model.len());
        }

        /// Marking is idempotent and never clears other bits.
        #[test]
        fn marking_is_monotone(seed in any::<[u8; 32]>(), n in any::<u64>()) {
            let mut bits = seed;
            mark_used(&mut bits, n);
            for (after, before) in bits.iter().zip(seed.iter()) {
                prop_assert_eq!(after & before, *before);
            }
            let once = bits;
            mark_used(&mut bits, n);
            prop_assert_eq!(once, bits);
        }

        /// Cancelling with a mask is a bitwise OR.
        #[test]
        fn cancel_mask_is_or(seed in any::<[u8; 32]>(), mask in any::<[u8; 32]>()) {
            let mut bits = seed;
            cancel_mask(&mut bits, &mask);
            for i in 0..32 {
                prop_assert_eq!(bits[i], seed[i] | mask[i]);
            }
        }
    }
}
