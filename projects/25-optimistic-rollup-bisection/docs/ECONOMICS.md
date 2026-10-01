# Dispute economics: bond sizing, delay attacks, and a bounded-delay variant

This note sizes the two bonds of the protocol against the attacks that do not steal funds but cost honest parties
money or time. Every formula is implemented in [`crates/economics`](../crates/economics/src/lib.rs) and unit-tested;
the tables below are the literal output of `cargo run -p rollup-economics`.

## Parameters

| Symbol | Meaning | `rollup-cli deploy` default |
|---|---|---|
| `W` | challenge window | 3,600 s |
| `T` | chess-clock budget per party | 1,800 s |
| `D` | bisection depth (traces of `2^D` steps) | 16 |
| `B_p` | proposer bond | 1 ETH |
| `B_c` | challenger bond | 0.5 ETH |
| `β` | burned share of a forfeited bond | 10% |
| `g_c` | gas of the challenger's opening move, `challenge` | 250,000 (248,036 measured) |
| `g_e` | gas of the defender's opening move, `commitEnd` | 82,000 (81,555 measured) |
| `g_m` | gas of one bisection move, `bisect` or `choose` | 66,000 (measured max of `bisect`; `choose` is 54,536) |
| `g_s` | gas of the worst one-step proof | 580,000 (537,060 measured for the verifier call over a 24.6 KB tape, plus game overhead) |
| `p` | gas price | 20 gwei |
| `r` | opportunity cost of locked capital | 5% / year |
| `L` | reaction latency of an independent honest challenger (proposal to challenge on L1) | 1 min devnet, 1 h mainnet-like |

## 1. What a game costs the honest side

