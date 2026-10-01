# Blockchain Engineering Portfolio

**Smart contracts, DeFi protocol design, security, and blockchain infrastructure.** Solidity · Rust · Go · TypeScript · Circom · Move. EVM, Solana, and Sui.

This repository holds **25 self-contained projects**, arranged from hardened building blocks up to a working optimistic rollup. Each one ships with:

- unit, fuzz, invariant, and differential tests
- a threat model
- an honest README
- its own CI pipeline

The bar for each project is simple: it should read like it came out of a protocol team, not a tutorial.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Projects](https://img.shields.io/badge/projects-25-informational)
![Solidity](https://img.shields.io/badge/Solidity-0.8.37-363636?logo=solidity)
![Foundry](https://img.shields.io/badge/Foundry-1.8.3-orange)

---

## Start here

| | Project | Why it is worth five minutes |
|---|---|---|
| 🔐 | [**21 · Passkey smart account**](projects/21-passkey-smart-account) | One account contract that works both as an **EIP-7702 delegate** and as an **ERC-4337 v0.9** account. Signatures are WebAuthn/P-256. It adds guardian recovery, an ERC-20 paymaster, a local bundler, and a Next.js wallet tested end to end in a real browser. |
| 🏦 | [**22 · Isolated lending engine**](projects/22-isolated-lending-engine) | Morpho-Blue-derived lending markets with grief-proof reverse-Dutch liquidations. A **Rust flash-loan keeper** runs against anvil, and a cascade risk simulator is checked bit for bit against the on-chain math. |
| ⛓️ | [**25 · Minimal optimistic rollup**](projects/25-optimistic-rollup-bisection) | A Rust sequencer, proposer, and challenger, with interactive bisection down to a one-instruction Solidity VM, forced inclusion, and Merkle-proof withdrawals. Differential-fuzzed against `revm`. |
| 🛡️ | [**17 · Audit lab**](projects/17-seeded-bug-audit-lab) | An original DeFi protocol seeded with 12 bugs modelled on real incidents. Each bug comes with an exploit PoC, a minimal fix, and a property that guards the fix. Also: custom Slither detectors, a tool-detection scoreboard, and an audit-style report. |
| 🔑 | [**24 · FROST threshold custody**](projects/24-frost-threshold-custody) | t-of-n Schnorr signing in Rust (DKG, refresh, repair, verifiable blame) over authenticated transport. A Solidity vault verifies the aggregate signature in a single `ecrecover`. |

---

## Projects by level

Every row links to a project README that covers architecture, invariants, threat model, test results, and how to run it.

### Level 4 · Expert

| # | Project | What it demonstrates | Stack | CI |
|---|---|---|---|---|
| 21 | [Passkey-First Smart Account](projects/21-passkey-smart-account) | EIP-7702 + ERC-4337 v0.9 account with P-256 passkeys, guardian recovery, an ERC-20 paymaster, a local bundler, and a Next.js wallet | Solidity, Foundry, TypeScript, Next.js 16, wagmi 3, Playwright | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/21-passkey-smart-account.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/21-passkey-smart-account.yml) |
| 22 | [Isolated-Market Lending Engine](projects/22-isolated-lending-engine) | Isolated lending markets, reverse-Dutch liquidations, a Rust liquidation keeper, and a cascade risk simulator | Solidity, Foundry, Halmos, Medusa, Rust, alloy | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/22-isolated-lending-engine.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/22-isolated-lending-engine.yml) |
| 23 | [Two-Chain ERC-7683 Intents](projects/23-erc7683-intents-settlement) | Cross-chain intents with a crash-safe solver and three settlement modes: mailbox, optimistic fraud proofs, and Merkle-Patricia storage proofs | Solidity, Foundry, Permit2, TypeScript, viem | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/23-erc7683-intents-settlement.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/23-erc7683-intents-settlement.yml) |
| 24 | [FROST Threshold-Signature Custody](projects/24-frost-threshold-custody) | Threshold Schnorr custody: DKG, two-round signing, refresh, repair, and blame in Rust, plus on-chain verification in Solidity | Rust, frost-core, tokio, Solidity, alloy | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/24-frost-threshold-custody.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/24-frost-threshold-custody.yml) |
| 25 | [Minimal Optimistic Rollup](projects/25-optimistic-rollup-bisection) | Sequencer, proposer, and challenger, 16-round bisection to a one-step VM, forced inclusion, and withdrawals | Rust, alloy, revm, Solidity, Foundry | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/25-optimistic-rollup-bisection.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/25-optimistic-rollup-bisection.yml) |

