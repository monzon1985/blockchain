// SPDX-License-Identifier: MIT

#[test_only]
/// Kiosk marketplace under `TransferPolicy<Collectible>`: the compliant
/// purchase, royalty arithmetic, cooldown timing and every policy-bypass
/// attempt we could think of.
module flash_kiosk::kiosk_tests;

use flash_kiosk::collectible::{Self, Collectible, MintCap, PolicyAdmin};
use flash_kiosk::cooldown_rule;
use flash_kiosk::kiosk_lock_rule;
use flash_kiosk::royalty_rule;
use std::unit_test::{assert_eq, destroy};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::display::Display;
use sui::kiosk::{Self, Kiosk, KioskOwnerCap};
use sui::package::Publisher;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use sui::transfer_policy::{Self, TransferPolicy, TransferPolicyCap, TransferRequest};

const CREATOR: address = @0xC0FFEE;
const BUYER: address = @0xB1;
const BUYER_2: address = @0xB2;
/// 1 SUI.
const PRICE: u64 = 1_000_000_000;
/// 30 days, the longest cooldown a `PolicyAdmin` can set.
const THIRTY_DAYS_MS: u64 = 30 * 24 * 3_600_000;
/// Royalty at the default 5 %.
const ROYALTY: u64 = 50_000_000;
/// Default cooldown: 1 hour.
const HOUR_MS: u64 = 3_600_000;
/// Arbitrary non-zero start time for the test clock.
const T0: u64 = 1_700_000_000_000;

/// Everything a test needs to reach the shared objects.
public struct Market has drop {
    creator_kiosk: ID,
    item: ID,
}

// === fixtures ===

/// `init` + one collectible minted, locked and listed at `price` in the
/// creator's (shared) kiosk. Returns the scenario and a clock at `T0`.
fun setup(price: u64): (Scenario, Clock, Market) {
    let mut scenario = ts::begin(CREATOR);
    collectible::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);

    let policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let mut mint_cap = ts::take_from_address<MintCap>(&scenario, CREATOR);
    let (mut kiosk, kiosk_cap) = kiosk::new(scenario.ctx());
    let item = mint_cap.mint(b"Genesis".to_string(), scenario.ctx());
    let item_id = object::id(&item);
    kiosk.lock(&kiosk_cap, &policy, item);
    kiosk.list<Collectible>(&kiosk_cap, item_id, price);
    let creator_kiosk = object::id(&kiosk);
    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_cap, CREATOR);
    ts::return_to_address(CREATOR, mint_cap);
    ts::return_shared(policy);

    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(T0);
    scenario.next_tx(CREATOR);
    (scenario, clock, Market { creator_kiosk, item: item_id })
}

/// A compliant purchase, exactly as the TypeScript PTB builds it: purchase,
/// prove the cooldown, lock into the buyer's new kiosk, prove the lock, pay the
/// royalty, confirm. Returns the buyer's kiosk id.
fun buy(
    scenario: &mut Scenario,
    buyer: address,
    seller_kiosk: ID,
    item: ID,
    price: u64,
    clock: &Clock,
): ID {
    scenario.next_tx(buyer);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(scenario);
    let mut seller = ts::take_shared_by_id<Kiosk>(scenario, seller_kiosk);
    let (mut kiosk, kiosk_cap) = kiosk::new(scenario.ctx());

    let payment = coin::mint_for_testing<SUI>(price, scenario.ctx());
    let (mut collectible, mut request) = seller.purchase<Collectible>(item, payment);
    collectible.prove_cooldown(&policy, &mut request, clock);
    kiosk.lock(&kiosk_cap, &policy, collectible);
    kiosk_lock_rule::prove(&mut request, &kiosk);
    let mut budget = coin::mint_for_testing<SUI>(10 * ROYALTY, scenario.ctx());
    royalty_rule::pay(&mut policy, &mut request, &mut budget, scenario.ctx());
    let (confirmed_item, paid, from) = policy.confirm_request(request);
    assert_eq!(confirmed_item, item);
    assert_eq!(paid, price);
    assert_eq!(from, seller_kiosk);

    transfer::public_transfer(budget, buyer);
    let kiosk_id = object::id(&kiosk);
    transfer::public_share_object(kiosk);
    transfer::public_transfer(kiosk_cap, buyer);
    ts::return_shared(seller);
    ts::return_shared(policy);
    kiosk_id
}

