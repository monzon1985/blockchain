// SPDX-License-Identifier: MIT
import {
  getUserOperationHash,
  toPackedUserOperation,
  type PackedUserOperation,
  type UserOperation,
} from 'viem/account-abstraction'
import { isAddress, isHex, type Address, type Hex, type SignedAuthorization } from 'viem'

import { RpcError, RpcErrorCode } from './errors.ts'

/** EntryPoint v0.9 `initCode` marker for EIP-7702 senders, padded to 20 bytes. */
export const EIP7702_MARKER: Address = '0x7702000000000000000000000000000000000000'

export type UserOp = UserOperation<'0.9'>

type Json = Record<string, unknown>

function field(obj: Json, key: string): unknown {
  return obj[key]
}

function hexField(obj: Json, key: string, required: boolean): Hex | undefined {
  const value = field(obj, key)
  if (value === undefined || value === null) {
    if (required) throw new RpcError(RpcErrorCode.InvalidParams, `userOperation.${key} is required`)
    return undefined
  }
  if (typeof value !== 'string' || !isHex(value)) {
    throw new RpcError(RpcErrorCode.InvalidParams, `userOperation.${key} must be a 0x-prefixed hex string`)
  }
  return value
}

function quantity(obj: Json, key: string, required: boolean): bigint | undefined {
  const value = hexField(obj, key, required)
  return value === undefined ? undefined : BigInt(value)
}

function address(obj: Json, key: string, required: boolean): Address | undefined {
  const value = hexField(obj, key, required)
  if (value === undefined) return undefined
  if (!isAddress(value, { strict: false }) && !(key === 'factory' && isEip7702Factory(value))) {
    throw new RpcError(RpcErrorCode.InvalidParams, `userOperation.${key} must be an address`)
  }
  return value
}

export function isEip7702Factory(factory: string | undefined): boolean {
  if (factory === undefined) return false
  const f = factory.toLowerCase()
  return f === '0x7702' || f === EIP7702_MARKER
}

/**
 * Parses an ERC-7769 RPC user operation (hex quantities) into viem's bigint form. With `forEstimation`, gas limits
 * and the signature may be omitted.
 */
export function parseRpcUserOperation(raw: unknown, forEstimation = false): UserOp {
  if (typeof raw !== 'object' || raw === null) {
    throw new RpcError(RpcErrorCode.InvalidParams, 'userOperation must be an object')
  }
  const obj = raw as Json
  const strictGas = !forEstimation
  const factory = address(obj, 'factory', false)
  const op: UserOp = {
    sender: address(obj, 'sender', true) as Address,
    nonce: quantity(obj, 'nonce', true) as bigint,
    callData: hexField(obj, 'callData', true) as Hex,
    callGasLimit: quantity(obj, 'callGasLimit', strictGas) ?? 0n,
    verificationGasLimit: quantity(obj, 'verificationGasLimit', strictGas) ?? 0n,
    preVerificationGas: quantity(obj, 'preVerificationGas', strictGas) ?? 0n,
    maxFeePerGas: quantity(obj, 'maxFeePerGas', strictGas) ?? 0n,
    maxPriorityFeePerGas: quantity(obj, 'maxPriorityFeePerGas', strictGas) ?? 0n,
    signature: hexField(obj, 'signature', strictGas) ?? '0x',
  }
  if (factory !== undefined) {
    op.factory = (isEip7702Factory(factory) ? EIP7702_MARKER : factory)
    op.factoryData = hexField(obj, 'factoryData', false) ?? '0x'
  }
  const paymaster = address(obj, 'paymaster', false)
  if (paymaster !== undefined) {
    op.paymaster = paymaster
    op.paymasterData = hexField(obj, 'paymasterData', false) ?? '0x'
    op.paymasterVerificationGasLimit = quantity(obj, 'paymasterVerificationGasLimit', strictGas) ?? 0n
    op.paymasterPostOpGasLimit = quantity(obj, 'paymasterPostOpGasLimit', strictGas) ?? 0n
    const pmSig = hexField(obj, 'paymasterSignature', false)
    if (pmSig !== undefined && pmSig !== '0x') op.paymasterSignature = pmSig
  }
  const auth = field(obj, 'eip7702Auth')
  if (auth !== undefined && auth !== null) {
    if (typeof auth !== 'object') throw new RpcError(RpcErrorCode.InvalidParams, 'eip7702Auth must be an object')
    const a = auth as Json
    const authorization: SignedAuthorization = {
      address: address(a, 'address', true) as Address,
      chainId: Number(quantity(a, 'chainId', true)),
      nonce: Number(quantity(a, 'nonce', true)),
      r: hexField(a, 'r', true) as Hex,
      s: hexField(a, 's', true) as Hex,
      yParity: Number(quantity(a, 'yParity', true)),
    }
    op.authorization = authorization
  }
  return op
}

/** Packs for the EntryPoint (`handleOps`, simulations). The 7702 marker is always the padded 20-byte form. */
export function packUserOperation(op: UserOp): PackedUserOperation {
  return toPackedUserOperation(op)
}

/** EntryPoint v0.9 EIP-712 user operation hash. For 7702 ops `delegate` is the sender's (future) delegate. */
export function userOperationHash(op: UserOp, entryPoint: Address, chainId: number, delegate?: Address): Hex {
  const withDelegate: UserOp =
    op.factory !== undefined && isEip7702Factory(op.factory) && op.authorization === undefined && delegate !== undefined
      ? { ...op, authorization: { address: delegate, chainId, nonce: 0, r: '0x0', s: '0x0', yParity: 0 } }
      : op
  return getUserOperationHash({ chainId, entryPointAddress: entryPoint, entryPointVersion: '0.9', userOperation: withDelegate })
}

/** Serializes a user operation back to the RPC (hex) form, e.g. for `eth_getUserOperationByHash`. */
export function toRpcUserOperation(op: UserOp): Record<string, unknown> {
  const hex = (v: bigint): Hex => `0x${v.toString(16)}`
  const out: Record<string, unknown> = {
    sender: op.sender,
    nonce: hex(op.nonce),
    callData: op.callData,
    callGasLimit: hex(op.callGasLimit),
    verificationGasLimit: hex(op.verificationGasLimit),
    preVerificationGas: hex(op.preVerificationGas),
    maxFeePerGas: hex(op.maxFeePerGas),
    maxPriorityFeePerGas: hex(op.maxPriorityFeePerGas),
    signature: op.signature,
  }
  if (op.factory !== undefined) {
    out['factory'] = op.factory
    out['factoryData'] = op.factoryData ?? '0x'
  }
  if (op.paymaster !== undefined) {
    out['paymaster'] = op.paymaster
    out['paymasterData'] = op.paymasterData ?? '0x'
    out['paymasterVerificationGasLimit'] = hex(op.paymasterVerificationGasLimit ?? 0n)
    out['paymasterPostOpGasLimit'] = hex(op.paymasterPostOpGasLimit ?? 0n)
    if (op.paymasterSignature !== undefined) out['paymasterSignature'] = op.paymasterSignature
  }
  if (op.authorization !== undefined) {
    const a = op.authorization
    out['eip7702Auth'] = {
      address: a.address,
      chainId: hex(BigInt(a.chainId)),
      nonce: hex(BigInt(a.nonce)),
      r: a.r,
      s: a.s,
      yParity: hex(BigInt(a.yParity ?? 0)),
    }
  }
  return out
}