A game has at most `2D + 2` moves, `D + 1` per side, and lasts at most `2T` because each party can spend at most `T`
in total (chess clocks; invariant I5 in the Foundry suite). Each side pays for its opening move (the challenger's
`challenge`, the defender's `commitEnd`), its `D` bisection moves and possibly the one-step proof, and keeps a bond
locked for the game:

```
C_challenger = (g_c + D · g_m + g_s) · p + B_c · r · 2T
C_defender   = (g_e + D · g_m + g_s) · p + B_p · r · 2T
```

For an honest **challenger** proving fraud, the reward is `(1 − β) · B_p`. For an honest **defender** answering a
griefing challenge, the reward is `(1 − β) · B_c`. Honest play is rational when rewards exceed these costs, which gives
the minimum challenger bond:

```
B_c ≥ ((g_e + D · g_m + g_s) · p + B_p · r · 2T) / (1 − β)
```

## Devnet parameters (`rollup-cli deploy` defaults, 20 gwei)

| quantity | value |
|---|---|
| honest challenger: gas for a full game | 1886000 |
| honest defender: gas for a full game | 1718000 |
| honest challenger cost (gas + capital), ETH | 0.03772 |
| honest defender cost (gas + capital), ETH | 0.03437 |
| challenger profit per fraud proven, ETH | 0.86228 |
| defender profit per griefing challenge, ETH | 0.41563 |
| minimum challenger bond, ETH | 0.03818 |
| deployed challenger bond / minimum | 13.1 |
| max game duration, s | 3600 |

The deployed 0.5 ETH challenger bond is about 13 times the minimum, so answering griefing is profitable even if gas is
13 times more expensive than assumed.

## 2. Three delay attacks

**Griefing a correct output (bounded).** Games must be opened inside the window, they run concurrently, and each ends
within `2T`. Whatever the number of challengers, the output finalizes by `W + 2T`, and each challenge costs the
attacker `B_c`. The e2e scenario `griefing_challenger_loses_on_time` plays this.

**Squatting the head epoch (linear in budget).** Proposals extend a single chain, one canonical proposal per epoch. An
attacker proposes an invalid output for the next epoch; honest proposers must wait until it is invalidated, then
re-propose, and the attacker front-runs them again. The cheapest version is *self-dealing*: the attacker also plays
the challenger that wins, so the proposer bond comes back to it minus the burn, and each round costs `β · B_p`.

How long a round lasts depends on whether anyone else is watching. An independent honest challenger (the protocol's
safety assumption) opens its own game `L` after the proposal. In that game the attacker is the defender, with a clock
of `T`, and the honest challenger moves at once, so it ends by `L + T`. To keep its cost at `β · B_p` the attacker's
self-dealt game must invalidate the output before that; otherwise the honest challenger collects `(1 − β) · B_p`.
Only when nobody else challenges can the self-dealt game use both clocks, `2T`:

```
delay(budget) = ⌊budget / (β · B_p)⌋ · (T + L)      with an independent honest challenger
delay(budget) = ⌊budget / (β · B_p)⌋ · 2T           if nobody else challenges
```

This is why the burn exists: with `β = 0` self-dealing costs nothing and any budget buys unbounded delay (unit test
`zero_burn_makes_self_dealing_free` checks both on the model).

**Parameterized bounded-delay variant (BoLD-style).** Arbitrum's BoLD replaces the chain of 1-vs-1 games with one
all-vs-all tournament per assertion: every competing claim for an epoch is bisected in parallel against a shared
challenge period `W_b`, and confirmation is guaranteed within `k · W_b` (BoLD uses `k = 2`) *whatever the number of
adversarial claims*. What grows with the attack is the honest party's gas, one refutation path per adversarial claim
in the worst case, so the per-claim bond only has to cover that work:

```
delay_bold = k · W_b                            (independent of the attacker's budget)
bond_claim · (1 − β) ≥ (g_c + D · g_m + g_s) · p   (self-funding refutations)
```

## Delay bought with an attacker budget (mainnet-like: W = 7 d, T = 3.5 d, D = 32, honest challenger reacts within L = 1 h)

| B_p (ETH) | budget (ETH) | squat rounds | squat delay, honest challenger watching (days) | squat delay, nobody else challenging (days) | griefing delay (days) | BoLD-style k=2 delay (days) |
|---|---|---|---|---|---|---|
| 1 | 10 | 100 | 354.2 | 700.0 | 7.0 | 14.0 |
| 1 | 100 | 1000 | 3541.7 | 7000.0 | 7.0 | 14.0 |
| 1 | 1000 | 10000 | 35416.7 | 70000.0 | 7.0 | 14.0 |
| 10 | 10 | 10 | 35.4 | 70.0 | 7.0 | 14.0 |
| 10 | 100 | 100 | 354.2 | 700.0 | 7.0 | 14.0 |
| 10 | 1000 | 1000 | 3541.7 | 7000.0 | 7.0 | 14.0 |
| 100 | 10 | 1 | 3.5 | 7.0 | 7.0 | 14.0 |
| 100 | 100 | 10 | 35.4 | 70.0 | 7.0 | 14.0 |
| 100 | 1000 | 100 | 354.2 | 700.0 | 7.0 | 14.0 |

## Reading the table

- In the 1-vs-1 design, raising `B_p` only divides the delay an attacker can buy; it never bounds it. With 100 ETH
  bonds and a 1,000 ETH budget the head can still be held for about 354 days while an honest challenger is watching
  (700 days if nobody else challenges). The honest parties' costs stay small (they are paid by the slashed bonds), so
  the attack is purely a liveness one: no funds are at risk.
- Griefing a correct output is bounded by `2T` no matter the budget, because games run concurrently rather than
  sequentially.
- The bounded-delay variant caps delay at `k · W_b` (14 days here) independently of the budget, which is the property
  BoLD was designed for. The price is protocol complexity (a shared, multi-level tournament), which is out of scope
  for this repository and documented as future work in the README.

## Recommendations for this design

1. Keep `β > 0`; it is what makes self-dealing cost money.
2. Size `B_c` with the formula in section 1 using a pessimistic gas price; the defender must profit from answering.
3. Size `B_p` against the value of delay to the attacker per round (`T + L` with an honest challenger watching, `2T`
   without), not against TVL: funds are protected by the 1-of-N honesty assumption, not by the bond.
4. Allow competing proposals per epoch (or move to a tournament) before relying on this design where liveness has
   economic value.
