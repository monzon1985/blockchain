# Threat model: VolatilityFeeHook

Scope: `src/VolatilityFeeHook.sol`, `src/libraries/VolatilityMath.sol`, `src/modules/LiquidityTelemetry.sol`, as
deployed next to an unmodified Uniswap v4 `PoolManager`. Nothing in this repository has been professionally audited.

## Assets

| Asset | Where it lives | What the hook can do to it |
|---|---|---|
| LP principal and fees | PoolManager (ERC-20 balances + pool fee growth) | Nothing directly. The hook never holds, takes or settles LP funds, and declares neither `afterAddLiquidityReturnDelta` nor `afterRemoveLiquidityReturnDelta`, so it cannot tax deposits or exits. |
| Surcharge in flight | PoolManager transient deltas, within one `swap` call | Debited to the hook by `donate()` inside `afterSwap` and credited back by the `afterSwapReturnDelta` the PoolManager applies when `afterSwap` returns. Net zero by the time `swap` returns (asserted after every swap in `BatchSwapRouter` and the Medusa harness). |
| ERC-6909 claims | PoolManager | Nothing. Swaps settled by burning claims or taken as claims are reconciled like ERC-20 swaps (I-3), and the PoolManager's balances are checked to cover every claim (I-8). |
| Fee integrity | Hook storage (`PoolState` per `PoolId`) | Determines what every swap pays. The fee, rate and anchor are written only by the first swap of each block and by `beforeInitialize`; the block's price range is extended by the swaps of that block. |
| Liveness of swaps and exits | PoolManager control flow | A hook revert inside a callback reverts the user's operation, so every hook code path must be revert-free for valid inputs. |
| Admin configuration | Hook storage (allowlist, module) | Owner-controlled; see "Roles". |

## Actors

| Actor | Capabilities | Trust |
|---|---|---|
| Swapper (retail / noise flow) | Calls any router; chooses amounts, direction, price limits, `hookData`, ERC-20 or ERC-6909 settlement | Untrusted |
| Arbitrageur / searcher / builder | Everything a swapper can do, plus transaction ordering within and across blocks (bundles) | Untrusted |
| LP, including just-in-time LPs | Adds and removes liquidity at any time, in any range, alone or inside multi-action unlocks | Untrusted |
| Pool creator | Initializes any `PoolKey` that names this hook (pool creation is permissionless in v4) | Untrusted |
| Keeper (anyone) | Calls `deliverNotification` with a notification read from `LiquidityNotificationQueued` | Untrusted: can only deliver what was committed, once, outside any unlock |
| Owner (`Ownable2Step`) | Edits the currency allowlist, replaces the liquidity module | Trusted for liveness of the allowlist, not for funds (see below) |
| Liquidity module | Arbitrary code chosen by the owner, called when a notification is delivered | Untrusted: treated as hostile by design, and never run inside a swap, an addition or an exit |
| PoolManager | Calls every callback; holds all funds | Trusted (Uniswap v4-core, unmodified) |
| Tokens | ERC-20 contracts of the pool's currencies | Untrusted unless allowlisted; the allowlist assumes standard, non-rebasing, non-fee-on-transfer tokens |

## Roles and what a compromised role can do

| Role | Powers | Worst case if compromised |
|---|---|---|
| Owner | `setCurrencyAllowed`, `setLiquidityModule`, `transferOwnership` (two-step), `renounceOwnership` | Allowlist a malicious or fee-on-transfer token for **new** pools (existing pools are unaffected: the check only runs in `beforeInitialize`). Set a module: from then on every liquidity operation in every pool of this hook, existing pools included and with immediate effect (no timelock, no per-pool opt-in), pays a fixed ~33,000 gas to queue one notification (measured: 175,937 -> 208,572 gas for a removal). What the module does has no effect on that cost, and the owner cannot impose a gas floor on LPs or make a module run during their operations. Cannot move funds, change fees, block swaps or block exits. Renouncing freezes the allowlist and the module. |
| Liquidity module | Runs when someone delivers a notification addressed to it | Waste up to `MODULE_GAS_LIMIT` (100,000) gas of whoever delivers to it, and act inside that deliverer's transaction while the PoolManager is locked: it cannot take, settle, mint, burn, swap or modify liquidity there (all revert with `ManagerLocked`), only open an unlock of its own (which must settle itself) or move the transaction's `sync` checkpoint (which every settlement overwrites). Its failures are recorded (`success = false`) and the notification is consumed. |
| Keeper | Delivers notifications | Nothing: a notification is accepted only if it matches the stored commitment, only while the PoolManager is locked, only once, and only with enough gas to give the module its full budget. |

