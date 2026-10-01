# Threat model: Passkey-First Smart Account

Scope: `contracts/src` (PasskeyAccount, PasskeyAccountFactory, TokenPaymaster, TestUSD), `bundler/` (bundler-lite,
delegation-target classifier, 7702 signing policy) and the `web/` wallet. Nothing here has been audited; the code is a
technical demonstration that runs against local chains only. Vulnerability classes use the
[OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/) naming where one applies.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Account funds (ETH, ERC-20, NFTs), EntryPoint deposit included | Factory clones, or the EOA itself in 7702 mode | The thing an attacker wants; gas payments are one way to move it |
| Account configuration: passkey `(qx, qy, rpIdHash)`, guardians, threshold, freeze, pending recovery | ERC-7201 namespace `passkeysa.account.v1` | Whoever controls it controls the funds |
| Paymaster EntryPoint deposit and stake | EntryPoint v0.9 | Pays everybody's gas; draining it is a DoS and a loss |
| Paymaster token float (TestUSD) | TokenPaymaster | Fronts sponsor-guaranteed first operations |
| Sponsor key | Off-chain (an unlocked devnet account in the demo) | Can make the paymaster front costs |
| EOA key (7702 mode) | The user's device | Root of the account: can always re-delegate or send plain transactions |

## Actors and trust assumptions

| Actor | Trusted for | Not trusted for |
|---|---|---|
| Owner (passkey; in 7702 mode also the EOA key) | Everything the account can do | - |
| Guardians (EOAs or ERC-1271 contracts), as a threshold | Liveness of recovery; and, because an executed recovery installs the passkey they chose, custody whenever the owner does not veto within 48 h | Bypassing the timelock or an owner veto |
| A single guardian (below threshold) | Freezing the account once per recovery epoch | Moving funds, recovering alone, keeping the account frozen indefinitely |
| EntryPoint v0.9 (eth-infinitism, unmodified) | Correct validation/execution/accounting | - |
| Bundler (bundler-lite or any other) | Nothing: it can only submit operations the account and paymaster validated | - |
| Paymaster owner | Price, sponsor key, deposit/stake, token withdrawals | Cannot touch user accounts; worst case prices gas badly or stops sponsoring |
| Sponsor key | Authorizing guaranteed first operations | A compromised sponsor key makes the paymaster front gas for arbitrary ops (bounded by the float and deposit) |
| WebAuthn authenticator / browser | Binding assertions to the RP id, user presence/verification | - |
| Whoever controls the RP id's domain (every subdomain included) | Not producing assertions on the user's behalf: the account checks the RP id hash, not the origin | - |

Operational assumption: the owner (or a service acting for the owner) watches `RecoveryScheduled` events and vetoes
recoveries it did not ask for within the 48 h timelock.

Privileged roles and what a compromise enables:

| Role | Capabilities | Impact if compromised |
|---|---|---|
| `threshold` guardians | `approveRecovery` for a passkey of their choice; after 48 h anyone calls `executeRecovery`, which installs it and lifts any freeze | Account takeover unless the owner vetoes within 48 h (in 7702 mode the EOA key stays root and can re-delegate) |
| One guardian | `freeze()` once per recovery epoch (7 days) | Liveness griefing: at most 7 days per compromised guardian and epoch; the owner removes it once the freeze expires |
| `TokenPaymaster.owner` (Ownable2Step) | `setTokenPrice` (bounded to [1, 10^7] TUSD/ETH), `setSponsorSigner`, `withdraw`, `addStake`/`unlockStake`/`withdrawStake`, `withdrawTokens` | Paymaster funds and pricing; never user funds |
| `TestUSD.owner` | `mint` | Test token supply (valueless) |
| `PasskeyAccountFactory` | Initializes clones it just deployed | None over existing accounts or 7702 EOAs (it refuses delegated senders) |

## Attack surface and mitigations

