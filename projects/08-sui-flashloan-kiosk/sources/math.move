// SPDX-License-Identifier: MIT

/// Fixed-point helpers shared by the pool and the royalty rule.
///
/// Every helper takes `u64` operands and widens to `u128` before multiplying.
/// The product of two `u64` values is at most `(2^64 - 1)^2 = 2^128 - 2^65 + 1`,
/// which is strictly below `2^128`, so the intermediate multiplication can never
/// overflow. The only abort paths are a zero denominator and a quotient that
/// does not fit back into `u64` (both arithmetic errors raised by the VM).
///
/// Rounding is always explicit: `_down` floors, `_up` ceils. The protocol rounds
/// fees up and user-facing outputs down, so every rounding error accrues to the
/// pool (LPs) or to the creator, never to the caller.
module flash_kiosk::math;

/// Basis-point denominator: 10_000 bps = 100 %.
const BPS: u64 = 10_000;

/// `floor(a * b / d)`, computed in `u128`.
public macro fun mul_div_down($a: u64, $b: u64, $d: u64): u64 {
    let product = ($a as u128) * ($b as u128);
    (product / ($d as u128)) as u64
}

/// `ceil(a * b / d)`, computed in `u128`.
///
/// `product + d - 1` cannot overflow either: `(2^64 - 1)^2 + 2^64 - 2 < 2^128`.
public macro fun mul_div_up($a: u64, $b: u64, $d: u64): u64 {
    let d = $d as u128;
    let product = ($a as u128) * ($b as u128);
    ((product + d - 1) / d) as u64
}

/// Fee of `bps` basis points on `amount`, rounded up in favour of the fee
/// recipient. Any non-zero amount at a non-zero rate pays at least 1 unit.
public macro fun fee_up($amount: u64, $bps: u64): u64 {
    flash_kiosk::math::mul_div_up!($amount, $bps, flash_kiosk::math::bps())
}

/// The basis-point denominator (10_000), exposed for macros and clients.
public fun bps(): u64 { BPS }

/// Integer square root, rounded down. Used once, to size the first LP mint.
public fun sqrt_down(a: u64, b: u64): u64 {
    // `a * b < 2^128` (see module doc) and `sqrt(x) < 2^64` for any `x < 2^128`,
    // so the cast back to `u64` is lossless.
    std::u128::sqrt((a as u128) * (b as u128)) as u64
}

/// Output of a constant-product swap after the input fee, rounded down.
///
/// `fee = ceil(amount_in * fee_bps / 10_000)` is removed from the input first, so
/// the remaining multiplication is `u64 * u64` and fits in `u128`.
/// `reserve_in + in_after_fee` is computed in `u128` so that it never aborts; the
/// caller's `Balance::join` rejects reserves that would exceed `u64::MAX`.
/// Returns `(amount_out, fee)`.
public fun amount_out(amount_in: u64, reserve_in: u64, reserve_out: u64, fee_bps: u64): (u64, u64) {
    let fee = fee_up!(amount_in, fee_bps);
    let in_after_fee = amount_in - fee;
    let numerator = (in_after_fee as u128) * (reserve_out as u128);
    let denominator = (reserve_in as u128) + (in_after_fee as u128);
    // `in_after_fee / (reserve_in + in_after_fee) < 1` whenever `reserve_in > 0`, so
    // the quotient is strictly below `reserve_out` and fits in `u64`.
    ((numerator / denominator) as u64, fee)
}
