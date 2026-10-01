// SPDX-License-Identifier: MIT
//! End-to-end scenarios against a real `anvil` node. Run with:
//!
//! ```text
//! (cd contracts && forge build) && cargo test -p e2e --features anvil -- --test-threads=1
//! ```
#![cfg(feature = "anvil")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, missing_docs)]

use std::time::Duration;

use alloy::{
    primitives::{Address, U256},
    providers::Provider,
    rpc::types::Filter,
    sol_types::SolEvent,
};
use e2e::{CHALLENGE_WINDOW, CLOCK, Devnet, POLL, accounts::*, eth, wait_for};
use rollup_l1::{IBatchInbox, IBridge, IDisputeGame, IOutputOracle, Outcome, Phase, ProposalStatus};
use rollup_node::{
    ProposerConfig,
    games::{outcome, proposal_at},
    util::send,
    wallet,
};
use rollup_stf::Kind;
use rollup_stf::Stf;

const T: Duration = Duration::from_secs(120);

async fn deposit(net: &Devnet, from: usize, to: Address, amount: U256) -> anyhow::Result<()> {
    let (_, c) = net.as_account(from)?;
    send(c.bridge.deposit(to).value(amount), net.address(from)).await?;
    Ok(())
}

async fn l2_send(
    net: &Devnet,
    client: &rollup_node::SequencerClient,
    from: usize,
    kind: Kind,
    to: Address,
    amount: U256,
    nonce: u64,
) -> anyhow::Result<rollup_stf::Record> {
    let domain = net.file.stf()?.domain();
    let record = wallet::sign_tx(&net.signer(from), kind, to, amount, U256::from(nonce), domain)?;
    client.submit(&record).await?;
    Ok(record)
}

async fn wait_balance(client: &rollup_node::SequencerClient, who: Address, expected: U256) -> anyhow::Result<()> {
    wait_for(&format!("L2 balance of {who} to reach {expected}"), T, || async {
        Ok((client.account(who).await?.balance == expected).then_some(()))
    })
    .await
}

/// Every posted epoch has a canonical proposal.
async fn wait_all_proposed(net: &Devnet) -> anyhow::Result<u64> {
    let c = net.contracts()?;
    wait_for("every posted epoch to be proposed", T, || async {
        let batches = c.inbox.batchCount().call().await?.to::<u64>();
        let next = c.oracle.nextEpoch().call().await?;
        Ok((batches > 0 && next == batches + 1).then_some(batches))
    })
    .await
}

async fn wait_finalized(net: &Devnet, epoch: u64) -> anyhow::Result<()> {
    let c = net.contracts()?;
    wait_for(&format!("epoch {epoch} to be finalized"), T, || async {
        Ok((c.oracle.lastFinalizedEpoch().call().await? >= epoch).then_some(()))
    })
    .await
}

async fn wait_game_resolved(net: &Devnet, id: u64) -> anyhow::Result<Outcome> {
    let c = net.contracts()?;
    wait_for(&format!("game {id} to resolve"), T, || async {
        if c.game.gameCount().call().await? < U256::from(id) {
            return Ok(None);
        }
        Ok(outcome(&c, U256::from(id)).await?)
    })
    .await
}

async fn logs<E: SolEvent>(net: &Devnet, address: Address) -> anyhow::Result<Vec<E>> {
    let (provider, _) = net.as_account(DEPLOYER)?;
    let filter = Filter::new().address(address).event_signature(E::SIGNATURE_HASH).from_block(0u64);
    Ok(provider.get_logs(&filter).await?.iter().map(|l| l.log_decode::<E>().unwrap().inner.data).collect())
}

// ---------------------------------------------------------------------------------------------------------------------

