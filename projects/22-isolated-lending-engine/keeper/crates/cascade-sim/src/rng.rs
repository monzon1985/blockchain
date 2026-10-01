// SPDX-License-Identifier: MIT
//! Platform-independent pseudo-random numbers.
//!
//! The simulator's reports are committed and re-checked in CI on a different OS, so every random draw must be
//! bit-identical everywhere. The generator is xoshiro256** seeded through SplitMix64, and every transcendental
//! function goes through `libm` (a pure-Rust port of musl's libm) rather than the platform's C library, whose
//! last-ulp results differ between MSVC and glibc.

/// SplitMix64 step, used to expand a 64-bit seed into generator state and to derive stream seeds.
pub fn splitmix64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// Derives an independent stream seed from a base seed and a stream index.
pub fn stream_seed(base: u64, stream: u64) -> u64 {
    let mut s = base ^ stream.wrapping_mul(0xD1B5_4A32_D192_ED03);
    splitmix64(&mut s)
}

/// xoshiro256** generator.
#[derive(Debug, Clone)]
pub struct Rng {
    s: [u64; 4],
}

impl Rng {
    /// Seeds the generator.
    pub fn new(seed: u64) -> Self {
        let mut sm = seed;
        Self { s: [splitmix64(&mut sm), splitmix64(&mut sm), splitmix64(&mut sm), splitmix64(&mut sm)] }
    }

    /// Next 64 random bits.
    pub fn next_u64(&mut self) -> u64 {
        let result = self.s[1].wrapping_mul(5).rotate_left(7).wrapping_mul(9);
        let t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = self.s[3].rotate_left(45);
        result
    }

    /// Uniform in `[0, 1)` with 53 bits of precision.
    pub fn uniform(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    /// Uniform in `[lo, hi)`.
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.uniform()
    }

    /// Uniform integer in `[0, n)` (n > 0), by rejection to avoid modulo bias.
    pub fn below(&mut self, n: u64) -> u64 {
        let zone = u64::MAX - (u64::MAX % n);
        loop {
            let x = self.next_u64();
            if x < zone {
                return x % n;
            }
        }
    }

    /// Standard normal via Box-Muller (one draw per call; the pair's second value is discarded for simplicity).
    pub fn normal(&mut self) -> f64 {
        // 1 - u is in (0, 1], so the logarithm is finite.
        let u1 = 1.0 - self.uniform();
        let u2 = self.uniform();
        libm::sqrt(-2.0 * libm::log(u1)) * libm::cos(2.0 * core::f64::consts::PI * u2)
    }

    /// Poisson draw by inversion (Knuth); intended for small means.
    pub fn poisson(&mut self, mean: f64) -> u32 {
        let limit = libm::exp(-mean);
        let mut k = 0u32;
        let mut p = self.uniform();
        while p > limit {
            k += 1;
            p *= self.uniform();
        }
        k
    }

    /// Log-normal draw with the given median and log-space standard deviation.
    pub fn lognormal(&mut self, median: f64, sigma: f64) -> f64 {
        median * libm::exp(sigma * self.normal())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_for_a_seed() {
        let mut a = Rng::new(42);
        let mut b = Rng::new(42);
        for _ in 0..1_000 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn matches_reference_xoshiro256starstar() {
        // Values from an independent Python implementation of SplitMix64 seeding + xoshiro256** (seed 0). Pinned
        // so an accidental change to the generator, which would silently change every report, fails here.
        let mut r = Rng::new(0);
        let first: Vec<u64> = (0..3).map(|_| r.next_u64()).collect();
        assert_eq!(first, vec![11_091_344_671_253_066_420, 13_793_997_310_169_335_082, 1_900_383_378_846_508_768]);
    }

    #[test]
    fn moments_are_plausible() {
        let mut r = Rng::new(7);
        let n = 100_000;
        let draws: Vec<f64> = (0..n).map(|_| r.normal()).collect();
        let mean = draws.iter().sum::<f64>() / n as f64;
        let var = draws.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n as f64;
        assert!(mean.abs() < 0.02, "mean {mean}");
        assert!((var - 1.0).abs() < 0.02, "variance {var}");

        let pois: f64 = (0..n).map(|_| f64::from(r.poisson(0.3))).sum::<f64>() / n as f64;
        assert!((pois - 0.3).abs() < 0.01, "poisson mean {pois}");

        let u = r.below(10);
        assert!(u < 10);
    }

    #[test]
    fn stream_seeds_differ() {
        assert_ne!(stream_seed(1, 0), stream_seed(1, 1));
        assert_ne!(stream_seed(1, 0), stream_seed(2, 0));
    }
}
