// SPDX-License-Identifier: MIT

/// Shared body of every demo currency `init`: register the currency in the
/// `CoinRegistry` from its one-time witness. The caller (`init`) sends the
/// returned `TreasuryCap` and `MetadataCap` to the publisher.
module demo_coins::factory;

use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, MetadataCap};

/// Creates a 9-decimal currency for the one-time witness `otw`.
public(package) fun create<T: drop>(
    otw: T,
    symbol: vector<u8>,
    name: vector<u8>,
    ctx: &mut TxContext,
): (TreasuryCap<T>, MetadataCap<T>) {
    let (builder, treasury) = coin_registry::new_currency_with_otw(
        otw,
        9,
        symbol.to_string(),
        name.to_string(),
        b"Demo currency for the flash_kiosk localnet e2e suite. No value.".to_string(),
        b"".to_string(),
        ctx,
    );
    (treasury, builder.finalize(ctx))
}