/// Honest run: deposits and transfers flow through the sequencer, every epoch is proposed, nothing is challenged,
/// and all outputs finalize after the window with bonds returned.
#[tokio::test(flavor = "multi_thread")]
async fn honest_run() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let seq = net.spawn_sequencer(vec![]).await?;
    let proposer = net.spawn_proposer(PROPOSER, false, POLL)?;
    let challenger = net.spawn_challenger(CHALLENGER)?;
    let (alice, bob, carol) = (net.address(ALICE), net.address(BOB), net.address(CAROL));

    deposit(&net, ALICE, alice, eth(5)).await?;
    deposit(&net, BOB, bob, eth(1)).await?;
    wait_balance(&seq.client, alice, eth(5)).await?;
    wait_balance(&seq.client, bob, eth(1)).await?;
    let alice_tx = l2_send(&net, &seq.client, ALICE, Kind::Transfer, bob, eth(2), 0).await?;
    l2_send(&net, &seq.client, BOB, Kind::Transfer, carol, eth(1) / U256::from(2), 0).await?;
    wait_balance(&seq.client, carol, eth(1) / U256::from(2)).await?;
    wait_balance(&seq.client, bob, eth(3) - eth(1) / U256::from(2)).await?;
    // Anyone can copy an included transaction from L1 calldata; the sequencer refuses to post it again.
    let replay = seq.client.submit(&alice_tx).await.unwrap_err().to_string();
    assert!(replay.contains("stale nonce"), "{replay}");

    let head = wait_all_proposed(&net).await?;
    let c = net.contracts()?;
    // Independent re-derivation agrees with every proposed root, and the challenger opened no game.
    let mut chain = net.file.chain()?;
    let (provider, _) = net.as_account(DEPLOYER)?;
    chain.sync(&provider, &c).await?;
    for e in 1..=head {
        let (_, p) = proposal_at(&c, e).await?.unwrap();
        assert_eq!(Some(p.stateRoot), chain.state_root_at(e), "epoch {e}");
    }
    assert_eq!(c.game.gameCount().call().await?, U256::ZERO);

    net.warp(CHALLENGE_WINDOW).await?;
    wait_finalized(&net, head).await?;
    wait_for("proposer to collect every bond", T, || async {
        Ok((c.oracle.lockedBonds().call().await?.is_zero()
            && c.oracle.credit(net.address(PROPOSER)).call().await?.is_zero())
        .then_some(()))
    })
    .await?;
    assert!(c.oracle.totalBurned().call().await?.is_zero());

    challenger.stop().await;
    proposer.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// Fraud: a malicious proposer mints 1,000 ETH to itself half-way through the epoch's trace. The challenger
/// re-derives, disputes, and the bisection converges to exactly the forged step; the one-step proof on L1 settles
/// it, the proposer bond is slashed (90% to the challenger, 10% burned), and an honest proposer takes over.
#[tokio::test(flavor = "multi_thread")]
async fn fraud_caught_and_dishonest_bond_slashed() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let seq = net.spawn_sequencer(vec![]).await?;
    let challenger = net.spawn_challenger(CHALLENGER)?;
    let alice = net.address(ALICE);
    deposit(&net, ALICE, alice, eth(3)).await?;
    wait_balance(&seq.client, alice, eth(3)).await?;
    l2_send(&net, &seq.client, ALICE, Kind::Transfer, net.address(BOB), eth(1), 0).await?;
    wait_balance(&seq.client, net.address(BOB), eth(1)).await?;

    // One fraudulent proposal, defended with its self-consistent fake trace.
    let mallory = net.spawn_proposer_with(
        MALLORY,
        ProposerConfig { malicious: true, poll: POLL, max_epoch: None, max_proposals: Some(1) },
    )?;
    let c = net.contracts()?;
    let bond_p = c.oracle.PROPOSER_BOND().call().await?;
    let bond_c = c.game.CHALLENGER_BOND().call().await?;
    let challenger_before = net.balance(net.address(CHALLENGER)).await?;

    assert_eq!(wait_game_resolved(&net, 1).await?, Outcome::ChallengerWins);
    mallory.stop().await;

    // The game walked the full depth: commitEnd + 16 x (bisect, choose) + step.
    let g = c.game.getGame(U256::from(1)).call().await?;
    let depth = u16::from(c.game.MAX_DEPTH().call().await?);
    assert_eq!(g.moves, 2 * depth + 2);
    assert_eq!(
        ProposalStatus::from_u8(c.oracle.getProposal(g.proposalId).call().await?.status),
        ProposalStatus::Invalidated
    );

    // Bisection converged to the exact step the fault was injected at (half of the honest trace).
    let mut chain = net.file.chain()?;
    let (provider, _) = net.as_account(DEPLOYER)?;
    chain.sync(&provider, &c).await?;
    let fault_step = chain.trace(g.epoch, None)?.steps() / 2;
    let steps = logs::<IDisputeGame::StepExecuted>(&net, c.deployment.game).await?;
    let first = steps.first().expect("a one-step proof was executed");
    assert_eq!(first.stepIndex, fault_step);
    assert!(!first.defenderCorrect);

    // Bonds: the challenger ends up with its bond back plus 90% of the proposer bond; 10% is burned.
    let payout = bond_c + bond_p - bond_p / U256::from(10);
    wait_for("challenger to claim its winnings", T, || async {
        let got: U256 = logs::<IOutputOracle::CreditClaimed>(&net, c.deployment.oracle)
            .await?
            .iter()
            .filter(|e| e.account == net.address(CHALLENGER))
            .map(|e| e.amount)
            .sum();
        Ok((got >= payout).then_some(()))
    })
    .await?;
    assert_eq!(c.oracle.totalBurned().call().await?, bond_p / U256::from(10));
    assert!(net.balance(net.address(CHALLENGER)).await? > challenger_before);

    // An honest proposer re-proposes the correct root; nobody disputes it.
    let honest = net.spawn_proposer(PROPOSER, false, POLL)?;
    wait_for("honest re-proposal of every epoch", T, || async {
        let Some((_, p)) = proposal_at(&c, 1).await? else { return Ok(None) };
        Ok((p.proposer == net.address(PROPOSER) && Some(p.stateRoot) == chain.state_root_at(1)).then_some(()))
    })
    .await?;
    net.warp(CHALLENGE_WINDOW).await?;
    wait_finalized(&net, 1).await?;
    assert_eq!(c.oracle.finalizedStateRoot(1).call().await?, chain.state_root_at(1).unwrap());

    honest.stop().await;
    challenger.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// Timeout loss, dishonest side: the fraudulent proposer goes offline right after proposing, so it never reveals its
