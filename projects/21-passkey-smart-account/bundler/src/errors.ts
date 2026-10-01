// SPDX-License-Identifier: MIT

/** JSON-RPC error codes: the generic ones plus the ERC-7769 (ERC-4337 RPC) ones bundler-lite uses. */
export const RpcErrorCode = {
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  Internal: -32603,
  /** Rejected by the EntryPoint or the account during validation (includes factory failures). */
  RejectedByEntryPointOrAccount: -32500,
  /** Rejected by the paymaster's validatePaymasterUserOp. */
  RejectedByPaymaster: -32501,
  /** A validation frame violated an ERC-7562 opcode rule. */
  BannedOpcode: -32502,
  /** The validity time range is expired or not yet due. */
  OutOfTimeRange: -32503,
  /** Paymaster (or aggregator) stake too low for what it accessed. */
  InsufficientStake: -32505,
  /** The account (or paymaster) signature check failed. */
  InvalidSignature: -32507,
  /** Execution simulation reverted during gas estimation. */
  ExecutionReverted: -32521,
} as const

/** An error that is returned verbatim to the JSON-RPC client. */
export class RpcError extends Error {
  readonly code: number
  readonly data: unknown

  constructor(code: number, message: string, data?: unknown) {
    super(message)
    this.name = 'RpcError'
    this.code = code
    this.data = data
  }
}