/// `owner` relists `item` from its kiosk at `price`.
fun relist(scenario: &mut Scenario, owner: address, kiosk_id: ID, item: ID, price: u64) {
    scenario.next_tx(owner);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(scenario, kiosk_id);
    let cap = ts::take_from_address<KioskOwnerCap>(scenario, owner);
    kiosk.list<Collectible>(&cap, item, price);
    ts::return_to_address(owner, cap);
    ts::return_shared(kiosk);
}

/// Starts a purchase and returns the loose pieces for the bypass tests.
fun start_purchase(
    scenario: &mut Scenario,
    market: &Market,
): (TransferPolicy<Collectible>, Kiosk, Collectible, TransferRequest<Collectible>) {
    scenario.next_tx(BUYER);
    let policy = ts::take_shared<TransferPolicy<Collectible>>(scenario);
    let mut seller = ts::take_shared_by_id<Kiosk>(scenario, market.creator_kiosk);
    let payment = coin::mint_for_testing<SUI>(PRICE, scenario.ctx());
    let (item, request) = seller.purchase<Collectible>(market.item, payment);
    (policy, seller, item, request)
}

// === init ===

#[test]
fun init_installs_three_rules_and_burns_the_publisher() {
    let (scenario, clock, _market) = setup(PRICE);
    let policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    assert_eq!(policy.rules().length(), 3);
    assert_eq!(royalty_rule::amount_bps(&policy), collectible::default_royalty_bps());
    assert_eq!(royalty_rule::min_amount(&policy), collectible::default_min_royalty_mist());
    assert_eq!(cooldown_rule::cooldown_ms(&policy), collectible::default_cooldown_ms());
    assert!(transfer_policy::has_rule<Collectible, kiosk_lock_rule::Rule>(&policy));
    // The publisher was burned: no second TransferPolicy<Collectible> can exist.
    assert!(!ts::has_most_recent_for_address<Publisher>(CREATOR));
    // The policy cap is wrapped in the PolicyAdmin; nobody holds it directly.
    assert!(ts::has_most_recent_for_address<PolicyAdmin>(CREATOR));
    assert!(!ts::has_most_recent_for_address<TransferPolicyCap<Collectible>>(CREATOR));
    assert!(ts::has_most_recent_for_address<Display<Collectible>>(CREATOR));
    ts::return_shared(policy);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun mint_numbers_items_sequentially() {
    let mut scenario = ts::begin(CREATOR);
    collectible::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let mut cap = ts::take_from_address<MintCap>(&scenario, CREATOR);
    let first = cap.mint(b"One".to_string(), scenario.ctx());
    let second = cap.mint(b"Two".to_string(), scenario.ctx());
    assert_eq!(first.serial(), 1);
    assert_eq!(second.serial(), 2);
    assert_eq!(second.name(), b"Two".to_string());
    assert_eq!(cap.minted(), 2);
    assert!(first.last_transfer_ms().is_none());
    destroy(first);
    destroy(second);
    ts::return_to_address(CREATOR, cap);
    scenario.end();
}

#[test, expected_failure(abort_code = collectible::EEmptyName)]
fun mint_rejects_an_empty_name() {
    let mut scenario = ts::begin(CREATOR);
    collectible::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let mut cap = ts::take_from_address<MintCap>(&scenario, CREATOR);
    let _item = cap.mint(b"".to_string(), scenario.ctx());
    abort
}

// === the compliant purchase ===

#[test]
fun compliant_purchase_pays_seller_and_creator_and_locks_the_item() {
    let (mut scenario, clock, market) = setup(PRICE);
    let buyer_kiosk = buy(&mut scenario, BUYER, market.creator_kiosk, market.item, PRICE, &clock);

    scenario.next_tx(CREATOR);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let seller = ts::take_shared_by_id<Kiosk>(&scenario, market.creator_kiosk);
    let bought = ts::take_shared_by_id<Kiosk>(&scenario, buyer_kiosk);
    // Seller got the full price, the creator got 5 % on top, paid by the buyer.
    assert_eq!(seller.profits_amount(), PRICE);
    assert!(!seller.has_item(market.item));
    assert!(bought.has_item(market.item) && bought.is_locked(market.item));
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    let royalties = admin.withdraw_royalties(&mut policy, option::none(), scenario.ctx());
    assert_eq!(royalties.value(), ROYALTY);
    // The buyer's change came back: 10x budget minus one royalty.
    let change = ts::take_from_address<Coin<SUI>>(&scenario, BUYER);
    assert_eq!(change.value(), 9 * ROYALTY);

    destroy(royalties);
    ts::return_to_address(BUYER, change);
    ts::return_to_address(CREATOR, admin);
    ts::return_shared(bought);
    ts::return_shared(seller);
    ts::return_shared(policy);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun delisted_items_stay_in_the_kiosk() {
    let (mut scenario, clock, market) = setup(PRICE);
    scenario.next_tx(CREATOR);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, market.creator_kiosk);
    let cap = ts::take_from_address<KioskOwnerCap>(&scenario, CREATOR);
    kiosk.delist<Collectible>(&cap, market.item);
    assert!(!kiosk.is_listed(market.item));
    assert!(kiosk.is_locked(market.item));
    ts::return_to_address(CREATOR, cap);
    ts::return_shared(kiosk);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = sui::dynamic_field::EFieldDoesNotExist)]
