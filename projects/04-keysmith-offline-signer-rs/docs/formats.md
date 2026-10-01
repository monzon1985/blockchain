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
| `selfAuthorizations` | `eip7702` only; delegations the signing key authorizes for itself. Their nonce is never supplied: it is always `tx.nonce + 1`, because the sender's nonce is bumped before the authorization list is processed |

The signer rebuilds the transaction from these fields, appends the self-authorizations, checks
consensus rules (intrinsic gas including the EIP-7623 floor, EIP-7825 cap warning, tip <= fee cap,
initcode size, non-empty authorization list for type 4, nonce < 2^64 - 1) and the policy, and only
then signs.

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
  "allowUnprotectedLegacy": false
}
```

Every list and limit is optional (absent means unrestricted); every boolean permission defaults
to **deny**. `allowedChainIds` also applies to the chain id of every EIP-7702 authorization in the
transaction, including sponsored ones signed by other keys. Any violation makes `keysmith sign`
and `keysmith sign-auth` exit with code 3 without producing output.

## Exit codes

| Code | `keysmith` | `keysmith-relay` |
|---|---|---|
| 0 | success | success |
| 1 | error (bad input, wrong password, ...) | error (bad input, node or transport failure) |
| 2 | invalid command line (clap) | invalid command line (clap) |
| 3 | **refused**: invalid transaction or policy violation, nothing signed | **refused**: envelope fails verification or targets another chain, nothing sent |
| 4 | - | mined but reverted (`broadcast --wait`) |
