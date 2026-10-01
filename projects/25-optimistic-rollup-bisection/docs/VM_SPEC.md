# VM and state-transition specification

This document is the normative description of the rollup VM, its per-step commitment, the one-step witness format,
and the state-transition program. Two implementations follow it: the Rust interpreter
([`crates/vm/src/interp.rs`](../crates/vm/src/interp.rs)) and the Solidity verifier
([`contracts/src/OneStepVM.sol`](../contracts/src/OneStepVM.sol)). The differential suite
([`crates/diff/tests/differential.rs`](../crates/diff/tests/differential.rs)) runs both on the same inputs and compares
the full post-state.

## 1. Machine state and commitment

| Field | Type | Meaning |
|---|---|---|
| `status` | `uint8` | 0 running, 1 halted, 2 errored |
| `pc` | `uint32` | index of the next instruction |
| `stackDepth` | `uint32` | number of stack words (at most 1,024) |
| `stackHash` | `bytes32` | hash chain: `H(empty) = 0`, `H(push(s, x)) = keccak256(x ‖ H(s))` |
| `stateRoot` | `bytes32` | root of the 256-level sparse Merkle tree holding the L2 state |
| `codeRoot` | `bytes32` | Merkle root of the program (section 3) |
| `codeSize` | `uint32` | number of instructions |
| `inputRoot` | `bytes32` | `keccak256(tape)` |
| `inputSize` | `uint32` | tape length in words |

The **state hash** is `keccak256(abi.encode(machine))` (nine 32-byte words). The Rust interpreter recomputes it after
every instruction; the dispute game bisects over these hashes. Every field is derived from real data in the Rust
`MachineState` (the stack hash from the stack, the state root from the tree, and so on), so an internally inconsistent
machine cannot be constructed there.

A machine whose status is not `running` is a **fixed point**: stepping it returns it unchanged. The dispute game pads
every trace to exactly `2^MAX_DEPTH` steps with this fixed point.

## 2. Instruction set

All words are 256-bit. Binary operators pop `a` (the top) and then `b`, and push `a OP b`.

| Byte | Mnemonic | Reads → writes | Semantics |
|---|---|---|---|
| `0x00` | `HALT` | 0 → 0 | status := halted (pc unchanged) |
| `0x01` | `PUSH imm` | 0 → 1 | push `imm` |
| `0x02` | `POP` | 1 → 0 | drop the top |
| `0x03` | `DUP n` | n+1 → n+2 | push a copy of item `n` (0 = top), `n ≤ 15` |
| `0x04` | `SWAP n` | n+1 → n+1 | swap the top with item `n`, `1 ≤ n ≤ 15` |
| `0x05` | `ADD` | 2 → 1 | `a + b mod 2^256` |
| `0x06` | `SUB` | 2 → 1 | `a - b mod 2^256` |
| `0x07` | `MUL` | 2 → 1 | `a * b mod 2^256` |
| `0x08` | `DIV` | 2 → 1 | `a / b`, 0 if `b = 0` |
| `0x09` | `LT` | 2 → 1 | `a < b` |
| `0x0a` | `GT` | 2 → 1 | `a > b` |
| `0x0b` | `EQ` | 2 → 1 | `a = b` |
| `0x0c` | `ISZERO` | 1 → 1 | `a = 0` |
| `0x0d` | `AND` | 2 → 1 | bitwise and |
| `0x0e` | `OR` | 2 → 1 | bitwise or |
| `0x0f` | `HASH` | 2 → 1 | `keccak256(a ‖ b)` |
| `0x10` | `JUMP imm` | 0 → 0 | `pc := imm` |
| `0x11` | `JUMPI imm` | 1 → 0 | if `a ≠ 0` then `pc := imm` |
| `0x12` | `INPUT` | 1 → 1 | tape word `a`, or 0 if `a ≥ inputSize` |
| `0x13` | `INPUTSIZE` | 0 → 1 | `inputSize` |
| `0x14` | `SLOAD` | 1 → 1 | value stored at key `a` (0 if absent) |
| `0x15` | `SSTORE` | 2 → 0 | store `b` at key `a` (0 deletes) |
| `0x16` | `ECRECOVER` | 4 → 1 | pops digest, `v`, `r`, `s`; pushes the signer as a word, 0 on failure. `v` must be the full word 27 or 28; high-`s` is accepted: identical to the `ecrecover` precompile |
| `0x17` | `FAIL` | - | status := errored |

### Evaluation order

The order below decides which rule wins when several apply, and both implementations follow it line by line:

1. a halted or errored machine is returned unchanged;
2. `pc ≥ codeSize` → errored;
3. the instruction witness must verify against `codeRoot` (**revert** otherwise);
4. undefined opcode, `FAIL`, or an out-of-range `DUP`/`SWAP` operand → errored; `HALT` → halted;
5. `stackDepth < reads` (underflow) or `stackDepth - reads + writes > 1024` (overflow) → errored;
6. the revealed stack words must hash to `stackHash` (**revert** otherwise);
7. the opcode executes. A jump (or taken `JUMPI`) to a target `≥ codeSize` → errored. `INPUT` requires the tape
   to hash to `inputRoot`, `SLOAD`/`SSTORE` require a state proof against `stateRoot` (**revert** otherwise).

