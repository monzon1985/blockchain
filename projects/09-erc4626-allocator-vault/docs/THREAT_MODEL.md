# Threat model: Curated ERC-4626 Allocator Vault

Scope: `src/AllocatorVault.sol`, `src/libraries/VaultMath.sol`, `src/access/VaultRoles.sol` and their interaction
with an OpenZeppelin `AccessManager` and curated ERC-4626 strategies. Vulnerability classes are named after the
[OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/). Nothing here has been professionally audited.

## 1. Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Depositor principal | Idle balance of the vault and the vault's shares of each strategy | The thing being protected |
| Share price integrity | `totalAssets()` and the conversions | Wrong price = value transfer between depositors, or bad collateral valuation for integrators |
| Unlock schedule | `_lockedProfit`, `_checkpoint.unlockEnd` | Controls how fast profit reaches the price (sandwich surface) |
| Booked value and impairment state | `lastTotalAssets`, pending removals, each strategy's valuation | Decides whether a markdown is priced in, booked as a loss, or reversed |
| High-water mark and fee state | `highWaterMark`, fee rates, `feeRecipient` | Fees are paid in shares, i.e. by depositors |
| Curation state | caps, withdraw queue, pending values | Decides where principal can go |

## 2. Actors

| Actor | Powers | Worst case if malicious or compromised |
|---|---|---|
| Depositor | deposit, mint, withdraw, redeem | Economic attacks: donation/inflation, sandwiching, first-mover exits, rounding extraction. All covered by PoCs. |
| Keeper / anyone | `accrue`, `acceptCap` and `acceptFees` once a timelock has elapsed | None beyond timing: accrual cannot move the price unfairly (profit is locked, losses are immediate, an impaired position books nothing). Under-funding the transaction cannot make a strategy look broken (out-of-gas guard). |
| Allocator | `reallocate`, `setWithdrawQueue` | Concentrates funds in the riskiest listed strategy up to its cap; orders the queue so withdrawals hit illiquid strategies last or first; churns allocations, losing at most one strategy share of rounding per move. Cannot send funds anywhere but listed strategies. |
| Curator | `submitCap`, `submitStrategyRemoval`, `removeStrategy`, `submitFees`, `setFeeRecipient` | After a 3-day timelock the guardian did not revoke: lists a malicious strategy, raises caps, raises fees (max 50 % performance / 5 % a year management), crystallizes a forced removal's write-off. Immediately: lowers caps, lowers fees, redirects future fees to itself, and announces a forced removal of a zero-cap strategy, which redeems what it can, prices the rest in at once and pauses deposits (it cannot buy into that markdown itself). |
| Guardian | `revokePendingCap`, `revokePendingRemoval`, `revokePendingFees`, `zeroCap` | Blocks curation (no new strategies, cap increases, fee increases, forced removals) and stops new allocations. Revoking a forced removal restores the position's full valuation at once (it was never booked as a loss). Cannot move funds; withdrawals keep working. |
| AccessManager admin | grants roles, maps selectors to roles, can replace the vault's authority | Can make itself curator and allocator, but the timelocks live in the vault, so it is bounded by the curator row above. |
| Strategy (after listing) | holds vault funds, answers `balanceOf` / `previewRedeem` / `maxRedeem` / `maxWithdraw` | **Trusted component.** A lying `previewRedeem` mis-prices the vault. A strategy whose views revert (paused, which EIP-4626 allows, or broken) is contained: its position counts as 0, the vault keeps working at the conservative price, books no profit or loss, pauses deposits, and the strategy can be force-removed. A non-compliant strategy that reports `maxWithdraw` / `maxRedeem` it then refuses blocks the withdrawals that reach it in the queue until the allocator reorders it. A strategy whose views burn all the gas they are given is not contained (see Known limitations). The vault also defends against short delivery and reentrancy. |
| Asset token | transfers | Fee-on-transfer and rebasing behavior is detected on deposit and on strategy withdrawals. |

## 3. Trust assumptions

1. Listed strategies are honest ERC-4626 vaults over the same asset: `previewRedeem` reflects what the vault could
   withdraw and does not over-state it. This is the curator's job and the reason listings are timelocked.
2. The asset is a standard ERC-20 and the vault holds at most 2^186 (about 1e56) base units of it. Share prices are kept
   in RAY (1e27) and the virtual shares put at least 1e6 share units against the vault's assets, so below that bound
   every price and every share supply fits in 256 bits; far beyond it the price views revert. No real token comes close,
   but the bound is exact and tested (`test/unit/AssetBound.t.sol`); the a16z time-and-fees configuration found it with
   a donation of ~2^255.
3. The guardian is independent from the curator (for example, a separate multisig), so it can veto the curator.
4. Timestamps are accurate to within a few seconds; nothing in the vault needs more precision than that.

## 4. Attack surface and mitigations

