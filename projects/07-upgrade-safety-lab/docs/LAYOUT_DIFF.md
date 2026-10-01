# `layout-diff`: rules and data model

`layout-diff` is a small Rust CLI (in [`../layout-diff`](../layout-diff)) that decides whether one storage layout
can replace another behind the same proxy. It reads `forge inspect <Contract> storageLayout --json` output
extended with ERC-7201 namespaces, and never looks at AST ids: every type is expanded structurally, so layouts
from different compilations compare correctly.

```
layout-diff diff <old.json> <new.json> [--allow KIND:LABEL]... [--sequential-only] [--format text|json]
layout-diff lint <layout.json> [--sequential-only] [--format text|json]
layout-diff selectors <set.json> [--format text|json]
layout-diff erc7201 <id>...
```

Exit codes: `0` safe, `1` unsafe (or an unused allowance), `2` invalid input or usage.

Raw `forge inspect` output carries no namespace information at all, so a #6362-style move of state into a
namespace is invisible in it: on the lab's own V1 and V2, raw output only shows three `renamed` warnings. The CLI
therefore refuses raw input (exit code `2`) unless `--sequential-only` is passed; with the flag it adds a
`namespaces-unchecked` warning and its verdict reads "SAFE for sequential storage only, ERC-7201 namespaces NOT
checked". Use the snapshots the gate builds for a real check.

## Making namespaces visible: probes

Plain `storageLayout` output lists sequential state variables only. ERC-7201 structs are reached through
assembly (`$.slot := location`), so the compiler reports nothing about them. The lab closes the gap in two parts:
**probe contracts** give each namespace's member layout, and the **accessors** read from the AST give the slots
the production code really uses.

Probes ([`test/layout/NamespaceProbes.sol`](../test/layout/NamespaceProbes.sol)):

```solidity
contract RegistryV3NamespaceProbe layout at REGISTRY_STORAGE_LOCATION {
    RegistryNamespaceV3.RegistryStorage internal $;
}
```

Solidity 0.8.29 added the `layout at <base>` specifier, and 0.8.35 the `erc7201(id)` builtin that computes the
base at compile time. A probe pins the real struct type at its ERC-7201 slot, so `forge inspect` reports every
member with its absolute slot. The lab's own probes reuse the production location constants; OpenZeppelin's use
`erc7201("openzeppelin.storage.…")`.

The driver ([`scripts/check-layouts.mjs`](../scripts/check-layouts.mjs)) compiles the project once more, without
cache, into `out-layout/`, so that a single build-info file holds every AST with consistent ids. For each contract
it then follows the code that runs against the contract's storage: every member of its inheritance linearization
(for the diamond, of the facets it delegatecalls too: the `delegates` in `layouts.config.json`, and the gate fails
if the routing table cuts a facet that is not listed there), and every library function, free function or base
function that code references, transitively. In that code it finds:

- every struct annotated `@custom:storage-location erc7201:<id>`, declared by the contracts or reached through
  libraries. A namespace without a probe fails the gate;
- every **accessor**: a function whose inline assembly assigns `<pointer>.slot` for a pointer to an annotated
  struct. The assigned value is resolved statically, through local initializers, constants (OpenZeppelin's private
  `...StorageLocation` constants included), the `erc7201` builtin, type conversions and pure getters with a single
  `return` (following overrides in the linearization). The snapshot records it as `{"erc7201": id}`,
  `{"slot": "0x..."}` or, when it cannot be evaluated, `{"unresolved": "<source text>"}`;
- any struct **without** an annotation that an accessor places at a constant slot: the gate cannot check such a
  hidden namespace, so it fails.

`layout-diff` then checks each accessor against the formula: a typo'd or copy-pasted location in production code
is an `erc7201-slot-mismatch` even when the probe is right, the accessor's real placement takes part in the
collision check, and an unresolved accessor is an `accessor-unresolved` error.

## Snapshot format

```json
{
  "contract": "SubscriptionRegistryV3",
  "storage": [ ...forge storageLayout entries... ],
  "types": { ...forge types table... },
  "namespaces": [
    { "id": "openzeppelin.storage.Ownable", "struct": "OwnableUpgradeable.OwnableStorage",
      "probe": "OzOwnableProbe",
      "accessors": [ { "function": "OwnableUpgradeable._getOwnableStorage",
                       "location": { "slot": "0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300" } } ],
      "layout": { "storage": [ ...one struct variable... ], "types": { ... } } }
  ]
}
```

