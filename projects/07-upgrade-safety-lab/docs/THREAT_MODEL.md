# Threat model

Scope: the subscription registry in its UUPS lineage (V1, bridge, V2, V3) and its diamond variant, plus the
tooling that gates upgrades (`layout-diff`, `scripts/check-layouts.mjs`). Nothing here has been audited or
deployed with real funds; this is a technical demonstration written to production standards.

## 1. Assets

| Asset | Where | Loss means |
|---|---|---|
| Upgrade authority | V1: owner (slot 51); bridge: owner (namespace); V2+: AccessManager UPGRADER role, and the manager's ADMIN, which can grant it; diamond: owner | whoever holds it can replace all logic and read or rewrite all state |
| Plan administration | owner (Ownable2Step) in every version, owner of the diamond | prices, plan availability, pause, treasury |
| Subscribers' allowances | a standing ERC-20 approval to the registry | a payment larger than the subscriber expected |
| Subscription state | legacy region (slots 201-250) and the registry namespace | users lose paid access, or get it for free |
| Payments in flight | `subscribe` pulls the price from the payer straight to the treasury | the registry never holds funds (`UupsVsDiamond` asserts a zero balance) |
| Layout integrity | every storage slot across versions | stranded or corrupted state after an upgrade |

## 2. Actors and trust assumptions

| Actor | Trusted for | If compromised |
|---|---|---|
| Owner (V1, bridge) | authorizing upgrades until V2 | can upgrade to anything before the AccessManager is wired |
| Owner (V2, V3, diamond) | plan administration, grace period, pause, treasury, `initializeV3` (once) | can reprice plans (a pending `subscribeWithMaxPrice` then reverts instead of overpaying), pause subscriptions, redirect future payments; cannot upgrade a UUPS proxy (V2+) and cannot replay `initializeV2`/`initializeV3` on a fresh proxy to swap the authority or the token |
| AccessManager ADMIN | granting roles, changing delays, `updateAuthority` | every ADMIN operation has a 2-day execution delay (`UpgradeGovernance`): a malicious grant or authority move is public for 2 days and the guardian can cancel it |
| UPGRADER role | scheduling and executing upgrades after a 2-day delay | can push any implementation, but only after a public 2-day window during which a guardian can cancel |
| GUARDIAN role | cancelling scheduled upgrades and scheduled ADMIN operations | can delay upgrades and governance changes indefinitely (liveness, not safety) |
| Subscribers | nothing | can only act on their own subscription |
| Payment token | behaving as a standard ERC-20 | a malicious token could reenter; `nonReentrant` (transient) blocks it, and state is final before the transfer |
| Layout gate reviewers | writing allowances only for moves a migration step performs | a wrong allowance lets an unsafe layout through; the tests still exercise the real migration |

In production the owner, ADMIN, UPGRADER and GUARDIAN are distinct multisigs; the anvil demo uses one throwaway
keystore for all of them and says so. Because ADMIN is itself delayed, even that single key cannot upgrade faster
than the 2-day window (`OwnerIsAdminTimelockTest`, `DiamondOwnerIsAdminTimelockTest`).

