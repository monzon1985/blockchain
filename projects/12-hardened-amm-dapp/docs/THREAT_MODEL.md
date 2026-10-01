# Threat model

Scope: `contracts/src` (`AMMFactory`, `AMMPair`, `AMMRouter`, `AMMLibrary`) and the dApp in `web/`. Vulnerability
classes are named after the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/). Nothing in this
project has been professionally audited, and it is not deployed anywhere with real funds.

## Assets

| Asset | Where it lives | What losing it means |
|---|---|---|
| Pool reserves (token0 / token1) | Each `AMMPair` | Direct loss for every LP of the pair. |
| LP principal (LP token balances) | `AMMPair` (Solady ERC-20) | Loss of the holder's share of the reserves. |
| The 1,000 locked LP units | `balanceOf(address(0))` in each pair | Share-price inflation becomes possible again (first-depositor attack). |
| Protocol fee stream | `AMMFactory.feeTo` | 1/6 of the LP fee growth goes to the wrong address. |
| Trader input / output | In flight through `AMMRouter` | Value extracted by front-running or by a bad quote. |
| TWAP accumulators | `price{0,1}CumulativeLast` | Downstream oracles read a manipulated price. |

## Actors

| Actor | Trust | Capabilities |
|---|---|---|
| Liquidity provider | Untrusted | `mint` / `burn` through the router or directly. |
| Trader | Untrusted | Swaps, flash swaps, direct transfers to pairs, `skim`, `sync`. |
| Searcher / MEV bot | Untrusted, adversarial | Reorders, front-runs and back-runs transactions in the same block. |
| Token contract | Untrusted | Arbitrary `transfer` semantics: fees, rebases, missing return values, callbacks (ERC-777-like hooks). |
| Integrating protocol | Untrusted, but a victim | Reads `getReserves()` / `totalSupply()` to price LP tokens. |
| Factory owner | Trusted for the fee only | `setFeeTo` (two-step ownership transfer). Cannot pause, upgrade, move reserves or mint LP. |
| dApp operator | Trusted for the UI | Serves the frontend and the deployment manifest. |

### Privileged roles

| Role | Function | A compromised role can... | ...and cannot |
|---|---|---|---|
| `AMMFactory.owner` (Ownable2Step) | `setFeeTo(address)` | Redirect the protocol fee (at most 1/6 of LP fee growth, i.e. 0.05 % of volume, and only while it is switched on) to an address of its choice. | Touch reserves, LP principal, swaps or pair code. Pairs and the router have no admin functions at all. |

## Attack surface and mitigations

