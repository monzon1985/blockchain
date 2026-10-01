# Threat model: ZK KYC credential gate

This is a **technical demonstration**, not a compliant KYC/AML product and not a
professionally audited system. It holds no value pool. The point of the project
is to show ZK-circuit soundness engineering (an under-constrained "bug zoo")
applied to a privacy-preserving compliance flow.

Vulnerability classes are named after the
[OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/), using the
same labels as the rest of this repository: SC01 Access Control, SC02 Business
Logic, SC03 Price Oracle Manipulation, SC05 Lack of Input Validation, SC08
Reentrancy, SC09 Integer Overflow and Underflow. The Top 10 has no ZK-specific
class, so each circuit bug is mapped to the class that describes its *effect*
(a missing constraint is missing input validation; a field wrap is an integer
overflow) and also labelled with its usual ZK-audit name.

## Assets

| Asset | Why it matters |
|---|---|
| Soundness of the credential statement | A verifying proof must imply a real, unexpired, unrevoked, adult, non-sanctioned credential from a trusted issuer. |
| Nullifier uniqueness per scope | One credential maps to exactly one registration per gate per epoch. |
| Subject privacy / unlinkability | The gate learns nothing beyond a per-gate, per-epoch nullifier; the issuer cannot link registrations to the identity it vetted; the same subject is unlinkable across gates. |
| The holder's registration | Only the holder (the address the proof is bound to) can use their proof; nobody else can burn their nullifier. |
| Issuer trust set integrity | Only credentials signed by issuers in the trusted Merkle tree count. |

## Actors and trust assumptions

| Actor | Trust | Capability if malicious |
|---|---|---|
| Prover / holder | Untrusted | Chooses every private input. Must not be able to prove a false statement, mint extra nullifiers, or link/replay across gates. |
| Mempool observer / front-runner | Untrusted | Sees pending `register*` calldata. Cannot reuse it: the proof is bound to `recipient = uint160(msg.sender)`. |
| Issuer (in the trusted tree) | Semi-trusted | Signs credentials over the holder's **commitment** `Poseidon(secret)`; it never receives the secret, so it cannot compute any nullifier, link registrations or build proofs for the holder. The circuit rejects field-wrapped values even from an issuer, but it does **not** check that a date is a real calendar date or that `accredited` is boolean: those are issuer policy (enforced by `src/cli/issuer.ts`). **Per-person Sybil resistance relies on the issuer signing one commitment per vetted person**; an issuer that signs many credentials for one person gives that person many nullifiers. |
| Governor role | Trusted | Publishes and invalidates issuer/revocation roots, replaces the sanctioned list, deregisters accounts. A compromised governor can trust a rogue issuer root or an empty sanctioned list. The strongest privileged role (SC01). |
| Date-oracle role | Trusted | Advances `currentDate`. Bounded on-chain: only real calendar dates in `[19000101, 99991231]` (so `< 2^32`, satisfiable by the circuit) and never backwards. Within those bounds a compromised oracle can still pick a wrong date (SC03-style oracle manipulation, here of a date feed). |
| Trusted-setup ceremony | **Not trusted (dev)** | The dev ceremony is a public beacon, so the toxic waste is derivable by anyone and proofs can be forged. These keys must never secure real value. |

## Attack surface and mitigations