| # | Threat | OWASP class | Mitigation | Evidence |
|---|---|---|---|---|
| T1 | First-depositor donation / inflation attack | SC07 Arithmetic Errors (Rounding & Precision), SC02 Business Logic | 10^6 virtual shares; donations are profit that unlocks over 7 days; deposits that would mint 0 shares revert | `test/attacks/DonationAttack.t.sol` (naive steals 1,000 tokens; hardened attacker loses ~half the donation, victim loses at most donation / 10^6) |
| T2 | Harvest sandwich (deposit before a yield event, redeem after) | SC04 Flash Loan-Facilitated Attacks, SC02 | Every profit is locked; whenever new profit arrives, all locked profit restarts a full 7-day linear unlock, so no profit is ever released faster than over 7 days | `test/attacks/HarvestSandwich.t.sol` (same-block P&L <= 0; the gain from a harvest when holding `dt` is <= yield x dt / 7d x share, fuzzed, including with older profit still unlocking: the earlier profit-weighted merge broke this by ~5x) |
| T3 | First-mover loss escape | SC02 | Strategies are valued live and the loss is recognized before pricing any exit; a strategy that under-delivers reverts the withdrawal instead of being topped up from other depositors' idle assets; announcing a forced removal redeems everything redeemable and the rest counts as 0 while it is pending, so the write-off reaches the price when the removal is announced, not three days later, and no live liquidity figure (which a flash-loaned deposit into the strategy can raise for one transaction) is ever trusted | `test/attacks/FirstMoverLoss.t.sol` (same price for early and late withdrawers, fuzzed over amounts, loss and order); `test_remove_forcedRemovalWindowGivesNoFirstMoverEscape` (800 vs 800; was 1,000 vs 600); `test_remove_flashLiquidityCannotReopenTheFirstMoverEscape` (800 vs 800; 1,000 vs 600 when the pending position was counted at `previewRedeem(min(shares, maxRedeem))`) |
| T4 | Rounding extraction (1-wei loops) | SC07 | Deposit and redeem round down, mint and withdraw round up, all against the caller | `test/attacks/OneWeiRoundingLoop.t.sol`, rounding fuzz tests in 6/8/18 decimals, a16z suite at `_delta_ = 0` |
| T5 | Share price used as collateral is inflated (Resupply-class) | SC03 Price Oracle Manipulation | 7-day unlock plus `safeSharePrice` / `safeConvertToAssets`, whose growth is capped at a fixed rate per year, linear from the last checkpoint at which the cap did not bind (the checkpoint stays put while it binds, so frequent `accrue()` calls cannot compound it), and which follow losses down at once | `test/unit/RateLimiter.t.sol` (`test_safePrice_resupplyClassInflationIsBounded`, `test_safePrice_frequentAccrualsDoNotCompoundTheLimit`: 1.25x a year with daily accruals, was 1.2839x) |
| T6 | Read-only reentrancy (a strategy reads the price mid-withdrawal, when shares are burned but assets not yet moved) | SC08 Reentrancy Attacks | `ReentrancyGuardTransient` on every state-changing entry point and `nonReentrantView` on every price view | `test/unit/Reentrancy.t.sol` (a hostile strategy calls all 17 price views and 11 entry points mid-call; each must revert with `ReentrancyGuardReentrantCall`) |
| T7 | Fee-on-transfer or rebasing asset mints unbacked shares | SC05 Lack of Input Validation | Balance-delta check on deposit (`AssetTransferMismatch`); strategy withdrawals must deliver in full (`StrategyUnderDelivered`); forced removal books what actually arrived | `test/unit/FeeOnTransfer.t.sol` (naive vault charges earlier depositors for later fees; hardened reverts) |
| T8 | Curator rug: list a malicious strategy, raise caps or fees, write off a strategy | SC01 Access Control | 3-day timelock enforced inside the vault (not only in AccessManager), guardian veto, fee maximums, write-offs need their own timelock | `test/unit/Governance.t.sol`, `test/unit/Fees.t.sol`, `test/unit/StrategyRemoval.t.sol` |
| T9 | Fees above what the high-water mark allows | SC02, SC07 | Performance fee only on gain above the mark, management fee linear in time, both rounded down; the mark never decreases | Invariant I4 and I5, `test/unit/Fees.t.sol`, mutation check (doubled fee is caught) |
| T10 | Unbounded loops / gas griefing | SC02 | At most 20 strategies; every accrual reads each once | `test_acceptCap_revertsWhenQueueIsFull`, GasBench |
| T11 | Overflow in views that must never revert | SC09 Integer Overflow and Underflow | 512-bit `mulDiv` everywhere; `maxRedeem` compares in asset space first | Found by the a16z suite, fixed, regression `test_maxRedeem_doesNotRevertWithHugeLockedDonation` |
| T12 | Unchecked external call results | SC06 Unchecked External Calls | `SafeERC20` for every transfer, balance deltas for every inbound strategy transfer | Slither `unused-return` triaged in `docs/STATIC_ANALYSIS.md` |
| T13 | Upgradeability | SC10 Proxy & Upgradeability | Not applicable: the vault is not upgradeable; migrations are done by deploying a new vault | - |
| T14 | One strategy whose views revert (paused, broken) freezes the whole vault, idle funds included, and cannot be removed | SC02, SC06 Unchecked External Calls | Strategy views are called through `try`/`catch`: a failing position counts as 0 and marks the vault impaired; every ERC-4626 view keeps answering, withdrawals keep working, and `removeStrategy` works after a forced removal without valuing the strategy live | `test/unit/Impairment.t.sol` (paused, broken, and refusing-redemption strategies) |
| T15 | Exploiting an impairment: buying into a markdown that later reverses (a strategy resumes, a removal is revoked), or faking one by under-funding a transaction so a strategy call runs out of gas | SC02, SC04 | While a position is impaired: no profit or loss is booked, the price is the conservative `min(counted gross, booked gross - locked profit)`, and deposits are paused (`maxDeposit` = 0); when the impairment ends the value returns at once and nothing is re-locked. A strategy call that comes back with a quarter or less of its gas reverts the transaction instead of counting as a failure | `test_pausedStrategy_noFirstMoverGainAndValueReturnsAtOnce`, `test_pausedStrategy_depositsAndMintsArePaused`, `test_outOfGasInAStrategyIsNeverTreatedAsAFailingStrategy`; invariants I1-I9 with a pausable strategy and forced removals in the handler |

