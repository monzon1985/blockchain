// SPDX-License-Identifier: MIT

/// Demo currency `BETA` (see `factory`).
module demo_coins::beta;

/// One-time witness.
public struct BETA has drop {}

fun init(otw: BETA, ctx: &mut TxContext) {
    let (treasury, metadata_cap) = demo_coins::factory::create(otw, b"BETA", b"Beta (demo)", ctx);
    transfer::public_transfer(treasury, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}