The ADMIN delay is what makes the UPGRADER delay meaningful. OpenZeppelin's AccessManager gives its initial admin
no execution delay, and an undelayed ADMIN can grant itself an undelayed UPGRADER role, or re-point the proxy at a
manager it controls, and upgrade in the same block. `UpgradeGovernance.configure`, which the deployment scripts and
the tests both apply, therefore (1) restricts the upgrade function to UPGRADER with a 2-day delay, (2) makes
GUARDIAN the guardian of UPGRADER, (3) assigns every ADMIN function of the manager to a role nobody holds whose
guardian is GUARDIAN (AccessManager allows no guardian for ADMIN_ROLE itself, but lets the guardian of a target
function's role cancel), (4) sets the UPGRADER grant delay and the proxy's target admin delay to 2 days as defence
in depth (effective after the manager's 5-day `minSetback`), and (5) last, gives ADMIN a 2-day execution delay
(increases take effect immediately). For the diamond, handing ownership to someone else is a path to new code, so
`transferOwnership` is an UPGRADER function next to `diamondCut`.

## 3. Attack surface and mitigations (OWASP Smart Contract Top 10, 2026)

| Threat | OWASP | Mitigation | Evidence |
|---|---|---|---|
| Direct OZ 4.x to 5.x upgrade strands owner and initialized version (issue #6362): owner locked out, `initialize` open to anyone | SC10:2026 Proxy & Upgradeability | bridge implementation copies both into the namespaces in the upgrade transaction; `layout-diff` rejects the direct pair | `NaiveMigration6362.t.sol`, `SubscriptionRegistryBridge.t.sol`, gate case `naive-v4-to-v5` |
| Uninitialized implementation taken over (initialize, then `upgradeToAndCall` on the implementation) | SC10:2026, SC01:2026 Access Control | `_disableInitializers()` in every implementation constructor; OZ `onlyProxy` as a second layer | `ImplementationTakeover.t.sol` (pre-Cancun brick, post-Cancun takeover, fix), `Initializers.t.sol` |
| Front-running a re-initializer after an upgrade without calldata | SC10:2026, SC01:2026 | `migrateFromV4` accepts only the legacy owner; `initializeV2`/`initializeV3` are `onlyOwner` | `test_migrateFromV4_onlyLegacyOwner`, `test_initializeV2_requiresOwnerAndCode`, `test_v3_initializeV3_onlyOwnerOnlyOnce` |
| Owner replays an upgrade-path initializer on a fresh proxy (swap the AccessManager, then upgrade at once; or swap the payment token) | SC10:2026, SC01:2026 | a fresh `initialize` admits only a never-initialized proxy and records version 3 (V2) or 4 (V3), the version the upgrade path ends at, so `initializeV2` (`reinitializer(3)`) and `initializeV3` (`reinitializer(4)`) are closed | `test_v2_freshProxy_ownerCannotSwapTheAuthorityThroughInitializeV2`, `test_v3_freshProxy_initializeV3IsClosed`, `test_v2_freshProxy_upgradesToV3AndEnablesPayments` |
| Storage corruption by reordering, retyping, removing, gap mis-sizing | SC10:2026 | frozen legacy region, append-only namespaces, the Rust gate on every version pair | 11 broken fixtures + the naive V1 to V2 pair + lineage pairs in `layout-diff`, gate in CI |
| ERC-7201 slot typo or copy-pasted location in an accessor, a namespace held by a library, a struct placed at a constant slot without an annotation | SC10:2026 | `erc7201` builtin instead of hand-written constants; the gate reads every accessor's `$.slot` from the AST (libraries included), checks it against the formula and against every other region, refuses accessors it cannot evaluate and unannotated constant placements | `Erc7201Formula.t.sol`, gate cases `erc7201-miscomputed`, `erc7201-collision`, `library-namespace`, `accessor-unresolved` |
| Instant malicious upgrade by a compromised upgrader key | SC10:2026, SC01:2026 | AccessManager execution delay (2 days) and guardian cancellation; the plan owner cannot upgrade at all from V2 | `TimelockUpgrade.t.sol`, `DiamondTimelock.t.sol`, anvil demo cancel path |
| Instant upgrade by a compromised ADMIN key (self-grant of an undelayed UPGRADER role, authority swap, opening the upgrade function) | SC10:2026, SC01:2026 | ADMIN has the same 2-day execution delay and GUARDIAN can cancel every ADMIN operation (`UpgradeGovernance`) | `AdminDelayTest`, `OwnerIsAdminTimelockTest`, `DiamondOwnerIsAdminTimelockTest`, `VerifyDeployment` stage `v2` (on-chain) |
| Diamond selector clash (duplicate or 4-byte collision) silently routing to the wrong facet | SC10:2026 | `diamondCut` rejects any Add of an existing selector; build-time detector over the routing table that is really cut (`DiamondSelectors`, shared by the deployment script and the tests) | `DiamondCut.t.sol`, `DiamondRouting.t.sol`, gate selector sets |
| Removing or replacing the diamond's introspection | SC10:2026 | `facetAddress` and `functionFacetPairs` are immutable functions of the diamond | `test_replace_rejectsUnknownSameFacetAndImmutable`, `test_remove_rejectsNonZeroFacetUnknownAndImmutable` |
| Owner reprices a plan in front of a pending subscription, against a standing allowance | SC02:2026 Business Logic | `subscribeWithMaxPrice(planId, maxPrice)` reverts with `PriceAboveMax` when the price exceeds the bound; the one-argument `subscribe` never moves tokens | `test_subscribeWithMaxPrice_rejectsARepricingThatLandsFirst`, `testFuzz_subscribeWithMaxPrice_paysThePriceOnlyWithinTheBound`, `test_subscribe_neverPaysForAPricedPlan` (both architectures) |
| Reentrancy through the payment token | SC08:2026 Reentrancy | checks-effects-interactions plus `ReentrancyGuardTransient` in both architectures | `test_subscribe_blocksReentrancyFromPaymentToken` (both architectures) |
| Unchecked token transfer | SC06:2026 Unchecked External Calls | `SafeERC20.safeTransferFrom` | `test_paidSubscription_revertsWithoutAllowance` |
| Invalid inputs (durations, grace, zero treasury, non-contract token or authority) | SC05:2026 Input Validation | explicit bounds with custom errors carrying the values | behaviour suite, `Initializers.t.sol` |
| Timestamp skew by a block proposer | SC02:2026 Business Logic | accepted: a few seconds against periods of days | Slither `timestamp` excluded with this justification |

## 4. Static analysis triage

Slither 0.11.6 runs in CI with `fail_on: pedantic` (any finding fails the build). Remaining findings are
suppressed only here or next to the code:

| Detector | Where | Decision |
|---|---|---|
| `assembly` | ERC-7201 accessors, diamond fallback, loupe array shrinking | excluded in `slither.config.json`; every block carries a comment explaining why it is safe |
| `naming-convention` | ERC-2535 parameter names (`_diamondCut`, `_init`), OZ `__gap` convention | excluded: names are mandated by the standards the code implements |
| `timestamp` | expiry comparisons | excluded: subscriptions are time-based by design (section 3) |
| `incorrect-equality` | `planId == 0` in `cancel` | excluded: zero is the "no subscription" sentinel, not a balance or a timestamp |
| `unindexed-event-address` | `Paused(address)`, `Unpaused(address)`, `DiamondCut(...)` | excluded: signatures must stay identical to OpenZeppelin `Pausable` and ERC-2535 |
| `missing-inheritance` | `SubscriptionRegistryV3` vs `ISubscriptionRegistry` | excluded: half of the interface is served by OZ parents; the gate's API-parity check proves V3 serves every selector |
| `uninitialized-state`, `constable-states`, `unused-state` | `LegacyOzV4Slots`, `RegistryStorageV1` | suppressed in place (`slither-disable-start/end`): V1 wrote these slots in the proxy's storage |
| `unused-return` | `Address.functionDelegateCall` in `LibDiamond._initialize` | suppressed in place: an initializer's return data is meaningless for a cut; failures revert inside `Address` |

`forge lint` runs with `--deny warnings`; `block-timestamp` (same reason as above) and `reentrancy-events` (a
false positive on the ERC-7201 accessor assembly; the only real external call comes after every event) are
excluded in `foundry.toml`.

## 5. Known limitations

- **The legacy region is frozen, not reclaimed.** Slots 0-200 are zeroed where they held state and reserved
  forever; slots 201-250 keep the V1 data because mappings cannot be moved in O(1).
- **Fee-on-transfer and rebasing payment tokens are unsupported.** `totalRevenue` counts nominal prices; the
  owner picks the token.
- **No refunds.** Cancelling forfeits the remaining time; switching plans restarts the period.
- **The diamond's owner is a single key unless handed to an AccessManager** (`DiamondTimelock.t.sol` shows the
  hand-over and the same `UpgradeGovernance` configuration). Cuts are not timelocked by the diamond itself.
- **The ADMIN delay's defence-in-depth parts start late.** The UPGRADER grant delay and the target admin delay
  only take effect after AccessManager's 5-day `minSetback`; the ADMIN execution delay, which is what closes the
  bypass, is effective immediately.
- **Paying through the one-argument `subscribe` is impossible by design.** Integrations written for V1/V2 keep
  working for free plans; paid plans need `subscribeWithMaxPrice`.
- **ERC-8109 is withdrawn** (superseded by ERC-8153). The diamond keeps ERC-2535 compatibility (cut, loupe,
  ERC-165, `DiamondCut` event) and adds the parts of ERC-8109 that were explicit (per-function events,
  `functionFacetPairs`, `FunctionNotFound`). ERC-8153's facet-level events and `upgradeDiamond` are not
  implemented.
- **The layout gate proves layout compatibility, not migration correctness.** Allowances are human decisions;
  the Solidity tests are what prove the bridge actually moves the values. Accessor slots are resolved statically
  (constants, the `erc7201` builtin, pure getters); an accessor computed at run time is refused, not analysed.
