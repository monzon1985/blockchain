# ERC-7683 v1 vs the resolver-centric draft

This project implements the **first ERC-7683 draft** (settler-centric: `GaslessCrossChainOrder`, `IOriginSettler.open/openFor/resolve/resolveFor`, `ResolvedCrossChainOrder`, `IDestinationSettler.fill`), as it stood at [ethereum/ERCs@5635555](https://github.com/ethereum/ERCs/blob/563555549226f2222de2ec3b405945c8f5d6c2b2/ERCS/erc-7683.md) (January 2025).

On 2026-05-13 the ERC was rewritten around **resolvers** ([ethereum/ERCs@96d110f](https://github.com/ethereum/ERCs/blob/96d110fbbe7042b061064833edaf8fa2cf5db195/ERCS/erc-7683.md), status Draft). A protocol now publishes an opaque payload plus a resolver contract, and `resolve(payload)` returns *steps* (calls to make), *variables* (values the solver decides or observes), *payments* and *named assumptions*. Solvers integrate once against that instruction set instead of once per protocol.

[`ERC7683ResolverAdapter`](../src/adapters/ERC7683ResolverAdapter.sol) exposes this protocol's v1 orders through the new interface: `resolve(abi.encode(GaslessCrossChainOrder, signature))`. The adapter is tested two ways (see [`test/unit/ResolverAdapter.t.sol`](../test/unit/ResolverAdapter.t.sol)): the shape of its output, and a small **generic interpreter** that executes the returned steps on both chains, knowing nothing about this protocol beyond the draft and the witness kinds listed below. The interpreter ends up repaid in all three settlement modes, which is the real test of the mapping. It also honours the revert policies: it skips an `openFor` already done by another solver (`ignore`) and gives up on an order someone else filled first (`abort`).

## How a v1 order maps

| Draft concept | Mapping for this protocol |
|---|---|
| Step 0 `Call` | `OriginSettler.openFor(order, signature, "")` on the origin chain. `TimingBounds(block.timestamp, -, openDeadline)`. `RevertPolicy("ignore", OrderAlreadyExists(orderId))`: if another solver opened it, the step counts as done. |
| Step 1 `Call` | `DestinationSettler.fillWithRepayment(orderId, originData, <PaymentRecipient>)` on the destination chain. `NeedsStep(0)`, `SpendsERC20(outputToken, Constant(outputStartAmount), settler, recipient)`, `TimingBounds(-, fillDeadline)`, `RevertPolicy("abort", AlreadyFilled(orderId,..))`, plus `RevertPolicy("abort", NotExclusiveFiller(..))` when the order is exclusive. |
| Mode 1 (mailbox) | Step 2 `MailboxFillReporter.report(orderId, originChainId)`. Payment on step 2 with `estimatedDelaySeconds` = mailbox latency. Assumption `erc7683-intents/trusted-mailbox`. |
| Mode 2 (optimistic) | Step 2 `claim(orderId, <PaymentRecipient>, <fill timestamp>, fillHash)` with `SpendsERC20(bond)`. Step 3 `finalize(orderId, <PaymentRecipient>, <fill timestamp>)` (claims are keyed by order, filler and fill time, so finalize names the claim step 2 posted) with `TimingBounds(<claim time + window + 1>, -)`. Payment on step 3, delay = challenge window. Assumptions `erc7683-intents/honest-watcher` and `erc7683-intents/trusted-header-relayer`. |
| Mode 3 (proof) | Step 2 `proveFill(orderId, <relayed block>, fillHash, <accountProof>, <slotProof>)`. The three `<..>` are `Witness` variables. Payment on step 2, delay = header relay cadence. Assumption `erc7683-intents/trusted-header-relayer`. |
| Payment | `ERC20(inputToken@origin, originSettler@origin, Constant(inputAmount), PaymentRecipient, onStep, delay)`. |

Addresses are ERC-7930 interoperable addresses (`InteroperableAddress.formatEvmV1` from OpenZeppelin 5.7).

## Where the draft cannot express v1 exactly (the drift)

| # | Gap | What v1 does | What the adapter does |
|---|---|---|---|
| 1 | **Opaque `fillerData`.** Call arguments are constants or variables; there is no way to build `abi.encode(address)` from a variable inside a `bytes` argument. | `fill(orderId, originData, fillerData)` with `fillerData = abi.encode(repaymentAddress)`. | The settler has a typed twin, `fillWithRepayment(orderId, originData, repaymentRecipient)`, and the adapter targets it. Both share one internal `_fill`. |
| 2 | **No arithmetic in formulas.** Formulas are `Constant` or `Variable`, so "claim time + challenge window" cannot be a timing bound. | The optimistic claim can be finalized strictly after `claimTime + window`. | A `Witness` of kind `erc7683-intents/uint256-add` (`variables[0] + abi.decode(data)`) computes the bound from the claim step's `ExecutionOutput(block.timestamp)`. |
| 3 | **Dutch decay is not a formula.** The owed amount depends on inclusion time. | `DutchDecay` from `outputStartAmount` to `outputEndAmount`. | `SpendsERC20` uses `Constant(outputStartAmount)`, the upper bound the draft allows ("the amount SHOULD decrease with time so that a tight upper bound can be estimated"). |
| 4 | **No exclusivity primitive.** The resolver does not know who is resolving, so "only X before T" cannot be a per-solver timing bound. | Exclusive filler until `exclusivityDeadline`. | Named assumption `erc7683-intents/exclusive-filler(filler, deadline)` plus `RevertPolicy("abort", NotExclusiveFiller(..))`. |
| 5 | **Proof inputs are off-chain procedures.** A storage proof is not a call result or a log. | `proveFill` needs a relayed block number and `eth_getProof` output. | `Witness` kinds `erc7683-intents/relayed-header` (lowest stored header at or after the fill block), `eth_getProof/accountProof` and `eth_getProof/storageProof`. The draft allows exactly this ("kind MUST identify some off-chain procedure"). |
| 6 | **Collateral is not a payment.** Payments go to a `PaymentRecipient`; a bond returned to the claimant is neither. | Mode 2 returns the bond to whoever posted it. | Declared only as `SpendsERC20` on the claim step. The refund is not advertised as a payment, which understates what the solver gets back. |
| 7 | **`PaymentChain` is not honoured.** v1 repays on the origin chain only. | Repayment on the origin chain. | No `PaymentChain` variable; the payment's token address carries the origin chain. |
| 8 | **`maxSpent`/`minReceived` removed.** The draft drops them because bounds that are not tight hide profitable orders. | `resolve()` still returns them for v1 integrators. | The adapter derives steps and payments from the same order; v1 `resolve` is unchanged. |
| 9 | **Fill-first protocols.** The draft supports resource-lock designs where no origin transaction precedes the fill. | Escrow-first: `open` before `fill`. | The fill step has `NeedsStep(0)`; this protocol cannot drop it. |

## Not implemented

- `Query` and `QueryEvents` variables are defined in the interface but not emitted; the witness kinds above cover what this protocol needs.
- The adapter resolves gasless orders only. On-chain orders are already open, so a solver needs the fill step onwards, which is the same as the gasless case minus step 0.
