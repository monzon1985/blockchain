// SPDX-License-Identifier: MIT

/// Demo currency `ALPHA` (see `factory`).
module demo_coins::alpha;

/// One-time witness.
public struct ALPHA has drop {}

fun init(otw: ALPHA, ctx: &mut TxContext) {
    let (treasury, metadata_cap) = demo_coins::factory::create(otw, b"ALPHA", b"Alpha (demo)", ctx);
    transfer::public_transfer(treasury, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
