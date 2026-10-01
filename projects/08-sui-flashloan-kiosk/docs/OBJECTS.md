# Object layout and contention analysis

Sui executes transactions that touch disjoint sets of objects in parallel. Transactions that only touch **owned** objects can take the fast path. Every transaction that touches a **shared** object is ordered by consensus, and transactions that write the same shared object run one after another. Since protocol-level congestion control, Sui also caps how many transactions per commit may write one shared object and defers the rest. The consequence: the objects a design shares, and how often it writes them, set its throughput ceiling. This document lists every object in the package, how it is owned, and why.

## Inventory

| Object | Ownership | Created by | Written by | Read by | Notes |
|---|---|---|---|---|---|
| `Pool<A, B, LP>` | **shared** | `pool::create_pool` | swaps, deposits, withdrawals, flash borrow/repay, pause, fees, migrate | quotes, views | `key` only, no `store`: it can never be wrapped, transferred or frozen (compile-fail `public-transfer-pool`, `private-transfer-pool`). |
| `FlashReceipt` | *not an object* | `flash_borrow_{a,b}` | consumed by `flash_repay_{a,b}` | `amount_due`, accessors | No `UID`, no abilities: it exists only inside one PTB and costs no storage. |
| `Coin<LpCoin<LP>>` (LP shares) | owned, by each LP | `create_pool`, `add_liquidity` | burned by `remove_liquidity` | wallets | The pool's own currency type: `LP` is only a marker, and a marker backs one pool. |
| `TreasuryCap<LpCoin<LP>>` | wrapped in its `Pool` | `create_pool` (`coin_registry::new_currency`) | `add_liquidity` / `remove_liquidity` (mint / burn) | `lp_supply` | The only treasury of the LP coin; nobody can address it once the pool exists. |
| `Currency<LpCoin<LP>>` | **shared** (registry-derived) | `create_pool` | never (its `MetadataCap` is deleted at creation) | wallets, `coin_registry` getters | Unregulated by construction: no `DenyCapV2` for an LP coin can exist, so no deny list can freeze LP shares. |
| `MetadataCap<LpCoin<LP>>` | *deleted* | `create_pool` | n/a | n/a | Deleted in the same call (`finalize_and_delete_metadata_cap`): LP metadata is fixed. |
| `CoinRegistry` (`0xc`) | shared, system | genesis | `create_pool` (registers the LP currency) | `create_pool` | Global, but touched only when a pool is created, never on the swap path. |
| `AdminCap` | owned | `pool::init` | never | pause, unpause, set_fees, migrate | Holds no funds; see the roles table in the README. |
| `PoolCap` | owned | `create_pool` | never | `set_flash_loans_enabled` | Carries its pool id; rejected on every other pool. |
| `UpgradeCap` | owned, by the publisher | package publish | `package::authorize_upgrade` / `commit_upgrade` | upgrades | The most powerful key in the system (see [UPGRADES.md](UPGRADES.md)). |
| `TransferPolicy<Collectible>` | **shared** | `collectible::init` | `royalty_rule::pay` (balance), `PolicyAdmin` calls | cooldown and lock rules, `confirm_request` | The only policy that can ever exist for the type (the publisher is burned). |
| `PolicyAdmin` | owned | `collectible::init` | never | `set_royalty`, `set_cooldown`, `withdraw_royalties` | Bounded: royalty ≤ 10 %, floor ≤ 1 SUI, cooldown ≤ 30 days; no rule can be added or removed. |
| `TransferPolicyCap<Collectible>` | wrapped in `PolicyAdmin` | `collectible::init` | never | `PolicyAdmin` functions only | No function returns it or a reference to it (compile-fail `reach-policy-cap`). |
| `Publisher` | *burned* | `collectible::init` (from the OTW) | n/a | n/a | Used for `Display` and the policy, then burned in the same `init`. |
| `MintCap` | owned | `collectible::init` | `mint` (serial counter) | `minted` | |
| `Display<Collectible>` | owned | `collectible::init` | display edits | wallets / indexers | Created before the publisher is burned. Its owner controls what wallets show for every item. |
| `Kiosk` | **shared**, one per user | `kiosk::new` | list, delist, purchase, lock | `is_locked`, `has_item` | Framework object. |
| `KioskOwnerCap` | owned | `kiosk::new` | never | owner operations | Framework object. |
| `PurchaseCap<Collectible>` | owned, temporary | `kiosk::list_with_purchase_cap` | consumed by `purchase_with_cap` | n/a | Exclusive listing; the purchase still yields a `TransferRequest`. |
| `TransferRequest<Collectible>` | *not an object* | `kiosk::purchase`, `purchase_with_cap` | the three rules (receipts) | consumed by `confirm_request` | Hot potato, the Kiosk twin of `FlashReceipt` (compile-fail `drop-transfer-request`). |
| `Collectible` | dynamic object field of a kiosk (or owned right after `mint`) | `collectible::mint` | `cooldown_rule::prove` (via `collectible::prove_cooldown`) | views | Locked in a kiosk after its first sale. |
| cooldown stamp (`u64`) | dynamic field on the **item's** `UID`, key `LastTransferKey` | `cooldown_rule::prove` | `cooldown_rule::prove` | `last_transfer_ms` | Travels with the item. The key has no public constructor. |
| `Clock` (`0x6`) | shared, system | genesis | consensus only | `cooldown_rule::prove` (`&Clock`) | Read-only access never conflicts with other readers. |

