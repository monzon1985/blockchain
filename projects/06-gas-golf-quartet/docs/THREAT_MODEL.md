# Threat model

Scope: the four token implementations (`QuartetSolidity`, `QuartetAssembly`, `QuartetYul`,
`QuartetVyper`) and the fixed-point kernel (`FixedPointRef`, `FixedPointGolf`, `FixedPointLegacy`).
`OZReference` is a test oracle and out of scope. Nothing here has been audited or deployed with real
funds; this is an engineering demonstration of how to golf safely.

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| Balances | token storage (three different layouts) | Direct loss if moved, created or destroyed incorrectly |
| Allowances | token storage | A wrong decrement or a missed check lets a spender take more than approved |
| Permit nonces and signatures | token storage, EIP-712 domain | Replay or forgery grants allowances without the owner |
| Kernel results | `FixedPointGolf` return values | Integrators price, round and account with them; a wrong result or a missing revert is silent value leakage |

## Actors

- **Holders and spenders**: call `transfer`, `approve`, `transferFrom`.
- **Relayers**: submit someone else's signed `permit`.
- **Arbitrary callers**: send any calldata, including malformed ABI (dirty address bits, truncated
  arguments, unknown selectors, ETH to non-payable functions).
- **Block proposers**: pick `block.timestamp` within protocol bounds (permit deadlines).
- **Chain forks**: a fork keeps state but changes `block.chainid`.
- **Proxies**: a contract may `DELEGATECALL` a token implementation.

There are **no privileged roles**: no owner, no minter, no pauser, no upgrade path. The supply is minted
once in the constructor. A compromised deployer key can do nothing after deployment.

## Trust assumptions

1. The EVM implements Osaka semantics, including EIP-7939 `CLZ` for `FixedPointGolf`. The tokens and
   `FixedPointLegacy` contain no `CLZ` (checked by `ClzOpcode.t.sol`) and also run on Prague.
2. solc 0.8.37, Vyper 0.4.3 and the `ecrecover` precompile behave as specified.
3. keccak256 is collision resistant. The Yul layout additionally relies on a keccak output landing below
   2\*\*161 with probability 2\*\*-95 (see "Storage aliasing" below).
4. No state-changing transaction has `msg.sender == address(0)`. OpenZeppelin checks this; the assembly,
   Yul and Vyper versions do not (trick T15), and the halmos proofs state it as their only precondition.
   An `eth_call` without `from` does run with sender zero, and there the golfed versions succeed where
   OpenZeppelin reverts (`test_ZeroSender_Characterization`); integrators that simulate calls this way
   see a different result, but no state can change.
