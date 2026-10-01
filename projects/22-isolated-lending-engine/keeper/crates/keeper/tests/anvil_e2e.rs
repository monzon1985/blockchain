// SPDX-License-Identifier: MIT
//! End-to-end: a real anvil node, the real contracts (deployed from Foundry's `out/`), scripted price crashes, and
//! the keeper liquidating through the flash-loan-funded `FlashLiquidator`.
//!
//! Requires `forge build` (for the artifacts) and `anvil` on `PATH`. Run with
//! `cargo test -p keeper --features anvil-e2e -- --test-threads=1`.
#![cfg(feature = "anvil-e2e")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, missing_docs)]
// `sol!` generates a 10-argument constructor for the `Liquidate` event.
#![allow(clippy::too_many_arguments)]

use std::time::Duration;

use alloy::network::EthereumWallet;
use alloy::node_bindings::{Anvil, AnvilInstance};
use alloy::primitives::{Address, B256, I256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::sol;
use alloy::sol_types::{SolCall, SolEvent};
use keeper::bindings::{self, ILendingEngine as KeeperEngine};
use keeper::{Keeper, KeeperConfig, SkipReason, TickReport};

sol!(
    #[sol(rpc)]
    EngineArtifact,
    "../../../out/LendingEngine.sol/LendingEngine.json"
);
sol!(
    #[sol(rpc)]
    IrmArtifact,
    "../../../out/AdaptiveCurveIrm.sol/AdaptiveCurveIrm.json"
);
sol!(
    #[sol(rpc)]
    TokenArtifact,
    "../../../out/MockERC20.sol/MockERC20.json"
);
sol!(
    #[sol(rpc)]
    OracleArtifact,
    "../../../out/MockOracle.sol/MockOracle.json"
);
sol!(
    #[sol(rpc)]
    VenueArtifact,
    "../../../out/MockSwapVenue.sol/MockSwapVenue.json"
);

/// `FlashLiquidator`'s ABI nests `MarketParams` from another file, which `sol!` cannot resolve from a single JSON
/// artifact, so it is deployed from its raw creation code and driven through the keeper's own bindings.
const LIQUIDATOR_ARTIFACT: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../../out/FlashLiquidator.sol/FlashLiquidator.json");

fn artifact(path: &str) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(path).expect("run `forge build` first")).expect("artifact json")
}

async fn deploy_liquidator<P: Provider>(provider: &P, engine: Address, owner: Address) -> Address {
    use alloy::network::TransactionBuilder;
    use alloy::rpc::types::TransactionRequest;
    use alloy::sol_types::SolValue;
    let code = artifact(LIQUIDATOR_ARTIFACT)["bytecode"]["object"].as_str().expect("bytecode").to_owned();
    let mut init = alloy::primitives::hex::decode(code).expect("hex bytecode");
    init.extend_from_slice(&(engine, owner).abi_encode_params());
    let receipt = provider
        .send_transaction(TransactionRequest::default().with_deploy_code(init))
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    receipt.contract_address.expect("contract address")
}

const E18: u128 = 1_000_000_000_000_000_000;
const PRICE_SCALE: u128 = 1_000_000_000_000_000_000_000_000_000_000_000_000; // 1e36
/// A realistic L1 base fee, set before every keeper tick: at 30 gwei and ETH at 2,000 loan units, a ~300k-gas flash
/// liquidation costs about 18 loan units, which a dust position cannot pay for.
const BASE_FEE_WEI: u64 = 30_000_000_000;

fn e18(x: u64) -> U256 {
    U256::from(x) * U256::from(E18)
}

/// Collateral price (loan per collateral, both 18 decimals) in the oracle's 1e36 scale.
fn price(loan_per_collateral: u64) -> U256 {
    U256::from(loan_per_collateral) * U256::from(PRICE_SCALE)
}

macro_rules! tx {
    ($call:expr) => {{
        // Explicit gas limit: estimates run against the pending block and can miss the IRM's adaptation path.
        let receipt = $call.gas(3_000_000).send().await.unwrap().get_receipt().await.unwrap();
        assert!(receipt.status(), "transaction reverted: {:?}", receipt.transaction_hash);
        receipt
    }};
}

/// The deployed system: LLTV 86 %, bonus = min(5 %, 2 x deficit), collateral starting at 2,000 loan units.
struct System<P: Provider> {
    engine: EngineArtifact::EngineArtifactInstance<P>,
    oracle: OracleArtifact::OracleArtifactInstance<P>,
    loan: TokenArtifact::TokenArtifactInstance<P>,
    collateral: TokenArtifact::TokenArtifactInstance<P>,
    params: EngineArtifact::MarketParams,
    market_id: B256,
    venue: Address,
    liquidator: Address,
}

