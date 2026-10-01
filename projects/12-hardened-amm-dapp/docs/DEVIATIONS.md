# Deviations from canonical Uniswap v2

The differential suite (`contracts/test/differential/`) deploys the canonical `UniswapV2Factory` from the
`@uniswap/v2-core@1.0.1` npm build artifacts. The pair bytecode in that package hashes to
`0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f`, the mainnet init-code hash, and
`CanonicalOracleTest` asserts it. The canonical factory then creates the canonical pair itself (CREATE2 with
its own embedded bytecode).

For every sequence of `mint`, `burn`, `swap` (plain, with empty `data`), `skim`, `sync`, direct donations, LP
transfers, time jumps (including the 2^32 timestamp wrap) and protocol-fee toggles, both pairs must:

- agree on the outcome: both succeed or both revert;
- return the same values (`mint` liquidity, `burn` amounts);
- end with identical reserves, `blockTimestampLast`, `price0CumulativeLast`, `price1CumulativeLast`, `kLast`,
  LP `totalSupply`, LP balances of every actor, of `address(0)`, of the fee recipient and of the pair itself,
  and identical token balances.

Everything below is an **intentional** difference. None of it is reachable by the operations above, which is why the
differential suite can require exact equality.

## Pair (`AMMPair` vs `UniswapV2Pair`)

| # | Canonical behaviour | Hardened behaviour | Why | Evidence |
|---|---|---|---|---|
| D-1 | Reentrancy lock is a storage slot (`unlocked`), invisible to other contracts. `getReserves()` answers at any time, including mid-`swap`/`burn`. | Lock is OpenZeppelin `ReentrancyGuardTransient` (EIP-1153). `isLocked()` exposes it; `getReserves()` is `nonReentrantView` and reverts with `ReentrancyGuardReentrantCall()` while any state-changing function runs. | Read-only reentrancy: during `burn` the LP supply has already dropped while reserves are stale, so an oracle pricing LP tokens from `getReserves()/totalSupply()` can be fed a ~10x price through a hook token. | `ReadOnlyReentrancyTest` (canonical leaks the inflated price, hardened reverts); `AMMPairFlashSwapTest::test_readOnlyReentrancy_getReservesRevertsInsideCallback` |
| D-2 | Flash swap calls `IUniswapV2Callee(to).uniswapV2Call(...)` and ignores the result. | Calls `IAMMCallee(to).ammSwapCall(...)`, which must return `keccak256("IAMMCallee.ammSwapCall")`; `to` must have code (`CallbackTargetNotContract`). | A flash swap to an address that did not opt in (a contract whose fallback accepts anything) fails loudly instead of relying on the k check alone. The callee must still authenticate the pair and the initiator; see `FlashBorrower`. | `AMMPairFlashSwapTest` |
| D-3 | `initialize(token0, token1)` called by the factory after CREATE2; tokens are storage variables. | No `initialize`. The pair constructor reads `(token0, token1)` from the factory's transient `parameters()`; tokens are immutables. | No initialiser to misuse, and two cold `SLOAD`s saved on every call. The init code does not depend on the tokens, so addresses are still `CREATE2(factory, keccak256(token0, token1), initCodeHash)`, with a different init-code hash. | `AMMFactoryTest::test_createPair_deploysAtCreate2AddressWithSortedImmutableTokens`, gas table |
| D-4 | LP token `Uniswap V2` / `UNI-V2`, OpenZeppelin-free ERC-20 with EIP-2612. | Solady `ERC20` with EIP-2612, `Hardened AMM LP` / `HAMM-LP`. Permit2 does **not** get Solady's implicit infinite allowance. | Different name, so EIP-712 domains (and permit signatures) differ. Allowance semantics are unchanged: `type(uint256).max` is infinite in both. | `AMMPairTest::test_domainSeparator_isEip712WithPairAddress`, `test_permit2_hasNoImplicitAllowance` |
| D-5 | Revert strings (`UniswapV2: K`, `ds-math-sub-underflow`, ...). | Custom errors that carry the offending values (`K(balanceProduct, reserveProduct)`, `InsufficientLiquidity(...)`, ...); Solidity 0.8 checked arithmetic reverts with `Panic(0x11)` where `SafeMath` reverted. | Cheaper, and the dApp decodes them into readable toasts. The differential suite compares success/failure, not revert data. | Unit tests assert exact error payloads |
| D-6 | `_safeTransfer` accepts an empty return from any address, including one without code. | OpenZeppelin `SafeERC20`: an empty return is accepted only from an address with code; `false` reverts with `SafeERC20FailedOperation(token)`. | Pairs of code-less "tokens" cannot be created in the first place (D-8); this closes the remaining path. | `WeirdTokensTest::test_returnsFalse_isRejectedOnPullAndOnPush` |

## Factory (`AMMFactory` vs `UniswapV2Factory`)

| # | Canonical behaviour | Hardened behaviour | Why |
|---|---|---|---|
| D-7 | `feeToSetter` (single step) controls `feeTo` and can hand itself over with `setFeeToSetter`. | `Ownable2Step` owner controls `feeTo` (`setFeeTo`, event `FeeToUpdated`). | Two-step ownership transfer and an event for every change. The protocol-fee formula (1/6 of sqrt(k) growth) is unchanged and differential-tested. |
| D-8 | `createPair` accepts any two distinct non-zero addresses. | Also requires both tokens to have code (`TokenHasNoCode`). | A pair can otherwise be pre-created for a counterfactual token address. |
| D-9 | No init-code hash getter. | `PAIR_INIT_CODE_HASH` immutable and the transient `parameters()` view. | Routers derive pair addresses without hard-coding a hash that depends on compiler settings. |

## Router (`AMMRouter` vs `UniswapV2Router02`)

The router is not part of the bytecode oracle (the canonical router lives in `v2-periphery`), but its quote math is
checked against the canonical pair: `getAmountOut` is exactly the canonical k boundary (the quote is accepted and
one more wei is rejected), and `getAmountIn` always buys the requested output
(`CanonicalDifferentialTest::testFuzz_diff_getAmountOutIsTheExactKBoundary`, `..._getAmountInIsSufficient`).

| # | Router02 | AMMRouter |
|---|---|---|
| R-1 | ETH/WETH entry points (`addLiquidityETH`, `swapExactETHForTokens`, ...). | ERC-20 only; no payable function, so ETH cannot get stuck. Wrap ETH before trading. |
| R-2 | `removeLiquidityWithPermit` reverts if anyone front-runs the permit (nonce consumed). | `permit` is wrapped in `try`; if it fails but the allowance is already sufficient, the removal proceeds (`PermitFailed` otherwise). |
| R-3 | A missing pair makes `getReserves` revert without data. | `PairNotFound(tokenA, tokenB)`. |
| R-4 | `to` is not checked. | `to != address(0)` (`InvalidRecipient`). |
| R-5 | Fee-on-transfer removal only for ETH pairs. | `removeLiquiditySupportingFeeOnTransferTokens` for any token pair (minimums checked on what `to` received). |
| R-6 | `removeLiquidityWithPermit` checks the deadline inside `permit`. | The router checks `deadline` first, so an expired call fails with `Expired(deadline, timestamp)`. |