5. Permit signers are EOAs. `permit` verifies ECDSA signatures only, as EIP-2612 and OpenZeppelin 5.7's
   `ERC20Permit` do; ERC-1271 contract-wallet signatures are not supported (a stated deviation from the
   repository standards, see the README's design decisions).

## Attack surface and mitigations

| Threat | OWASP SC Top 10 (2026) | Mitigation | Evidence |
|---|---|---|---|
| A golfed implementation diverges from the reference on some input or state (wrong balance, missing revert, wrong event) | SC02 Business Logic Vulnerabilities | Lockstep differential fuzzing of all four against OpenZeppelin; halmos equivalence proofs for Solidity, assembly and Yul over symbolic balances and allowances, for every non-zero caller (trust assumption 4) | `LockstepInvariant.t.sol`, `ERC20Equivalence.t.sol`, mutants in the README |
| Malformed calldata accepted by the hand-written Yul decoder (dirty address bits in any address word, the second of a pair included; dirty `uint8 v`; short calldata; 1-3 byte selectors, which can match `nonces(address)` = `0x7ecebe00`) | SC05 Lack of Input Validation | The Yul object re-implements Solidity's ABI checks: per-function length, clean addresses (pairs checked with one `shr(160, or(a, b))`), clean `uint8`, global `callvalue` check | halmos `check_dirtyWordsAreRejected`; `ERC20Spec` ABI-strictness tests (every address word dirtied alone, every selector prefix); lockstep `malformed` (one strictly typed word dirtied at a time) and `raw` actions; mutants M11-M13 |
| Permit signature malleability (high-`s` twin) | SC05 Lack of Input Validation | Every implementation rejects `s > secp256k1n / 2`, as OpenZeppelin's ECDSA does | `test_Permit_RevertWhen_SignatureIsMalleableHighS`, lockstep permit mode 3 |
| Permit replay (same chain, fork, or proxy context) | SC05 Lack of Input Validation | Per-owner nonce; the cached domain separator is recomputed when `chainid` or `address(this)` differs from deployment | `test_Permit_RevertWhen_Replayed`, `test_DomainSeparator_FollowsChainIdAfterFork`, `test_DomainSeparator_UsesExecutingAddressUnderDelegatecall`, `invariant_DomainSeparatorFollowsChainId` |
| `ecrecover` returning `address(0)` matched against `owner == address(0)` | SC06 Unchecked External Calls | The precompile's output word is pre-zeroed and `signer != 0` is required together with `signer == owner`; the precompile's success flag carries no information and is ignored by design | `test_Permit_RevertWhen_OwnerIsZero` (signatures asserted unrecoverable first: r = 0, r = n, r = 5), lockstep permit mode 7, mutant M14 |
| Allowance bypass: infinite allowance decreased, finite allowance not decreased, zero-address owner | SC01 Access Control Vulnerabilities | OpenZeppelin's rules, in OpenZeppelin's check order | `ERC20Spec` transferFrom tests, halmos `check_transferFrom` (all allowance values) |
| Balance overflow / underflow in `unchecked` code | SC09 Integer Overflow and Underflow | Every subtraction follows an explicit bound check; the recipient's addition wraps exactly like OpenZeppelin's `unchecked` block and cannot overflow while balances sum to the fixed supply | halmos proofs over symbolic balances (wrapping included), `invariant_BalancesSumToTotalSupply` |
| Kernel rounding or overflow bug (`mulDiv` intermediate overflow, off-by-one in `sqrt`, `log2(0)`) | SC07 Arithmetic Errors (Rounding & Precision) | Reference implementation, halmos proofs for `mulDiv`, `mulDivUp`, `log2`, `log2Up`, `clz`; exhaustive and boundary tests plus fuzzing for `sqrt`; independent 512-bit oracle | `MathEquivalence.t.sol`, `MathKernel.t.sol`, `ClzOpcode.t.sol` |
| Reentrancy | SC08 Reentrancy Attacks | No external calls other than a `STATICCALL` to the `ecrecover` precompile | code inspection; Slither clean |
| Behaviour under `DELEGATECALL` from a proxy | SC10 Proxy & Upgradeability Vulnerabilities | No upgrade mechanism; the only address-dependent value (domain separator) is recomputed for the executing address | `test_DomainSeparator_UsesExecutingAddressUnderDelegatecall` |
| Oracle manipulation, flash-loan attacks | SC03, SC04 | Not applicable: no prices, no external protocol state | n/a |

## Storage aliasing (Yul layout)

`QuartetYul` stores balances at slot `owner` (< 2\*\*160) and nonces at `owner + 2**160`, and allowances at
`keccak256(owner ‖ spender)`. An allowance slot aliases a balance or nonce slot only if the hash is below
2\*\*161, probability 2\*\*-95 per pair. The attacker chooses `spender` freely and `owner` among accounts
whose keys they hold. What they could do, and what it costs (this is the one statement of these figures;
the README, TRICKS.md and the Yul source repeat it):

- **Write some unowned account's balance or nonce.** Grinding (owner, spender) pairs until one hash lands
  below 2\*\*161 costs about 2\*\*95 hash evaluations (2\*\*96 for a balance slot alone). The payoff is
  setting the balance of an address that is essentially random, which nobody controls. This breaks the
  "balances sum to supply" accounting but moves no one's funds.
- **Write the balance of an account the attacker controls.** The hash must equal one of the attacker's own
  addresses as a full 256-bit word (96 zero bits plus 160 address bits). With K attacker keys and H
  hashes the expected number of hits is K·H / 2\*\*256, so a meet-in-the-middle balance needs about 2\*\*128
  of each. Out of reach.
- **Write a chosen victim's balance.** The target word is fixed, so there is nothing to meet in the
  middle: about 2\*\*256 hash evaluations. Out of reach.

`testFuzz_AllowanceWriteTouchesNoBalanceOrNonce` checks the layout side of this on the deployed tokens
(an allowance write leaves every balance and nonce a getter can see unchanged, including those of the
address that shares the allowance slot's low 160 bits); the probability bound itself is this argument.

The Solidity, assembly and Vyper layouts hash every key and have no such trade-off. This is the price of
the Yul version's cheaper storage access (trick T2) and is documented as such.

## Known limitations

- Vyper is covered by differential fuzzing only: halmos 0.3.3 cannot run Vyper artifacts through forge.
- Halmos 0.3.3 does not implement `CLZ`; the golfed kernel is proven with a plain-EVM model of the opcode,
  and the model is tested against the real opcode separately (`ClzOpcode.t.sol`): the proofs say nothing
  about opcode `0x1e` itself.
- The ERC-20 proofs assume a non-zero caller (trust assumption 4) and ABI-encoded arguments; malformed
  address and `uint8` words are covered by `check_dirtyWordsAreRejected`, other malformed calldata
  (truncation, trailing bytes, unknown selectors) by the specification and the lockstep fuzzer only.
- No ERC-1271: contract wallets cannot sign permits (trust assumption 5).
- Halmos cannot observe events; event equality is enforced by the lockstep fuzzer, not proven.
- `permit` equivalence is fuzzed, not proven: each token has its own EIP-712 domain, so the recovered
  signer is a different uninterpreted value per implementation for the SMT solver.
- `sqrt` is not proven; it is tested exhaustively below 2\*\*16 and on every bit length.
- Selector-only errors in the golfed versions drop the ERC-6093 arguments; integrators that decode them
  must use the Solidity version.
- ERC-20's `approve` front-running race is inherent to the standard and not mitigated here.
- Constructor arguments are outside the shared surface (only the deployer supplies them), and there the
  implementations differ in one way: with the last argument word missing, OpenZeppelin, Solidity,
  assembly and Yul refuse to deploy, while Vyper 0.4.3 reads the missing word as zero and deploys a
  zero-supply token. `test_Constructor_TruncatedArguments` pins this behaviour.
