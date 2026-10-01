# Migration playbook: OpenZeppelin 4.x (sequential storage) to 5.x (ERC-7201)

This is the procedure the lab implements and tests for moving a live UUPS proxy from an implementation built
on OpenZeppelin Contracts-Upgradeable 4.9.x to one built on 5.x. It is written for the registry in this
project, and the failure mode and the fix apply to any OZ 4.x UUPS proxy.

**Transparent proxies** share the layout problem (the owner and initialized version still move from sequential
slots to namespaces, so `onlyOwner` application functions lock out and `initialize` reopens), but not the upgrade
lockout: upgrades are authorized by the `ProxyAdmin`, not by the implementation's owner. The bridge as written does
not fit them either: inside `ProxyAdmin.upgradeAndCall` the caller of `migrateFromV4` is the `ProxyAdmin`, so its
`msg.sender == legacyOwner` check would revert. A transparent-proxy bridge must authorize the migration
differently, for example by accepting the `ProxyAdmin` as caller, or by splitting the migration into a separate
call by the legacy owner on the bridge.

## 1. Why a direct upgrade fails

OZ 4.x parents keep their state in sequential slots, padded with `__gap` arrays. For
`Initializable, OwnableUpgradeable, UUPSUpgradeable` (4.9.6) the layout is:

| Slot | Variable | Parent |
|---|---|---|
| 0 | `_initialized` (uint8), `_initializing` (bool) | `Initializable` |
| 1-50 | `__gap` | `ContextUpgradeable` |
| 51 | `_owner` | `OwnableUpgradeable` |
| 52-100 | `__gap` | `OwnableUpgradeable` |
| 101-150 | `__gap` | `ERC1967UpgradeUpgradeable` |
| 151-200 | `__gap` | `UUPSUpgradeable` |
| 201+ | application variables | the application |

OZ 5.x parents keep the same state in ERC-7201 namespaces instead:

| Namespace | Base slot | Holds |
|---|---|---|
| `openzeppelin.storage.Initializable` | `0xf0c57e16…229c6a00` | `_initialized` (uint64), `_initializing` |
| `openzeppelin.storage.Ownable` | `0x9016d09d…0a528c199300` | `_owner` |

After `V1.upgradeTo(V2)` (the upgrade itself succeeds, because V1 still authorizes it with the owner it reads
from slot 51), V2 reads an owner of `address(0)` and an initialized version of `0`:

- every `onlyOwner` or `restricted` function, `upgradeToAndCall` included, reverts for the real owner, forever;
- `initialize` is callable again by anyone, so the first caller takes the proxy.

This is the failure class reported in [OpenZeppelin issue #6362](https://github.com/OpenZeppelin/openzeppelin-contracts/issues/6362),
where `initialize` additionally panicked (Panic 0x22) on a legacy value, which made the deadlock total. Here it
does not panic, so the lockout becomes a race: the first caller of `initialize`, legitimate owner or front-runner,
takes the proxy. `test/uups/NaiveMigration6362.t.sol` reproduces both halves on the lab's own contracts, and
`layout-diff` rejects the V1 to V2 layout pair with three `moved-to-namespace` errors.

## 2. What cannot move, and what must

- **Mappings cannot be relocated in O(1).** Their entries live at `keccak256(key . slot)`; moving the mapping
  changes every entry's address. The application region (slots 201-250) therefore stays where it is:
  `RegistryStorageV1` is inherited unchanged by every later version and is frozen (append nothing, remove
  nothing). All state added from V2 on goes into the application's own namespace
  (`upgradelab.storage.SubscriptionRegistry`).
- **The OZ parent state is two words.** `_initialized` and `_owner` are copied once, in the upgrade transaction.

## 3. The two-step migration

| Step | Transaction (owner) | Authorized by | Effect |
|---|---|---|---|
| 1 | `V1.upgradeToAndCall(bridge, migrateFromV4())` | V1's `onlyOwner` (slot 51) | `migrateFromV4` runs as `reinitializer(2)`: checks slot 0 is "initialized at version 1, not initializing", checks `msg.sender` is the owner in slot 51, zeroes slots 0 and 51, writes the owner into `openzeppelin.storage.Ownable` and version 2 into `openzeppelin.storage.Initializable` |
| 2 | `bridge.upgradeToAndCall(V2, initializeV2(manager))` | the bridge's `onlyOwner` (namespace) | `initializeV2` runs as `reinitializer(3)` and wires the AccessManager that gates every later upgrade |

Design choices:

- **The bridge is minimal.** It serves the V1 read API (so `isActive` keeps answering for integrators); no
  application write has a selector, so no plan or subscription can change between the two steps. Only the owner
  functions (`upgradeToAndCall`, `transferOwnership`, `acceptOwnership`) remain, and `migrateFromV4`, which its
  `reinitializer(2)` has already closed. Bundling both transactions in one multisig batch removes the maintenance
  window entirely.
- **`migrateFromV4` can only be triggered by the legacy owner.** An owner who forgets the calldata in step 1
  is not exposed to a front-runner.
- **Legacy slots are zeroed, not left behind.** A later version that accidentally reads slot 51 sees zero, and
  `RetiredSlots.t.sol` proves that no function of the V2 or V3 API touches slots 0-200 at all.
- **Version numbers are monotonic.** V1 was version 1 (legacy slot), the bridge writes 2, V2 uses
  `reinitializer(3)`, V3 `reinitializer(4)`. Every re-initializer after the bridge is owner-gated. A fresh V2 or V3
  deployment's `initialize` admits only a never-initialized proxy and records 3 or 4 directly, so the upgrade-path
  re-initializers can never run on a fresh proxy (`Initializers.t.sol`).

## 4. Verification after every step

Each step is checked three ways:

1. **Tests.** `UpgradeSequence.t.sol` writes storage sentinels through the V1 API (plans, subscriptions,
   packed counters) and asserts, after the bridge, V2 and V3, that every value reads back through the current
   API *and* that every raw slot is byte-identical. A fuzzed variant randomizes the V1 state;
   `UpgradeChainInvariant.t.sol` interleaves random traffic with the upgrade steps against a ghost model.
2. **The layout gate.** `layout-diff` passes V1 to bridge only with three reviewed allowances (the moves the
   bridge performs), and passes bridge to V2 and V2 to V3 with no allowance at all.
3. **On a live chain.** `scripts/demo-anvil.mjs` runs the keystore-signed forge scripts on anvil and, after
   each step, a read-only `VerifyDeployment` script checks the ERC-1967 implementation slot, the empty admin
   slot, `version()`, the owner and the sentinels recorded right after deployment; from the bridge on also the
   owner and the version in the OZ 5.x namespaces (2 at the bridge, 3 at V2, 4 at V3) and the zeroed legacy
   slots, and at V2 the AccessManager configuration. The demo broadcasts steps 1 and 2 separately so the bridge
   state is verified on-chain; in production they are one batch.

## 5. Upgrades after the migration

From V2 on, `_authorizeUpgrade` is `restricted`: the AccessManager assigns `upgradeToAndCall` to an UPGRADER
role with a 2-day execution delay, and a GUARDIAN role can cancel a scheduled upgrade before it executes. The
manager's ADMIN is put behind the same delay and every ADMIN operation is cancellable by the GUARDIAN
(`script/UpgradeGovernance.sol`), otherwise ADMIN could grant itself an undelayed UPGRADER role and skip the
window.
V3 is reached through `schedule` then `execute`; payments are enabled afterwards by the owner
(`initializeV3`, `reinitializer(4)`), because inside a manager-executed upgrade `msg.sender` is the manager.
