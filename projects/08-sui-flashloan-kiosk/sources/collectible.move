// SPDX-License-Identifier: MIT

/// Demo NFT traded through Sui Kiosk under a `TransferPolicy<Collectible>` with
/// three rules: royalty (bps with a floor), resale cooldown and kiosk lock.
///
/// `init` claims the `Publisher` from the one-time witness, uses it to create the
/// Display and the *only* transfer policy the type will ever have (with all
/// three rules installed before it is shared), and then burns the `Publisher`.
/// With the publisher gone nobody, including the deployer, can create a second,
/// rule-free `TransferPolicy<Collectible>` and route purchases through it.
///
/// The policy's `TransferPolicyCap` never leaves this module either: `init`
/// wraps it in a `PolicyAdmin`, which can retune the three installed rules
/// within fixed bounds and withdraw royalties, but cannot add or remove rules.
/// A raw cap could install a rule nobody can satisfy (or one that demands a
/// payment to the cap holder) and freeze every locked item for good; the
/// wrapper makes the rule set itself permanent for this package version.
module flash_kiosk::collectible;

use flash_kiosk::cooldown_rule;
use flash_kiosk::kiosk_lock_rule;
use flash_kiosk::royalty_rule;
use std::string::String;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::display;
use sui::event;
use sui::package;
use sui::sui::SUI;
use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};

/// Default royalty: 5 %.
const DEFAULT_ROYALTY_BPS: u64 = 500;
/// Default royalty floor: 0.01 SUI.
const DEFAULT_MIN_ROYALTY_MIST: u64 = 10_000_000;
/// Default resale cooldown: 1 hour.
const DEFAULT_COOLDOWN_MS: u64 = 60 * 60 * 1000;
/// Highest royalty a `PolicyAdmin` can set: 10 %.
const MAX_ROYALTY_BPS: u64 = 1_000;
/// Highest royalty floor a `PolicyAdmin` can set: 1 SUI.
const MAX_MIN_ROYALTY_MIST: u64 = 1_000_000_000;
/// Longest resale cooldown a `PolicyAdmin` can set: 30 days.
const MAX_COOLDOWN_MS: u64 = 30 * 24 * 60 * 60 * 1000;

#[error(code = 0)]
const EEmptyName: vector<u8> = b"Collectible name must not be empty";
#[error(code = 1)]
const ERoyaltyAboveBound: vector<u8> = b"Royalty is above MAX_ROYALTY_BPS";
#[error(code = 2)]
const EMinRoyaltyAboveBound: vector<u8> = b"Royalty floor is above MAX_MIN_ROYALTY_MIST";
#[error(code = 3)]
const ECooldownAboveBound: vector<u8> = b"Cooldown is above MAX_COOLDOWN_MS";

/// One-time witness of this module.
public struct COLLECTIBLE has drop {}

/// The demo NFT. `store` is required by Kiosk; the kiosk lock rule is what
/// keeps it from being moved outside the policy after the first sale.
public struct Collectible has key, store {
    id: UID,
    /// Display name chosen at mint.
    name: String,
    /// 1-based mint counter.
    serial: u64,
}

/// Authorises minting. Minted once in `init`.
public struct MintCap has key, store {
    id: UID,
    /// Number of collectibles minted so far.
    minted: u64,
}

/// Bounded administration of `TransferPolicy<Collectible>`. It owns the
/// policy's `TransferPolicyCap` and exposes only `set_royalty`, `set_cooldown`
/// and `withdraw_royalties`, so the rule set installed by `init` can be tuned
/// but never extended or reduced. Minted once in `init`.
public struct PolicyAdmin has key, store {
    id: UID,
    /// The policy's cap; no function hands out a reference to it.
    cap: TransferPolicyCap<Collectible>,
}

/// Emitted by `mint`.
public struct CollectibleMinted has copy, drop {
    item_id: ID,
    serial: u64,
    name: String,
}

/// Emitted once by `init` with the ids clients need.
public struct MarketplaceInitialized has copy, drop {
    policy_id: ID,
    policy_admin_id: ID,
    mint_cap_id: ID,
}

/// Emitted by `set_royalty`.
public struct RoyaltyUpdated has copy, drop {
    amount_bps: u64,
    min_amount: u64,
}

/// Emitted by `set_cooldown`.
public struct CooldownUpdated has copy, drop {
    cooldown_ms: u64,
}

/// Emitted by `withdraw_royalties`.
public struct RoyaltiesWithdrawn has copy, drop {
    amount: u64,
}

