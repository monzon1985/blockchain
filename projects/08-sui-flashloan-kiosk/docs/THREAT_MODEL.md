# Threat model

Scope: the `flash_kiosk` Move package (`sources/`) and the PTB builders in `sdk/src/`. The Sui framework (`sui::kiosk`, `sui::transfer_policy`, `sui::coin`, `sui::coin_registry`, ...) and the validators are trusted. **Nothing here has been professionally audited**. This is a portfolio project written to production standards and never deployed with real funds.

## Assets

| Asset | Where it lives | Worst case if lost |
|---|---|---|
| Pool reserves (`Balance<A>`, `Balance<B>`) | inside each shared `Pool` | LPs lose funds |
| LP share value (`k / S²`) | implied by reserves and the LP supply | dilution of existing LPs |
| LP coins (`Coin<LpCoin<LP>>`) | owned by each LP | an LP cannot redeem (frozen by a deny list) |
| Coins lent by a flash loan | in the borrower's PTB, for one transaction | loan never repaid |
| Royalties | balance of the shared `TransferPolicy<Collectible>` | creator loses income |
| Sale proceeds | `profits` of the seller's `Kiosk` | seller loses income |
| Collectibles | locked in kiosks (dynamic object fields) | transfer outside the policy, or frozen for good |
| Capabilities | owned objects (`AdminCap`, `PoolCap`, `PolicyAdmin`, `MintCap`, `Display<Collectible>`, `UpgradeCap`) | see the roles table in the README |

## Actors and trust

