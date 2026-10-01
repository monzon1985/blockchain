# Wire format of the three schemes

All three schemes use the x402 v2 envelope unchanged (`PaymentRequired`, `PaymentPayload`, `SettlementResponse`, base64 JSON in the `PAYMENT-REQUIRED`, `PAYMENT-SIGNATURE` and `PAYMENT-RESPONSE` headers; facilitator `POST /verify` and `POST /settle` with `{x402Version, paymentPayload, paymentRequirements}`). Only `extra` and `payload` are scheme specific. Network is always `eip155:31337`, asset is always the deployment's TestUSD, amounts and timestamps are decimal strings.

## Resource hash

```
canonical    = METHOD + " " + origin + path + sortedQuery + "#sha256=" + hex(sha256(body))
resourceHash = keccak256(utf8(canonical))
```

The server puts `resourceHash` in `extra`; the agent recomputes it from the request it is about to send and refuses the challenge if they differ (`src/x402/resource.ts`, `src/policy/clientPolicy.ts`).

## `exact` (EOA, EIP-3009 `transferWithAuthorization`)

`extra`:

```json
{ "assetTransferMethod": "eip3009", "name": "TestUSD (local only)", "version": "1",
  "settlementLog": "0x…", "resourceHash": "0x…" }
```

`payload`:

```json
{ "signature": "0x…",
  "authorization": { "from": "0x…", "to": "<payTo>", "value": "<amount>",
                     "validAfter": "…", "validBefore": "…", "nonce": "0x…" },
  "resourceSalt": "0x…" }
```

`nonce = keccak256(abi.encode(keccak256("x402-local/exact/resource-binding/v1"), resourceHash, resourceSalt)) & ~(2^64-1)`.
The only field added to the standard x402 `exact` payload is `resourceSalt`, which opens the commitment. OpenZeppelin's `ERC20TransferAuthorization` reads the low 64 bits of the nonce as a sequence number, so they are zero; the upper 192 bits are a fresh pseudorandom key. Settlement: `SettlementLog.settleExact(auth, resourceHash, resourceSalt, signature)`.

## `budget-exec` (ERC-7579 smart account, session key)

`extra`:

```json
{ "budgetExecutor": "0x…", "resourceHash": "0x…" }
```

`payload`:

```json
{ "signature": "0x…",
  "intent": { "account": "0x…", "payee": "<payTo>", "amount": "<amount>", "resourceHash": "0x…",
              "nonce": "0x<32 random bytes>", "validAfter": "…", "validBefore": "…" } }
```

EIP-712 domain `{name: "BudgetExecutor", version: "1", chainId, verifyingContract: budgetExecutor}`, type
`PaymentIntent(address account,address payee,uint256 amount,bytes32 resourceHash,bytes32 nonce,uint256 validAfter,uint256 validBefore)`. Settlement: `BudgetExecutor.pay(intent, signature)`, which calls `AgentAccount.executeFromExecutor` in single-call mode.

## `escrow` (EOA, EIP-3009 `receiveWithAuthorization`)

`extra`:

```json
{ "assetTransferMethod": "eip3009-receive", "name": "TestUSD (local only)", "version": "1",
  "escrow": "0x…", "resourceHash": "0x…", "deliveryWindowSeconds": 600 }
```

`payload`:

```json
{ "signature": "0x…",
  "authorization": { "from": "0x…", "to": "<escrow>", "value": "<amount>",
                     "validAfter": "…", "validBefore": "…", "nonce": "0x…" },
  "escrow": { "payee": "<payTo>", "resourceHash": "0x…", "deliveryDeadline": "…", "salt": "0x…" } }
```

`nonce = keccak256(abi.encode(keccak256("x402-local/escrow/terms-binding/v1"), payee, resourceHash, deliveryDeadline, salt)) & ~(2^64-1)`.
Settlement opens the escrow (`PaymentEscrow.open`); the server answers `202` with `{escrowId, status, statusUrl, accessToken}` and later calls `deliver(escrowId, keccak256(canonicalJson(result)))`. The result is served at `GET statusUrl` only with `Authorization: Bearer <accessToken>`: escrow ids are public (`EscrowOpened` is an indexed event), the token is not. After `deliveryDeadline` without delivery, anyone may call `refund(escrowId)`.

## Retries and the claim window

A client may resend the same `PAYMENT-SIGNATURE` after a failure (network error, `5xx`, or a `402` with `facilitator_unavailable` or `settlement_unverified`). The server then calls `/settle` even if `/verify` reports `nonce_already_used` or a closed validity window: `/settle` is idempotent and answers from the chain when the payment already settled with the same terms. The server serves the call if the on-chain settlement is this payment's (receipt or escrow id derived from payer and nonce), is not consumed yet, and settled at most `settlementClaimWindowSeconds` (default 600) ago; an escrow is served while it is still `Open` and before its deadline. Later attempts get `payment_already_used` or `settlement_expired`. For an escrow, "served" means the `202` carrying the access token: once a job is accepted, a retry does not issue a new token (threat model, known limitation 12).

## Validation documents

`GET /validation/:requestHash` returns the canonical JSON work document `{service, resource, body, receiptId, output}`, whose keccak256 is the on-chain request hash. `resource` and `body` are exactly what the payment's resource hash commits to, so they may contain personal data. The server returns the document only to the validator named in the on-chain request, which sends an EIP-191 signature in `x-validator-signature` and its expiry (Unix seconds, at most 300 s ahead) in `x-validator-expires`. The signed text is (`src/validator/access.ts`):

```text
x402-local validation document
requestHash: <request hash, lowercase hex>
expires: <unix seconds>
```

## `SettlementResponse.extensions`

The facilitator adds `{ "receiptId": "0x…" }` (exact, budget-exec) or `{ "escrowId": "0x…" }` (escrow). Consumers must not trust it: `confirmSettlement` (`src/chain/settlement.ts`) re-derives the outcome from the transaction receipt.

## Error reasons

Standard x402 reasons are used where they exist (`invalid_exact_evm_payload_signature`, `invalid_exact_evm_payload_authorization_value_mismatch`, `invalid_exact_evm_payload_recipient_mismatch`, `..._valid_after`, `..._valid_before`, `insufficient_funds`, `invalid_network`, `invalid_payload`, `invalid_payment_requirements`, `unsupported_scheme`). Additions: `invalid_resource_binding`, `nonce_already_used`, `nonce_already_used_mismatch` (a settlement with this payer and nonce exists on-chain with other terms), `simulation_failed:<CustomError>`, `settlement_failed:<reason>`, `budget_not_installed`, `budget_session_expired`, `budget_per_call_cap_exceeded`, `budget_payee_not_allowed`, `budget_exhausted`, `invalid_budget_exec_*`, `invalid_escrow_*`, and, from the resource server, `facilitator_unavailable`, `settlement_unverified`, `settlement_expired` and `payment_already_used`.