// `share_owned` is a false positive: the policy is created by
// `transfer_policy::new` a few lines above, in this same transaction, so sharing
// it cannot hit the "object already owned" abort the lint guards against.
#[allow(lint(share_owned))]
fun init(otw: COLLECTIBLE, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let mut item_display = display::new_with_fields<Collectible>(
        &publisher,
        vector[b"name".to_string(), b"description".to_string()],
        vector[
            b"{name}".to_string(),
            b"Flash-kiosk demo collectible #{serial}. Royalty, cooldown and kiosk-lock rules apply.".to_string(),
        ],
        ctx,
    );
    item_display.update_version();

    let (mut policy, policy_cap) = transfer_policy::new<Collectible>(&publisher, ctx);
    royalty_rule::add(&mut policy, &policy_cap, DEFAULT_ROYALTY_BPS, DEFAULT_MIN_ROYALTY_MIST);
    cooldown_rule::add(&mut policy, &policy_cap, DEFAULT_COOLDOWN_MS);
    kiosk_lock_rule::add(&mut policy, &policy_cap);
    publisher.burn_publisher();

    let admin = PolicyAdmin { id: object::new(ctx), cap: policy_cap };
    let mint_cap = MintCap { id: object::new(ctx), minted: 0 };
    event::emit(MarketplaceInitialized {
        policy_id: object::id(&policy),
        policy_admin_id: object::id(&admin),
        mint_cap_id: object::id(&mint_cap),
    });

    transfer::public_share_object(policy);
    transfer::transfer(admin, ctx.sender());
    transfer::public_transfer(item_display, ctx.sender());
    transfer::transfer(mint_cap, ctx.sender());
}

/// Mints a new collectible. The caller normally `kiosk::lock`s it straight away.
public fun mint(cap: &mut MintCap, name: String, ctx: &mut TxContext): Collectible {
    assert!(!name.is_empty(), EEmptyName);
    cap.minted = cap.minted + 1;
    let item = Collectible { id: object::new(ctx), name, serial: cap.minted };
    event::emit(CollectibleMinted { item_id: object::id(&item), serial: item.serial, name });
    item
}

/// PTB-callable adapter for `cooldown_rule::prove`. This is the only place the
/// item's `&mut UID` is handed out, and only to the cooldown rule.
public fun prove_cooldown(
    item: &mut Collectible,
    policy: &TransferPolicy<Collectible>,
    request: &mut TransferRequest<Collectible>,
    clock: &Clock,
) {
    cooldown_rule::prove(policy, request, &mut item.id, clock)
}

/// Replaces the royalty rule's parameters: `amount_bps <= MAX_ROYALTY_BPS` and
/// `min_amount <= MAX_MIN_ROYALTY_MIST`. The rule itself stays installed.
public fun set_royalty(
    admin: &PolicyAdmin,
    policy: &mut TransferPolicy<Collectible>,
    amount_bps: u64,
    min_amount: u64,
) {
    assert!(amount_bps <= MAX_ROYALTY_BPS, ERoyaltyAboveBound);
    assert!(min_amount <= MAX_MIN_ROYALTY_MIST, EMinRoyaltyAboveBound);
    transfer_policy::remove_rule<Collectible, royalty_rule::Rule, royalty_rule::Config>(
        policy,
        &admin.cap,
    );
    royalty_rule::add(policy, &admin.cap, amount_bps, min_amount);
    event::emit(RoyaltyUpdated { amount_bps, min_amount });
}

/// Replaces the cooldown rule's parameter: `0 < cooldown_ms <= MAX_COOLDOWN_MS`
/// (zero is rejected by the rule itself). Existing stamps on items are kept.
public fun set_cooldown(
    admin: &PolicyAdmin,
    policy: &mut TransferPolicy<Collectible>,
    cooldown_ms: u64,
) {
    assert!(cooldown_ms <= MAX_COOLDOWN_MS, ECooldownAboveBound);
    transfer_policy::remove_rule<Collectible, cooldown_rule::Rule, cooldown_rule::Config>(
        policy,
        &admin.cap,
    );
    cooldown_rule::add(policy, &admin.cap, cooldown_ms);
    event::emit(CooldownUpdated { cooldown_ms });
}

/// Withdraws `amount` of the accumulated royalties (everything with `none`).
public fun withdraw_royalties(
    admin: &PolicyAdmin,
    policy: &mut TransferPolicy<Collectible>,
    amount: Option<u64>,
    ctx: &mut TxContext,
): Coin<SUI> {
    let royalties = policy.withdraw(&admin.cap, amount, ctx);
    event::emit(RoyaltiesWithdrawn { amount: royalties.value() });
    royalties
}

/// Display name.
public fun name(item: &Collectible): String { item.name }

/// Mint serial number.
public fun serial(item: &Collectible): u64 { item.serial }

/// Last policy-enforced transfer, if the item was ever sold.
public fun last_transfer_ms(item: &Collectible): Option<u64> {
    cooldown_rule::last_transfer_ms(&item.id)
}

/// Collectibles minted so far.
public fun minted(cap: &MintCap): u64 { cap.minted }

/// Default royalty in basis points installed by `init`.
public fun default_royalty_bps(): u64 { DEFAULT_ROYALTY_BPS }

/// Default royalty floor in MIST installed by `init`.
public fun default_min_royalty_mist(): u64 { DEFAULT_MIN_ROYALTY_MIST }

/// Default resale cooldown in milliseconds installed by `init`.
public fun default_cooldown_ms(): u64 { DEFAULT_COOLDOWN_MS }

/// Highest royalty, in basis points, a `PolicyAdmin` can set.
public fun max_royalty_bps(): u64 { MAX_ROYALTY_BPS }

/// Highest royalty floor, in MIST, a `PolicyAdmin` can set.
public fun max_min_royalty_mist(): u64 { MAX_MIN_ROYALTY_MIST }

/// Longest resale cooldown, in milliseconds, a `PolicyAdmin` can set.
public fun max_cooldown_ms(): u64 { MAX_COOLDOWN_MS }

#[test_only]
/// Runs `init` with a test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(COLLECTIBLE {}, ctx)
}