/// Deploys everything, funds the market with 1,000,000 loan tokens and the venue with `venue_liquidity`.
async fn deploy<P: Provider + Clone>(
    provider: &P,
    owner: Address,
    keeper: Address,
    venue_liquidity: U256,
) -> System<P> {
    let loan = TokenArtifact::deploy(provider.clone(), "Loan".into(), "LOAN".into(), 18).await.unwrap();
    let collateral = TokenArtifact::deploy(provider.clone(), "Collateral".into(), "COLL".into(), 18).await.unwrap();
    let oracle = OracleArtifact::deploy(provider.clone(), price(2_000)).await.unwrap();
    let engine = EngineArtifact::deploy(provider.clone(), owner, owner).await.unwrap();
    let irm = IrmArtifact::deploy(provider.clone(), *engine.address()).await.unwrap();
    tx!(engine.enableIrm(*irm.address()).from(owner));
    tx!(engine
        .enableLltv(U256::from(860_000_000_000_000_000u64), U256::from(50_000_000_000_000_000u64), e18(2))
        .from(owner));
    let params = EngineArtifact::MarketParams {
        loanToken: *loan.address(),
        collateralToken: *collateral.address(),
        oracle: *oracle.address(),
        irm: *irm.address(),
        lltv: U256::from(860_000_000_000_000_000u64),
    };
    let market_id = bindings::market_id(&bindings::MarketParams {
        loanToken: params.loanToken,
        collateralToken: params.collateralToken,
        oracle: params.oracle,
        irm: params.irm,
        lltv: params.lltv,
    });
    tx!(engine.createMarket(params.clone()));

    let venue = VenueArtifact::deploy(
        provider.clone(),
        *oracle.address(),
        *collateral.address(),
        *loan.address(),
        U256::from(30u8),
    )
    .await
    .unwrap();
    tx!(loan.mint(*venue.address(), venue_liquidity));
    let liquidator = deploy_liquidator(provider, *engine.address(), keeper).await;
    assert_eq!(bindings::IFlashLiquidator::new(liquidator, provider.clone()).owner().call().await.unwrap(), keeper);

    tx!(loan.mint(owner, e18(1_000_000)));
    tx!(loan.approve(*engine.address(), U256::MAX).from(owner));
    tx!(engine.supply(params.clone(), e18(1_000_000), U256::ZERO, owner, Default::default()).from(owner));
    System { engine, oracle, loan, collateral, params, market_id, venue: *venue.address(), liquidator }
}

impl<P: Provider + Clone> System<P> {
    /// Posts `collateral` (wei) for `borrower` and borrows `ltv_bps` of its value at the starting price.
    async fn open(&self, borrower: Address, collateral: U256, ltv_bps: u64) {
        tx!(self.collateral.mint(borrower, collateral));
        tx!(self.collateral.approve(*self.engine.address(), U256::MAX).from(borrower));
        tx!(self.engine.supplyCollateral(self.params.clone(), collateral, borrower, Default::default()).from(borrower));
        let amount = collateral * U256::from(2_000u64) * U256::from(ltv_bps) / U256::from(10_000u64);
        tx!(self.engine.borrow(self.params.clone(), amount, U256::ZERO, borrower, borrower).from(borrower));
    }

    async fn debt_shares(&self, borrower: Address) -> u128 {
        self.engine.position(self.market_id, borrower).call().await.unwrap().borrowShares
    }

    /// The event-sourced book equals the engine's storage for every account.
    async fn assert_book_matches_chain<Q: Provider + Clone>(&self, keeper: &Keeper<Q>, accounts: &[Address]) {
        for account in accounts {
            let on_chain = self.engine.position(self.market_id, *account).call().await.unwrap();
            let book = keeper.book().position(account);
            assert_eq!(book.collateral, U256::from(on_chain.collateral), "collateral of {account}");
            assert_eq!(book.borrow_shares, U256::from(on_chain.borrowShares), "shares of {account}");
        }
    }

    fn keeper_config(&self, receipt_timeout: Duration, confirmations: u64) -> KeeperConfig {
        KeeperConfig {
            engine: *self.engine.address(),
            liquidator: self.liquidator,
            venue: self.venue,
            market_id: self.market_id,
            eth_price_in_loan: e18(2_000),
            min_net_profit: e18(1),
            flash_buffer_bps: 50,
            log_chunk_size: 5_000,
            from_block: 0,
            confirmations,
            receipt_timeout,
        }
    }
}