### Level 3 · Advanced

| # | Project | What it demonstrates | Stack | CI |
|---|---|---|---|---|
| 13 | [Uniswap v4 Volatility Fee Hook](projects/13-v4-volatility-fee-hook) | A v4 hook that prices swaps from an in-hook EWMA of tick volatility and returns a top-of-block surcharge to LPs (LVR recapture) | Solidity, Uniswap v4, Foundry, Medusa, Python | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/13-v4-volatility-fee-hook.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/13-v4-volatility-fee-hook.yml) |
| 14 | [Zero-Knowledge KYC Gate](projects/14-zk-kyc-credential-gate) | Proves age, a non-sanctioned country, and an unrevoked credential with Groth16/PLONK verified on-chain, plus a "bug zoo" of under-constrained circuits with forged proofs | Circom, snarkjs, Solidity, Foundry, TypeScript | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/14-zk-kyc-credential-gate.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/14-zk-kyc-credential-gate.yml) |
| 15 | [Solana RFQ Settlement](projects/15-solana-rfq-token2022) | Atomic RFQ settlement as Anchor **and** Pinocchio programs, ed25519 verification through instruction introspection, Token-2022 transfer fees and hooks | Rust, Anchor 1.2, Pinocchio, LiteSVM, Mollusk | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/15-solana-rfq-token2022.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/15-solana-rfq-token2022.yml) |
| 16 | [x402 Agent Payments](projects/16-x402-agent-payments) | Pay-per-call x402 marketplace for AI agents: an untrusted facilitator, an ERC-7579 budget-bounded agent account, and ERC-8004 reputation | Solidity, Foundry, TypeScript, Hono, viem | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/16-x402-agent-payments.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/16-x402-agent-payments.yml) |
| 17 | [Audit Lab](projects/17-seeded-bug-audit-lab) | Vulnerable-by-design protocol: exploits, fixes, properties, custom detectors, and an audit report | Solidity, Foundry, Medusa, Halmos, Slither, Python | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/17-seeded-bug-audit-lab.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/17-seeded-bug-audit-lab.yml) |
| 18 | [Tokenized T-Bill Fund (demo)](projects/18-rwa-tbill-fund) | RWA fund with an ERC-3643-style permissioned token, pluggable compliance, an ERC-7540 async epoch vault, wallet recovery, and Merkle distributions | Solidity, Foundry, Medusa, Slither | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/18-rwa-tbill-fund.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/18-rwa-tbill-fund.yml) |
| 19 | [Custodial Withdrawal Engine](projects/19-go-custody-withdrawal-engine) | Exchange-style hot wallet: idempotent API, policy engine, nonce manager with replace-by-fee, reorg-aware deposits, a double-entry ledger, and crash tests | Go, go-ethereum, SQLite, Solidity | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/19-go-custody-withdrawal-engine.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/19-go-custody-withdrawal-engine.yml) |
| 20 | [Oracle-Based Perpetuals Engine](projects/20-oracle-perps-engine) | GMX-v2-style perps: funding, price impact, liquidations, ADL, a 3-signer EIP-712 oracle network, and a Go keeper | Solidity, Foundry, Medusa, Go, Python | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/20-oracle-perps-engine.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/20-oracle-perps-engine.yml) |

### Level 2 · Intermediate

