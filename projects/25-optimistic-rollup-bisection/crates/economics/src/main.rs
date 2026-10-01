// SPDX-License-Identifier: MIT
//! Prints the tables used in `docs/ECONOMICS.md`.

use rollup_economics::{Bold, classic_delay, classic_delay_unchallenged, devnet, griefing_delay, mainnet_like};

fn days(s: f64) -> f64 {
    s / 86_400.0
}

fn main() {
    let d = devnet();
    println!("## Devnet parameters (`rollup-cli deploy` defaults, 20 gwei)\n");
    println!("| quantity | value |");
    println!("|---|---|");
    println!("| honest challenger: gas for a full game | {:.0} |", d.challenger_gas());
    println!("| honest defender: gas for a full game | {:.0} |", d.defender_gas());
    println!("| honest challenger cost (gas + capital), ETH | {:.5} |", d.honest_challenger_cost());
    println!("| honest defender cost (gas + capital), ETH | {:.5} |", d.honest_defender_cost());
    println!("| challenger profit per fraud proven, ETH | {:.5} |", d.challenger_profit());
    println!("| defender profit per griefing challenge, ETH | {:.5} |", d.defender_profit());
    println!("| minimum challenger bond, ETH | {:.5} |", d.min_challenger_bond());
    println!("| deployed challenger bond / minimum | {:.1} |", d.challenger_bond / d.min_challenger_bond());
    println!("| max game duration, s | {:.0} |", d.max_game_duration());

    println!(
        "\n## Delay bought with an attacker budget (mainnet-like: W = 7 d, T = 3.5 d, D = 32, honest challenger reacts \
         within L = 1 h)\n"
    );
    println!(
        "| B_p (ETH) | budget (ETH) | squat rounds | squat delay, honest challenger watching (days) | squat delay, nobody \
         else challenging (days) | griefing delay (days) | BoLD-style k=2 delay (days) |"
    );
    println!("|---|---|---|---|---|---|---|");
    for bond in [1.0, 10.0, 100.0] {
        let p = mainnet_like(bond, 1.0);
        let bold = Bold { period: p.window, k: 2.0, claim_bond: 1.0 };
        for budget in [10.0, 100.0, 1_000.0] {
            let c = classic_delay(&p, budget);
            let alone = classic_delay_unchallenged(&p, budget);
            let g = griefing_delay(&p, budget);
            println!(
                "| {bond} | {budget} | {:.0} | {:.1} | {:.1} | {:.1} | {:.1} |",
                c.rounds,
                days(c.seconds),
                days(alone.seconds),
                days(g.seconds),
                days(bold.max_delay())
            );
        }
    }
}
