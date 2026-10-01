// SPDX-License-Identifier: MIT
//! # rollup-economics
//!
//! A small, explicit model of bond sizing against delay attacks for this rollup's dispute protocol, and of a
//! BoLD-style bounded-delay variant. `docs/ECONOMICS.md` derives the formulas; `cargo run -p rollup-economics`
//! prints the tables quoted there.
//!
//! All amounts are in wei-denominated `f64` ether units for readability; this is a planning model, not accounting.

/// Parameters of the dispute protocol and of the environment it runs in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Params {
    /// Challenge window `W`, seconds.
    pub window: f64,
    /// Chess-clock budget per party `T`, seconds.
    pub clock: f64,
    /// Bisection depth `D` (traces of `2^D` steps).
    pub depth: u32,
    /// Proposer bond `B_p`, ether.
    pub proposer_bond: f64,
    /// Challenger bond `B_c`, ether.
    pub challenger_bond: f64,
    /// Burned share of a forfeited bond (0.10 in this protocol).
    pub burn: f64,
    /// Gas of the challenger's opening move, `DisputeGame.challenge` (`g_c`).
    pub gas_challenge: f64,
    /// Gas of the defender's opening move, `DisputeGame.commitEnd` (`g_e`).
    pub gas_commit_end: f64,
    /// Gas of one bisection move, `bisect` or `choose` (`g_m`).
    pub gas_move: f64,
    /// Gas of the one-step proof (worst case: `INPUT` over a full tape) (`g_s`).
    pub gas_step: f64,
    /// Gas price, ether per gas.
    pub gas_price: f64,
    /// Opportunity cost of locked capital, per second (e.g. 5%/year).
    pub capital_rate: f64,
    /// Reaction latency `L` of an independent honest challenger: from an invalid proposal to its challenge on L1.
    pub reaction: f64,
}

/// Seconds per year.
pub const YEAR: f64 = 365.0 * 24.0 * 3600.0;

impl Params {
    /// Moves one side makes in a full game: the defender reveals its final state and posts `D` midpoints, the
    /// challenger opens the game and chooses `D` times; the one-step proof is extra and made by whoever wins it.
    pub fn moves_per_side(&self) -> f64 {
        f64::from(self.depth) + 1.0
    }

    /// Upper bound on a game's duration: each party can spend at most `T` in total.
    pub fn max_game_duration(&self) -> f64 {
        2.0 * self.clock
    }

    /// Gas an honest challenger spends on a full game: `challenge` + `D` choices + the one-step proof.
    pub fn challenger_gas(&self) -> f64 {
        self.gas_challenge + f64::from(self.depth) * self.gas_move + self.gas_step
    }

    /// Gas an honest defender spends on a full game: `commitEnd` + `D` midpoints + the one-step proof.
    pub fn defender_gas(&self) -> f64 {
        self.gas_commit_end + f64::from(self.depth) * self.gas_move + self.gas_step
    }

    /// Cost of playing one game to the end: `gas` at the gas price plus `bond_locked` locked for the game's duration.
    pub fn game_cost(&self, gas: f64, bond_locked: f64) -> f64 {
        gas * self.gas_price + bond_locked * self.capital_rate * self.max_game_duration()
    }

    /// What an honest challenger spends proving an output wrong.
    pub fn honest_challenger_cost(&self) -> f64 {
        self.game_cost(self.challenger_gas(), self.challenger_bond)
    }

    /// What an honest defender spends answering a griefing challenge.
    pub fn honest_defender_cost(&self) -> f64 {
        self.game_cost(self.defender_gas(), self.proposer_bond)
    }

    /// What an honest challenger nets for proving an output wrong: `(1 - burn) * B_p` minus its costs.
    pub fn challenger_profit(&self) -> f64 {
        (1.0 - self.burn) * self.proposer_bond - self.honest_challenger_cost()
    }

    /// What an honest defender nets from a griefing challenge: `(1 - burn) * B_c` minus its costs.
    pub fn defender_profit(&self) -> f64 {
        (1.0 - self.burn) * self.challenger_bond - self.honest_defender_cost()
    }

    /// Smallest challenger bond for which answering a griefing challenge is never a loss for the defender.
    pub fn min_challenger_bond(&self) -> f64 {
        self.honest_defender_cost() / (1.0 - self.burn)
    }

    /// What one round of the self-dealing squat costs the attacker: it plays both the invalid proposer and the
    /// challenger that wins against it, so the proposer bond comes back minus the burn.
    pub fn self_dealing_cost_per_round(&self) -> f64 {
        self.burn * self.proposer_bond
    }