| # | Threat | OWASP SC class | Mitigation | Test |
|---|---|---|---|---|
| T1 | Forged or replayed user operation | Access control | WebAuthn (type, challenge = userOpHash, rpIdHash, UP, UV, BE/BS, low-s) or 7702 EOA ECDSA; EntryPoint nonce | `PasskeyAccountValidation.t.sol`, INV-1/INV-2 |
| T2 | Assertion made for another relying party | Access control | `rpIdHash` bound per passkey (OpenZeppelin's WebAuthn omits this check). The `clientDataJSON` origin is **not** checked: see the known limitations | `test_WebAuthn_WrongRpId`, `test_WebAuthn_WrongRpIdEvenWithTheRightOrigin`, `test_WebAuthn_OriginIsNotChecked_SameRpIdFromAnotherOriginIsAccepted`, bundler integration "another relying party" |
| T3 | Signature malleability | Signature issues | High-s rejected by `P256.verify` | `test_WebAuthn_HighS` |
| T4 | Initialization front-running of a 7702 delegate | Access control | `initialize` only from self / EntryPoint (EOA-signed op) / factory; `initializeWithSig` needs an EIP-712 signature by the EOA | H01 |
| T5 | Storage collision after re-delegation | Unsafe storage | ERC-7201 namespace unique to this implementation | H02 |
| T6 | chainId-0 authorization replay | Replay | Wallet policy never signs chainId 0; bundler-lite refuses them; init signatures are chain-bound | `units.test.ts` policy tests, bundler integration "-32602", `test_Hazard03_InitSignatureIsChainBound` (the H03 pair itself is a protocol demonstration) |
| T7 | `tx.origin == msg.sender` assumptions broken by 7702 | Reentrancy | No ORIGIN opcode in any production contract | `test_Hazard04_NoTxOriginInProductionBytecode` (the H04 vault pair is a demonstration) |
| T8 | ERC-1271 replay across accounts sharing a passkey | Replay | ERC-7739 nested typed data / personal sign | H05, `PasskeyAccountErc1271.t.sol` |
| T9 | Malicious guardians (up to N) | Access control | 48 h timelock + owner veto; approvals die with each epoch bump. At threshold they win if the owner does not veto in time (accepted, see limitations) | `PasskeyAccountRecovery.t.sol`, INV-4/INV-5 |
| T10 | Stolen passkey | Access control | Any guardian can freeze for 7 days. While frozen every user operation fails validation (`validAfter = frozenUntil`), the veto included, so the thief cannot move value, not even as gas paid to a beneficiary it picks; execution, rotation, guardian changes and ERC-1271 are blocked too. The owner vetoes through `cancelRecoveryWithSig`, relayed and paid by a third party | `test_Freeze_*` (including `test_Freeze_StolenPasskeyCannotSpendEthAsVetoGas` and `...TokensAsVetoGas`), `test_Veto_Relayed*`, INV-6 |
| T11 | Paymaster deposit drain via inflated `paymasterPostOpGasLimit` | DoS / economic | OpenZeppelin 5.7 prices the EntryPoint's unused-gas penalty into the charge; limit bounded to [60k, 200k] | `test_PostOpPenalty_IsChargedToTheSender`, INV-7/INV-8 |
| T12 | postOp griefing (drain balance or revoke allowance during execution) | DoS / economic | Worst case pulled during validation; refund in postOp | `test_Griefing_*`, INV-8 |
| T13 | Bundler DoS by ops that pass simulation and fail on chain | DoS | bundler-lite enforces ERC-7562 opcode rules on a real trace, the EntryPoint access rules (OP-052/053/054) on the call tree, the account and paymaster validity windows (-32503), and requires a staked paymaster | `bundler.integration.test.ts`, `opcodeRules.test.ts`, `units.test.ts` |
| T14 | User signs a 7702 authorization to a sweeper | Phishing | Delegation-target classifier + signing policy run before the EOA key signs: balance drains, value forwarding, open executors, execution controlled by a hardcoded third party, dynamic delegatecall, self-destruct, unverified `validateUserOp`; anything not rated `safe` is refused | `classifier.test.ts` (20-contract corpus, caller-guard semantics), `units.test.ts` policy tests, e2e test 2 (an upgrade attempted with the demo sweeper as target fails with "authorization refused"; the EOA code stays `0x`, its nonce 0, and no block is mined) |
| T15 | One compromised guardian keeps the account frozen by re-freezing | DoS / access control | One freeze per guardian per recovery epoch; the owner removes the guardian once its freeze expires | `test_Freeze_OncePerGuardianPerEpoch`, `test_Freeze_GriefingGuardianCannotLockTheAccountForever`, INV-10 |

## Known limitations (accepted)

- **7702 mode keeps the EOA key all-powerful.** A freeze cannot stop the EOA key from sending plain transactions or
  re-delegating. Guardians protect the passkey, not the EOA key.
- **Guardians at threshold can take the account over.** They approve a passkey of their choice; 48 h later anyone can
  execute the recovery, which installs it and lifts any freeze. Only an owner veto stops this, so the owner must watch
  `RecoveryScheduled` events. Recovery exists for owners who lost their device, so the design accepts that an owner who
  stays away for 48 h while a threshold of guardians turns against them loses the account (in 7702 mode the EOA key
  still re-delegates).
- **A thief holding the passkey can stall recovery**: it can veto every scheduled recovery. Each veto bumps the recovery
  epoch, which restores every guardian's freeze, so guardians that keep scheduling recoveries keep the account frozen:
  a stalemate that moves no funds, because a frozen account validates no user operation.
- **The freeze is rate-limited, which cuts both ways.** Each guardian freezes at most once per recovery epoch, so k
  compromised guardians below the threshold can lock the account for at most k x 7 days before the owner removes them
  (one batch, so they cannot re-freeze in between). Conversely, guardians that never schedule a recovery can hold off a
  thief for at most N x 7 days in one epoch.
- **The veto during a freeze needs a relayer.** A frozen factory account validates no user operation, so the owner
  vetoes by having anyone submit `cancelRecoveryWithSig` and pay its gas. (A 7702 EOA can call `cancelRecovery` on
  itself.) The demo wallet does not expose freezing or this relayed path.
- **The WebAuthn origin is not checked, only the RP id hash.** Browsers let every origin whose registrable domain
  matches the RP id, subdomains included, request assertions for it, and such assertions validate
  (`test_WebAuthn_OriginIsNotChecked_SameRpIdFromAnotherOriginIsAccepted`). Whoever controls any subdomain of the RP id
  is therefore trusted. Binding an origin would break on localhost ports and cost a string comparison per validation.
- **Delegating away and back restores the old configuration** (`test_Hazard02_Note_StateSurvivesRoundTrip`).
- **Raw EOA signatures stop working with code-aware ERC-1271 verifiers after the upgrade** (OpenZeppelin 5.7
  `SignatureChecker`, Permit2): the account only accepts ERC-7739-wrapped signatures (`test_Eip7702_EoaSignerThroughErc7739`).
- **`isValidSignature` reads `block.timestamp`** for the freeze check; a paymaster or aggregator that calls ERC-1271 during
  validation would trip ERC-7562 OP-011.
- **`initializeWithSig` reads `block.timestamp`** for its deadline, so it is meant for relayed transactions, not for the
  EntryPoint's 7702 `initCode` stage (the wallet uses the EntryPoint-only `initialize` path in `callData` instead).
- **Sponsor-guaranteed operations can be unpaid**: if the new account does not approve the paymaster, the paymaster
  absorbs the cost the sponsor authorized (`test_Guaranteed_UnpaidOpIsAbsorbedByPaymaster`, INV-9).
- **Admin-set price, no oracle.** The price is bounded but can be stale.
- **bundler-lite is a development bundler**: single node, one operation per bundle, no reputation system, no mempool
  sharing, no storage-rule enforcement (it requires a staked paymaster instead; the storage rules are proven in Foundry).
- **The classifier is a heuristic**, not a verifier. It trusts code reachable only through `CALLER == ADDRESS` (the EOA
  itself) or `CALLER == <EntryPoint>` (canonical v0.6 to v0.9 EntryPoints, plus the one the wallet passes, since the local
  EntryPoint is compiled from source). Trusting the EntryPoint path is only sound if `validateUserOp` verifies a signature:
  the classifier flags a `validateUserOp` that reaches no signature primitive, but a contract that calls one and ignores
  the result gets through. It also misses destinations computed through memory or deep internal call chains, code
  fetched with `EXTCODECOPY` or deployed by the delegate, and token transfers behind the EOA's own check. Caller checks
  against a storage-loaded address give `review`. It fails closed on budget exhaustion (`review`, not `safe`), and the
  wallet only signs for `safe` targets.
- **Demo sponsor and dev routes** (`/api/sponsor`, `/api/dev/*`) sign or send with unlocked devnet accounts and are
  disabled unless `WALLET_DEV_TOOLS=1`.
