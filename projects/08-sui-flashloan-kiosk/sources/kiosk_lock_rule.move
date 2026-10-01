// SPDX-License-Identifier: MIT

/// TransferPolicy rule: the purchased item must end up *locked* in a kiosk.
///
/// `Collectible` has `store`, so outside a kiosk it could be moved with
/// `transfer::public_transfer`, which never creates a `TransferRequest` and would
/// skip the royalty and the cooldown. Requiring the buyer to `kiosk::lock` the
/// item closes that path: a locked item can only leave a kiosk through
/// `kiosk::purchase` / `purchase_with_cap`, i.e. through this policy again.
///
/// Written from scratch; Mysten Labs' `kiosk_lock_rule` is the reference design.
module flash_kiosk::kiosk_lock_rule;

use sui::kiosk::Kiosk;
use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};

#[error(code = 0)]
const ENotLockedInKiosk: vector<u8> = b"Item is not locked in the given kiosk";

/// Witness identifying this rule inside a `TransferPolicy`.
public struct Rule has drop {}

/// The rule has no parameters.
public struct Config has drop, store {}

/// Installs the rule. Requires the policy's `TransferPolicyCap`.
public fun add<T: key + store>(policy: &mut TransferPolicy<T>, cap: &TransferPolicyCap<T>) {
    transfer_policy::add_rule(Rule {}, policy, cap, Config {})
}

/// Adds the receipt if the requested item is locked in `kiosk`.
public fun prove<T: key + store>(request: &mut TransferRequest<T>, kiosk: &Kiosk) {
    let item = request.item();
    assert!(kiosk.has_item(item) && kiosk.is_locked(item), ENotLockedInKiosk);
    transfer_policy::add_receipt(Rule {}, request)
}