fun purchasing_a_delisted_item_aborts() {
    let (mut scenario, _clock, market) = setup(PRICE);
    scenario.next_tx(CREATOR);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, market.creator_kiosk);
    let cap = ts::take_from_address<KioskOwnerCap>(&scenario, CREATOR);
    kiosk.delist<Collectible>(&cap, market.item);
    let payment = coin::mint_for_testing<SUI>(PRICE, scenario.ctx());
    let (_item, _request) = kiosk.purchase<Collectible>(market.item, payment);
    abort
}

#[test, expected_failure(abort_code = sui::kiosk::EIncorrectAmount)]
fun underpaying_the_listing_aborts() {
    let (mut scenario, _clock, market) = setup(PRICE);
    scenario.next_tx(BUYER);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, market.creator_kiosk);
    let payment = coin::mint_for_testing<SUI>(PRICE - 1, scenario.ctx());
    let (_item, _request) = kiosk.purchase<Collectible>(market.item, payment);
    abort
}

#[test, expected_failure(abort_code = sui::kiosk::EItemLocked)]
fun a_locked_item_cannot_be_taken_out_of_the_kiosk() {
    let (mut scenario, _clock, market) = setup(PRICE);
    scenario.next_tx(CREATOR);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, market.creator_kiosk);
    let cap = ts::take_from_address<KioskOwnerCap>(&scenario, CREATOR);
    kiosk.delist<Collectible>(&cap, market.item);
    let _item = kiosk.take<Collectible>(&cap, market.item);
    abort
}

// === royalty arithmetic ===