There is no upgrade path (no proxy), and the fee curve is immutable per deployment.

## Attack surface and mitigations

Vulnerability classes follow the OWASP Smart Contract Top 10 (2026). "Test" names the function that enforces the
mitigation; mutants are the committed patches in `test/mutants/` (`bash script/mutants.sh`).

| # | Threat | Class | Mitigation | Test |
|---|---|---|---|---|
| T1 | Anyone calls a callback directly with crafted arguments, or forges a module notification | SC01 Access Control | `BaseHook.onlyPoolManager` on all ten callbacks; admin is `onlyOwner`; `deliverNotification` is permissionless but only accepts data matching a commitment stored by a real liquidity change | `testFuzz_ToB1_*`, `test_callbacks_revertWhenNotCalledByPoolManager`, `test_deliver_revertsForTamperedOrUnknownNotifications` |
| T2 | Attacker creates a pool with this hook and hostile or fee-on-transfer tokens, or a static fee that silently ignores the override | SC05 Input Validation | `beforeInitialize` requires `DYNAMIC_FEE_FLAG` and allowlisted currencies; all state keyed by `PoolId` | `test_ToB2_*`, `test_initialize_revertsFor*`, `test_feeOnTransfer_*`, `test_rebasing_*` |
| T3 | Surcharge accounting leaks value: wrong sign, wrong currency, rounding in the trader's favour, a charge without a matching donation, claim-settled swaps treated differently | SC02 Business Logic, SC07 Arithmetic | Surcharge on the unspecified side, rounded up and never above the charge on the whole amount; donated in full in the same callback; hook holds nothing | `testFuzz_ToB3_everyChargeMatchesItsDonation`, `test_surcharge_settledWithClaimsReconciles`, invariants I-1 to I-4, `test_differential_proRatedSurcharge`, mutants M01, M17 |
| T4 | Rounding drift amplified by repetition (the Bunni lesson) | SC07 Arithmetic | EWMA rounds down and is a contraction (errors cannot grow); fee and surcharge round up | `test_differential_repeatedUpdates50`, `test_ToB3_fiftyTinySwapsCannotUndercutOneSwap`, `test_ToB3_fiftyLiquidityCyclesCannotExtractValue`, mutants M10 to M12 |
| T5 | Oracle manipulation: pump or depress the fee | SC03 Price Oracle Manipulation | The sample is the open-to-close tick move of each block, so an intra-block round trip moves nothing; the fee is fixed for the whole block before any swap in it runs; moving the price across blocks means paying LP fees and surcharges on real volume | `test_fee_constantWithinBlock`, `test_ToB4_firstSwapCannotPriceItsOwnFee`, invariant I-6, Medusa `property_feeConstantWithinBlock` (applied fee), mutants M14, M15 |
| T6 | Splitting or shaping an arbitrage to dodge the top-of-block surcharge: a dust swap first, a two-transaction bundle, or a swap split at the block's opening price (the review's crossing cliff) | SC02 Business Logic | The surcharge follows the block's price range, not the swap's position in the block, and a swap that leaves the range is charged pro rata for the new ground only, in the coordinate in which its currency is linear, so the charge is continuous in the end price and split-invariant at constant liquidity (1 wei per extra leg). Residual: a detour through thin liquidity on the other side of the opening price still undercuts it (known limitation 5) | `test_surcharge_dustFirstSwapDoesNotShieldTheArbitrage`, `test_surcharge_crossingSwapPaysTheSameAsTheSplitTrade`, `testFuzz_ToB3_splittingASwapCannotUndercutTheSurcharge`, `test_surcharge_knownLimitation_thinSideDetourUndercutsTheArbitrage`, invariant I-9, mutants M06 to M09 |
| T7 | Hook logic runs in the wrong callback (pre- vs post-swap state) | SC02 Business Logic | Oracle sample, anchor and range reset in `beforeSwap` (pre-swap = block open); surcharge sized from the realized delta and donated in `afterSwap` (post-swap range) | `test_ToB4_donationReachesPostSwapLiquidityOnly` |
| T8 | Declared permissions, address bits and implemented callbacks disagree | SC05 Input Validation | HookMiner-mined CREATE2 address; `BaseHook` validates at construction; test cross-checks all 14 bits and every callback | `HookPermissionsTest` (5 tests), `test_missingReturnDeltaBitBricksSurchargedSwaps` |
| T9 | Non-essential module blocks or griefs exits: revert, out-of-gas, return bomb, unsettled deltas, `sync` hijack, the count-neutral `settleFor` trick that defeated the earlier in-unlock sandbox, reentrancy | SC06 Unchecked External Calls, SC08 Reentrancy | Liquidity callbacks only store a commitment and emit an event (no external call); the module runs in `deliverNotification`, which requires the PoolManager to be locked, forwards a fixed gas budget with a low-level call that copies no return data, checks EIP-150 gas sufficiency, and deletes the commitment before calling | `ExitAlwaysWorksTest` (16 tests, including `test_exit_countNeutralModuleCannotBlockAMultiActionExit`), `test_deliver_revertsWhileThePoolManagerIsUnlocked`, `test_deliver_neverStarvesTheModule`, invariants I-8 and I-10 (multi-action exits with hostile modules), Medusa `removeLiquidity` and `deliverNotification` assertions, mutants M02, M04 |
| T10 | Notification replayed or delivered to the wrong module | SC01 Access Control, SC02 Business Logic | Commitment is keccak256(module, notification), deleted before the module call | `test_module_deliveryRunsTheModuleExactlyOnce`, `test_deliver_goesToTheModuleThatWasActiveWhenQueued`, invariant I-10, mutant M16 |
| T11 | Surcharge donation reverts because no liquidity is in range after the swap, blocking swaps | SC02 Business Logic (liveness) | Skip the surcharge when `getLiquidity == 0` (the range is still updated) | `test_surcharge_skippedWhenSwapLeavesNoLiquidityInRange`, `test_extremeAmounts_drainingSwapsDoNotRevert`, mutant M03 |
| T12 | State changes between callbacks or across pools in one transaction, including around a rejected nested unlock | SC08 Reentrancy | Transient pre-swap price keyed by `PoolId` and cleared after use; no hook state written after an external call; the hook never opens an unlock | `test_ToB7_*`, `test_manySwapsInOneTransaction`, `test_nestedUnlock_betweenTwoHookPoolSwapsChangesNothing` |
| T13 | Overflow at extreme ticks, amounts or configurations | SC09 Overflow | Bounds proven in comments; `SafeCast` on every narrowing store (EWMA to 88 bits, fee and rate to 16 bits); 512-bit `mulDiv` in the pro rata; fuzzing across the whole config space | `testFuzz_extremeConfig_anyValidConfigIsSafe`, `test_ToB6_extremePriceJumpsNeverBreakSwaps`, `testFuzz_proRatedSurcharge_bounded` |
| T14 | Deployment with an unintended, immutable fee curve (an environment override silently truncated) | SC05 Input Validation | The deployment script narrows overrides with `SafeCast`, so an out-of-range value reverts | `test_readConfig_overridesAreCheckedNotWrapped` |