    /// Longest a squatted head epoch stays blocked per round when an independent honest challenger is watching: its
    /// own game against the invalid output starts `L` after the proposal and, with the attacker defending on a
    /// clock of `T` and the challenger moving at once, ends by `L + T`. The attacker's self-dealt game must resolve
    /// before that, or the honest challenger collects the bond.
    pub fn squat_round(&self) -> f64 {
        self.clock + self.reaction
    }
}

/// Outcome of a delay attack of a given budget.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Delay {
    /// Rounds the attacker can afford (infinite when a round costs nothing).
    pub rounds: f64,
    /// Extra time before the attacked epoch finalizes, seconds.
    pub seconds: f64,
}

fn rounds(budget: f64, cost_per_round: f64) -> f64 {
    if cost_per_round > 0.0 { (budget / cost_per_round).floor() } else { f64::INFINITY }
}

/// Classic 1-vs-1 protocol (this repository): an attacker squats the head epoch with an invalid output and, to keep
/// its cost at the burn only, also plays the winning challenger against itself. Each round costs `burn * B_p` and,
/// with an independent honest challenger watching (the protocol's safety assumption), blocks the head for at most
/// `T + L` ([`Params::squat_round`]). The delay grows linearly with the attacker's budget.
pub fn classic_delay(p: &Params, budget: f64) -> Delay {
    let rounds = rounds(budget, p.self_dealing_cost_per_round());
    Delay { rounds, seconds: rounds * p.squat_round() }
}

/// The same squat when nobody else challenges: the attacker's self-dealt game may use both clocks, `2T` per round.
pub fn classic_delay_unchallenged(p: &Params, budget: f64) -> Delay {
    let rounds = rounds(budget, p.self_dealing_cost_per_round());
    Delay { rounds, seconds: rounds * p.max_game_duration() }
}

/// Griefing an honest output with challenges. Games must start inside the window and each ends within `2T`, and they
/// run concurrently, so finalization moves from `W` to at most `W + 2T` whatever the number of challenges; the
/// attacker loses `B_c` per challenge.
pub fn griefing_delay(p: &Params, budget: f64) -> Delay {
    let rounds = rounds(budget, p.challenger_bond);
    Delay { rounds, seconds: if rounds >= 1.0 { p.max_game_duration() } else { 0.0 } }
}

/// BoLD-style bounded delay (parameterized): all competing claims for an epoch are resolved in one all-vs-all
/// tournament with a shared challenge period `W_b` and a confirmation bound of `k * W_b` (BoLD uses `k = 2`). The
/// delay is bounded independently of the attacker's budget; what grows with the number of adversarial claims is
/// the honest party's gas, which the per-claim bond must cover.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bold {
    /// Shared challenge period, seconds.
    pub period: f64,
    /// Confirmation bound in periods.
    pub k: f64,
    /// Bond per adversarial claim, ether.
    pub claim_bond: f64,
}

impl Bold {
    /// Maximum delay whatever the attacker spends.
    pub fn max_delay(&self) -> f64 {
        self.k * self.period
    }

    /// Honest gas to refute `n` adversarial claims in a depth-`D` tournament, assuming each claim forces one full
    /// challenger-side game (opening move, bisection path and one-step proof): a conservative upper bound, since
    /// shared prefixes are refuted once in practice.
    pub fn honest_cost(&self, p: &Params, n: f64) -> f64 {
        n * p.challenger_gas() * p.gas_price
    }

    /// Whether every adversarial claim's forfeited bond pays for the honest work it causes.
    pub fn self_funding(&self, p: &Params) -> bool {
        self.claim_bond * (1.0 - p.burn) >= self.honest_cost(p, 1.0)
    }
}

/// Parameters matching `rollup-cli deploy` defaults (window 1 h, clocks 30 min, depth 16, 1 ETH / 0.5 ETH bonds) at
/// 20 gwei. Gas figures are measured, not assumed (`forge test --gas-report`, max): `challenge` 248,036,
/// `commitEnd` 81,555, `bisect` 65,754 and `choose` 54,536 (one figure, the larger, for both); the worst one-step
/// proof is INPUT over a maximum-size 24.6 KB tape, 537,060 gas for the bare verifier call
/// (`worst_case_batch_step_gas` in `crates/diff`) plus ~40k of game overhead. The devnet challenger polls every
/// 500 ms; one minute of reaction latency is generous.
pub fn devnet() -> Params {
    Params {
        window: 3_600.0,
        clock: 1_800.0,
        depth: 16,
        proposer_bond: 1.0,
        challenger_bond: 0.5,
        burn: 0.10,
        gas_challenge: 250_000.0,
        gas_commit_end: 82_000.0,
        gas_move: 66_000.0,
        gas_step: 580_000.0,
        gas_price: 20e-9,
        capital_rate: 0.05 / YEAR,
        reaction: 60.0,
    }
}