#[test]
fun royalty_is_percentage_or_floor_whichever_is_larger() {
    let (scenario, clock, _market) = setup(PRICE);
    let policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    assert_eq!(royalty_rule::fee_amount(&policy, PRICE), ROYALTY); // 5 % of 1 SUI
    assert_eq!(royalty_rule::fee_amount(&policy, 200_000_000), 10_000_000); // 5 % == floor
    assert_eq!(royalty_rule::fee_amount(&policy, 100_000_000), 10_000_000); // floor wins
    assert_eq!(royalty_rule::fee_amount(&policy, 0), 10_000_000); // zero-price listing
    ts::return_shared(policy);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun royalty_rounds_up() {
    let (scenario, clock, _market) = setup(PRICE);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    admin.set_royalty(&mut policy, 250, 0);
    assert_eq!(royalty_rule::fee_amount(&policy, 0), 0);
    assert_eq!(royalty_rule::fee_amount(&policy, 1), 1); // 0.025 -> 1
    assert_eq!(royalty_rule::fee_amount(&policy, 40), 1); // exactly 1
    assert_eq!(royalty_rule::fee_amount(&policy, 41), 2); // 1.025 -> 2
    ts::return_to_address(CREATOR, admin);
    ts::return_shared(policy);
    clock.destroy_for_testing();
    scenario.end();
}

/// The rule module's own bound, checked on a stand-alone policy (the
/// `PolicyAdmin` bound below is tighter and would trip first).
#[test, expected_failure(abort_code = royalty_rule::EInvalidBps)]
fun the_royalty_rule_rejects_more_than_100_percent() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap) = transfer_policy::new_for_testing<Collectible>(&mut ctx);
    royalty_rule::add(&mut policy, &cap, 10_001, 0);
    abort
}

#[test, expected_failure(abort_code = royalty_rule::EInsufficientPayment)]
fun royalty_payment_smaller_than_due_aborts() {
    let (mut scenario, _clock, market) = setup(PRICE);
    let (mut policy, _seller, _item, mut request) = start_purchase(&mut scenario, &market);
    let mut short = coin::mint_for_testing<SUI>(ROYALTY - 1, scenario.ctx());
    royalty_rule::pay(&mut policy, &mut request, &mut short, scenario.ctx());
    abort
}

// === cooldown ===

#[test]
fun first_sale_stamps_the_item_and_resale_waits_for_the_cooldown() {
    let (mut scenario, mut clock, market) = setup(PRICE);
    let kiosk_1 = buy(&mut scenario, BUYER, market.creator_kiosk, market.item, PRICE, &clock);
    relist(&mut scenario, BUYER, kiosk_1, market.item, 2 * PRICE);

    // Exactly one cooldown later the resale goes through.
    clock.increment_for_testing(HOUR_MS);
    let kiosk_2 = buy(&mut scenario, BUYER_2, kiosk_1, market.item, 2 * PRICE, &clock);

    scenario.next_tx(BUYER_2);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, kiosk_2);
    let cap = ts::take_from_address<KioskOwnerCap>(&scenario, BUYER_2);
    let item: &Collectible = kiosk.borrow(&cap, market.item);
    assert_eq!(item.last_transfer_ms(), option::some(T0 + HOUR_MS));
    ts::return_to_address(BUYER_2, cap);
    ts::return_shared(kiosk);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = cooldown_rule::ECooldownActive)]
fun resale_one_millisecond_before_the_cooldown_aborts() {
    let (mut scenario, mut clock, market) = setup(PRICE);
    let kiosk_1 = buy(&mut scenario, BUYER, market.creator_kiosk, market.item, PRICE, &clock);
    relist(&mut scenario, BUYER, kiosk_1, market.item, 2 * PRICE);
    clock.increment_for_testing(HOUR_MS - 1);
    buy(&mut scenario, BUYER_2, kiosk_1, market.item, 2 * PRICE, &clock);
    abort
}

/// The owner of a locked item can borrow it mutably and forge a
/// `TransferRequest` (`transfer_policy::new_request` is public), so the only
/// write path to the stamp, `prove_cooldown`, is reachable outside a purchase.
/// It still enforces the cooldown: it cannot be used to reset the clock.
/// (Reaching the stamp any other way does not compile: see the
/// `forge-cooldown-key` and `reach-collectible-uid` fixtures.)
#[test, expected_failure(abort_code = cooldown_rule::ECooldownActive)]
fun the_owner_cannot_restamp_an_item_inside_its_cooldown() {
    let (mut scenario, mut clock, market) = setup(PRICE);
    let kiosk_1 = buy(&mut scenario, BUYER, market.creator_kiosk, market.item, PRICE, &clock);
    scenario.next_tx(BUYER);
    let policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, kiosk_1);
    let cap = ts::take_from_address<KioskOwnerCap>(&scenario, BUYER);
    clock.increment_for_testing(HOUR_MS - 1);
    let mut forged = transfer_policy::new_request<Collectible>(market.item, 0, kiosk_1);
    let item: &mut Collectible = &mut kiosk[&cap, market.item];
    item.prove_cooldown(&policy, &mut forged, &clock);
    abort
}