SC04 (flash loans) is covered by T5: a flash loan cannot change a block's fee, and moving the price with borrowed funds
costs the same fees as with owned funds. SC10 does not apply (no proxy).

## Known limitations

1. **Just-in-time donation capture.** The surcharge is donated to the liquidity in range after the swap. A builder
   who sees the arbitrage can add concentrated liquidity at the post-swap price in front of it and remove it after,
   capturing most of the donation. Uniswap v4 donations have this property in general; vesting donations over time
   would mitigate it at the cost of holding funds in the hook.
2. **The oracle only sees its own pool.** A pool's per-block move is filtered by its own no-arbitrage band, so the
   EWMA under-reads external volatility when fees are high relative to the move (visible in the GBM replay). There is
   no external oracle by design.
3. **Warm-up.** A new pool starts at the 5 bps floor until volatility is observed, and the first block's swaps pay no
   surcharge.
4. **Range surcharges also hit retail flow** that trades beyond the block's range in the same direction as the
   block's arbitrage, after it. The alternative (surcharging only the literal first swap) is trivially bypassed (T6).
   Conversely, ground the block already covered is free: a trader who pushes the price back and then forward again
   within the range pays no surcharge for the second push.
5. **The pro rata assumes constant liquidity over the swap.** When the in-range liquidity changes inside the swapped
   range, a swap that leaves the block's range and the same swap split at the range edge are charged differently, by
   at most the ratio of the largest to the smallest in-range liquidity along the swap
   (`test_surcharge_steppedLiquidityDeviationIsBoundedByTheLiquidityRatio`). The charge never exceeds the rate on the
   swap's whole unspecified amount. The ratio can be large and a trader can exploit it deliberately: where liquidity
   is thin on one side of the block's opening price and thick on the other, a detour through the thin side is cheap,
   turns that side into range the block has already covered, and leaves the arbitrage swap that follows charged on only
   a small share of its thick new ground. With 1,000x thicker liquidity above the opening price the detour cuts the
   surcharge paid by 93% and the trader keeps 88% of it after the detour's LP fees
   (`test_surcharge_knownLimitation_thinSideDetourUndercutsTheArbitrage`). The attack needs that liquidity profile,
   pays LP fees and its own surcharge on the detour, and can only remove LP surcharge income, never principal. An exact
   beyond-the-edge amount (a second tick walk in `afterSwap`) would close it and is listed as future work.