/// final state and loses on time without a single move.
#[tokio::test(flavor = "multi_thread")]
async fn offline_fraudulent_proposer_loses_on_time() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let seq = net.spawn_sequencer(vec![]).await?;
    deposit(&net, ALICE, net.address(ALICE), eth(1)).await?;
    wait_balance(&seq.client, net.address(ALICE), eth(1)).await?;
    let c = net.contracts()?;

    // One tick (it proposes), then it sleeps for an hour: effectively offline.
    let mallory = net.spawn_proposer(MALLORY, true, Duration::from_secs(3_600))?;
    wait_for("fraudulent proposal", T, || async { Ok(proposal_at(&c, 1).await?.map(|_| ())) }).await?;
    mallory.stop().await;

    let challenger = net.spawn_challenger(CHALLENGER)?;
    wait_for("challenge", T, || async { Ok((c.game.gameCount().call().await? == U256::from(1)).then_some(())) })
        .await?;
    net.warp(CLOCK + 1).await?;
    assert_eq!(wait_game_resolved(&net, 1).await?, Outcome::ChallengerWins);
    let g = c.game.getGame(U256::from(1)).call().await?;
    assert_eq!(g.moves, 0, "the defender never moved");
    assert_eq!(c.oracle.nextEpoch().call().await?, 1, "the chain was truncated back to the fraudulent epoch");

    challenger.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// Timeout loss, griefing side: a challenger disputes a correct output and then stops playing; the honest proposer
/// keeps its output and collects 90% of the challenger's bond.
#[tokio::test(flavor = "multi_thread")]
async fn griefing_challenger_loses_on_time() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let seq = net.spawn_sequencer(vec![]).await?;
    let proposer = net.spawn_proposer(PROPOSER, false, POLL)?;
    deposit(&net, ALICE, net.address(ALICE), eth(1)).await?;
    wait_all_proposed(&net).await?;

    let griefer = 8;
    let (_, gc) = net.as_account(griefer)?;
    let bond_c = gc.game.CHALLENGER_BOND().call().await?;
    send(gc.game.challenge(1).value(bond_c), net.address(griefer)).await?;
    let c = net.contracts()?;
    wait_for("defender to bisect and hand the move to the challenger", T, || async {
        let g = c.game.getGame(U256::from(1)).call().await?;
        Ok((Phase::from_u8(g.phase) == Phase::AwaitingChoice).then_some(()))
    })
    .await?;
    net.warp(CLOCK + 1).await?;
    assert_eq!(wait_game_resolved(&net, 1).await?, Outcome::DefenderWins);
    let credited: U256 = logs::<IOutputOracle::Credited>(&net, c.deployment.oracle)
        .await?
        .iter()
        .filter(|e| e.account == net.address(PROPOSER))
        .map(|e| e.amount)
        .sum();
    assert_eq!(credited, bond_c - bond_c / U256::from(10));

    net.warp(CHALLENGE_WINDOW).await?;
    wait_finalized(&net, 1).await?;
    proposer.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// Censorship: the sequencer ignores Alice. Her L2 transaction never lands, and once her forced L1 transaction is