| # | Project | What it demonstrates | Stack | CI |
|---|---|---|---|---|
| 06 | [Gas Golf Quartet](projects/06-gas-golf-quartet) | One ERC-20 written four ways (Solidity, inline assembly, pure Yul, Vyper), proven equivalent with Halmos and lockstep fuzzing | Solidity, Yul, Vyper, Foundry, Halmos | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/06-gas-golf-quartet.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/06-gas-golf-quartet.yml) |
| 07 | [Upgrade Safety Lab](projects/07-upgrade-safety-lab) | UUPS v1 → v3 and an ERC-2535 diamond, a reproduced OZ v4 → v5 migration failure, and a Rust storage-layout CI gate | Solidity, OpenZeppelin, Foundry, Rust | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/07-upgrade-safety-lab.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/07-upgrade-safety-lab.yml) |
| 08 | [Sui Flash-Loan AMM + Kiosk](projects/08-sui-flashloan-kiosk) | Hot-potato flash loans enforced by Move's type system, and a policy-enforced Kiosk marketplace driven by TypeScript PTBs | Sui Move 2024, TypeScript, @mysten/sui | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/08-sui-flashloan-kiosk.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/08-sui-flashloan-kiosk.yml) |
| 09 | [Curated ERC-4626 Allocator Vault](projects/09-erc4626-allocator-vault) | Meta-vault with capped strategies, a timelocked curator, high-water-mark fees, linear profit unlock, and inflation/sandwich hardening | Solidity, OpenZeppelin, Foundry, Medusa | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/09-erc4626-allocator-vault.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/09-erc4626-allocator-vault.yml) |
| 10 | [Regulated Payment Stablecoin (test token)](projects/10-regulated-payment-stablecoin) | Issuer controls: UUPS + ERC-7201, governance delays, reserve-gated rate-limited minting, freeze/seize, and gasless EIP-2612 / ERC-3009 transfers | Solidity, OpenZeppelin, Foundry, Medusa | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/10-regulated-payment-stablecoin.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/10-regulated-payment-stablecoin.yml) |
| 11 | [Reorg-Safe EVM Indexer](projects/11-go-reorg-safe-indexer) | Go indexer with transactional reorg rollback, SSE retractions, and a differential test against a full reindex | Go, go-ethereum, SQLite, PostgreSQL | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/11-go-reorg-safe-indexer.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/11-go-reorg-safe-indexer.yml) |
| 12 | [Hardened AMM + Swap dApp](projects/12-hardened-amm-dapp) | Constant-product AMM fuzzed for exact equality against the canonical UniswapV2Pair bytecode, with a Next.js swap UI whose quotes match the chain to the wei | Solidity, Foundry, Next.js 16, wagmi 3, Playwright | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/12-hardened-amm-dapp.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/12-hardened-amm-dapp.yml) |

### Level 1 · Foundations

