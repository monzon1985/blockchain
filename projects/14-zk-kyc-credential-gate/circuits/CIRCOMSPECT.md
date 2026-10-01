# circomspect triage

[`npm run lint:circuits`](../scripts/lint-circuits.mjs) runs
[circomspect](https://github.com/trailofbits/circomspect) **0.9.0** (the
latest release on crates.io; `cargo install circomspect --version 0.9.0 --locked`)
over the **production** circuits:

- `circuits/lib/credential_lib.circom`
- `circuits/lib/credential_core.circom`
- `circuits/main/credential.circom`

The zoo circuits (`circuits/zoo/**`) are intentionally vulnerable and are not
gated, but one of them is used as a **self-test**: before linting production,
the gate requires circomspect to flag the `<--` nullifier in
`circuits/zoo/nullifier_unconstrained.circom` (it reports CS0013 there, plus
CS0006 for the never-read value). If circomspect is missing, crashes, is
killed, exits with an unexpected status, writes no SARIF, or stops finding
that known bug, the gate fails. It never prints "clean" without having
analysed anything.

## What fails the gate

1. Any **error-level** result (for example a parse error), wherever it points.
2. Any warning located in `circuits/lib/` or `circuits/main/` that is not
   matched by a suppression in
   [`circomspect-triage.json`](circomspect-triage.json).
3. Any suppression that matches **no** current finding (stale entries are
   deleted, not kept "just in case").

Warnings that circomspect raises inside circomlib (`node_modules/`) are not
gated: that is third-party code pinned at `circomlib@2.0.5`.

## Triage file format

Suppressions live **only** in the machine-readable
[`circomspect-triage.json`](circomspect-triage.json); this Markdown file is
documentation and is never parsed. Each entry names:

| Field | Meaning |
|---|---|
| `ruleId` | circomspect rule, e.g. `CS0017`. |
| `file` | Forward-slash path suffix of the flagged file. |
| `match` | Text that must appear on the flagged source line, so a suppression cannot silently cover a different finding of the same rule in the same file. |
| `justification` | Why the finding is a reviewed, accepted trade-off (at least 40 characters). |

`test/lint.test.ts` checks that the loader rejects malformed entries and that
the current file loads exactly the entry below.

## Current suppressions

| Rule | Location | Why it is accepted |
|---|---|---|
| CS0017 (under-constrained signal) | `credential_core.circom`, `signal recipientSquare` | The front-running fix binds the proof to its submitter through a public input `recipient`. That input takes part in no other constraint, so the circuit adds the standard dummy quadratic constraint `recipientSquare <== recipient * recipient` (the Semaphore "signal hash square" pattern). `recipientSquare` is fully determined by `recipient` and intentionally never read, which is exactly what CS0017 ("intermediate signals should occur in at least two separate constraints") describes. |

## Rule references

circomspect rule ids are documented at
<https://github.com/trailofbits/circomspect/blob/main/doc/analysis_passes.md>
(ids verified against the 0.9.0 source, `program_structure/report_code.rs`).
The ones that matter most for this project's threat model:

- **CS0005 — signal assignment statement (`<--`)**: a witness-only assignment
  that adds no constraint.
- **CS0013 — unnecessary `<--`**: `<--` used where `<==` was possible. This is
  zoo bug #1 (unconstrained nullifier) and the self-test's expected finding.
- **CS0017 — under-constrained signal**: an intermediate signal that occurs in
  fewer than two constraints.
- **CS0018 — unused output signal**: a sub-component output that is never
  constrained by the caller.