/// overdue the inbox refuses any batch that skips it; Alice posts a forced batch herself and the transfer executes.
#[tokio::test(flavor = "multi_thread")]
async fn censorship_defeated_by_forced_inclusion() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let alice = net.address(ALICE);
    let seq = net.spawn_sequencer(vec![alice]).await?;
    let proposer = net.spawn_proposer(PROPOSER, false, POLL)?;
    let challenger = net.spawn_challenger(CHALLENGER)?;
    let (bob, carol) = (net.address(BOB), net.address(CAROL));

    // Bob funds Alice (a deposit *from* Bob is not censored).
    deposit(&net, BOB, alice, eth(3)).await?;
    wait_balance(&seq.client, alice, eth(3)).await?;

    // Alice's L2 transaction is accepted by the API but never sequenced.
    l2_send(&net, &seq.client, ALICE, Kind::Transfer, carol, eth(1), 0).await?;
    deposit(&net, BOB, bob, eth(1)).await?; // other traffic keeps flowing
    wait_balance(&seq.client, bob, eth(1)).await?;
    assert_eq!(seq.client.account(carol).await?.balance, U256::ZERO);

    // Alice goes through L1.
    let (_, ac) = net.as_account(ALICE)?;
    send(ac.queue.forceTransfer(carol, eth(2)), alice).await?;
    let c = net.contracts()?;
    let window = c.queue.INCLUSION_WINDOW().call().await?;
    net.mine(window + 1).await?;

    // The censoring sequencer can no longer post a batch that skips the overdue message.
    let (_, sc) = net.as_account(SEQUENCER)?;
    let err = sc
        .inbox
        .submitBatch(Default::default(), vec![])
        .from(net.address(SEQUENCER))
        .call()
        .await
        .expect_err("a batch skipping an overdue message must revert");
    assert!(matches!(
        err.as_decoded_interface_error::<IBatchInbox::IBatchInboxErrors>(),
        Some(IBatchInbox::IBatchInboxErrors::ForcedInclusionViolated(_))
    ));

    // Escape hatch: Alice posts the forced batch herself.
    let (ap, _) = net.as_account(ALICE)?;
    let mut chain = net.file.chain()?;
    let epoch = wallet::force_batch(&ap, &ac, &mut chain, alice).await?;
    assert!(c.inbox.batch(U256::from(epoch)).call().await?.forced);
    wait_balance(&seq.client, carol, eth(2)).await?;

    // The epoch is proposed with the forced transfer applied, left unchallenged, and finalizes.
    let head = wait_all_proposed(&net).await?;
    net.warp(CHALLENGE_WINDOW).await?;
    wait_finalized(&net, head).await?;
    assert_eq!(c.game.gameCount().call().await?, U256::ZERO);
    let (provider, _) = net.as_account(DEPLOYER)?;
    chain.sync(&provider, &c).await?;
    assert_eq!(c.oracle.finalizedStateRoot(head).call().await?, chain.state_root_at(head).unwrap());
    assert_eq!(chain.account(carol).0, eth(2));
    assert_eq!(chain.account(alice).0, eth(1), "the censored L2 transaction never executed");

    challenger.stop().await;
    proposer.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// Withdrawals: an L2 withdrawal (and a forced one) can only be paid on L1 after its epoch finalizes, with a Merkle