/// Mainnet-like parameters: 7-day window, 3.5-day clocks, depth 32, and an honest challenger that reacts within an
/// hour.
pub fn mainnet_like(proposer_bond: f64, challenger_bond: f64) -> Params {
    Params {
        window: 7.0 * 86_400.0,
        clock: 3.5 * 86_400.0,
        depth: 32,
        proposer_bond,
        challenger_bond,
        reaction: 3_600.0,
        ..devnet()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classic_delay_is_linear_in_budget() {
        let p = mainnet_like(10.0, 1.0);
        let d1 = classic_delay(&p, 10.0);
        let d2 = classic_delay(&p, 20.0);
        assert_eq!(d1.rounds, 10.0); // 10 ETH / (10% of 10 ETH)
        assert!((d2.seconds - 2.0 * d1.seconds).abs() < 1e-6);
        assert_eq!(d1.seconds, 10.0 * (3.5 * 86_400.0 + 3_600.0));
    }

    #[test]
    fn an_independent_challenger_roughly_halves_the_squat() {
        // With someone else watching, a round lasts T + L instead of the 2T a self-dealt game alone could take.
        let p = mainnet_like(10.0, 1.0);
        let watched = classic_delay(&p, 100.0);
        let alone = classic_delay_unchallenged(&p, 100.0);
        assert_eq!(watched.rounds, alone.rounds);
        assert_eq!(alone.seconds, 100.0 * 7.0 * 86_400.0);
        let ratio = watched.seconds / alone.seconds;
        assert!(ratio > 0.5 && ratio < 0.51, "{ratio}");
    }

    #[test]
    fn griefing_delay_is_bounded_by_two_clocks() {
        let p = devnet();
        assert_eq!(griefing_delay(&p, 0.1).seconds, 0.0);
        assert_eq!(griefing_delay(&p, 0.5).seconds, 3_600.0);
        assert_eq!(griefing_delay(&p, 1_000.0).seconds, 3_600.0);
    }

    #[test]
    fn bold_delay_ignores_budget_and_bonds_can_self_fund() {
        let p = mainnet_like(10.0, 1.0);
        let b = Bold { period: p.window, k: 2.0, claim_bond: 1.0 };
        assert_eq!(b.max_delay(), 14.0 * 86_400.0);
        assert!(b.self_funding(&p));
        let cheap = Bold { claim_bond: 1e-6, ..b };
        assert!(!cheap.self_funding(&p));
    }

    #[test]
    fn devnet_bonds_make_honest_play_profitable() {
        let p = devnet();
        assert!(p.challenger_profit() > 0.0);
        assert!(p.defender_profit() > 0.0);
        assert!(p.min_challenger_bond() < p.challenger_bond);
        assert_eq!(p.moves_per_side(), 17.0);
    }

    #[test]
    fn opening_moves_are_charged_to_the_side_that_makes_them() {
        let p = devnet();
        let bare = f64::from(p.depth) * p.gas_move + p.gas_step;
        assert_eq!(p.challenger_gas() - bare, p.gas_challenge);
        assert_eq!(p.defender_gas() - bare, p.gas_commit_end);
        // The challenger's costliest non-step transaction is its first one; leaving it out understated its cost.
        assert!(p.gas_challenge > p.gas_commit_end && p.gas_challenge > p.gas_move);
        let without_opening = Params { gas_commit_end: 0.0, ..p };
        assert!(without_opening.min_challenger_bond() < p.min_challenger_bond());
    }

    #[test]
    fn zero_burn_makes_self_dealing_free() {
        // Without the burn a proposer that also plays the winning challenger loses nothing per round, so any budget
        // (even zero) buys unbounded delay; with the default 10% burn every round costs 0.1 * B_p.
        let free = Params { burn: 0.0, ..devnet() };
        assert_eq!(free.self_dealing_cost_per_round(), 0.0);
        assert!(classic_delay(&free, 0.0).rounds.is_infinite());
        assert!(classic_delay(&free, 1.0).seconds.is_infinite());
        let burned = devnet();
        assert!((burned.self_dealing_cost_per_round() - 0.1 * burned.proposer_bond).abs() < 1e-12);
        assert_eq!(classic_delay(&burned, 1.0).rounds, 10.0);
    }
}
