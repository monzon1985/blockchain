# Versioning and upgrade policy

## Why shared objects need a version

Upgrading a Sui package publishes a **new** package object. The old package keeps existing and all its public functions stay callable, forever. A bug fix in `v2` therefore protects nobody if an attacker can still call the `v1` function on the same shared `Pool`.

The fix is the versioned-shared-object pattern:

1. Each `Pool` stores `version: u64`.
2. Each package version has `const VERSION: u64`, and every entry point that reads or writes a pool starts with `assert!(pool.version == VERSION, EWrongVersion)`.
3. `migrate(pool, &AdminCap)`, which is only callable through the new package, moves the pool to the new `VERSION`. From then on, the old package's checks compare against their old constant and abort.

`migrate` itself asserts `pool.version < VERSION` (`ENotUpgrade`), so it cannot be replayed and cannot move a pool backwards. It also aborts while a flash loan is open (`EFlashLoanOpen`), so a loan is always repaid through the package version it was taken from.

What is gated: `swap_a_for_b`, `swap_b_for_a`, `add_liquidity`, `remove_liquidity`, `flash_borrow_{a,b}`, `flash_repay_{a,b}`, `pause`, `unpause`, `set_fees`, `set_flash_loans_enabled`. What is not gated: pure reads (`reserves`, quotes, getters), so indexers and migration tooling can inspect a pool whose version is stale. The other shared object the package governs, `TransferPolicy<Collectible>`, has no version and cannot have one; see [Rules and upgrades](#rules-and-upgrades).

This is exercised twice:

* **Unit tests** (`tests/admin_tests.move`): a pool is set to version 0 with a test-only hook, and every gated entry point is shown to abort with `EWrongVersion`. Then `migrate` restores service.
* **A real upgrade on localnet** (`sdk/e2e/localnet.e2e.test.ts`, last test): the package is published, then upgraded with `sui client test-upgrade` to a copy whose only change is `VERSION = 2`. The test checks the whole lifecycle on chain. Before `migrate`, `v1` still trades and `v2` aborts with `EWrongVersion`. `migrate` is called through `v2`. After it, `v1` aborts with `EWrongVersion` and `v2` trades. It then buys three collectibles: two through `v2` (one naming the `Collectible` type with `v2`'s id, one with the original id; Sui resolves both to the same type) and one through `v1`'s rule code, which the policy still accepts (see below).

## Rules and upgrades

The version gate protects pools. It cannot protect the transfer policy, because of how Sui identifies a rule:

* `transfer_policy::add_receipt(Rule {}, request)` records the rule by its witness **type**, and `confirm_request` accepts any receipt whose type is installed.
* A type keeps the id of the package that first defined it, across every upgrade. `v1::royalty_rule::Rule` and `v2::royalty_rule::Rule` are the *same* type.
* So after any upgrade, `v1`'s `royalty_rule::pay`, `cooldown_rule::prove` and `collectible::prove_cooldown` still produce receipts the policy accepts. The e2e suite shows this on chain: after the upgrade, a purchase built against `v1` still succeeds.

Consequence: **a bug fixed in a rule by an upgrade stays exploitable through the old package** until the rule itself is swapped. The remedy is to retire the old witness type:

1. The upgrade adds a new rule module (for example `cooldown_rule_v2` with its own `Rule` and `Config`), and a new function on `PolicyAdmin` in `collectible`, e.g. `swap_cooldown_rule_v2(admin, policy, ...)`, that calls `transfer_policy::remove_rule` for the old `Rule` and `add_rule` for the new one. Adding functions is allowed under the `compatible` and `additive` policies. The `TransferPolicyCap` is wrapped inside `PolicyAdmin`, so only code in `collectible` (of any version) can make that swap; nothing outside the package can.
2. The `PolicyAdmin` holder calls it. From then on, `confirm_request` demands the `RuleV2` receipt, which only the new code can produce, and old receipts are rejected (`EIllegalRule`).
3. A new cooldown rule must keep reading and writing the existing stamps. They live under `cooldown_rule::LastTransferKey`, which only `cooldown_rule` can construct, so the new rule has to go through a function added to `cooldown_rule` itself (the original module, upgraded), not through a fresh module with its own key, or every item would lose its last-sale time and become instantly resellable.

Until such a swap, a rule bug is a standing risk across versions. That is listed in the threat model.

## Upgrade policy: additive discipline under `compatible`

The `UpgradeCap` stays at Sui's default `compatible` policy, and the project restricts *itself*, by review, to additive changes:

| Allowed in an upgrade | Not allowed |
|---|---|
| New modules, new functions, new structs and events | Changing the layout or abilities of any existing struct (Sui rejects it anyway) |
| New state, stored in dynamic fields under new key types | Changing the meaning of an existing field or error code |
| Bumping `VERSION`, plus bug fixes inside existing function bodies that keep their semantics. (The on-chain `additive` policy forbids these; see below.) | Removing or renaming public functions, or changing their signatures (Sui rejects it anyway) |
| New rules for the transfer policy, installed through a new `PolicyAdmin` function (see above) | Changing a rule's `Config` layout in place (add a new rule type instead) |

### Why not the on-chain `additive` policy?

Sui also has an on-chain policy called `additive` (`package::only_additive_upgrades`). It allows new code but forbids changing *any* existing function body. Bumping `VERSION` changes the compiled code of every function that loads the constant (`assert_version`, through which every gated entry point passes, and `migrate`): Sui's compatibility check compares normalized bytecode, constant values included. Under the on-chain `additive` policy the version gate could therefore never move again, and `migrate` would become dead code. Restricting the cap now would give up the ability to disable vulnerable code. We keep that ability, and apply the additive discipline through review instead.

Recommended hardening path once the logic is final:

1. Restrict the cap to `additive` (`package::only_additive_upgrades`). No existing function can change after this, but new functions can still be added (see below).
2. Later, restrict it to `dep_only` (`package::only_dep_upgrades`).
3. Finally, make the package immutable (`package::make_immutable`), which destroys the `UpgradeCap`.

Each step is one-way, and Sui enforces that a policy can only become more restrictive.

### Who holds what

| Capability | Can do | Cannot do |
|---|---|---|
| `UpgradeCap` (publisher) | Publish a new package version. Under `compatible` **and** under `additive`, that version may add new functions to the `pool` module itself, and a new function can read and write `Pool` fields without any version check. It can also add `PolicyAdmin` functions that change the rule set | Nothing in the pools or the policy is out of its reach until the policy is `dep_only` or the package is immutable |
| `AdminCap` | Pause, set fees within `[1, 100]` bps, `migrate` pools to the new version | Upgrade the package, move reserves, mint LP |
| `PolicyAdmin` | Retune the three installed rules within bounds, withdraw royalties, and call whatever rule-swap function a future upgrade adds | Add or remove rules on its own |

### What the version gate does, and what it does not

The gate retires **old** pool code after an **honest** upgrade: once a pool is migrated, a bug fixed in `v2` can no longer be reached through `v1`. It does **not** constrain the upgrade authority. A malicious or compromised `UpgradeCap` holder can publish a version whose new function moves reserves directly, and splitting the `UpgradeCap` and the `AdminCap` between two parties does not change that. The `UpgradeCap` is the most powerful key in the system.

The mitigations are operational and on-chain policy, not code in this package:

1. Hold the `UpgradeCap` in a multisig behind a timelock, so every upgrade is public before it can run. Withdrawals are never pausable (`remove_liquidity` works while paused), and no deny list can apply to an LP coin (each pool registers its own, unregulated), so LPs can exit during the timelock window.
2. Walk the hardening path above. Only `dep_only` or an immutable package removes the upgrade authority's power over the pools.