async fn set_next_base_fee<P: Provider>(provider: &P, wei: u64) {
    let _: serde_json::Value =
        provider.raw_request("anvil_setNextBlockBaseFeePerGas".into(), (U256::from(wei),)).await.unwrap();
}

fn keeper_provider(anvil: &AnvilInstance) -> impl Provider + Clone + use<> {
    ProviderBuilder::new()
        .wallet(EthereumWallet::from(alloy::signers::local::PrivateKeySigner::from(anvil.keys()[1].clone())))
        .connect_http(anvil.endpoint_url())
}

fn skip_reason(report: &TickReport, who: Address) -> &SkipReason {
    &report.skipped.iter().find(|(a, _)| *a == who).unwrap_or_else(|| panic!("{who} not skipped: {report:?}")).1
}

#[tokio::test(flavor = "multi_thread")]
async fn keeper_liquidates_profitably_skips_what_it_must_and_resolves_the_rest() {
    // Port 0: anvil binds a free port and reports it; the instance is killed (by PID) on drop.
    let anvil = Anvil::new().try_spawn().expect("anvil on PATH");
    let wallet: EthereumWallet = anvil.wallet().expect("anvil dev keys");
    let provider = ProviderBuilder::new().wallet(wallet).connect_http(anvil.endpoint_url());
    let accounts = anvil.addresses().to_vec();
    let (owner, keeper_account) = (accounts[0], accounts[1]);
    // Five ordinary borrowers (10 collateral each), a dust borrower and a whale the venue cannot absorb.
    let borrowers: Vec<Address> = accounts[2..7].to_vec();
    let (dust, whale) = (accounts[7], accounts[8]);
    let mut everyone = borrowers.clone();
    everyone.extend([dust, whale]);

    // The venue holds 120,000 loan tokens: enough for every ordinary liquidation (about 77,000 in total), not for
    // the whale's collateral (about 178,000 at the first crash).
    let system = deploy(&provider, owner, keeper_account, e18(120_000)).await;
    for (borrower, ltv_bps) in borrowers.iter().zip([8_550u64, 8_400, 8_000, 7_000, 6_000]) {
        system.open(*borrower, e18(10), ltv_bps).await;
    }
    system.open(dust, U256::from(5_000_000_000_000_000u64), 8_550).await; // 0.005 collateral, 8.55 of debt
    system.open(whale, e18(100), 8_500).await;

    let keeper_provider = keeper_provider(&anvil);
    let mut keeper =
        Keeper::new(keeper_provider.clone(), system.keeper_config(Duration::from_secs(30), 2)).await.unwrap();
    keeper.sync().await.unwrap();
    system.assert_book_matches_chain(&keeper, &everyone).await;

    // Healthy market: nothing to do.
    let calm: TickReport = keeper.tick().await.unwrap();
    assert_eq!(calm.candidates, 0);
    assert!(calm.executed.is_empty());

    // --- crash 1: -10 % --------------------------------------------------------------------------------------------
    // Health = 0.86 / LTV * 0.9: 0.905, 0.921 and 0.968 for the first three (liquidatable, collateral still covers
    // debt plus the 5 % bonus), 1.106 and 1.29 (healthy); the dust borrower sits at 0.905 and the whale at 0.911.
    tx!(system.oracle.setPrice(price(1_800)));
    set_next_base_fee(&provider, BASE_FEE_WEI).await;
    let first = keeper.tick().await.unwrap();
    println!("crash 1: {}", serde_json::to_string_pretty(&first).unwrap());
    assert_eq!(first.candidates, 5);
    assert_eq!(first.executed.len(), 3, "skipped: {:?}", first.skipped);
    for execution in &first.executed {
        assert!(borrowers[..3].contains(&execution.borrower));
        assert!(!execution.closeout, "solvent positions are repaid in full, not closed out");
        assert_eq!(execution.bad_debt_assets, U256::ZERO);
        assert!(execution.net_profit >= I256::from_raw(e18(1)), "below min_net_profit after gas: {execution:?}");
        assert!(execution.gas_used > 0 && execution.effective_gas_price > 0);
    }
    // The whale is planned but cannot be sold: its dry run reverts. The dust borrower is profitable before gas but
    // not after. Neither stops the candidates behind them (the whale sorts before two of the executed ones).
    assert!(matches!(skip_reason(&first, whale), SkipReason::SimulationReverted(_)));
    match skip_reason(&first, dust) {
        SkipReason::Unprofitable { profit, gas_cost_in_loan, min_net_profit } => {
            assert!(profit > &U256::ZERO, "the dust liquidation does pay something before gas");
            assert!(profit < &(*gas_cost_in_loan + *min_net_profit));
        }
        other => panic!("dust borrower: {other:?}"),
    }
    for borrower in &borrowers[..3] {
        assert_eq!(system.debt_shares(*borrower).await, 0);
    }
    system.assert_book_matches_chain(&keeper, &everyone).await;

    // --- crash 2: gap down to 61.5 % of the start ---------------------------------------------------------------------
    // Borrower 3 (14,000 of debt) is under water: all its collateral (worth 12,300) is seized at the 5 % bonus and
    // the rest is bad debt. Borrower 4 (12,000 of debt) is not: its collateral covers the debt but not the bonus, so
    // the closeout repays all 12,000 and the bonus is capped at the borrower's 300 of equity (no supplier loss).
    let supply_before = system.engine.market(system.market_id).call().await.unwrap().totalSupplyAssets;
    tx!(system.oracle.setPrice(price(1_230)));
    set_next_base_fee(&provider, BASE_FEE_WEI).await;
    let second = keeper.tick().await.unwrap();
    println!("crash 2: {}", serde_json::to_string_pretty(&second).unwrap());
    assert_eq!(second.candidates, 4);
    assert_eq!(second.executed.len(), 2, "skipped: {:?}", second.skipped);
    let underwater = second.executed.iter().find(|e| e.borrower == borrowers[3]).expect("borrower 3 liquidated");
    let band = second.executed.iter().find(|e| e.borrower == borrowers[4]).expect("borrower 4 liquidated");
    for execution in [underwater, band] {
        assert!(execution.closeout);
        assert_eq!(execution.seized_assets, e18(10));
        assert!(execution.net_profit >= I256::from_raw(e18(1)), "below min_net_profit after gas: {execution:?}");
    }
    assert!(underwater.bad_debt_assets > U256::ZERO);
    assert_eq!(band.bad_debt_assets, U256::ZERO);
    assert!(band.repaid_assets >= e18(12_000), "the band closeout repays the whole debt");
    assert!(matches!(skip_reason(&second, whale), SkipReason::SimulationReverted(_)));
    assert!(matches!(skip_reason(&second, dust), SkipReason::Unprofitable { .. }));
    let supply_after = system.engine.market(system.market_id).call().await.unwrap().totalSupplyAssets;
    // Suppliers of this market absorb exactly the under-water closeout's bad debt (interest accrued meanwhile is a
    // few wei at most), and nothing for the band closeout.
    let lost = U256::from(supply_before) - U256::from(supply_after);
    assert!(lost <= underwater.bad_debt_assets && lost + e18(1) >= underwater.bad_debt_assets);

    for borrower in &borrowers {
        assert_eq!(system.debt_shares(*borrower).await, 0, "every executable position was resolved");
    }
    assert!(system.debt_shares(dust).await > 0 && system.debt_shares(whale).await > 0, "skipped positions remain");
    system.assert_book_matches_chain(&keeper, &everyone).await;

    let executed: Vec<_> = first.executed.iter().chain(&second.executed).collect();
    let net: I256 = executed.iter().map(|e| e.net_profit).fold(I256::ZERO, |a, b| a + b);
    let gas: u64 = executed.iter().map(|e| e.gas_used).sum();
    println!("{} liquidations, net profit after gas {net} (loan wei), gas used {gas}", executed.len());
    assert!(net > I256::ZERO);
    assert_eq!(
        U256::from(system.loan.balanceOf(keeper_account).call().await.unwrap()),
        executed.iter().map(|e| e.profit).fold(U256::ZERO, |a, b| a + b),
        "the keeper received exactly the reported profits"
    );
    drop(anvil);
}