## Decisions and their contention cost

### 1. One shared object per pool, and nothing global on the swap path

A constant-product pool must be shared: every trader reads and writes the same two reserves, so trades on one pool are necessarily sequenced. That cost is inherent to the AMM and it is paid **per pool**: two pools never contend with each other.

The design deliberately has **no shared object that every swap touches**:

* There is no `Factory` or `Registry` in `swap_*`, `flash_*` or the liquidity functions. (`create_pool` does write Sui's global `CoinRegistry`, to register the pool's LP coin, but pool creation is rare and never on the trading path.) A registry that tracked pools, or a global config holding the fee or a global pause flag, would appear in every transaction of every pool. Even as a read-only (`&`) input it must be ordered by consensus, and each admin write to it would conflict with all traffic at once.
* The pause flag, the fees and the version live **in each pool**. The trade-off is operational: pausing *N* pools takes *N* calls (a single PTB can batch them). That is acceptable for a rare emergency action, and it removes a global bottleneck from the hot path.
* Because the LP type identifies a pool (see the README), any number of pools can exist for the same pair. Liquidity can be split across pools if one becomes congested, and the flash-arbitrage PTB uses exactly that: it borrows from one pool and trades on two others.

### 2. The flash-loan lock is a field, not an object

`PoolState::FlashLoanOpen` is stored in the pool that lent the coins. It needs no extra shared object and it never outlives a transaction: the `FlashReceipt` that sets the pool back to `Active` cannot be stored, so by the end of the PTB the pool is `Active` again (or the whole PTB aborted). A design that recorded open loans in a shared "loan book" would add a second hot object and make an unrepaid loan a state that can persist. Here that state cannot exist between transactions.

### 3. The cooldown stamp lives on the item, not in a shared table

The cooldown rule has to remember when each item last changed hands. The obvious design is a shared `Table<ID, u64>`, and it would make every sale of every collectible **write the same shared object**: a global bottleneck, plus a table that grows forever.

Instead, the stamp is a dynamic field on the item's own `UID`, under a key type (`LastTransferKey`) that only `cooldown_rule` can construct. It adds no shared object: the item is already part of the purchase transaction. The stamp moves with the item from kiosk to kiosk. An owner who borrows the item mutably from their kiosk still cannot remove or reset the stamp: that needs a value of the key type, or the item's `UID`, and both are private (compile-fail `forge-cooldown-key`, `reach-collectible-uid`). The only writer, `cooldown_rule::prove`, enforces the cooldown and only ever moves the stamp later.

The cost of this choice: the rule needs `&mut UID` of the item, and a PTB cannot produce a reference (Move calls in a PTB cannot return references). The rule is therefore generic, and each item type exposes a small adapter (`collectible::prove_cooldown`). The adapter is the only place `Collectible` hands out its `UID`, and it hands it only to the rule.

### 4. The transfer policy is a deliberate hotspot

`TransferPolicy<Collectible>` is shared, and `royalty_rule::pay` writes to it: the royalty is added to the policy's balance. Every purchase of the type is therefore sequenced on that one object. This is inherent to Sui Kiosk (policies are per type). The rules keep writes to a minimum: the cooldown and lock rules take the policy by immutable reference, so only `pay` writes it.

The way to shard this load would be several `TransferPolicy<Collectible>` objects. That would weaken the guarantees, because a buyer can settle a `TransferRequest` against *any* policy of the type and would pick the laxest one. `collectible::init` therefore installs all three rules before sharing the only policy, **burns the `Publisher`**, so no second policy can ever be created, and wraps the policy's cap in a `PolicyAdmin` that can tune the rules but never add or remove one. We accept per-type serialization of purchases in exchange for a single, fixed rule set. A creator who needs more throughput could pay royalties to an address instead of the policy balance (an owned-object write). That rule is not implemented here.

### 5. Kiosks, caps and the clock

* Kiosks are per-user shared objects. Purchases from different sellers into different buyers' kiosks share nothing except the policy.
* The `Clock` is taken by immutable reference. Read-only access to a shared object does not conflict with other readers, so the cooldown rule adds no contention.
* All capabilities (`AdminCap`, `PoolCap`, `PolicyAdmin`, `MintCap`, `KioskOwnerCap`) are owned objects. The transactions that use them also touch a shared object, so they go through consensus anyway. Operational note: an owned object is locked to one transaction per version, so a key holder must not submit two transactions that use the same cap concurrently. Equivocating on an owned object can lock it until the end of the epoch.

## Summary

| Hot path | Shared objects written | Contention scope |
|---|---|---|
| Pool creation | the new pool, its LP `Currency`, the `CoinRegistry` | global, once per pool |
| Swap / deposit / withdraw | the pool | per pool |
| Flash loan (borrow + repay) | the lending pool | per pool, within one PTB |
| Flash arbitrage PTB (L → X → Y) | pools L, X, Y | those three pools only |
| Kiosk purchase | seller kiosk, buyer kiosk, `TransferPolicy<Collectible>` | per kiosk pair + **per collectible type** |
| Cooldown stamp | none (dynamic field on the item) | none |