## 5. Known limitations

- **Strategy honesty is assumed.** A strategy whose `previewRedeem` over-states value inflates `totalAssets`. The
  vault cannot detect this; the timelock and the guardian are the defense, plus caps that bound the exposure.
- **Hidden losses.** A loss that a strategy has not yet reflected in its own `previewRedeem` (for example, bad debt a
  lending market has not socialized yet) is invisible to the vault until the strategy reports it. The vault
  recognizes losses as soon as they are observable, not before.
- **Strategy rounding is socialized.** Moving assets through an ERC-4626 strategy can lose up to one strategy share of
  value per move to the strategy's own rounding. The loss is recognized at the next accrual and shared pro rata. It
  cannot be turned into profit (the invariant suite bounds it per action).
- **Profit unlocking is a trade-off.** Holders who leave during the unlock window forgo their share of still-locked
  profit, which goes to those who stay. This is what removes the sandwich incentive. Because new profit restarts the
  7-day line for everything still locked, a vault that sees profit at every accrual releases older profit more slowly
  (roughly exponentially, time constant 7 days, instead of linearly) and holds about 7 days of yield locked instead of
  3.5. Anyone can cause a restart with a 1-wei donation; that only delays profit, it cannot redirect it.
- **Losses first cancel locked profit.** A loss smaller than the still-locked profit does not move the price; it only
  reduces what will unlock. Every holder is treated identically, so there is no first-mover advantage.
- **Impaired positions are priced conservatively.** While a strategy cannot be valued, or a forced removal is pending on
  a position that still holds value, withdrawals pay the conservative price and deposits are paused. If the markdown
  later reverses, the holders who stayed receive the haircut of those who left; if it does not, everyone ends at the
  same price. A strategy that pauses for a single block therefore costs whoever withdraws during that block. A haircut
  large enough to lift the stayers' share price above the high-water mark pays the performance fee on that excess, like
  any other gain above the mark; a recovery that only brings the price back towards the mark pays none
  (`test/medusa/MedusaRegression.t.sol` replays both cases). Borrowers repaying into a strategy whose removal is pending
  do not move the price until the funds are recovered (by the allocator, the removal itself, or a revocation): counting
  live liquidity is exactly what a flash deposit can fake.
- **The loss event itself can be front-run.** A forced removal prices its write-off in the transaction that announces
  it; someone watching the mempool could exit just before it, as before any loss that becomes visible in one
  transaction. Curators should submit removals through a private relay.
- **Re-listing is visible.** A written-off strategy that recovers comes back as locked profit when it is re-listed
  (3-day timelock). Depositors who enter during that window share in the recovered value as it unlocks.
- **Non-compliant strategies.** A strategy whose `maxRedeem` / `maxWithdraw` report liquidity it then refuses is only
  contained partly: withdrawals that reach it revert until the allocator moves it down the queue (once its forced
  removal is announced it counts as 0 like any other pending removal).
- **Strategies whose views burn all their gas.** A view that fails by consuming all the gas it is forwarded (an infinite
  loop, or a pre-0.8 Solidity `assert` / division by zero, which use the `INVALID` opcode) looks exactly like a call
  the transaction under-funded, so the out-of-gas guard reverts instead of counting it as impaired. Such a strategy
  blocks every accrual, and therefore `removeStrategy`, like a reverting strategy did before `try`/`catch`. Curators
  should only list strategies whose views revert normally (Solidity >= 0.8 or Vyper); a bounded gas stipend per view
  would contain it at the price of treating legitimately gas-heavy strategies as failing.
- **Management fee is simple interest** between accruals and is capped at 100 % of total assets.
- **Fee-on-transfer assets are not supported**; the vault refuses deposits of them rather than accounting for them.
- **Liquidity.** Withdrawals can only be as liquid as idle plus the strategies' `maxWithdraw`. `maxWithdraw` and
  `maxRedeem` report this honestly, and a withdrawal that cannot be covered reverts.
- **Size.** The runtime bytecode is 22,765 bytes (EIP-170 limit 24,576) with `optimizer_runs = 1_000`.