/// A liquidation that is sent but never confirms (mining is paused) is reported as a failed candidate after the
/// receipt timeout; the tick still completes and handles the next candidate, and once the blocks are mined the
/// keeper picks the outcome up from the events.
#[tokio::test(flavor = "multi_thread")]
async fn keeper_survives_transactions_that_never_confirm() {
    let anvil = Anvil::new().try_spawn().expect("anvil on PATH");
    let wallet: EthereumWallet = anvil.wallet().expect("anvil dev keys");
    let provider = ProviderBuilder::new().wallet(wallet).connect_http(anvil.endpoint_url());
    let accounts = anvil.addresses().to_vec();
    let (owner, keeper_account) = (accounts[0], accounts[1]);
    let borrowers: Vec<Address> = accounts[2..4].to_vec();

    let system = deploy(&provider, owner, keeper_account, e18(1_000_000)).await;
    for (borrower, ltv_bps) in borrowers.iter().zip([8_550u64, 8_400]) {
        system.open(*borrower, e18(10), ltv_bps).await;
    }
    let keeper_provider = keeper_provider(&anvil);
    let mut keeper =
        Keeper::new(keeper_provider.clone(), system.keeper_config(Duration::from_secs(2), 0)).await.unwrap();
    tx!(system.oracle.setPrice(price(1_800)));

    let _: serde_json::Value = provider.raw_request("evm_setAutomine".into(), (false,)).await.unwrap();
    let stuck = keeper.tick().await.expect("per-candidate failures never fail the tick");
    println!("mining paused: {}", serde_json::to_string_pretty(&stuck).unwrap());
    assert_eq!(stuck.candidates, 2);
    assert!(stuck.executed.is_empty());
    assert_eq!(stuck.skipped.len(), 2, "both candidates were attempted");
    for (_, reason) in &stuck.skipped {
        assert!(matches!(reason, SkipReason::ExecutionFailed(_)), "{reason:?}");
    }
    assert!(
        stuck.skipped.iter().any(|(_, r)| matches!(r, SkipReason::ExecutionFailed(m) if m.contains("no receipt"))),
        "the first candidate timed out waiting for its receipt: {stuck:?}"
    );

    let _: serde_json::Value = provider.raw_request("evm_mine".into(), serde_json::json!([])).await.unwrap();
    let _: serde_json::Value = provider.raw_request("evm_setAutomine".into(), (true,)).await.unwrap();
    let resumed = keeper.tick().await.unwrap();
    println!("mining resumed: {}", serde_json::to_string_pretty(&resumed).unwrap());
    for borrower in &borrowers {
        assert_eq!(system.debt_shares(*borrower).await, 0, "resolved by the mined transaction or the next tick");
    }
    system.assert_book_matches_chain(&keeper, &borrowers).await;
    drop(anvil);
}

