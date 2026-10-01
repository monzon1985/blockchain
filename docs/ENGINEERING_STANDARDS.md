# Engineering Standards

Every project under [`projects/`](../projects) follows the same bar. This document is the contract: if a project deviates, its README says where and why.

## 1. Pinned toolchain

| Tool | Version | Notes |
|---|---|---|
| Solidity | `0.8.37` (exact pragma) | EVM `osaka` (compiler default). Documented exceptions only (e.g. Uniswap v4 pins `0.8.26` / `cancun`). |
| Foundry | `1.8.3` | `forge`, `anvil`, `cast`. Dependencies via **Soldeer** (`soldeer.lock` committed). |
| OpenZeppelin Contracts (+ Upgradeable) | `5.7.0` | No v4 idioms (`Counters`, `_beforeTokenTransfer`, owner-less `Ownable`). |
| forge-std | `1.16.2` | |
| Solady | `0.1.26` | Only where gas matters and the trade-off is documented. |
| Hardhat | `3.x` | Only where the project explicitly showcases Hardhat 3. |
| Node.js / TypeScript | `24` / `5.9` (pinned) | `strict: true`. |
| viem / wagmi / Next.js | `2.x` / `3.x` / `16.x` | |
| Rust | stable `1.98`, edition 2024 | `alloy 2.x` for EVM interaction. |
| Go | `1.27` | `go-ethereum 1.17.x`, `CGO_ENABLED=0` builds. |
| Python | `3.12` via `uv` | `uv.lock` committed. |
| Circom / snarkjs | `2.2.3` / `0.7.6` | `circomspect` clean. |
| Sui CLI | `1.80.x` | Move 2024 edition. |
| Solana | Agave `4.3`, Anchor `1.2` | Programs built with `cargo build-sbf`, tested with LiteSVM / Mollusk. |
| Static / dynamic analysis | Slither `0.11.6`, Medusa `1.5.1`, Halmos `0.3.3` | |

## 2. Project layout

```
projects/NN-slug/
├── README.md            # follows the template in section 8
├── src/ | contracts/    # production code
├── test/                # unit, fuzz, invariant, differential, e2e
├── script/              # deployment / demo scripts (keystore-based, no raw keys)
├── docs/                # threat model, design notes, reports (when large)
└── <toolchain files>    # foundry.toml, Cargo.toml, go.mod, package.json, ...
```

Each project is self-contained: its own toolchain root, its own lockfiles, its own CI workflow at `.github/workflows/NN-slug.yml`.

## 3. Solidity rules

- Exact pragma (`pragma solidity 0.8.37;`), and `solc_version` + `evm_version` pinned in `foundry.toml`.
- Custom errors, raised with `require(condition, CustomError(args))` or `revert CustomError(args)`. Errors carry the offending values.
- NatSpec (`@notice`, `@dev`, `@param`, `@return`) on every external/public function, event, error, and storage variable. The comments say something specific.
- Checks-effects-interactions. Reentrancy guards (`ReentrancyGuardTransient`) wherever external calls meet state.
- `SafeERC20` for all token transfers. No `transfer` / `send` for ETH. No `tx.origin` authorization.
- Every state change emits an event.
- Every `unchecked` block and every assembly block has a comment explaining why it is safe.
- Access control through OpenZeppelin `AccessManager` / `AccessControl` / `Ownable2Step`. Privileged roles are listed in the README with what a compromised role can do.
- Upgradeable contracts use ERC-7201 namespaced storage and call `_disableInitializers()` in the constructor.
- Signatures use EIP-712 domains with nonce, deadline, and chain id. Contract wallets are supported through ERC-1271 (`SignatureChecker`).
- No `console.log`, no TODOs, no compiler warnings in `src/`.

## 4. Testing rules

- **Fresh clone to green** with the commands documented in the README. No RPC endpoints, no API keys, no mainnet forks: everything runs offline against local chains (`anvil`, LiteSVM, Sui test scenarios, in-process simulators).
- **Unit tests** cover the happy path *and* every revert path.
- **Fuzz tests** constrain inputs with `bound()` rather than `vm.assume` wherever possible.
- **Invariant tests** (stateful, handler-based, ghost variables) for anything that holds value. Every invariant is written in plain English in the README and linked to the test function that enforces it.
- **Differential tests** against a canonical implementation whenever one exists (e.g. go-ethereum's trie, OpenZeppelin's Merkle tree, Uniswap v2 math).
- **Gas snapshots** are committed and checked in CI (`forge snapshot --check`).
- **Coverage** targets ≥ 90 % line coverage of production code; the README reports the real number.
- Tests are deterministic in CI (fixed fuzz seeds in the CI profile). A test is never skipped, weakened, or hard-coded to make CI green.

## 5. Other languages

| Language | Gates |
|---|---|
| Rust | `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`. `thiserror` in libraries, no `unwrap()` outside tests, `proptest` for properties. |
| Go | `gofmt`, `go vet`, table-driven tests, native fuzzing, `log/slog`, context-aware shutdown. |
| TypeScript | `tsc --noEmit` (strict), lint, `vitest` or `node:test`, Playwright for UI end-to-end tests. |
| Python | `uv`, `ruff`, `pytest`. |
| Circom | `circomspect` clean, constraint-level tests, including negative tests for under-constrained signals. |
| Move | `sui move test` with coverage, including expected-failure tests for every abort code. |

## 6. Security process

- Each project has a **threat model**: assets, actors, trust assumptions, attack surface, mitigations, known limitations.
- Static analysis (Slither, `forge lint`) runs in CI; every remaining finding is triaged in a config file with a justification.
- Vulnerability classes are named after the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/).
- **Nothing in this repository has been professionally audited.** Code is written to production standards but is not deployed with real funds.

## 7. Continuous integration

- One GitHub Actions workflow per project, triggered on changes to that project's folder or workflow file (plus `workflow_dispatch`).
- CI runs the same gates as the local commands in the README, on `ubuntu-latest`, with pinned tool versions.
- Each project README shows its own CI badge.

## 8. README template (every project)

1. **Title, one-line description, badges** (CI, license, main language/toolchain).
2. **What's interesting here**: 3–5 bullets with concrete numbers (invariants, gas deltas, proofs, test counts).
3. **Overview**: the problem and why it is non-trivial.
4. **Architecture**: Mermaid diagram plus a component table (component, responsibility, key external calls).
5. **Roles and trust assumptions** (when applicable).
6. **Invariants / properties**: numbered, plain English, linked to tests.
7. **Security considerations and threat model**, including known limitations.
8. **Design decisions and trade-offs**.
9. **Testing**: exact commands, a table of suites with counts, coverage, and fuzz/invariant settings. Numbers are copied from real command output.
10. **Gas** (EVM projects): snapshot table and baseline comparison.
11. **Getting started**: prerequisites with versions, install, build, test, local demo.
12. **Project structure**.
13. **Scope notes and future work**.
14. **References**: EIPs, papers, and prior art that inspired the design, with credit.

## 9. Integrity rules

- No claims of audits, mainnet deployments, users, TVL, clients, or partnerships.
- Projects in regulated domains (stablecoins, tokenized funds, KYC) are technical demonstrations, not compliant financial products, and say so.
- Third-party code and ideas are credited. No real brands are impersonated.
- Secrets never touch the repository: `.env.example` only, keystore-based deployment scripts.

## 10. Licensing

MIT (SPDX header in every source file) unless a dependency's license requires otherwise, in which case the project README states the license and why.