| Surface | Attack | OWASP SC (2026) | Mitigation | Test |
|---|---|---|---|---|
| Circuit constraints | Under-constrained signal lets a prover substitute a witness value (zoo #1). | SC05 | Every output bound with `<==`; circomspect gate fails closed; zoo #1 forged proof + production negative test. | `zoo.test.ts` #1, `npm run zoo` |
| Circuit comparators | Field wrap-around smuggles a non-integer past `<=` (zoo #2). | SC09 (+ SC05) | Every comparator input range-checked with `Num2Bits(32)` inside the gadget that uses it (`AgeAtLeast18`, `NotExpired` now also guards `currentDate` itself). | `subcircuits.test.ts`, `zoo.test.ts` #2 |
| Issuer Merkle path | Non-boolean selector turns the mux into an affine map and forges membership of an untrusted key (zoo #3). | SC05 (impact: SC01) | `pathIndices[i] * (pathIndices[i] - 1) === 0`. | `subcircuits.test.ts`, `zoo.test.ts` #3 |
| Nullifier domain | Nullifier without the scope equals the issuer-signed commitment: issuer de-anonymisation and cross-gate linkage (zoo #4). | SC02 | `nullifier = Poseidon(secret, appScope)`. | `zoo.test.ts` #4 |
| Front-running | Copy a pending registration: attacker allowlisted, victim's nullifier burned. | SC02 (transaction-ordering) | Public input `recipient` bound in-circuit (dummy quadratic constraint) and required to equal `uint160(msg.sender)`. | `test_FrontRunnerCannotStealRegistration`, `testFuzz_WrongRecipientReverts`, e2e tamper tests, `npm run demo` |
| Scope | Replay a proof collected by a clone gate that shares the action id. | SC02 | `appScope = keccak256(abi.encode(chainid, address(this), actionId, epoch)) mod r`, derived only from chain data. | `test_CloneGateWithSameActionIdRejectsProof` |
| Proof malleability | Derive state from (malleable) Groth16 proof bytes. | SC02 | The gate derives nothing from proof bytes; the nullifier is a constrained public output. | design |
| Public inputs | Out-of-field or mismatched public inputs. | SC05 | Every signal range-checked against `r`; date, roots, the full sanctioned list, scope and recipient bound before verification. | `ZkGateFuzzTest` (9 fuzz properties) |
| Revocation | Prove against an older revocation root that predates the revocation. | SC02 | A superseded root is accepted only for `revocationRootGracePeriod` (constructor parameter, default 1 hour in the deploy script, max 30 days; 0 = latest root only); the governor can `invalidateRevocationRoot` immediately. | `test_StaleRevocationRootRejectedAfterGrace`, `test_ZeroGraceAcceptsOnlyLatestRevocationRoot`, `test_InvalidatedRevocationRootRejectedImmediately` |
| Revocation | Forge an SMT exclusion proof for a revoked id: replayed pre-revocation siblings, a fake empty branch, or a **non-boolean `isOld0`**. circomlib's `SMTVerifier` never constrains `isOld0`; its insertion-level node is `(1 - isOld0) * H(oldKey, oldValue, 1)`, so solving for `isOld0` rebuilds the revoked leaf and the proof passes against the *current* root (found in the release review; a real Groth16 proof verified against the pre-fix keys). | SC05 | circomlib `SMTVerifier` (depth 20) against the public root, plus `isOld0 * (isOld0 - 1) === 0` in `RevocationNonMembership`. | `credential.test.ts` "revoked credential with a forged exclusion proof" (3 cases); `subcircuits.test.ts` differential: the raw circomlib gadget accepts the `isOld0` forgery, the guarded gadget rejects it |
| Issuer set | A compromised issuer stays acceptable through older roots. | SC01 | Superseded issuer roots expire after `issuerRootGracePeriod`; `invalidateIssuerRoot` removes a root at once. | `test_SupersededIssuerRootStaleAfterGrace`, `test_InvalidatedIssuerRootRejectedImmediately` |
| Existing registrations | A member whose credential is later revoked/expired/sanctioned stays allowlisted forever. | SC02 | Registrations are **epoch-scoped**: they lapse at the end of the epoch, and renewing needs a fresh proof under the new epoch's scope. Governor `deregister` for immediate removal (nullifier stays burned). | `test_RegistrationLapsesAtEpochEnd`, `test_Deregister*`, `invariant_AllowlistMatchesEpochModel` |
| Signature | Forged issuer signature, or a secret that does not open the commitment. | SC05 | EdDSA-Poseidon verification over all six fields. | `credential.test.ts` |
| Reentrancy | Re-enter during verification. | SC08 | Verification is a `staticcall`; `register*` is `nonReentrant` and checks-effects-interactions. | design |
| Access control | Unauthorized root/date/list/deregistration changes. | SC01 | OpenZeppelin `AccessControl` (`GOVERNOR_ROLE`, `DATE_ORACLE_ROLE`). | `test_*Requires*` (7 tests) |
| Date oracle | Absurd or backwards date; value `>= 2^32` that bricks every proof. | SC03 / SC05 | `InvalidDate` / `DateRegression` checks. | `test_SetCurrentDateRejectsNonDates`, `test_SetCurrentDateRejectsRegression` |
| Lint tooling | circomspect missing or broken, gate prints "clean". | — | Fails closed (ENOENT, signal, unexpected status, missing SARIF) and self-tests on a known-bad zoo circuit. | `lint.test.ts` |

## Registration semantics (what a registration means)

The circuit proves the credential's properties **at registration time**.
`ZkGate` turns that into a bounded-lifetime allowlist entry:

- An account is registered while `block.timestamp < registeredUntil[account]`,
  where `registeredUntil` is the end of the epoch in which it registered.
- In the next epoch the scope changes, so the old proof is useless and the
  holder must prove again; at that point revocation, expiry, sanctions changes
  and issuer removal apply. The maximum staleness is one epoch
  (`epochDuration`, 30 days in the tests and the deploy script).
- The governor can `deregister` an account immediately. The nullifier stays
  burned, so the same credential cannot re-register at that gate in the same
  epoch.
- The allowlisted address itself is public. If it is a transferable smart
  account, control of the registration moves with it; integrators that need
  "this person, now" must check `isRegistered` at the point of use and keep
  epochs short.

## Known limitations

- **Not audited. Not for production.** The trusted setup is a deterministic dev
  ceremony with public toxic waste; anyone can forge proofs for these keys.
- **Governance is trusted**: the sanctioned list, `currentDate`, root sets and
  deregistration are controlled by `GOVERNOR_ROLE` / `DATE_ORACLE_ROLE`. A real
  deployment would decentralise or time-lock these.
- **Per-person Sybil resistance depends on the issuer** issuing one commitment
  per vetted person (see actors table).
- **The revocation tree can never be empty.** An empty circomlib sparse Merkle
  tree has root 0, which the gate rejects (`ZeroRoot`, 0 marks an empty ring
  slot). Every deployment therefore revokes the sentinel credential id
  `REVOKED_SENTINEL = 1`; the issuer CLI refuses to sign ids 0 and 1.
- **Exact-date matching**: the proof's `currentDate` must equal the gate's, so a
  date update (and an epoch boundary, for the scope) invalidates proofs that
  are in flight. Accepting the previous date as well was considered and
  rejected: it would let a credential that expired on the update day register.
  Provers simply re-prove (about 3 s for Groth16 on the dev box).
- **Grace windows**: within `revocationRootGracePeriod` after a new revocation
  root, a credential revoked by that root can still register against the
  previous root. Choose a short window (or 0) and use `invalidateRevocationRoot`
  for urgent revocations.
- **Issuer-side policy**: the circuit does not check that dates are calendar
  dates or that `accredited` is boolean; a malicious issuer can sign such
  values (zoo #2's precondition). Only field-wrapped values are rejected by the
  circuit itself.
- **Low-entropy secrets** make commitments and nullifiers guessable. The holder
  CLI generates 248-bit secrets and the prover refuses secrets under 128 bits.
- The demo sanctioned list and issuer set are illustrative, not authoritative.

## Bug zoo mapping

| # | Circuit | ZK-audit name | OWASP SC (2026) | Forged proof? | Production rejects via |
|---|---|---|---|---|---|
| 1 | `zoo/nullifier_unconstrained.circom` | Under-constrained signal (`<--`) | SC05 | Yes (patched `.wtns`) | `nullifier <== nf.out` (constraint violation; `wtns check` differential) |
| 2 | `zoo/age_no_rangecheck.circom` | Missing range check / field overflow | SC09 (+ SC05) | Yes (needs an issuer that signs a non-date) | `Num2Bits(32)` in `AgeAtLeast18` |
| 3 | `zoo/merkle_selector_nonboolean.circom` | Non-boolean selector / mux forgery | SC05 (impact SC01) | Yes (self-signed credential, untrusted key) | boolean constraint in `MerkleInclusionProof` |
| 4 | `zoo/nullifier_no_scope.circom` | Missing domain separation (fully constrained) | SC02 | No: two honest proofs, wrong statement | `NullifierHash` binds `appScope` |

## Static analysis triage

- **circomspect**: one suppression, `CS0017` on `recipientSquare` (the dummy
  quadratic constraint that binds `recipient`); justification in
  `circuits/circomspect-triage.json` and `circuits/CIRCOMSPECT.md`.
- **Slither 0.11.6** (`--fail-high`): 0 results after triage. Suppressed
  inline in `ZkGate.sol`, each with a comment: `weak-prng` on
  `scopeForEpoch` (the `% FIELD` reduces a public domain-separation hash into
  the scalar field; it is not randomness) and `timestamp` on the epoch and
  grace-window comparisons (windows are hours to days; validator drift is
  seconds).
- **forge lint**: `block-timestamp` (same reasoning) and one `unsafe-typecast`
  (`uint64(block.timestamp)` cannot truncate for ~5.8e11 years), suppressed
  inline with justifications.