Raw `forge inspect` output (no `namespaces` key, AST ids in type keys) is only accepted with `--sequential-only`.
An empty `namespaces` list means "no namespaces", which is different from "unknown".

## Rules

A variable is **reserved** when its name starts with `__` **and** it is a fixed-size `uint256` array
(`uint256[47] __gap`, `uint256[50] __legacyContextGap`, `uint256[1] __retiredOwnerSlot`): its slots may be handed to
new variables. Every other variable is **live**, whatever its name, so a real `uint256 __counter` that is removed,
moved or retyped is reported like any other variable. Each old gap is matched with the lowest reserved variable of
the new layout that overlaps it.

| Kind | Severity | Trigger |
|---|---|---|
| `moved` | error | a live variable sits at another slot or offset (reordering, insertion before it, a gap resized) |
| `removed` | error | a live variable is gone; its value is orphaned and its bytes may be reused by another variable |
| `retired` | error | a live variable is now covered by reserved space: the value is still there, nothing reads it |
| `type-changed` | error | same position, incompatible type: width, kind (value, mapping, array, struct), array length, a struct that grows in place, a struct whose members move |
| `gap-resized` | error | a `__gap` no longer ends at the same slot, so everything after it shifts |
| `moved-to-namespace` | error | a live sequential variable reappears, by name, in a namespace that the old layout did not have (the OpenZeppelin #6362 class) |
| `namespace-removed` | error | a namespace id of the old layout is missing |
| `erc7201-slot-mismatch` | error | the probe or an accessor places a namespace away from `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~0xff` |
| `accessor-unresolved` | error | an accessor's slot is not a compile-time constant the driver can evaluate |
| `storage-collision` | error | two static footprints overlap (two namespaces, a namespace and sequential storage, or an accessor's real placement and either) |
| `duplicate-namespace` | error | the same id is declared twice |
| `namespaces-unchecked` | warning | raw `forge inspect` input accepted with `--sequential-only` |
| `renamed` | warning | same position and type, different name |
| `type-relabeled` | warning | same bytes, different type name (`address` to `contract IERC20`, enum renamed, `bytes` to `string`) |
| `added`, `gap-consumed`, `namespace-added` | info | expected evolution: appended variables, gaps giving slots away without moving their end, new namespaces |
| `selector-collision` | error | two different functions share a 4-byte selector (e.g. `burn(uint256)` and `collate_propagate_storage(bytes16)`) |
| `duplicate-function` | error | the same function is served by two facets |
| `selector-mismatch` | error | a selector does not equal keccak256 of its signature (the tool recomputes every one) |

Structs may gain members only where every instance has its own hashed location (mapping values) or at the end of
a namespace; a struct stored in place, or as a dynamic-array element, keeps its size.

## Allowances

`--allow KIND:LABEL` accepts one reviewed error. The gate's allowances live in
[`layouts.config.json`](../layouts.config.json), each with the reason and the test that proves it. An allowance
that matches nothing fails the check, so the allowlist cannot silently go stale. The lab uses exactly three,
all on the V1 to bridge step (`moved-to-namespace` for `_initialized`, `_initializing` and `_owner`), because
that step is where the bridge copies them.

## Known limitations

- Hashed data (mapping entries, dynamic-array elements) is not part of any static footprint, so collisions
  through hashed locations are out of scope; they are cryptographically unlikely by construction.
- Accessors are resolved statically. An accessor whose slot is computed at run time (even with the right formula,
  see the `accessor-unresolved` fixture) is refused rather than analysed; generic slot helpers whose slot is a
  function parameter (OpenZeppelin's `StorageSlot`) are not namespaces and are not checked.
- `moved-to-namespace` matches by name. OpenZeppelin kept names stable between 4.x and 5.x, which is what makes
  the #6362 class detectable; a variable renamed during the move is reported as `removed` (still an error).
- Enum member reorders are invisible in solc's layout output (only the size is), so an enum rename is a warning.
- The tool validates layouts, not initialization logic: the bridge's correctness is established by the Solidity
  tests, the allowance only records that it was reviewed.