/// Once the cooldown has elapsed the same forged call succeeds, and all it
/// does is move the stamp to `now`: the next resale only gets later.
#[test]
fun restamping_only_ever_postpones_the_next_resale() {
    let (mut scenario, mut clock, market) = setup(PRICE);
    let kiosk_1 = buy(&mut scenario, BUYER, market.creator_kiosk, market.item, PRICE, &clock);
    scenario.next_tx(BUYER);
    let policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, kiosk_1);
    let cap = ts::take_from_address<KioskOwnerCap>(&scenario, BUYER);
    clock.increment_for_testing(2 * HOUR_MS);
    let mut forged = transfer_policy::new_request<Collectible>(market.item, 0, kiosk_1);
    let item: &mut Collectible = &mut kiosk[&cap, market.item];
    assert_eq!(item.last_transfer_ms(), option::some(T0));
    item.prove_cooldown(&policy, &mut forged, &clock);
    assert_eq!(item.last_transfer_ms(), option::some(T0 + 2 * HOUR_MS));
    // The forged request can never be confirmed into a transfer: the item
    // stays in this kiosk. Tests may destroy the hot potato directly.
    destroy(forged);
    ts::return_to_address(BUYER, cap);
    ts::return_shared(kiosk);
    ts::return_shared(policy);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = cooldown_rule::EItemMismatch)]
fun proving_the_cooldown_with_another_item_aborts() {
    let (mut scenario, clock, market) = setup(PRICE);
    let (policy, _seller, _item, mut request) = start_purchase(&mut scenario, &market);
    let mut cap = ts::take_from_address<MintCap>(&scenario, CREATOR);
    // A fresh, never-sold item has no stamp; using it would dodge the cooldown.
    let mut decoy = cap.mint(b"Decoy".to_string(), scenario.ctx());
    decoy.prove_cooldown(&policy, &mut request, &clock);
    abort
}

#[test, expected_failure(abort_code = cooldown_rule::EInvalidCooldown)]
fun a_zero_cooldown_is_rejected() {
    let (scenario, _clock, _market) = setup(PRICE);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    admin.set_cooldown(&mut policy, 0);
    abort
}

/// The rule module's own bound, checked on a stand-alone policy.
#[test, expected_failure(abort_code = cooldown_rule::EInvalidCooldown)]
fun the_cooldown_rule_rejects_more_than_one_year() {
    let mut ctx = tx_context::dummy();
    let (mut policy, cap) = transfer_policy::new_for_testing<Collectible>(&mut ctx);
    cooldown_rule::add(&mut policy, &cap, 365 * 24 * HOUR_MS + 1);
    abort
}

#[test]
fun the_policy_owner_can_shorten_the_cooldown() {
    let (mut scenario, mut clock, market) = setup(PRICE);
    let kiosk_1 = buy(&mut scenario, BUYER, market.creator_kiosk, market.item, PRICE, &clock);
    relist(&mut scenario, BUYER, kiosk_1, market.item, 2 * PRICE);

    scenario.next_tx(CREATOR);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    admin.set_cooldown(&mut policy, 1_000);
    ts::return_to_address(CREATOR, admin);
    ts::return_shared(policy);

    clock.increment_for_testing(1_000);
    buy(&mut scenario, BUYER_2, kiosk_1, market.item, 2 * PRICE, &clock);
    clock.destroy_for_testing();
    scenario.end();
}

// === PolicyAdmin: bounded tuning, no new rules ===

