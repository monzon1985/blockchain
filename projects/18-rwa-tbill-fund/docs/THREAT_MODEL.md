# Threat model

> Technical demonstration. Not a real fund, not a compliant financial product, not audited.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Share ownership records | `FundShareToken` balances, `ComplianceEngine` investor ledger | The register of who owns the fund. Must only change through compliant paths. |
| Pending subscriptions | Settlement asset held by `FundVault` (`totalPendingDepositAssets`) | Investor cash waiting for the next epoch. |
| Reserved redemptions | Settlement asset held by `FundVault` (`totalReservedRedeemAssets`) | Cash owed to redeemers after settlement. |
| Fund assets | Idle balance in `FundVault` plus principal deployed with the custodian | Backs every outstanding share at NAV. |
| Dividend funds and escrow | `DividendDistributor` | Entitlements of record-date holders, including frozen ones. |
| Identity integrity | `IdentityRegistry` wallet bindings, claims and removal watermarks | Decides who may hold shares at all. |
| NAV integrity | `FundVault.latestNav` / `referenceNav` / `navWindowAnchor` | Prices every subscription and redemption. |
| Lawful orders | `FundShareToken.lawfulOrders` (and the anchored documents behind them) | The only authority for referenced forced transfers. |
| Document trail | `DocumentRegistry` hashes and anchoring times | Evidence for lawful orders and fund documents. |

## Actors

| Actor | Capabilities |
|---|---|
| Investor | Holds shares, transfers them, requests subscriptions and redemptions, claims, appoints ERC-7540 operators, vetoes a recovery of its own wallet, converts a settled subscription that compliance refuses to mint into a redemption. |
| Claim issuer (KYC provider) | Signs EIP-712 claims (EOA or ERC-1271 contract); revokes its own claims. Trusted per topic by the compliance officer. |
| Anyone | Relays signed claims, triggers dividend claims and escrow releases (always paid to the entitled wallet). |
| Transfer agent (`TRANSFER_AGENT`) | Executes lawful orders (forced transfers within an order issued by the fund administrator), initiates / cancels / executes lost-wallet recoveries. Cannot bind wallets. |
| Compliance officer (`COMPLIANCE_OFFICER`) | Binds wallets to identities, trusted issuers, required topics, claim removal, modules and their limits, freezes. |
| Fund administrator (`FUND_ADMIN`) | Epoch close and settlement, custody moves, documents, lawful orders (issue / revoke), dividends. |
| NAV oracle (`NAV_ORACLE`) | Posts NAV observations within the circuit breaker. |
| Governance (`ADMIN`, AccessManager root) | Grants roles, wires selectors, binds the token, the reference-less 7943 forced transfer, custodian changes and custody write-downs, NAV reference reset. The deployment script puts it behind an execution delay (default 2 days) and delays role grants and selector re-wiring. |
| Custodian | Holds deployed principal; must approve the vault for recalls. |

## Trust assumptions

1. Governance is honest and slow (multisig + AccessManager delays; `script/Deploy.s.sol` configures them). It can re-wire everything.
2. The NAV oracle reports the true NAV. On-chain checks bound the damage of a wrong value (forward pricing, 24 h staleness, +/- 2 % per epoch and per 24 h window) but cannot detect a plausible lie inside the band.
3. The custodian returns deployed assets; the vault cannot enforce it. Losses are recognised by a governance write-down.
4. Claim issuers attest truthfully. The registry enforces who may attest to what, expiry, revocation and removal, not truthfulness.
5. The fund administrator posts a dividend Merkle root that matches record-date balances. The contract caps payouts at the funded amount but does not recompute balances on-chain.
6. Compliance modules are reviewed before the compliance officer plugs them in. The engine calls them on every movement.
7. The settlement asset is a plain ERC-20 (USDC-like): no transfer fees, no rebasing, no transfer hooks, and the same decimals as the share (enforced by the vault constructor).

## Attack surface and mitigations

Vulnerability classes follow the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/).

