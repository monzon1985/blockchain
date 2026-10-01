# Threat model

> **Technical demonstration.** The Test Payment Dollar (tPD) is a test token for local chains. It is not a stablecoin, has no reserves, is not affiliated with any issuer, is not a compliant financial product under the GENIUS Act or any other regime, and has not been audited. The model below is written the way it would be for a production system so that the controls can be judged on their merits.

## Assets

| Asset | Why it matters |
|---|---|
| Holder balances | The value itself. |
| Supply integrity | Every token must be backed: supply may only grow within attested reserves, allowances and rolling limits. |
| Compliance guarantees | A blocklisted or frozen account must not be able to move value, and funds may only leave it under a recorded lawful order. |
| Signed authorizations | Permits, ERC-3009 authorizations and reserve attestations are bearer instruments until used; replay equals theft or fake backing. |
| Governance and upgrade path | Whoever controls the implementation controls every balance. |

## Actors and trust assumptions

| Actor | Trust |
|---|---|
| Holders, spenders, relayers | Untrusted. Relayers only pay gas for ERC-3009 / permit submissions and cannot alter what was signed. |
| Role holders (see [ROLE-COMPROMISE.md](ROLE-COMPROMISE.md)) | Trusted within their role; each compromise is analysed separately. |
| Reserve attestor | Trusted to report reserves honestly. The contract enforces freshness, monotonicity and domain binding, not truthfulness. |
| OpenZeppelin AccessManager 5.7.0 | Trusted authority: correct scheduling, delays, guardians and role bookkeeping. |
| Off-chain legal process | Produces the lawful orders whose hashes (`orderRef`) are recorded. The contract cannot judge an order's validity. |

## Attack surface and mitigations (OWASP Smart Contract Top 10, 2026)

| Class | Surface | Mitigation | Evidence |
|---|---|---|---|
| SC01 Access Control | 20 restricted token selectors (16 mapped to operational roles, 4 ADMIN-only) plus the AccessManager admin selectors | Every selector wired through AccessManager; governance and upgrades behind a 2-day execution delay in every configuration (also when the deployer is governance); PAUSER guardian on upgrades; deployer renounces ADMIN; `initialize` rejects an authority without code; post-deploy verification checks the ERC-1967 implementation, rebuilds membership from events and fails on anything unexpected or still pending (members, delays, scheduled operations) | `AccessControl.t.sol` (every selector rejects outsiders and wrong roles), `RoleGraph.t.sol`, `Initialization.t.sol`, `VerifyRoles.s.sol` |
| SC02 Business Logic | freeze / blocklist bypass through any value-moving path; minting beyond allowances, limits or reserves | Single `_update` choke point for every movement except the two lawful-order paths; restricted minters and bridges refused; minter issuance capped three times, bridge issuance twice | Invariants I-1 to I-6 (Foundry + Medusa properties and `assert` postconditions), 9-mutant smoke test |
| SC03 Price Oracle Manipulation | the reserve attestation is the oracle | EIP-712 domain binding (chain id + proxy), strictly increasing `asOf`, 26 h freshness at submission and at mint, ERC-1271 attestors supported, shortfalls recorded rather than rejected | `Reserves.t.sol`, `SignatureFuzz.t.sol` (wrong domain, fork, replay), invariant I-2 |
| SC04 Flash-Loan Facilitated | none: no price, no collateral, no vote weight derived from balances | n/a | n/a |
| SC05 Lack of Input Validation | zero addresses, zero amounts, empty order references, limits above the ceiling | Custom errors carrying the offending values for each case | revert-path unit tests (100 % branch coverage) |
| SC06 Unchecked External Calls | ERC-1271 `isValidSignature` | `SignatureChecker` checks success, return size and magic value in a `staticcall` | `test_permit_bytes_walletRevocation`, `testFuzz_*_erc1271` |
| SC07 Arithmetic Errors | reserve headroom, rolling-window sums | headroom written as a subtraction (no overflow panic for absurd amounts); OpenZeppelin `RateLimiter` saturating math | `testFuzz_attestation_gatesMint`, `testFuzz_rollingLimitMatchesReferenceModel` (differential against a naive model) |
| SC08 Reentrancy | none reachable | no token hooks; external calls limited to the trusted AccessManager (before any state change) and `staticcall`s | [STATIC_ANALYSIS.md](STATIC_ANALYSIS.md) |
| SC09 Integer Overflow / Underflow | allowances, windows | Solidity 0.8 checked arithmetic; no `unchecked` block in `src/` | compiler |
| SC10 Proxy & Upgradeability | storage collisions, uninitialized implementation, initializer front-running, unauthorized upgrade | ERC-7201 namespaces only (no sequential storage), `_disableInitializers()` in both constructors, parameterless `initializeV2`, UUPS authorization through AccessManager with delay and guardian, storage-layout gate against the committed v1 baseline, sentinel test across a real upgrade, invariants across a mid-run upgrade | `Upgrade.t.sol`, `scripts/check-storage-layout.mjs`, invariant I-7 |