/// The admin can move every parameter up to its bound, and the policy still
/// holds exactly the three rules `init` installed.
#[test]
fun the_policy_admin_retunes_rules_up_to_their_bounds() {
    let (mut scenario, clock, _market) = setup(PRICE);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    admin.set_royalty(
        &mut policy,
        collectible::max_royalty_bps(),
        collectible::max_min_royalty_mist(),
    );
    admin.set_cooldown(&mut policy, collectible::max_cooldown_ms());
    assert_eq!(royalty_rule::amount_bps(&policy), 1_000);
    assert_eq!(royalty_rule::min_amount(&policy), PRICE);
    assert_eq!(cooldown_rule::cooldown_ms(&policy), THIRTY_DAYS_MS);
    assert_eq!(policy.rules().length(), 3);
    assert!(transfer_policy::has_rule<Collectible, kiosk_lock_rule::Rule>(&policy));
    ts::return_to_address(CREATOR, admin);
    ts::return_shared(policy);
    let effects = scenario.next_tx(CREATOR);
    assert_eq!(effects.num_user_events(), 2);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = collectible::ERoyaltyAboveBound)]
fun the_policy_admin_cannot_set_a_royalty_above_10_percent() {
    let (scenario, _clock, _market) = setup(PRICE);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    admin.set_royalty(&mut policy, collectible::max_royalty_bps() + 1, 0);
    abort
}

#[test, expected_failure(abort_code = collectible::EMinRoyaltyAboveBound)]
fun the_policy_admin_cannot_set_a_floor_above_1_sui() {
    let (scenario, _clock, _market) = setup(PRICE);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    admin.set_royalty(&mut policy, 500, collectible::max_min_royalty_mist() + 1);
    abort
}

#[test, expected_failure(abort_code = collectible::ECooldownAboveBound)]
fun the_policy_admin_cannot_set_a_cooldown_above_30_days() {
    let (scenario, _clock, _market) = setup(PRICE);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    admin.set_cooldown(&mut policy, THIRTY_DAYS_MS + 1);
    abort
}

/// Withdrawing part of the royalties leaves the rest in the policy.
#[test]
fun the_policy_admin_withdraws_royalties() {
    let (mut scenario, clock, market) = setup(PRICE);
    buy(&mut scenario, BUYER, market.creator_kiosk, market.item, PRICE, &clock);
    scenario.next_tx(CREATOR);
    let mut policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let admin = ts::take_from_address<PolicyAdmin>(&scenario, CREATOR);
    let part = admin.withdraw_royalties(&mut policy, option::some(1_000), scenario.ctx());
    let rest = admin.withdraw_royalties(&mut policy, option::none(), scenario.ctx());
    assert_eq!(part.value(), 1_000);
    assert_eq!(rest.value(), ROYALTY - 1_000);
    destroy(part);
    destroy(rest);
    ts::return_to_address(CREATOR, admin);
    ts::return_shared(policy);
    clock.destroy_for_testing();
    scenario.end();
}

// === policy bypass attempts ===

#[test, expected_failure(abort_code = sui::transfer_policy::EPolicyNotSatisfied)]
fun skipping_the_royalty_aborts() {
    let (mut scenario, clock, market) = setup(PRICE);
    let (policy, _seller, mut item, mut request) = start_purchase(&mut scenario, &market);
    let (mut kiosk, kiosk_cap) = kiosk::new(scenario.ctx());
    item.prove_cooldown(&policy, &mut request, &clock);
    kiosk.lock(&kiosk_cap, &policy, item);
    kiosk_lock_rule::prove(&mut request, &kiosk);
    policy.confirm_request(request);
    abort
}

#[test, expected_failure(abort_code = sui::transfer_policy::EPolicyNotSatisfied)]
fun skipping_the_cooldown_aborts() {
    let (mut scenario, _clock, market) = setup(PRICE);
    let (mut policy, _seller, item, mut request) = start_purchase(&mut scenario, &market);
    let (mut kiosk, kiosk_cap) = kiosk::new(scenario.ctx());
    kiosk.lock(&kiosk_cap, &policy, item);
    kiosk_lock_rule::prove(&mut request, &kiosk);
    let mut budget = coin::mint_for_testing<SUI>(ROYALTY, scenario.ctx());
    royalty_rule::pay(&mut policy, &mut request, &mut budget, scenario.ctx());
    policy.confirm_request(request);
    abort
}