| Threat | Class | Mitigation | Evidence |
|---|---|---|---|
| A code path moves shares without compliance (forced transfer, recovery, claim, burn) | SC02 Business logic | Single choke point: OZ `ERC20._update` is overridden and every movement, including forced and recovery ones, goes through `_checkedUpdate`, which calls `compliance.transferred` before balances change. | Invariants I-1, I-2; the mutation that bypasses the engine in `forcedTransfer` is caught (see the README). |
| An eligibility bug hides behind the "no path skips compliance" check | SC02 | The invariant handler and the Medusa harness judge every movement with an independent model (their own copy of wallet bindings, claim expiries, retired and pending wallets), never with the token's `canSend` / `canReceive`; I-6 compares the token's eligibility with that model for every wallet. | I-6; the mutation "any registered wallet is eligible" is caught. |
| Forced transfer to an ineligible wallet | SC01 Access control | `_checkedUpdate` requires recipient eligibility for every credit; forced transfers only bypass freezes and sender eligibility. Recipient-side modules (holder caps, investor cap) still apply. | `test_forcedTransfer_neverBypassesRecipientEligibility`, I-1. |
| Transfer agent seizes shares (with any anchored document, by replaying an order, or to a wallet it binds) | SC01 | A referenced forced transfer needs a `LawfulOrder` record issued by `FUND_ADMIN` that names the debited and credited accounts, a maximum amount and an expiry, and points at an anchored ERC-1643 document. Every execution consumes the amount; order ids are single-use; `FUND_ADMIN` can revoke what is left. Wallet binding is a compliance-officer power, not the transfer agent's. The reference-less 7943 entry point is governance-only. | `test_regression_transferAgentAloneCannotSeizeShares`, the order tests in `FundShareTokenTest`, I-1 ("lawful order executed beyond its amount"). |
| Lost-wallet recovery abused to steal a position | SC01 | Two roles: only `COMPLIANCE_OFFICER` binds the successor wallet to the identity; only `TRANSFER_AGENT` initiates and executes. The successor must be bound to the same identity and verified at initiation and at execution; 2-day timelock; the lost wallet can veto; after a veto or cancel the wallet cannot be targeted again for 7 days; the lost wallet is locked during the timelock and retired forever afterwards; full event trail. | `test_regression_transferAgentAloneCannotRecoverToAWalletItBinds`, `test_veto_startsCooldownAgainstReinitiation`, `RecoveryTest`. |
| A transfer agent keeps a holder locked out by re-initiating recoveries | SC01 | A pending recovery locks the wallet, but the holder can veto at once, and every veto or cancel starts a 7-day cooldown. | `test_veto_startsCooldownAgainstReinitiation`, `test_cancel_startsCooldownToo`. |
| A retired wallet (or an operator it approved) claims the controller's vault proceeds | SC01 | Vault claims accept only the current wallet of the succession chain and its operators, and nobody while a recovery of that wallet is pending. | `test_regression_retiredWalletAndItsOperatorsCannotClaim`, `test_claimsWaitWhileARecoveryIsPending`. |
| A removed or revoked claim is revived by relaying an older signed claim | SC01 / SC05 | Per (identity, topic) `minIssuedAt` watermark: raised to the `issuedAt` of every accepted claim and to the current time on removal or revocation of the stored claim; only claims issued strictly after it are accepted. Revoking a claim that is not stored never moves the watermark (anyone can call `revokeClaim` with a made-up claim naming themselves as issuer). | `test_regression_removedClaimCannotBeRevivedByAStaleSignedClaim`, `testFuzz_removalIsNeverUndoneByAClaimIssuedBeforeIt`, `test_revokeClaim_strangerCannotRaiseAnotherIdentitysWatermark`. |
| Per-country holder counts drift (the classic ERC-3643 bug: the decrement uses the investor's *current* country) | SC02 | Holders are counted per identity; the wallet -> identity binding and identity -> country attribution are snapshotted on entry, and the exit decrements the snapshotted bucket. | I-3; the classic bug re-injected as a mutation is caught. |
| Subscription accepted, settled, then never claimable (country full, investor cap), cash stranded | SC02 | `requestDeposit` checks the controller's whole unminted position (estimated at the lowest NAV the circuit breaker allows) against every module as a mint. If a cap fills up after the request, the controller converts the settled subscription into a redemption of the open epoch (`convertUnclaimableDeposit`), priced forward like any redemption. | `test_regression_subscriptionIntoAFullCountryIsRejectedUpFront`, `test_regression_unclaimableSubscriptionConvertsIntoARedemption`. |
| Buying at a stale NAV (subscribing after the NAV is known) | SC03 Oracle manipulation | Forward pricing: the settlement NAV must be observed strictly after the epoch cutoff; requests after the cutoff go to the next epoch. | `test_settleEpoch_forwardPricingRejectsNavAtOrBeforeCutoff`. |
| Compromised or faulty NAV oracle, alone or with the fund administrator | SC03 | +/- 2 % band per epoch against the previous settlement NAV **and** +/- 2 % against the anchor of the current 24 h window (so fast back-to-back epochs cannot ratchet the price), 24 h staleness limit, oracle cannot settle (separate `FUND_ADMIN` role). Larger moves need governance (`resetNavReference`). | `test_regression_navCannotBeRatchetedByFastEpochs`, `test_navWindow_rollsAfter24Hours`, `test_postNav_bandAndTimestampChecks`. |
| Early redeemers extract value from later ones through rounding | SC07 Arithmetic | Every conversion floors in favour of the fund; each controller's claim depends only on its own request and the epoch NAV; per-epoch dust returns to the fund once all requests are folded. | Fuzz over NAVs from 0.001 to 1000: order independence, exact partial claims, no-profit round trip, no dilution; invariants V-4, V-5; a Ceil mutation is caught. |
| Claim signature replay (same registry, other registry, other chain) | SC01 / SC05 | EIP-712 domain (name, version, chain id, verifying contract), issuer inside the signed struct (defeats cross-account ERC-1271 replay), one-time digests, the issuance watermark, issuer revocation including pre-emptive. | `ClaimSignaturesFuzzTest`, registry unit tests. |
| Frozen holder receives cash through dividends | SC02 | Payout to a wallet with any frozen shares is escrowed; release requires the freeze lifted and eligibility. Escrow follows recoveries. | `DividendDistributorTest`, I-1 (dividend branch), I-5. |
| Over-generous Merkle root drains other distributions | SC05 | Per-distribution `claimedAmount <= totalAmount`. | `test_claim_rootCannotPayMoreThanFunded`, I-1 (over-claim attempts on multi-leaf trees). |
| Reentrancy through modules or the settlement asset | SC08 | `ReentrancyGuardTransient` on every vault / distributor entry point that moves assets and on the token's choke point. | `test_moduleCannotReenterAMovement`. |
| Vault insolvency (reserved cash deployed to the custodian) | SC02 | `deployToCustodian` only moves idle assets; settlement reverts unless the vault holds every pending deposit and reserved redemption. | Invariants V-1, V-3. |
| Custodian loss makes the custodian irreplaceable | SC02 | Governance writes off unrecoverable principal (`writeDownCustody`), after which `setCustodian` works again. | `test_regression_custodianReplaceableAfterALoss`. |
| Redemption booked for a controller that can never claim | SC02 | `requestRedeem` rejects the zero controller (its unfolded request would also pin the epoch's rounding dust). | `test_regression_requestRedeemRejectsZeroController`. |
| Unbounded loops | DoS (not in the 2026 Top 10) | Modules <= 8, claim topics <= 31, documents <= 256, succession chain <= 16 hops. | Unit tests for every bound. |
| Overflow / truncation | SC09 | Checked arithmetic; every narrowing cast goes through `SafeCast`. | Static analysis clean. |
| Upgradeability | SC10 | Not applicable: no proxies. Contracts are immutable; configuration changes go through AccessManager. | — |

## Compromised roles

| Role | Worst case | Containment |
|---|---|---|
| `ADMIN` (governance) | Everything: can grant itself any role and re-wire selectors. | Multisig + AccessManager execution delay (deployment default 2 days), delayed role grants and target re-wiring. The delay also applies to `setTargetClosed`: an instant kill switch would need a separate guardian design. |
| `FUND_ADMIN` | Settle at a NAV the oracle posted, deploy idle cash to the (governance-chosen) custodian, anchor bogus documents and issue lawful orders, publish a wrong dividend root (bounded by what it funds). | Cannot post NAV, cannot execute a forced transfer, cannot change the custodian. Seizing shares needs the transfer agent as well. |
| `TRANSFER_AGENT` | Execute the lawful orders `FUND_ADMIN` issued (up to their amounts, before they expire); start recoveries to wallets the compliance officer bound to the same identity (the holder is locked for up to 2 days unless it vetoes, then protected by a 7-day cooldown). | Cannot issue orders, cannot bind wallets, cannot issue claims. Optional AccessManager execution delay (`TRANSFER_AGENT_EXECUTION_DELAY`). |
| `NAV_ORACLE` | Post a NAV inside the band. | Cannot settle; forward pricing and staleness still apply. |
| `NAV_ORACLE` + `FUND_ADMIN` (colluding, or one key as in the local demo) | Settle at a manipulated NAV and trade against it. | At most 2 % per 24 h window (about 4 % across a window boundary), so a walk is slow and visible on-chain; governance can intervene. Over days the walk is not bounded: keep the two roles on separate keys. |
| `COMPLIANCE_OFFICER` | Trust a rogue issuer (who could then verify anyone), bind wallets to any identity, freeze anyone, plug a malicious module (which could block transfers). | Cannot move shares or cash. A malicious module cannot re-enter a movement. Binding a wallet to a victim's identity is useless without the transfer agent. |
| `COMPLIANCE_OFFICER` + `TRANSFER_AGENT` | Bind a controlled wallet to a holder's identity and recover the position to it. | The holder can veto during the 2-day timelock; every step is evented. Keep the roles on separate keys. |
| `VAULT` (contract) | Only the vault contract holds it; mint and burn still go through compliance. | — |

## Recovery when the key is stolen rather than lost

A thief holding the key can veto every recovery. The fallback, all through existing roles: the compliance officer freezes the wallet (`setFrozenTokens`) and unbinds it (`unregisterWallet`), so it can no longer send or receive; the fund administrator anchors the court or regulator order and issues a lawful order from the stolen wallet to the investor's new wallet; the transfer agent executes it (forced transfers bypass the freeze and the sender's eligibility). See `test_stolenKeyFallback_lawfulOrderMovesThePosition`. Vault requests whose controller is the stolen wallet remain claimable by whoever holds that key (to an eligible receiver), so they should be settled and claimed, or redirected by the investor, before the key is reported stolen.

## Known limitations

- No ERC-7887 cancellation of pending requests and no partial fills: an epoch settles every request in full. A settled subscription that compliance refuses to mint can only be converted into a redemption.
- The subscription pre-check estimates at the lowest NAV the circuit breaker currently allows, so a request within about 2 % of an investor cap is refused even if the actual NAV would have fit.
- A NAV move above 2 % per epoch or per 24 h window halts settlement until governance calls `resetNavReference` (fail-safe, not fail-open).
- The dividend root is trusted; there is no on-chain record-date checkpoint of balances. Unclaimed dividends never expire.
- `requestRedeem` requires the owner to be eligible and unfrozen. A KYC-lapsed investor cannot redeem until KYC is renewed; otherwise the only route is a court- or regulator-ordered forced transfer (a lawful order issued by `FUND_ADMIN`, executed by `TRANSFER_AGENT`).
- A cancelled recovery also starts the 7-day cooldown, so an initiation with the wrong successor costs a week.
- ERC-20 approvals are not compliance-gated (only movements are), consistent with ERC-3643.
- The lockup keeps one lock per wallet: a new subscription restarts the clock for the whole locked amount.
- The transfer window has no holiday calendar.
- A compliant transfer costs about 153k gas (vs 64k for a plain ERC-20 transfer), and a subscription request about 196k (the compliance pre-check): eligibility reads, 4 modules and the investor ledger.
- Nothing here has been professionally audited.