/// proof against the finalized state root, and exactly once.
#[tokio::test(flavor = "multi_thread")]
async fn withdrawal_after_finalization() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let seq = net.spawn_sequencer(vec![]).await?;
    let proposer = net.spawn_proposer(PROPOSER, false, POLL)?;
    let challenger = net.spawn_challenger(CHALLENGER)?;
    let alice = net.address(ALICE);
    let recipient = Address::repeat_byte(0x77);
    let forced_recipient = Address::repeat_byte(0x78);

    deposit(&net, ALICE, alice, eth(2)).await?;
    wait_balance(&seq.client, alice, eth(2)).await?;
    let amount = eth(3) / U256::from(2);
    l2_send(&net, &seq.client, ALICE, Kind::Withdrawal, recipient, amount, 0).await?;
    let (_, ac) = net.as_account(ALICE)?;
    send(ac.queue.forceWithdrawal(forced_recipient, eth(1) / U256::from(4)), alice).await?;
    wait_balance(&seq.client, alice, eth(2) - amount - eth(1) / U256::from(4)).await?;

    let head = wait_all_proposed(&net).await?;
    // Queue records execute before sequenced ones, so look the ids up by recipient.
    let mut proofs = [seq.client.withdrawal_proof(head, 0).await?, seq.client.withdrawal_proof(head, 1).await?];
    proofs.sort_by_key(|p| p.recipient);
    let (proof, forced) = (proofs[0].clone(), proofs[1].clone());
    assert_eq!((proof.recipient, proof.amount), (recipient, amount));
    assert_eq!((forced.recipient, forced.amount), (forced_recipient, eth(1) / U256::from(4)));

    // Not yet final: the bridge refuses.
    let (_, bc) = net.as_account(BOB)?;
    let smt = |p: &rollup_node::WithdrawalProof| rollup_l1::bindings::SmtProof {
        bitmap: p.bitmap,
        siblings: p.siblings.clone(),
    };
    let early = bc
        .bridge
        .finalizeWithdrawal(head, proof.withdrawal_id, recipient, amount, smt(&proof))
        .from(net.address(BOB))
        .call()
        .await
        .err()
        .expect("withdrawals must wait for finalization");
    assert!(err_is::<IOutputOracle::NotFinalized>(&early));

    net.warp(CHALLENGE_WINDOW).await?;
    wait_finalized(&net, head).await?;
    wallet::check_against_l1(&bc, &proof).await?;
    wallet::finalize_withdrawal(&bc, &proof, net.address(BOB)).await?;
    assert_eq!(net.balance(recipient).await?, amount);

    let again = bc
        .bridge
        .finalizeWithdrawal(head, proof.withdrawal_id, recipient, amount, smt(&proof))
        .from(net.address(BOB))
        .call()
        .await
        .err()
        .expect("paid once only");
    assert!(err_is::<IBridge::AlreadyFinalized>(&again));

    wallet::finalize_withdrawal(&bc, &forced, net.address(BOB)).await?;
    assert_eq!(net.balance(forced_recipient).await?, eth(1) / U256::from(4));
    assert_eq!(logs::<IBridge::WithdrawalFinalized>(&net, bc.deployment.bridge).await?.len(), 2);

    challenger.stop().await;
    proposer.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// Posts deposits until the inbox holds `n` epochs (one deposit per batch).
async fn make_epochs(net: &Devnet, n: u64) -> anyhow::Result<()> {
    let c = net.contracts()?;
    for e in 1..=n {
        deposit(net, ALICE, net.address(ALICE), eth(1)).await?;
        wait_for(&format!("epoch {e} to be posted"), T, || async {
            Ok((c.inbox.batchCount().call().await? >= U256::from(e)).then_some(()))
        })
        .await?;
    }
    Ok(())
}

/// Liveness under capital pressure (regression): a proposer that can afford only one bond proposes epoch 1 and cannot
/// bond epoch 2. It must still finalize epoch 1 and collect that bond, which then pays for epoch 2. A failing
/// `propose` used to abort the whole tick before finalization, so the bond never came back.
#[tokio::test(flavor = "multi_thread")]
async fn underfunded_proposer_still_finalizes_and_recovers_its_bond() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let seq = net.spawn_sequencer(vec![]).await?;
    let c = net.contracts()?;
    let me = net.address(PROPOSER);
    make_epochs(&net, 2).await?;
    net.set_balance(me, eth(11) / U256::from(10)).await?;

    let proposer = net.spawn_proposer(PROPOSER, false, POLL)?;
    wait_for("epoch 1 to be proposed", T, || async { Ok(proposal_at(&c, 1).await?.map(|_| ())) }).await?;
    tokio::time::sleep(POLL * 20).await;
    assert!(proposal_at(&c, 2).await?.is_none(), "0.1 ETH cannot bond epoch 2");

    net.warp(CHALLENGE_WINDOW + 1).await?;
    wait_finalized(&net, 1).await?;
    wait_for("the returned bond to pay for epoch 2", T, || async {
        Ok(proposal_at(&c, 2).await?.filter(|(_, p)| p.proposer == me).map(|_| ()))
    })
    .await?;
    assert!(c.oracle.credit(me).call().await?.is_zero(), "the bond was claimed back");
    assert_eq!(c.oracle.lockedBonds().call().await?, c.oracle.PROPOSER_BOND().call().await?);

    proposer.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// Bond recovery survives a restart (regression): an honest proposer's epochs 1 and 2 are live when it goes offline;