/// The attack the lock rule exists for: pay everything, then walk away with
/// the item as a free object (and later transfer it without any policy).
#[test, expected_failure(abort_code = sui::transfer_policy::EPolicyNotSatisfied)]
fun keeping_the_item_outside_a_kiosk_aborts() {
    let (mut scenario, clock, market) = setup(PRICE);
    let (mut policy, _seller, mut item, mut request) = start_purchase(&mut scenario, &market);
    item.prove_cooldown(&policy, &mut request, &clock);
    let mut budget = coin::mint_for_testing<SUI>(ROYALTY, scenario.ctx());
    royalty_rule::pay(&mut policy, &mut request, &mut budget, scenario.ctx());
    transfer::public_transfer(item, BUYER);
    policy.confirm_request(request);
    abort
}

#[test, expected_failure(abort_code = kiosk_lock_rule::ENotLockedInKiosk)]
fun placing_without_locking_does_not_satisfy_the_lock_rule() {
    let (mut scenario, _clock, market) = setup(PRICE);
    let (_policy, _seller, item, mut request) = start_purchase(&mut scenario, &market);
    let (mut kiosk, kiosk_cap) = kiosk::new(scenario.ctx());
    kiosk.place(&kiosk_cap, item);
    kiosk_lock_rule::prove(&mut request, &kiosk);
    abort
}

#[test, expected_failure(abort_code = kiosk_lock_rule::ENotLockedInKiosk)]
fun proving_the_lock_against_an_empty_kiosk_aborts() {
    let (mut scenario, _clock, market) = setup(PRICE);
    let (policy, _seller, item, mut request) = start_purchase(&mut scenario, &market);
    let (mut kiosk, kiosk_cap) = kiosk::new(scenario.ctx());
    let (empty, _empty_cap) = kiosk::new(scenario.ctx());
    kiosk.lock(&kiosk_cap, &policy, item);
    kiosk_lock_rule::prove(&mut request, &empty);
    abort
}

/// A receipt stamped by a rule the policy does not know about cannot stand in
/// for a real one: `confirm_request` checks every receipt against the rule set.
public struct FakeRule has drop {}

#[test, expected_failure(abort_code = sui::transfer_policy::EIllegalRule)]
fun a_forged_receipt_from_another_rule_aborts() {
    let (mut scenario, clock, market) = setup(PRICE);
    let (policy, _seller, mut item, mut request) = start_purchase(&mut scenario, &market);
    let (mut kiosk, kiosk_cap) = kiosk::new(scenario.ctx());
    item.prove_cooldown(&policy, &mut request, &clock);
    kiosk.lock(&kiosk_cap, &policy, item);
    kiosk_lock_rule::prove(&mut request, &kiosk);
    // Instead of paying the royalty, stamp a receipt from a rule we control.
    transfer_policy::add_receipt(FakeRule {}, &mut request);
    policy.confirm_request(request);
    abort
}

#[test, expected_failure(abort_code = sui::transfer_policy::EPolicyNotSatisfied)]
fun the_exclusive_purchase_cap_path_is_policed_too() {
    let (mut scenario, _clock, market) = setup(PRICE);
    scenario.next_tx(CREATOR);
    let policy = ts::take_shared<TransferPolicy<Collectible>>(&scenario);
    let mut kiosk = ts::take_shared_by_id<Kiosk>(&scenario, market.creator_kiosk);
    let cap = ts::take_from_address<KioskOwnerCap>(&scenario, CREATOR);
    kiosk.delist<Collectible>(&cap, market.item);
    let purchase_cap = kiosk.list_with_purchase_cap<Collectible>(
        &cap,
        market.item,
        0,
        scenario.ctx(),
    );
    let payment = coin::zero<SUI>(scenario.ctx());
    let (_item, request) = kiosk.purchase_with_cap(purchase_cap, payment);
    policy.confirm_request(request);
    abort
}