## Signature-specific threats

| Threat | Mitigation |
|---|---|
| Replay on another chain after a fork | OpenZeppelin `EIP712` rebuilds the domain separator when `block.chainid` changes; covered for permit, `transferWithAuthorization` (`bytes` and `(v, r, s)` entry points) and attestations by `testFuzz_*_chainIdChangeAfterFork`. `receiveWithAuthorization` and `cancelAuthorization` hash through the same domain separator, and a wrong chain id in their domain is rejected by `testFuzz_3009_wrongDomainRejected`. |
| Replay on another deployment | `verifyingContract` is the proxy; `test_attestationIsBoundToThisToken`. |
| Replay of a used authorization | permit: sequential nonce; ERC-3009: random 32-byte nonces marked used (also by `cancelAuthorization`); attestations: strictly increasing `asOf`. |
| Signature malleability | OpenZeppelin `ECDSA` rejects high-`s` signatures. |
| Front-running `receiveWithAuthorization` | the caller must be the payee (`ERC20InvalidReceiver` otherwise). |
| Front-running `transferWithAuthorization` / `permit` | harmless for the signer: the signed payment or approval happens exactly as signed; only the gas payer changes. Integrators should tolerate a permit that was already consumed. |
| ERC-1271 revocation | contract signatures are checked at submission time, so a wallet can revoke a pending authorization (`test_permit_bytes_walletRevocation`). |
| EIP-7702 delegated EOAs | such accounts have code, so `SignatureChecker` routes them to ERC-1271; their delegate must implement `isValidSignature` for the `bytes` entry points to work (the `(v, r, s)` entry points keep working). |

## Known limitations

1. **Single-chain reserve accounting.** Bridge mints are reserve-gated like minter mints, which is exact for one deployment. A real multi-chain token needs the attestation to cover the global supply (or per-chain allocations); that accounting is out of scope.
2. **Attestor honesty.** The contract enforces freshness, domain binding and monotonicity, not truth. An inflated attestation removes the reserve cap; allowances, rolling limits and the ceiling still apply.
3. **Instant seizure power.** COMPLIANCE_OFFICER can freeze and seize any holder without delay, as lawful-order regimes require. The pause is the circuit breaker; a hardened option (execution delay + PAUSER guardian) is described in [ROLE-COMPROMISE.md](ROLE-COMPROMISE.md).
4. **Single ADMIN member.** No one but the scheduler can cancel a malicious admin operation in the default wiring; add a second ADMIN member in production.
5. **Lowering the minter ceiling is not retroactive.** Existing limits stay until the master minter reconfigures or removes the minter.
6. **Relayers are not screened.** A blocklisted address can still pay gas to relay someone else's ERC-3009 payment (as with USDC); it cannot move its own funds or receive any. Minters and bridges, by contrast, are screened: a restricted one can neither mint nor burn.
7. **Shortfall semantics.** A shortfall attestation is accepted and blocks issuance; burns and transfers continue. Invariant I-2 is therefore stated precisely: supply never exceeds the latest attested reserves unless that attestation itself reported the shortfall, and then supply has not grown since.
8. **Rolling-limit storage growth.** OpenZeppelin's `SlidingWindow` appends a checkpoint per successful consumption (reads stay logarithmic, and the history is reset whenever the window empties); a very active minter or flagged account slowly grows storage.
9. **Containment is global or slow for some roles.** Revoking a role, lowering a limit or replacing a key takes 2 days (it goes through ADMIN). A compromised BLOCKLISTER or COMPLIANCE_OFFICER can only be stopped instantly with the global pause, and a compromised PAUSER can lift the pause; see [ROLE-COMPROMISE.md](ROLE-COMPROMISE.md).
10. **Revoking allowances is always possible**, also while paused and for a restricted owner; this is deliberate (it moves no value) and differs from USDC, which refuses approvals of any amount in those states.
11. **Not audited.** Nothing in this repository has been professionally audited.