| # | Project | What it demonstrates | Stack | CI |
|---|---|---|---|---|
| 01 | [Resilient Oracle Router](projects/01-resilient-oracle-router) | Hardened price feeds: staleness, L2 sequencer grace period, bounds, a deviation breaker, and TWAP fallback, with an executable failure-mode matrix | Solidity, Foundry, Medusa, Slither | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/01-resilient-oracle-router.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/01-resilient-oracle-router.yml) |
| 02 | [Cumulative Merkle Distributor](projects/02-cumulative-merkle-distributor) | Multi-epoch rewards with cumulative Merkle leaves, a vetoable root timelock, and EIP-712 claims for EOAs, ERC-1271, and EIP-7702 accounts | Solidity, Foundry, TypeScript, fast-check | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/02-cumulative-merkle-distributor.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/02-cumulative-merkle-distributor.yml) |
| 03 | [Vesting Streams as On-Chain SVG NFTs](projects/03-vesting-stream-nfts-hardhat3) | Linear, cliff, and tranched vesting streams as ERC-721s with fully on-chain SVG art, built on Hardhat 3 | Solidity, Hardhat 3, viem, TypeScript | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/03-vesting-stream-nfts-hardhat3.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/03-vesting-stream-nfts-hardhat3.yml) |
| 04 | [Keysmith: Offline Signer](projects/04-keysmith-offline-signer-rs) | Air-gapped HD wallet in Rust covering BIP-39/32/44, every Ethereum transaction type (incl. EIP-7702), EIP-712, and keystore v3 | Rust, k256, clap, proptest | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/04-keysmith-offline-signer-rs.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/04-keysmith-offline-signer-rs.yml) |
| 05 | [Trie Inspector](projects/05-mpt-state-proofs-go) | RLP, Merkle-Patricia tries, block-header hashing, and state proofs from scratch in Go, checked against a live chain | Go, go-ethereum (as an oracle), anvil | [![CI](https://github.com/monzon1985/blockchain/actions/workflows/05-mpt-state-proofs-go.yml/badge.svg)](https://github.com/monzon1985/blockchain/actions/workflows/05-mpt-state-proofs-go.yml) |

---

## Skills matrix

| Capability | Where to look |
|---|---|
| Stateful invariant & property-based testing | [01](projects/01-resilient-oracle-router) · [02](projects/02-cumulative-merkle-distributor) · [03](projects/03-vesting-stream-nfts-hardhat3) · [09](projects/09-erc4626-allocator-vault) · [10](projects/10-regulated-payment-stablecoin) · [12](projects/12-hardened-amm-dapp) · [18](projects/18-rwa-tbill-fund) · [20](projects/20-oracle-perps-engine) · [22](projects/22-isolated-lending-engine) · [23](projects/23-erc7683-intents-settlement) |
| Formal / symbolic verification (Halmos) | [06](projects/06-gas-golf-quartet) · [17](projects/17-seeded-bug-audit-lab) · [22](projects/22-isolated-lending-engine) |
| Differential testing against canonical implementations | [02](projects/02-cumulative-merkle-distributor) · [04](projects/04-keysmith-offline-signer-rs) · [05](projects/05-mpt-state-proofs-go) · [12](projects/12-hardened-amm-dapp) · [22](projects/22-isolated-lending-engine) · [25](projects/25-optimistic-rollup-bisection) |
| Security auditing, exploit PoCs, static analysis | [17](projects/17-seeded-bug-audit-lab) · [14](projects/14-zk-kyc-credential-gate) · [07](projects/07-upgrade-safety-lab) |
| Gas optimization, Yul, assembly | [06](projects/06-gas-golf-quartet) · [02](projects/02-cumulative-merkle-distributor) · [13](projects/13-v4-volatility-fee-hook) |
| Upgradeability (UUPS, ERC-7201, diamonds) | [07](projects/07-upgrade-safety-lab) · [10](projects/10-regulated-payment-stablecoin) |
| Account abstraction (ERC-4337, EIP-7702, ERC-7579, passkeys) | [21](projects/21-passkey-smart-account) · [16](projects/16-x402-agent-payments) · [02](projects/02-cumulative-merkle-distributor) |
| Signatures (EIP-712, ERC-1271, EIP-2612, ERC-3009) | [02](projects/02-cumulative-merkle-distributor) · [10](projects/10-regulated-payment-stablecoin) · [16](projects/16-x402-agent-payments) · [20](projects/20-oracle-perps-engine) |
| DeFi: AMMs, vaults, lending, perps, oracles | [12](projects/12-hardened-amm-dapp) · [13](projects/13-v4-volatility-fee-hook) · [09](projects/09-erc4626-allocator-vault) · [22](projects/22-isolated-lending-engine) · [20](projects/20-oracle-perps-engine) · [01](projects/01-resilient-oracle-router) |
| Cross-chain, intents, rollups | [23](projects/23-erc7683-intents-settlement) · [25](projects/25-optimistic-rollup-bisection) |
| Zero-knowledge circuits | [14](projects/14-zk-kyc-credential-gate) |
| Custody, key management, threshold cryptography | [24](projects/24-frost-threshold-custody) · [19](projects/19-go-custody-withdrawal-engine) · [04](projects/04-keysmith-offline-signer-rs) · [21](projects/21-passkey-smart-account) |
| Tokenization, RWA, stablecoins, compliance | [18](projects/18-rwa-tbill-fund) · [10](projects/10-regulated-payment-stablecoin) · [14](projects/14-zk-kyc-credential-gate) |
| Backend services & indexing (Go) | [11](projects/11-go-reorg-safe-indexer) · [19](projects/19-go-custody-withdrawal-engine) · [20](projects/20-oracle-perps-engine) |
| Off-chain Rust (alloy, revm, tokio) | [22](projects/22-isolated-lending-engine) · [24](projects/24-frost-threshold-custody) · [25](projects/25-optimistic-rollup-bisection) · [04](projects/04-keysmith-offline-signer-rs) |
| Full-stack dApps (Next.js, wagmi, viem) | [12](projects/12-hardened-amm-dapp) · [21](projects/21-passkey-smart-account) |
| Non-EVM chains (Solana, Sui) | [15](projects/15-solana-rfq-token2022) · [08](projects/08-sui-flashloan-kiosk) |
| Protocol internals (RLP, tries, tx encoding, proofs) | [05](projects/05-mpt-state-proofs-go) · [04](projects/04-keysmith-offline-signer-rs) · [23](projects/23-erc7683-intents-settlement) · [25](projects/25-optimistic-rollup-bisection) |

---

## Engineering standards

All projects follow one written standard: **[docs/ENGINEERING_STANDARDS.md](docs/ENGINEERING_STANDARDS.md)**. In short:

- **Current, pinned toolchains.** Solidity 0.8.37, Foundry 1.8.3, OpenZeppelin 5.7, Rust 1.98, Go 1.27, Node 24. Dependencies are locked (Soldeer, npm, Cargo, Go modules, uv). No git submodules.
- **Tests that mean something.** Every revert path has a unit test. Fuzz inputs are bounded. Invariants are handler-based and spelled out in plain English. Differential tests compare against reference implementations wherever one exists. Gas snapshots are enforced in CI.
- **Security as process.** Each project has a threat model, Slither/forge-lint results triaged in config, and named failure modes (OWASP SC Top 10, 2026).
- **One CI workflow per project**, running the same gates as the local commands and triggered only by changes to that project.
- **README numbers are real.** Test counts, coverage, and gas figures are copied from actual runs.

## Running a project

Each project is independent. Open its folder and follow the *Getting started* section in its README. A typical Solidity project:

```bash
cd projects/09-erc4626-allocator-vault
forge soldeer install
forge build
forge test
```

Everything runs offline against local chains (anvil, LiteSVM, Sui test scenarios). No API keys, RPC endpoints, or testnet funds are needed.

## Repository layout

```
.
├── docs/ENGINEERING_STANDARDS.md   # the shared bar every project meets
├── projects/NN-name/               # 25 independent projects, numbered by level
└── .github/workflows/NN-name.yml   # one CI pipeline per project
```

## Scope and licensing

- **Not audited, not deployed.** These are portfolio projects written to production standards. None has been professionally audited or deployed with real funds.
- **Demos, not products.** Projects in regulated domains (stablecoin, tokenized fund, KYC) are technical demonstrations. They are not compliant financial products.
- **Licensing.** The repository is MIT-licensed, except where a project derives from GPL code and says so in its own LICENSE:
  - [12](projects/12-hardened-amm-dapp): contracts derived from Uniswap v2.
  - [22](projects/22-isolated-lending-engine): engine derived from Morpho Blue.
- **Prior art** is credited in each project's References section.

## Contact

GitHub: [@monzon1985](https://github.com/monzon1985). Open to smart-contract, protocol, and blockchain infrastructure roles and freelance work.
