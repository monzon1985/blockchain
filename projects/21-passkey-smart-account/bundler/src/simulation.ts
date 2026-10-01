// SPDX-License-Identifier: MIT
import {
  concat,
  decodeErrorResult,
  decodeFunctionResult,
  encodeFunctionData,
  parseAbi,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'
import { entryPoint09Abi, type PackedUserOperation } from 'viem/account-abstraction'

import { RpcError, RpcErrorCode } from './errors.ts'
import type { StructLog } from './validation/opcodeRules.ts'

/** ABI of the two EntryPointSimulations (v0.9) entry points bundler-lite calls through a code override. */
export const simulationsAbi = parseAbi([
  'struct PackedUserOperation { address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits; uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature; }',
  'struct ReturnInfo { uint256 preOpGas; uint256 prefund; uint256 accountValidationData; uint256 paymasterValidationData; bytes paymasterContext; }',
  'struct StakeInfo { uint256 stake; uint256 unstakeDelaySec; }',
  'struct AggregatorStakeInfo { address aggregator; StakeInfo stakeInfo; }',
  'struct ValidationResult { ReturnInfo returnInfo; StakeInfo senderInfo; StakeInfo factoryInfo; StakeInfo paymasterInfo; AggregatorStakeInfo aggregatorInfo; }',
  'struct ExecutionResult { uint256 preOpGas; uint256 paid; uint256 accountValidationData; uint256 paymasterValidationData; bool targetSuccess; bytes targetResult; }',
  'function simulateValidation(PackedUserOperation userOp) returns (ValidationResult)',
  'function simulateHandleOp(PackedUserOperation op, address target, bytes targetCallData) returns (ExecutionResult)',
])

export interface ValidationResult {
  readonly preOpGas: bigint
  readonly prefund: bigint
  readonly accountValidationData: bigint
  readonly paymasterValidationData: bigint
  readonly paymasterStake: bigint
  readonly paymasterUnstakeDelay: bigint
}

export interface CallFrame {
  readonly type: string
  readonly from: string
  readonly to?: string
  readonly input: Hex
  readonly output?: Hex
  readonly gasUsed: Hex
  readonly error?: string
  readonly calls?: readonly CallFrame[]
}

export type StateOverride = Record<string, { code?: Hex; balance?: Hex }>

/** Extracts revert data from a viem/JSON-RPC error chain. */
export function revertData(error: unknown): Hex | undefined {
  let current: unknown = error
  for (let depth = 0; depth < 8 && current !== undefined && current !== null; depth++) {
    if (typeof current === 'object') {
      const data = (current as { data?: unknown }).data
      if (typeof data === 'string' && data.startsWith('0x')) return data as Hex
      if (typeof data === 'object' && data !== null) {
        const nested = (data as { data?: unknown }).data
        if (typeof nested === 'string' && nested.startsWith('0x')) return nested as Hex
      }
      current = (current as { cause?: unknown }).cause
    } else break
  }
  return undefined
}

/** Maps an EntryPoint `FailedOp`/`FailedOpWithRevert` revert to the matching ERC-7769 error. */
export function entryPointRevertToRpcError(data: Hex | undefined, fallbackMessage: string): RpcError {
  if (data === undefined || data === '0x') {
    return new RpcError(RpcErrorCode.RejectedByEntryPointOrAccount, fallbackMessage)
  }
  try {
    const decoded = decodeErrorResult({ abi: entryPoint09Abi, data })
    if (decoded.errorName === 'FailedOp' || decoded.errorName === 'FailedOpWithRevert') {
      const reason = decoded.args[1]
      const inner = decoded.errorName === 'FailedOpWithRevert' ? (decoded.args[2]) : undefined
      const code = reason.startsWith('AA24') || reason.startsWith('AA34')
        ? RpcErrorCode.InvalidSignature
        : reason.startsWith('AA22') || reason.startsWith('AA32') || reason.startsWith('AA27') || reason.startsWith('AA37')
          ? RpcErrorCode.OutOfTimeRange
          : reason.startsWith('AA3')
            ? RpcErrorCode.RejectedByPaymaster
            : RpcErrorCode.RejectedByEntryPointOrAccount
      return new RpcError(code, reason, inner === undefined ? undefined : { revertData: inner })
    }
    return new RpcError(RpcErrorCode.RejectedByEntryPointOrAccount, decoded.errorName, { revertData: data })
  } catch {
    return new RpcError(RpcErrorCode.RejectedByEntryPointOrAccount, fallbackMessage, { revertData: data })
  }
}

/** Runs EntryPointSimulations logic at the EntryPoint address through `eth_call` / `debug_traceCall` overrides. */
export class Simulator {
  readonly client: PublicClient
  readonly entryPoint: Address
  readonly simulationsCode: Hex

  constructor(client: PublicClient, entryPoint: Address, simulationsCode: Hex) {
    this.client = client
    this.entryPoint = entryPoint
    this.simulationsCode = simulationsCode
  }

  /** Code override for the EntryPoint, plus the sender's 7702 designator when its authorization is not on chain yet. */
  overrides(sender: Address, pendingDelegate: Address | undefined, extra: StateOverride = {}): StateOverride {
    const out: StateOverride = { ...extra, [this.entryPoint]: { code: this.simulationsCode } }
    if (pendingDelegate !== undefined) out[sender] = { ...(out[sender] ?? {}), code: concat(['0xef0100', pendingDelegate]) }
    return out
  }

  private async call(data: Hex, overrides: StateOverride): Promise<Hex> {
    try {
      const result: Hex = await this.client.request({
        method: 'eth_call',
        params: [{ to: this.entryPoint, data, gas: '0x1c9c380' }, 'latest', overrides],
      } as never)
      return result
    } catch (error) {
      throw entryPointRevertToRpcError(revertData(error), 'validation simulation reverted')
    }
  }

  async simulateValidation(op: PackedUserOperation, overrides: StateOverride): Promise<ValidationResult> {
    const data = encodeFunctionData({ abi: simulationsAbi, functionName: 'simulateValidation', args: [op] })
    const result = decodeFunctionResult({
      abi: simulationsAbi,
      functionName: 'simulateValidation',
      data: await this.call(data, overrides),
    })
    return {
      preOpGas: result.returnInfo.preOpGas,
      prefund: result.returnInfo.prefund,
      accountValidationData: result.returnInfo.accountValidationData,
      paymasterValidationData: result.returnInfo.paymasterValidationData,
      paymasterStake: result.paymasterInfo.stake,
      paymasterUnstakeDelay: result.paymasterInfo.unstakeDelaySec,
    }
  }

  /** Struct-log trace of `simulateValidation`, for the opcode rules. */
  async traceValidation(op: PackedUserOperation, overrides: StateOverride): Promise<StructLog[]> {
    const data = encodeFunctionData({ abi: simulationsAbi, functionName: 'simulateValidation', args: [op] })
    const trace: { failed: boolean; structLogs: StructLog[] } = await this.client.request({
      method: 'debug_traceCall',
      params: [
        { to: this.entryPoint, data, gas: '0x1c9c380' },
        'latest',
        { disableStorage: true, enableMemory: false, enableReturnData: false, stateOverrides: overrides },
      ],
    } as never)
    return trace.structLogs
  }

  /** Call-tree trace of `simulateValidation`, for the EntryPoint access rules (OP-052/053/054). */
  async traceValidationCalls(op: PackedUserOperation, overrides: StateOverride): Promise<CallFrame> {
    const data = encodeFunctionData({ abi: simulationsAbi, functionName: 'simulateValidation', args: [op] })
    const tree: CallFrame = await this.client.request({
      method: 'debug_traceCall',
      params: [{ to: this.entryPoint, data, gas: '0x1c9c380' }, 'latest', { tracer: 'callTracer', stateOverrides: overrides }],
    } as never)
    return tree
  }

  /** Call-tree trace of `simulateHandleOp`, for gas estimation. */
  async traceHandleOp(op: PackedUserOperation, overrides: StateOverride): Promise<CallFrame> {
    const data = encodeFunctionData({
      abi: simulationsAbi,
      functionName: 'simulateHandleOp',
      args: [op, '0x0000000000000000000000000000000000000000', '0x'],
    })
    const tree: CallFrame = await this.client.request({
      method: 'debug_traceCall',
      params: [{ to: this.entryPoint, data, gas: '0x1c9c380' }, 'latest', { tracer: 'callTracer', stateOverrides: overrides }],
    } as never)
    return tree
  }

  decodeExecutionResult(output: Hex): { preOpGas: bigint; paid: bigint } {
    const result = decodeFunctionResult({ abi: simulationsAbi, functionName: 'simulateHandleOp', data: output })
    return { preOpGas: result.preOpGas, paid: result.paid }
  }
}