| Actor | Trusted for | Not trusted for |
|---|---|---|
| Liquidity provider | nothing | may try to dilute other LPs |
| Trader / flash borrower | nothing | controls a whole PTB: arbitrary call order, arbitrary objects |
| Pool creator (`PoolCap`) | choosing the initial price and the LP marker type; toggling flash loans on its own pool | touching any other pool, or the pool's LP coin: `create_pool` registers that currency itself, so the creator holds no `TreasuryCap`, `MetadataCap` or `DenyCapV2` for it |
| Protocol admin (`AdminCap`) | pausing, fee changes within `[1, 100]` bps, `migrate` | moving reserves, minting LP or blocking withdrawals (it can do none of these) |
| Upgrade authority (`UpgradeCap`) | everything: under the `compatible` (and `additive`) policy a new version can add functions to `pool` that move reserves without a version check | nothing; see [UPGRADES.md](UPGRADES.md#what-the-version-gate-does-and-what-it-does-not) |
| Creator (`PolicyAdmin`, `MintCap`, `Display<Collectible>`) | royalty and cooldown parameters within fixed bounds, royalty withdrawal, minting, item metadata | adding or removing rules (the `TransferPolicyCap` is wrapped), or creating a second, laxer policy (the `Publisher` is burned) |
| Seller / buyer | nothing | will try to skip royalties or the cooldown |

## Attack surface, by OWASP Smart Contract Top 10 (2026) class

Each row names the test that shows the attack failing. "compile-fail" means `fixtures/compile-fail/<name>`, checked by `scripts/compile-fail.mjs`.

| Class | Attack | Mitigation | Evidence |
|---|---|---|---|
| SC04 Flash loan–facilitated | Borrow and never repay | `FlashReceipt` has no abilities. The compiler rejects dropping, copying, storing, wrapping or transferring it, and Sui's PTB checker rejects an unconsumed receipt | compile-fail: `drop-receipt`, `discard-receipt-with-underscore`, `copy-receipt`, `store-receipt-in-object`, `store-receipt-in-dynamic-field`, `transfer-receipt`, `wrap-receipt-in-droppable-struct`, `generic-drop-escape`; e2e: *rejects a PTB that borrows and never repays* |
| SC04 | Forge a zero-fee receipt, or zero the fee in a real one | Struct packing and field writes are private to `pool` | compile-fail: `forge-receipt`, `destructure-receipt`, `rewrite-receipt-fee` |
| SC04 | Repay less, or repay in the cheaper coin | Exact `amount + fee` check; the receipt records the side | `flash_tests::repaying_*`, `overpaying_is_rejected_too` |
| SC04 | Settle a receipt on another pool of the same pair | Receipt carries `pool_id`, checked on repay | `flash_tests::repaying_to_another_pool_of_the_same_pair_aborts` |
| SC04 / SC03 | Borrow reserve A, then trade against the drained pool | `PoolState::FlashLoanOpen`: every state-changing entry point of the lending pool except the matching repay aborts until repay | `flash_tests::swapping_on_the_lending_pool_during_the_loan_aborts`, `depositing_…`, `withdrawing_…`, `a_second_loan_…`, `pausing_…`; e2e: *rejects swapping on the lending pool…* |
| SC04 | Change the pool's configuration under an open loan (fees, flash toggle, unpause, `migrate` to a version the loan was not taken from) | The same lock covers the capability-gated calls | `flash_tests::changing_fees_during_the_loan_aborts`, `toggling_flash_loans_…`, `unpausing_…`, `migrating_during_the_loan_aborts` |
| SC08 Reentrancy | Re-enter the pool mid-operation | Move has no dynamic dispatch or callbacks, so the only "re-entry" is a later command in the same PTB, and that command hits the lock above | as above |
| SC08 / SC03 | Read-only reentrancy: an integrator prices off `reserves()` during someone's loan | `reserves`, `quote_a_for_b` and `quote_b_for_a` abort while a loan is open | `flash_tests::reading_reserves_during_the_loan_aborts`, `quoting_*_during_the_loan_aborts` |
| SC07 Arithmetic (rounding) | Round fees down to borrow or trade for free; mint LP rounded up; withdraw rounded up | Fees round up (`fee_up!`); outputs, LP mints and withdrawals round down; deposits pull amounts rounded up | `flash_tests::flash_fee_rounds_up…`, `repaying_a_one_unit_loan…`; `pool_tests::*rounds*`; invariant I1; 168 differential vectors; mutants `flash-fee-rounds-down`, `lp-mint-rounds-up`, `deposit-pull-rounds-down`, `swap-fee-rounds-down` |
| SC07 | First-depositor share inflation | Reserves are `Balance` fields, so a coin cannot be "donated" into them. `MINIMUM_LIQUIDITY` (1_000) is locked forever | `pool_tests::create_pool_mints_sqrt_k_and_locks_minimum_liquidity`, invariant I4 |
| SC09 Overflow | `u64 × u64` products | Widened to `u128`. `(2^64−1)^2 < 2^128` is proven in `math.move`, and a quotient above `u64::MAX` aborts instead of truncating | `math_tests::the_u128_product_of_two_max_u64_does_not_overflow`, `a_quotient_above_u64_max_aborts…` |
| SC01 Access control | Pool creator traps LPs: supplies a *regulated* LP currency, keeps its `DenyCapV2`, and deny-lists LPs (or pauses the coin globally) so their `Coin<LP>` can no longer be spent in `remove_liquidity` | The pool does not accept a creator-supplied currency. `create_pool` registers `LpCoin<LP>` in the `CoinRegistry` itself and never calls `make_regulated`, which only exists on the initializer that never leaves the call. A legacy (one-time-witness) currency for `LpCoin<LP>` cannot exist, and the compiler lets only `pool` register it; a module that registered it first anyway would only make that marker unusable, because `create_pool` then aborts. So no `DenyCapV2` for the LP coin of an existing pool can exist. The `MetadataCap` is deleted too | `pool_tests::create_pool_registers_an_unregulated_lp_currency_with_frozen_metadata`, `is_regulated_cannot_vouch_for_a_creator_supplied_currency` (why vetting the creator's currency would not work); compile-fail: `register-lp-currency`; e2e: *registers every LP coin itself: unregulated, metadata frozen*; mutant `lp-metadata-cap-kept` |
| SC01 | Reuse one LP marker for two pools, so their LP coins are interchangeable and one pool's LPs can drain the other | The registry accepts one `Currency<LpCoin<LP>>` per type | `pool_tests::a_marker_type_backs_exactly_one_pool` (`coin_registry::ECurrencyAlreadyExists`) |
| SC01 | Use a `PoolCap` on another pool | Cap carries the pool id | `admin_tests::a_pool_cap_cannot_configure_another_pool` |
| SC01 | Admin drains a pool | No function lets any capability move reserves or mint LP | code review; roles table |
| SC01 | Take a shared pool out of shared ownership (transfer, freeze, wrap) | `Pool` has `key` only, and `transfer::transfer` is private to the defining module | compile-fail: `public-transfer-pool`, `private-transfer-pool` |
| SC01 | Compromised or lost policy cap installs a rule nobody can satisfy (or a ransom rule paying the attacker): every locked item is frozen for good, and the burned `Publisher` rules out a rescue policy | `init` wraps the `TransferPolicyCap` in a `PolicyAdmin` that exposes only bounded parameter changes and royalty withdrawal; no function adds or removes a rule or hands out the cap | compile-fail: `reach-policy-cap`; `kiosk_tests::init_installs_three_rules_and_burns_the_publisher`, `the_policy_admin_retunes_rules_up_to_their_bounds` |
| SC01 | `PolicyAdmin` sets extreme parameters: a 100 % royalty, a floor above any price, a year-long cooldown | Bounds: royalty ≤ 10 %, floor ≤ 1 SUI, cooldown ≤ 30 days | `kiosk_tests::the_policy_admin_cannot_set_a_royalty_above_10_percent`, `…_a_floor_above_1_sui`, `…_a_cooldown_above_30_days`; mutant `policy-admin-unbounded-cooldown` |
| SC05 Input validation | Zero amounts, A = B, out-of-range fee / royalty / cooldown, empty names | Explicit checks with distinct abort codes | every `expected_failure` in `pool_tests`, `admin_tests`, `kiosk_tests` |
| SC05 | Sandwiching a swap | `min_out` on swaps, `min_lp_out` on deposits, `min_a` / `min_b` on withdrawals; the arbitrage PTB derives its final `min_out` from the required profit | `pool_tests::*slippage*`, `invariant_tests::a_*_one_unit_above_*_aborts`, `sdk/test/flash-arbitrage.test.ts` |
| SC10 Upgradeability | Keep calling the old package after an upgrade | Every pool entry point checks `version == VERSION`; `migrate` is `AdminCap`-gated and one-way | `admin_tests::stale_pool_rejects_*`; e2e: real upgrade then migrate |
| SC10 | Exploit a bug in a transfer-policy rule through the old package after the rule was fixed | **Not mitigated by the version gate**: a rule is identified by its witness *type*, which is the same in every package version, so old rule code still produces valid receipts. Retiring it needs an upgrade that swaps the rule's witness (see [UPGRADES.md](UPGRADES.md#rules-and-upgrades)) | known limitation; e2e: after the upgrade, a purchase through the v1 rule code still succeeds |
| SC02 Business logic | Skip the royalty, the cooldown or the lock rule | `TransferRequest` is a hot potato; `confirm_request` requires one receipt per rule | `kiosk_tests::skipping_the_*`, `keeping_the_item_outside_a_kiosk_aborts`; compile-fail `drop-transfer-request`; e2e: *aborts in confirm_request when a rule is skipped* |
| SC02 | Forge a rule receipt | `confirm_request` rejects receipts from rules that are not installed | `kiosk_tests::a_forged_receipt_from_another_rule_aborts` |
| SC02 | List at price 0 and settle off-chain | Royalty floor (`min_amount`) | `kiosk_tests::royalty_is_percentage_or_floor_whichever_is_larger` |
| SC02 | Place the item unlocked, then take it out and transfer it freely | Lock rule requires `kiosk::is_locked` | `kiosk_tests::placing_without_locking_does_not_satisfy_the_lock_rule` |
| SC02 | Dodge the cooldown with a fresh decoy item | The rule checks that the UID belongs to the requested item | `kiosk_tests::proving_the_cooldown_with_another_item_aborts` |
| SC02 | Reset the cooldown stamp | The stamp's key type has no public constructor, and `Collectible` hands its `UID` only to the rule. The rule itself is reachable outside a purchase (an owner can borrow the item mutably and forge a request with the public `transfer_policy::new_request`), but it enforces the cooldown and only ever moves the stamp to *now*, i.e. later | compile-fail: `forge-cooldown-key`, `reach-collectible-uid`; `kiosk_tests::the_owner_cannot_restamp_an_item_inside_its_cooldown`, `restamping_only_ever_postpones_the_next_resale` |
| SC02 | Route purchases through a second, rule-free policy | The `Publisher` is burned in `init` after the only policy is created | `kiosk_tests::init_installs_three_rules_and_burns_the_publisher`; mutant `publisher-kept` |
| SC02 | Exclusive `PurchaseCap` path | Produces the same `TransferRequest`, so the same rules apply | `kiosk_tests::the_exclusive_purchase_cap_path_is_policed_too` |
| SC06 Unchecked external calls | n/a | Move has no untyped external calls; PTB composition is atomic | n/a |

## Invariants (enforced by `tests/invariant_tests.move`)

I1: LP share value never decreases. I2: reserves are conserved. I3: LP supply accounting holds. I4: the locked minimum never moves. I5: no loan survives its transaction. I6: every swap and every flash loan strictly grows `k`. The full statements are in the README.

## Known limitations

* **Spot price is not an oracle.** Like any constant-product pool, the price can be moved inside a PTB with a large swap. The package ships no TWAP. Integrators must not use `reserves()` as a price feed. (Views abort *during a loan*, which closes the flash-loan variant only.)
* **Selling the kiosk sells its contents.** `KioskOwnerCap` has `store`, so handing over a whole kiosk moves every locked item without a `TransferRequest`. Mysten's `personal_kiosk` rule addresses this; it is not implemented here.
* **Off-chain side deals** can avoid the percentage royalty, but never the floor.
* **The cooldown is type-specific at the edge.** The rule is generic, but each item type needs its own `prove_cooldown` adapter.
* **Clock resolution.** `sui::clock` is consensus-commit time: coarse-grained and monotonic, not wall-clock precise.
* **Compromised `PolicyAdmin`** can withdraw the accumulated royalties, raise the royalty to 10 % with a floor of up to 1 SUI, and delay every resale by up to 30 days after its last sale. It cannot add or remove rules, move items or touch kiosk proceeds. **A lost `PolicyAdmin` has no recovery path:** the royalties stay in the policy and the parameters stay where they are (trading continues). Hold it in a multisig.
* **Compromised `Display<Collectible>` owner** can rewrite the name, description, image or link that wallets show for every item, which is a phishing vector. It cannot move items or change any rule. Hold it in a multisig, or freeze it once the display is final.
* **Old rule code stays valid after an upgrade.** The version gate protects pools only; see [UPGRADES.md](UPGRADES.md#rules-and-upgrades).
* **Compromised `UpgradeCap`** can publish code that drains every pool. The version gate does not stop it (it only retires old code after honest upgrades). Mitigation is operational: multisig plus timelock, then the policy hardening path in [UPGRADES.md](UPGRADES.md).
* **Compromised `AdminCap`** can pause swaps, deposits and flash loans (withdrawals always stay open), raise fees to 1 % and migrate pools. It cannot take funds.
* **LP markers can be squatted.** Anyone can create the first pool for a given marker type; a later `create_pool` with that marker aborts. Nothing is lost, the creator picks another marker. Identify pools by object id and LP coin type, never by symbol: every LP coin is named `FKLP`.
* **Coins sent to a pool's address are lost.** The pool never calls `transfer::receive`. This is harmless to reserves.
* `MINIMUM_LIQUIDITY` (1_000 base units of LP per pool) is locked forever by design.
