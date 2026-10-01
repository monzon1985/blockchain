// SPDX-License-Identifier: MIT

/// TransferPolicy rule: pay a royalty of `amount_bps` of the sale price, with an
/// absolute floor of `min_amount` MIST.
///
/// The floor matters: without it a seller and buyer can agree off-chain, list at
/// a price of 0 and pay no royalty at all. The fee is rounded up, like every fee
/// in this package. The royalty accumulates in the `TransferPolicy` balance and
/// is withdrawn by the `TransferPolicyCap` holder with `transfer_policy::withdraw`.
///
/// Written from scratch; the shape follows Mysten Labs' reference `royalty_rule`
/// from the `kiosk` package (credited in the README).
module flash_kiosk::royalty_rule;

use flash_kiosk::math;
use sui::coin::Coin;
use sui::event;
use sui::sui::SUI;
use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};

/// Upper bound for `amount_bps`: 100 %.
const MAX_BPS: u64 = 10_000;

#[error(code = 0)]
const EInvalidBps: vector<u8> = b"Royalty must be at most 10_000 bps";
#[error(code = 1)]
const EInsufficientPayment: vector<u8> = b"Payment coin is smaller than the royalty due";

/// Witness identifying this rule inside a `TransferPolicy`.
public struct Rule has drop {}

/// Rule configuration stored in the policy.
public struct Config has drop, store {
    /// Royalty in basis points of the sale price.
    amount_bps: u64,
    /// Minimum royalty in MIST, applied when the percentage is smaller.
    min_amount: u64,
}

/// Emitted each time a royalty is paid.
public struct RoyaltyPaid has copy, drop {
    item_id: ID,
    price: u64,
    royalty: u64,
}

/// Installs the rule. Requires the policy's `TransferPolicyCap`.
public fun add<T: key + store>(
    policy: &mut TransferPolicy<T>,
    cap: &TransferPolicyCap<T>,
    amount_bps: u64,
    min_amount: u64,
) {
    assert!(amount_bps <= MAX_BPS, EInvalidBps);
    transfer_policy::add_rule(Rule {}, policy, cap, Config { amount_bps, min_amount })
}

/// Splits the royalty for `request` out of `payment` into the policy balance and
/// stamps the rule's receipt. The buyer bounds the maximum royalty by the value
/// of the coin it passes; the change stays in `payment`.
public fun pay<T: key + store>(
    policy: &mut TransferPolicy<T>,
    request: &mut TransferRequest<T>,
    payment: &mut Coin<SUI>,
    ctx: &mut TxContext,
) {
    let price = request.paid();
    let royalty = fee_amount(policy, price);
    assert!(payment.value() >= royalty, EInsufficientPayment);
    transfer_policy::add_to_balance(Rule {}, policy, payment.split(royalty, ctx));
    transfer_policy::add_receipt(Rule {}, request);
    event::emit(RoyaltyPaid { item_id: request.item(), price, royalty });
}

/// Royalty owed on a sale at `price`: `max(ceil(price * bps / 10_000), min_amount)`.
public fun fee_amount<T: key + store>(policy: &TransferPolicy<T>, price: u64): u64 {
    let config: &Config = transfer_policy::get_rule(Rule {}, policy);
    math::fee_up!(price, config.amount_bps).max(config.min_amount)
}

/// Configured royalty in basis points.
public fun amount_bps<T: key + store>(policy: &TransferPolicy<T>): u64 {
    let config: &Config = transfer_policy::get_rule(Rule {}, policy);
    config.amount_bps
}

/// Configured minimum royalty in MIST.
public fun min_amount<T: key + store>(policy: &TransferPolicy<T>): u64 {
    let config: &Config = transfer_policy::get_rule(Rule {}, policy);
    config.min_amount
}