/// The keeper's inline bindings agree with the compiled contracts' ABI.
#[test]
fn inline_bindings_match_compiled_abi() {
    assert_eq!(KeeperEngine::positionCall::SELECTOR, EngineArtifact::positionCall::SELECTOR);
    assert_eq!(KeeperEngine::marketCall::SELECTOR, EngineArtifact::marketCall::SELECTOR);
    assert_eq!(KeeperEngine::idToMarketParamsCall::SELECTOR, EngineArtifact::idToMarketParamsCall::SELECTOR);
    assert_eq!(KeeperEngine::liquidationConfigCall::SELECTOR, EngineArtifact::liquidationConfigCall::SELECTOR);
    assert_eq!(
        KeeperEngine::expectedMarketBalancesCall::SELECTOR,
        EngineArtifact::expectedMarketBalancesCall::SELECTOR
    );
    assert_eq!(KeeperEngine::healthFactorCall::SELECTOR, EngineArtifact::healthFactorCall::SELECTOR);
    assert_eq!(KeeperEngine::Liquidate::SIGNATURE_HASH, EngineArtifact::Liquidate::SIGNATURE_HASH);
    assert_eq!(KeeperEngine::Borrow::SIGNATURE_HASH, EngineArtifact::Borrow::SIGNATURE_HASH);
    assert_eq!(KeeperEngine::Repay::SIGNATURE_HASH, EngineArtifact::Repay::SIGNATURE_HASH);
    assert_eq!(KeeperEngine::SupplyCollateral::SIGNATURE_HASH, EngineArtifact::SupplyCollateral::SIGNATURE_HASH);
    assert_eq!(KeeperEngine::WithdrawCollateral::SIGNATURE_HASH, EngineArtifact::WithdrawCollateral::SIGNATURE_HASH);
    let identifiers = &artifact(LIQUIDATOR_ARTIFACT)["methodIdentifiers"];
    let liquidate = bindings::IFlashLiquidator::liquidateCall::SIGNATURE;
    assert_eq!(
        identifiers[liquidate].as_str(),
        Some(alloy::primitives::hex::encode(bindings::IFlashLiquidator::liquidateCall::SELECTOR).as_str()),
        "FlashLiquidator.liquidate selector drifted"
    );
    let abi = artifact(LIQUIDATOR_ARTIFACT)["abi"].to_string();
    assert!(abi.contains("\"name\":\"Liquidation\""), "Liquidation event missing from the ABI");
}
