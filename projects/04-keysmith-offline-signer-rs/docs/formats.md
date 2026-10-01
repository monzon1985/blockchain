# Air-gap file formats

Everything that crosses the air gap is a small JSON document. Integers are written as **decimal
strings**; on input, decimal strings, `0x`-hex strings and JSON numbers up to `2^64 - 1` are
accepted (larger bare numbers are rejected rather than rounded through a float). Byte strings are
`0x`-hex. Unknown keys are errors everywhere, so a misspelled field never vanishes silently.

## `keysmith/unsigned-tx@1` (online -> offline)

Produced by `keysmith-relay prepare` (or by hand), consumed by `keysmith sign`.

```json
{
  "format": "keysmith/unsigned-tx@1",
  "from": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "tx": {
    "type": "eip7702",
    "chainId": "31337",
    "nonce": "4",
    "gasLimit": "150000",
    "maxFeePerGas": "2000000000",
    "maxPriorityFeePerGas": "1000000000",
    "to": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "value": "0",
    "input": "0x",
    "accessList": [],
    "authorizationList": []
  },
  "selfAuthorizations": [
    { "chainId": "31337", "address": "0x5FbDB2315678afecb367f032d93F642f64180aa3" }
  ],
  "note": "delegate my EOA to the batch executor"
}
```

| Field | Rule |
|---|---|
| `from` | optional; when present the signing key must have this address |
| `tx.type` | `legacy`, `eip2930`, `eip1559` or `eip7702` |
| `tx.chainId` | required except for pre-EIP-155 legacy (omit it, and the policy must allow it) |
| `tx.gasPrice` | legacy / `eip2930` only |
| `tx.maxFeePerGas`, `tx.maxPriorityFeePerGas` | `eip1559` / `eip7702` only |
| `tx.to` | **required**; `null` explicitly requests a contract creation (not allowed for `eip7702`) |
| `tx.accessList` | not allowed for legacy |
| `tx.authorizationList` | `eip7702` only; already-signed tuples from other authorities (sponsored flow) |
| `selfAuthorizations` | `eip7702` only; delegations the signing key authorizes for itself. Their nonces are never supplied: the signer assigns `tx.nonce + 1`, `tx.nonce + 2`, ... in list order (after any tuples of the same key already in `tx.authorizationList`), because the sender's nonce is bumped before the list is processed and the authority's nonce again after every tuple that applies. Only the last delegation stays in force, and the review says so |
| `note` | optional free text from the envelope's author. **Untrusted**: the review prints it escaped and labelled as such, never as a description of what is signed |

The signer rebuilds the transaction from these fields, appends the self-authorizations, checks
consensus rules (intrinsic gas including the EIP-7623 floor, tip <= fee cap, initcode size,
non-empty authorization list for type 4, nonce < 2^64 - 1) and refuses on any violation. It
**warns** when the gas limit exceeds the EIP-7825 cap (2^24), and it checks every EIP-7702 tuple
for the cases a node would silently skip while still charging 25,000 gas, refusing on each:

| Code | Refused when |
|---|---|
| `authorization-wrong-chain` | the tuple's `chainId` is neither 0 nor the transaction's chain id |
| `authorization-nonce-max` | the tuple's nonce is `2^64 - 1` |
| `authorization-invalid-signature` | no authority can be recovered (bad parity, high `s`) |
| `authorization-nonce-mismatch` | a tuple signed by the sending key does not carry the sender's nonce at that point (`tx.nonce + 1`, plus one per earlier tuple of the sender) |
| `authorization-stale-nonce` | an authority appears again without the next nonce, so at most one of its tuples can apply |

`authorization-any-chain` (chain id 0) and `authorization-duplicate-authority` (only the last
delegation remains) are warnings. Then the policy is applied, the review is printed to stderr, the
operator confirms, and only then is the transaction signed.

## `keysmith/signed-tx@1` (offline -> online)

```json
{
  "format": "keysmith/signed-tx@1",
  "type": "eip1559",
  "from": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "hash": "0x...",
  "raw": "0x02f8...",
  "note": "carried over from the unsigned envelope"
}
```

`keysmith-relay broadcast` trusts none of the convenience fields: it strictly decodes `raw`,
recomputes `type`, `hash` and the signer, compares them with the envelope, checks the node's
`eth_chainId`, and requires `eth_sendRawTransaction` to return the same hash.

## Policy file (offline only)

```json
{
  "allowedChainIds": [1, 8453],
  "allowedRecipients": ["0x70997970C51812dc3A010C7d01b50e0d17dc79C8"],
  "maxValueWei": "1000000000000000000",
  "maxFeePerGasWei": "200000000000",
  "maxTotalCostWei": "1100000000000000000",
  "allowContractCreation": false,
  "allowedDelegates": ["0x5FbDB2315678afecb367f032d93F642f64180aa3"],
  "allowAnyChainAuthorizations": false,
  "allowUnprotectedLegacy": false,
  "allowedVerifyingContracts": ["0x5FbDB2315678afecb367f032d93F642f64180aa3"],
  "allowedSpenders": ["0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"],
  "maxPermitValue": "1000000000"
}
```

Every list and limit is optional (absent means unrestricted); every boolean permission defaults
to **deny**. Unknown keys are errors.

**Which policy applies.** `keysmith sign`, `sign-auth`, `sign-typed-data` and `permit` take
`--policy FILE`. Without it they apply the built-in default, the empty policy `{}`, so the
deny-by-default booleans always hold: contract creations, pre-EIP-155 legacy transactions and
chainId-0 delegations are refused unless a policy file allows them. `--no-policy` is the explicit
escape hatch (only the consensus checks remain). The review always prints which policy is in force.

| Rule | `sign` | `sign-auth` | `sign-typed-data`, `permit` |
|---|---|---|---|
| `allowedChainIds` | the transaction and every authorization in it, including sponsored tuples signed by other keys | the tuple | the domain's `chainId`; a domain without one is refused |
| `allowedRecipients`, `maxValueWei`, `maxFeePerGasWei`, `maxTotalCostWei`, `allowContractCreation`, `allowUnprotectedLegacy` | yes | - | - |
| `allowedDelegates`, `allowAnyChainAuthorizations` | every authorization in the transaction | the tuple | - |
| `allowedVerifyingContracts` | - | - | the domain's `verifyingContract`; a domain without one is refused |
| `allowedSpenders` | - | - | a top-level `spender` member of the message (ERC-2612, Permit2, DAI-style permits) |
| `maxPermitValue` | - | - | `value` of a message whose primary type is `Permit` |

`keysmith sign-message` (EIP-191) has no policy: a `personal_sign` message has no chain, contract
or amount to constrain. Its review shows the exact bytes and the digest.

Any violation makes the command exit with code 3 without producing output.

## Confirmation

Every signing command prints its review to stderr, then asks `Sign this? Type "yes" to confirm`
on the terminal. Anything but `yes` / `y` refuses (exit code 3) and nothing is signed. When stdin
is not a terminal keysmith cannot ask, so it exits with code 1 unless `--yes` (`-y`) was passed;
the review is printed either way.

## Exit codes

| Code | `keysmith` | `keysmith-relay` |
|---|---|---|
| 0 | success | success |
| 1 | error (bad input, wrong password, confirmation needed but stdin is not a terminal, ...) | error (bad input, node or transport failure) |
| 2 | invalid command line (clap) | invalid command line (clap) |
| 3 | **refused**: invalid transaction, policy violation or not confirmed by the operator; nothing signed | **refused**: envelope fails verification or targets another chain, nothing sent |
| 4 | - | mined but reverted (`broadcast --wait`) |