An erroring instruction changes nothing but `status`. A revert means the *witness* is wrong, never the program.

## 3. Program commitment

Leaf of instruction `pc`: `keccak256(keccak256(abi.encode(pc, opcode, imm)))` (double hashing, the OpenZeppelin
convention). Internal nodes: `Hashes.commutativeKeccak256` (sorted pair). An unpaired node at the end of a layer is
promoted unchanged. The instruction witness is verified with OpenZeppelin's `MerkleProof.verifyCalldata`. Because
every leaf commits to its own `pc` and the program is fixed, a valid proof for `(pc, op, imm)` implies that `op, imm` is
the instruction at `pc`.

## 4. State tree

A 256-level sparse Merkle tree keyed by 32-byte keys, where bit `h` of the key (as a big-endian `uint256`) selects the
side at height `h` (height 0 = leaves, height 256 = root):

- `leaf(k, v) = v = 0 ? 0 : keccak256(k ‖ v)`
- `node(l, r) = l = 0 ∧ r = 0 ? 0 : keccak256(l ‖ r)`

Empty subtrees hash to zero at every height, so proofs are compressed: a 256-bit bitmap marks the non-zero siblings,
which are shipped leaf level first. The same proof proves inclusion and absence, and `SSTORE` computes the new root
from the old proof. Deleting the last leaf restores the empty root (property-tested).

## 5. Witness (`StepProof`)

| Field | Used by | Content |
|---|---|---|
| `opcode`, `imm`, `codeProof` | every running step | the instruction and its Merkle path |
| `stack`, `stackRest` | steps past rule 5 | exactly `reads` top words (top first) and the hash below them |
| `leafValue`, `siblingBitmap`, `siblings` | `SLOAD`, `SSTORE` | current value at the key and its compressed path |
| `tape` | `INPUT` | the full tape (checked against `inputRoot`) |

The whole tape travels only in the rare `INPUT` step of a dispute: batch submission stays cheap (one `keccak256` over
calldata) and the worst-case witness (a 24.6 KB tape) costs 537,060 gas for the verifier call.

## 6. L2 state layout

| Item | Key | Value |
|---|---|---|
| balance of `a` | `keccak256(1 ‖ a)` | wei |
| nonce of `a` | `keccak256(2 ‖ a)` | next nonce |
| withdrawal `id` | `keccak256(3 ‖ id)` | `keccak256(recipient ‖ amount)` |
| withdrawal counter | `keccak256(4 ‖ 0)` | next id |

## 7. Input tape

For epoch `e` (the `e`-th batch in `BatchInbox`), the tape is `[Q] ++ queueRecords ++ sequencedRecords`, where `Q` is
the number of L1 queue records and every record is 8 words:
`kind, from, to, amount, nonce, v, r, s`. The inbox builds and hashes this tape itself, so `Q` cannot be forged.

| Kind | Allowed from | Effect |
|---|---|---|
| 1 deposit | queue | `balance[to] += amount` |
| 2 forced transfer | queue | transfer from the L1 sender, no signature or nonce |
| 3 forced withdrawal | queue | withdrawal from the L1 sender to L1 address `to` |
| 4 transfer | sequencer | signed transfer |
| 5 withdrawal | sequencer | signed withdrawal |

Any other kind, or a kind outside its allowed section, is skipped: a sequencer cannot mint by posting a deposit
record, and the queue cannot carry signed transactions.

Signed records must satisfy `ecrecover(digest, v, r, s) = from ≠ 0` and `nonce = nonce[from]`; then the nonce is
incremented even if the balance turns out to be insufficient (like a reverted Ethereum transaction). The digest is
`H(H(H(H(H(domain, kind), from), to), amount), nonce)` with `H(a, b) = keccak256(a ‖ b)` and
`domain = keccak256(keccak256("MiniRollup.L2Transaction.v1") ‖ chainId)`. The raw digest is signed (no EIP-191 prefix,
see the README's scope notes). The domain binds no contract address and records carry no deadline, so deployments that
share an L2 chain id share signatures and a signed record stays valid until its nonce is used (a documented deviation;
see the README's scope notes). Recipient words are not checked to be addresses: a signed record whose `to` has high
bits set is executed (and the sequencer API refuses to accept one).

## 8. The program

[`crates/stf/src/program.rs`](../crates/stf/src/program.rs) assembles the STF into 327 instructions (chain id 901,
code root `0xdf5f370f…087fed`; `rollup-cli program --disassemble` prints the listing). The worst batch the inbox
accepts (32 forced withdrawals + 64 signed withdrawals) takes 11,832 steps, under the 65,536-step padded trace. The
program is total: property tests run it on arbitrary tapes (including garbage headers) and require it to halt without
erroring and to agree with the native Rust STF on the post-state root.
