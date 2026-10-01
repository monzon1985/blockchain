// SPDX-License-Identifier: MIT

/// TransferPolicy rule, written from scratch: an item cannot be resold until
/// `cooldown_ms` milliseconds (measured with `sui::clock`) have passed since the
/// last transfer that went through this policy.
///
/// Where the timestamp lives. A rule only sees the `TransferRequest` (item id,
/// price, source kiosk), so it has to store state somewhere else:
/// * on the item itself, as a dynamic field under `LastTransferKey`. The key has
///   no public constructor, so nobody but this module can read, overwrite or
///   remove the stamp, even an owner holding `&mut UID` of the item;
/// * the rule is generic over `T`, but needs `&mut UID` of the item. The item's
///   module decides how that reference is exposed; `collectible::prove_cooldown`
///   is the adapter for the demo type (PTBs cannot pass `&mut UID` directly,
///   because Move calls in a PTB cannot return references).
///
/// The alternative, a shared `Table<ID, u64>`, would make every purchase of
/// every item contend on one shared object (see docs/OBJECTS.md).
module flash_kiosk::cooldown_rule;

use sui::clock::Clock;
use sui::dynamic_field as df;
use sui::event;
use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};

/// Longest configurable cooldown: 365 days. Bounds `last + cooldown_ms`.
const MAX_COOLDOWN_MS: u64 = 365 * 24 * 60 * 60 * 1000;

#[error(code = 0)]
const EInvalidCooldown: vector<u8> = b"Cooldown must be in (0, MAX_COOLDOWN_MS]";
#[error(code = 1)]
const EItemMismatch: vector<u8> = b"UID does not belong to the item in the transfer request";
#[error(code = 2)]
const ECooldownActive: vector<u8> = b"Item was transferred too recently to be resold";

/// Witness identifying this rule inside a `TransferPolicy`.
public struct Rule has drop {}

/// Rule configuration stored in the policy.
public struct Config has drop, store {
    /// Minimum time between two policy-enforced transfers of the same item.
    cooldown_ms: u64,
}

/// Dynamic-field key for the last transfer timestamp on the item's UID.
public struct LastTransferKey has copy, drop, store {}

/// Emitted each time the rule stamps an item.
public struct CooldownStamped has copy, drop {
    item_id: ID,
    transferred_at_ms: u64,
    resellable_at_ms: u64,
}

/// Installs the rule. Requires the policy's `TransferPolicyCap`.
public fun add<T: key + store>(
    policy: &mut TransferPolicy<T>,
    cap: &TransferPolicyCap<T>,
    cooldown_ms: u64,
) {
    assert!(cooldown_ms > 0 && cooldown_ms <= MAX_COOLDOWN_MS, EInvalidCooldown);
    transfer_policy::add_rule(Rule {}, policy, cap, Config { cooldown_ms })
}

/// Checks that the cooldown since the previous stamp has elapsed, re-stamps the
/// item with the current time and adds the rule's receipt to `request`.
/// An item that has never been transferred through the policy has no stamp and
/// passes. `item_uid` must be the UID of the item being transferred.
public fun prove<T: key + store>(
    policy: &TransferPolicy<T>,
    request: &mut TransferRequest<T>,
    item_uid: &mut UID,
    clock: &Clock,
) {
    let item_id = item_uid.to_inner();
    assert!(item_id == request.item(), EItemMismatch);
    let config: &Config = transfer_policy::get_rule(Rule {}, policy);
    let now = clock.timestamp_ms();

    if (df::exists(item_uid, LastTransferKey {})) {
        let last: &mut u64 = df::borrow_mut(item_uid, LastTransferKey {});
        assert!(now >= *last + config.cooldown_ms, ECooldownActive);
        *last = now;
    } else {
        df::add(item_uid, LastTransferKey {}, now);
    };

    transfer_policy::add_receipt(Rule {}, request);
    event::emit(CooldownStamped {
        item_id,
        transferred_at_ms: now,
        resellable_at_ms: now + config.cooldown_ms,
    });
}

/// Timestamp of the last policy-enforced transfer of the item, if any.
public fun last_transfer_ms(item_uid: &UID): Option<u64> {
    if (df::exists(item_uid, LastTransferKey {})) {
        option::some(*df::borrow(item_uid, LastTransferKey {}))
    } else {
        option::none()
    }
}

/// Configured cooldown in milliseconds.
public fun cooldown_ms<T: key + store>(policy: &TransferPolicy<T>): u64 {
    let config: &Config = transfer_policy::get_rule(Rule {}, policy);
    config.cooldown_ms
}