| # | Threat (OWASP SC Top 10) | Mitigation | Enforced by |
|---|---|---|---|
| T-1 | **Reentrancy** (SC08) into `mint` / `burn` / `swap` / `skim` / `sync` through a token hook or the flash-swap callback. | OpenZeppelin `ReentrancyGuardTransient` (EIP-1153) on every state-changing pair function; the callback runs with the lock held and `k` is checked after it. | `AMMPairFlashSwapTest`, invariant I-9 |
| T-2 | **Read-only reentrancy** (SC08): an integrator reads `getReserves()` mid-`burn`, when supply has already dropped but reserves are stale, and prices LP tokens ~10x too high. | `getReserves()` is `nonReentrantView` and reverts while the lock is held; `isLocked()` lets integrators check explicitly. | `ReadOnlyReentrancyTest` (the canonical pair leaks the inflated price; the hardened pair reverts) |
| T-3 | **Price oracle manipulation** (SC03): spot reserves moved inside one transaction. | The pair only exposes TWAP accumulators (bit-exact Uniswap v2, differential-tested across the 2^32 timestamp wrap); spot `getReserves()` must not be used as an oracle, and the README says so. | `testFuzz_diff_twapAcrossTimestampWrap`, the differential invariant |
| T-4 | **First-depositor / donation inflation** (SC07 arithmetic): mint 1 wei of LP, donate, round later depositors to zero. | `MINIMUM_LIQUIDITY = 1000` LP units minted to `address(0)` on the first deposit; `liquidity > 0` required on every mint. | `testFuzz_firstMint_isFloorSqrtMinusMinimumLiquidity`, invariant I-6 |
| T-5 | **Arithmetic** (SC07): overflow in reserves or k, rounding in the attacker's favour. | Reserves capped at `uint112` (`Overflow`); k compared in 256-bit with the fee applied to the input side; `getAmountOut` rounds down, `getAmountIn` rounds up, `burn` rounds down. Every `unchecked` block (TWAP only) carries a proof comment. | `testFuzz_getAmountOut_isTheLargestOutputThePairAccepts`, `test_decimals24_hitsThe112BitReserveCeiling`, invariants I-1, I-4, I-5 |
| T-6 | **Unchecked external calls / weird ERC-20s** (SC06): missing return values, `false` returns, fee-on-transfer, rebasing. | `SafeERC20` everywhere; amounts in are measured as balance deltas, never trusted from arguments; `*SupportingFeeOnTransferTokens` functions check slippage on what the recipient actually received; rebases are reconciled with `skim` / `sync`. | `WeirdTokensTest` (13 tests over fee-on-transfer, rebasing, USDT-style, `false`-returning and 6/18/24-decimal tokens) |
| T-7 | **Front-running / sandwiching** (SC02 business logic): stale or unbounded trades. | Every router entry point takes a `deadline` and a slippage bound (`amountOutMin`, `amountInMax`, `amountAMin`, `amountBMin`); the dApp derives them from its settings and quotes with the exact on-chain math. | Router unit tests; Playwright slippage spec (a front-run swap reverts with `InsufficientOutputAmount` and the toast explains it) |
| T-8 | **Flash-swap misuse** (SC04 flash-loan-facilitated attacks): optimistic transfer to a contract that did not opt in. | `to` must have code when `data` is non-empty and must return `keccak256("IAMMCallee.ammSwapCall")`; k is enforced after the callback. Callees must still authenticate the pair (see `FlashBorrower`). | `AMMPairFlashSwapTest` |
| T-9 | **Permit front-running** (SC02 business logic, griefing): someone submits a user's EIP-2612 signature first, consuming the nonce, so a router that blindly calls `permit` reverts. | `removeLiquidityWithPermit` wraps `permit` in `try` and proceeds if the resulting allowance already covers the removal. | `AMMRouterTest::test_removeLiquidityWithPermit_survivesFrontRunPermit` |
| T-10 | **Pair squatting**: a pair pre-created for a counterfactual token address. | `createPair` requires both tokens to have code (`TokenHasNoCode`). | `AMMFactoryTest` |
| T-11 | **Access control** (SC01) on the protocol fee. | `Ownable2Step`; `setFeeTo` emits `FeeToUpdated`. | `AMMFactoryTest` |
| T-12 | **Initializer misuse** (SC01): calling `initialize` on a pair twice or front-running it. | There is no initializer: tokens are immutables read from the factory's transient `parameters()` inside the constructor. | `AMMFactoryTest::test_createPair_deploysAtCreate2AddressWithSortedImmutableTokens` |
| T-13 | **Frontend shows a price the chain will not honour.** | The TypeScript quote library is bit-for-bit the Solidity math, including Solidity 0.8's checked `uint256` arithmetic (an input the router rejects with `Panic(0x11)` is an error, not a quote) and the pair's 112-bit reserve ceiling; it is differential-tested against the deployed router on anvil up to 2^256 - 1, and Playwright checks the rendered quote against `getAmountsOut` to the wei. | `web/test/quote.anvil.test.ts`, `web/test/quote.test.ts`, `web/e2e/amm.spec.ts` |
| T-14 | **Phishing-grade permit signing in the UI.** | The dApp rebuilds the EIP-712 domain (with the deployment's chain id) and refuses to sign unless it hashes to the pair's on-chain `DOMAIN_SEPARATOR`. | `remove liquidity with an EIP-2612 permit` e2e spec |
| T-15 | **Wallet on the wrong network.** The calls are simulated on the deployment chain, but a wallet on another chain would sign and send them there, to the same addresses (which hold unrelated code on public chains). | The guard reads the chain the wallet reports (`useConnection().chainId`; wagmi's `useChainId()` stays on the last configured chain), disables swap, liquidity and permit actions and offers a switch; every write carries the deployment's `chainId`, so wagmi refuses it before signing. | `web/test/hooks.anvil.test.tsx` (the mock wallet switches to chain 1: nothing is sent, the toast says why) |

## Trust assumptions

- Tokens are assumed not to be malicious towards their own holders beyond the "weird token" behaviours above. A
  token that can arbitrarily move balances (admin `burnFrom`, blacklist, pause) can break any pool that holds it;
  this is inherent to permissionless pools and is not mitigated on-chain.
- The router holds no funds and no state, so a compromised or malicious router can only spend approvals that users
  gave it. Users should approve only what they trade: the dApp approves exactly what each transaction spends (the
  input of an exact-in swap, the slippage-bounded maximum of an exact-out swap, each side of a deposit).
- The local demo uses anvil's unlocked dev accounts through wagmi's mock connector. It is a test harness, enabled
  only through `AMM_ENABLE_MOCK_CONNECTOR`, and must never be enabled against a public chain.

## Known limitations

- **Spot price is manipulable** within a block, as in every constant-product AMM. Integrators must use the TWAP
  accumulators (or an external oracle), never `getReserves()` alone.
- **Rebasing tokens**: negative rebases make `mint`, `skim` and swaps revert until someone calls `sync`; positive
  rebases accrue as a skimmable surplus that anyone can take until `sync` is called (the canonical behaviour,
  documented and tested, not changed).
- **Fee-on-transfer tokens** only work through the `*SupportingFeeOnTransferTokens` router functions; the plain
  exact-in / exact-out functions revert with `K`. This mirrors Uniswap v2.
- **MEV**: deadlines and slippage limits bound the loss of a sandwiched trade; they do not prevent it.
- **TWAP wrap**: accumulators wrap modulo 2^256 by design and `blockTimestampLast` wraps modulo 2^32 (year 2106);
  consumers must difference them with wrapping arithmetic, exactly as with Uniswap v2.
- **No ETH entry points**: users wrap ETH themselves (see `DEVIATIONS.md`, R-1).