/// a griefer challenges epoch 1 and wins on time, which invalidates epoch 1 and orphans epoch 2. A new proposer
/// process, with no memory of its earlier proposals, finds them in the `OutputProposed` logs, reclaims the orphaned
/// bond and rebuilds the chain.
#[tokio::test(flavor = "multi_thread")]
async fn restarted_proposer_reclaims_orphaned_bonds() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let seq = net.spawn_sequencer(vec![]).await?;
    let c = net.contracts()?;
    let me = net.address(PROPOSER);
    make_epochs(&net, 2).await?;
    let proposer = net.spawn_proposer(PROPOSER, false, POLL)?;
    wait_all_proposed(&net).await?;
    proposer.stop().await;
    let (orphan, _) = proposal_at(&c, 2).await?.unwrap();

    let griefer = 8;
    let (_, gc) = net.as_account(griefer)?;
    send(gc.game.challenge(1).value(gc.game.CHALLENGER_BOND().call().await?), net.address(griefer)).await?;
    net.warp(CLOCK + 1).await?;
    send(gc.game.claimTimeout(U256::from(1)), net.address(griefer)).await?;
    assert_eq!(outcome(&c, U256::from(1)).await?, Some(Outcome::ChallengerWins));
    assert!(!c.oracle.isLive(orphan).call().await?, "epoch 2 was orphaned by the invalidation of epoch 1");

    let restarted = net.spawn_proposer(PROPOSER, false, POLL)?;
    wait_for("the orphaned bond to be reclaimed", T, || async {
        let status = ProposalStatus::from_u8(c.oracle.getProposal(orphan).call().await?.status);
        Ok((status == ProposalStatus::Orphaned).then_some(()))
    })
    .await?;
    let reclaimed = logs::<IOutputOracle::OrphanedBondReclaimed>(&net, c.deployment.oracle).await?;
    assert_eq!(reclaimed.len(), 1);
    assert_eq!((reclaimed[0].proposalId, reclaimed[0].proposer), (orphan, me));
    wait_for("the chain to be re-proposed", T, || async {
        Ok(proposal_at(&c, 2).await?.filter(|(id, p)| *id != orphan && p.proposer == me).map(|_| ()))
    })
    .await?;

    restarted.stop().await;
    seq.service.stop().await;
    Ok(())
}

/// A deployment descriptor that disagrees with what L1 enforces (another program, depth, or contract) is refused
/// before any service starts, instead of letting honest parties bisect the wrong trace and lose on time.
#[tokio::test(flavor = "multi_thread")]
async fn descriptors_that_disagree_with_l1_are_refused() -> anyhow::Result<()> {
    let net = Devnet::start().await?;
    let c = net.contracts()?;
    assert_eq!(net.file.verify_on_l1(&c).await?.program().code_root(), c.game.CODE_ROOT().call().await?);

    let mut depth = net.file.clone();
    depth.config.max_depth = 15;
    let e = depth.verify_on_l1(&c).await.unwrap_err().to_string();
    assert!(e.contains("MAX_DEPTH is 16"), "{e}");

    let mut chain_id = net.file.clone();
    chain_id.l2_chain_id = 902;
    chain_id.config.code_root = Stf::new(902).program().code_root();
    let e = chain_id.verify_on_l1(&c).await.unwrap_err().to_string();
    assert!(e.contains("runs program"), "{e}");

    let mut elsewhere = net.file.clone();
    elsewhere.deployment.game = net.address(ALICE);
    let (provider, _) = net.as_account(DEPLOYER)?;
    assert!(elsewhere.verify_on_l1(&elsewhere.contracts(provider)).await.is_err());
    Ok(())
}

fn err_is<E: alloy::sol_types::SolError>(e: &alloy::contract::Error) -> bool {
    e.as_decoded_error::<E>().is_some()
}