6. **One block means one `block.number`.** "One fee per block", the EWMA sample and the block's surcharge range are all
   keyed on `block.number`. The design assumes an L1-style block number that advances once per block of the chain
   the pool lives on (Ethereum, OP Stack chains). On Arbitrum, `block.number` returns an approximation of the L1 block
   number shared by many L2 blocks: there one "block" of this hook spans all of them, so the fee is fixed and the range
   accumulates across them, and the decay counts L1 blocks. Deploying there would need a different block source.
7. **Module notifications are asynchronous.** A module learns about a liquidity change only when someone delivers the
   notification, possibly much later, and a delivery can fail (it is then consumed). Modules must reconcile from
   PoolManager position state rather than trust that every notification arrives. A delivery transaction must hold
   `MODULE_GAS_LIMIT * 64/63 + 15,000` gas (~117,000) at the hook's check: `eth_estimateGas` finds that limit, but tools
   that set the gas limit from simulated usage (e.g. `forge script`, whose default multiplier is 1.3) need a higher
   multiplier (the local demo uses 3.0).
8. **Allowlist assumptions.** Fee-on-transfer and rebasing tokens break PoolManager accounting, not the hook's; the
   allowlist is the only defence and relies on the owner. The adversarial suite shows what happens if it is misused.
9. **`slot0.lpFee` stays 0.** The effective fee comes from the per-swap override; integrators should call
   `quoteFees(key)` (or simulate the swap) instead of reading `slot0`.
10. **Legacy-pipeline PoolManager in tests.** Tests and gas numbers use v4-core compiled with this project's settings
   (legacy pipeline, 1,000,000 optimizer runs). The canonical PoolManager is compiled via-IR, so absolute gas differs;
   the hook-vs-static deltas are the meaningful numbers. Built this way the PoolManager is 26,934 bytes, above
   EIP-170's 24,576, so the local demo runs anvil with a raised code-size limit.
