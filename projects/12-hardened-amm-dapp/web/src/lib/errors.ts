// SPDX-License-Identifier: MIT
// Decodes the protocol's custom errors (pair, router, library, factory, Solady ERC-20, SafeERC20, OZ guards) from
// any viem error or raw revert data, and turns them into messages a trader can act on.
import {
  BaseError,
  ChainMismatchError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  decodeErrorResult,
  type Abi,
  type Hex,
} from 'viem'

import { ammFactoryAbi, ammPairAbi, ammRouterAbi } from '@/generated'

import { formatAmount } from './format'

type AbiError = Extract<Abi[number], { type: 'error' }>

/** Every custom error any AMM contract can revert with, deduplicated by signature. */
export const ammErrorsAbi: readonly AbiError[] = (() => {
  const seen = new Map<string, AbiError>()
  // The pair ABI also carries the Solady ERC-20 errors, which the demo tokens share.
  for (const abi of [ammRouterAbi, ammPairAbi, ammFactoryAbi] as readonly Abi[]) {
    for (const item of abi) {
      if (item.type !== 'error') continue
      const signature = `${item.name}(${item.inputs.map((input) => input.type).join(',')})`
      if (!seen.has(signature)) seen.set(signature, item)
    }
  }
  return [...seen.values()]
})()

export interface DecodedError {
  /** Custom error name (e.g. "InsufficientOutputAmount"), or a short category for non-revert failures. */
  name: string
  args: readonly unknown[]
  /** Human-readable explanation. */
  message: string
}

/** Optional token context so amounts in messages can be shown in whole units. */
export interface ErrorContext {
  tokenIn?: { symbol: string; decimals: number }
  tokenOut?: { symbol: string; decimals: number }
}

function amount(value: unknown, token?: { symbol: string; decimals: number }): string {
  if (typeof value !== 'bigint') return String(value)
  return token ? `${formatAmount(value, token.decimals)} ${token.symbol}` : value.toString()
}

/** Shown when the wallet is on another chain than the deployment; the write is refused before signing. */
export const WRONG_NETWORK_MESSAGE =
  'Your wallet is on a different network than this deployment. Switch it to Anvil and try again; nothing was sent.'

/** Maps a custom error to a message; unknown errors fall back to their signature. */
export function describeError(name: string, args: readonly unknown[], ctx: ErrorContext = {}): string {
  switch (name) {
    case 'InsufficientOutputAmount':
      return args.length === 2
        ? `Price moved beyond your slippage tolerance: the trade would return ${amount(args[0], ctx.tokenOut)} but your minimum is ${amount(args[1], ctx.tokenOut)}.`
        : 'The trade output would be zero.'
    case 'ExcessiveInputAmount':
      return `Price moved beyond your slippage tolerance: the trade would cost ${amount(args[0], ctx.tokenIn)} but your maximum is ${amount(args[1], ctx.tokenIn)}.`
    case 'InsufficientAAmount':
    case 'InsufficientBAmount':
      return `The pool ratio moved beyond your slippage tolerance (${amount(args[0])} < minimum ${amount(args[1])}).`
    case 'Expired':
      return 'The transaction deadline passed before it was mined. Submit it again.'
    case 'K':
      return 'The pool rejected the trade: the constant-product invariant would decrease (fee-on-transfer or rebasing token?).'
    case 'InsufficientLiquidity':
      return 'Not enough liquidity in the pool for this trade.'
    case 'InsufficientInputAmount':
      return 'The input amount is zero or too small.'
    case 'InsufficientAmount':
      return 'The amount must be greater than zero.'
    case 'InsufficientLiquidityMinted':
      return 'This deposit is too small to mint any LP tokens.'
    case 'InsufficientLiquidityBurned':
      return 'This withdrawal is too small to return both tokens.'
    case 'PairNotFound':
      return 'There is no pool for this token pair.'
    case 'InvalidPath':
      return 'The swap route is invalid.'
    case 'InvalidRecipient':
    case 'InvalidTo':
      return 'The recipient address is not allowed.'
    case 'PermitFailed':
      return 'The LP permit signature was rejected and no allowance is in place.'
    case 'InvalidPermit':
      return 'The permit signature is invalid.'
    case 'PermitExpired':
      return 'The permit signature has expired.'
    case 'InsufficientAllowance':
      return 'The router is not approved to spend this token.'
    case 'InsufficientBalance':
      return 'Your balance is too low for this transaction.'
    case 'SafeERC20FailedOperation':
      return 'A token transfer failed.'
    case 'ReentrancyGuardReentrantCall':
      return 'The pool is locked by a transaction in progress (reentrancy guard).'
    case 'Overflow':
      return 'Pool reserves would exceed the 112-bit limit.'
    case 'IdenticalAddresses':
      return 'Both sides of the pair are the same token.'
    case 'ZeroAddress':
      return 'A token address is zero.'
    case 'PairExists':
      return 'This pool already exists.'
    case 'TokenHasNoCode':
      return 'One of the tokens is not a deployed contract.'
    case 'OwnableUnauthorizedAccount':
    case 'OwnableInvalidOwner':
      return 'Only the factory owner can do this.'
    case 'AllowanceOverflow':
    case 'AllowanceUnderflow':
      return 'The allowance change is out of range.'
    case 'TotalSupplyOverflow':
      return 'The LP token supply would overflow.'
    case 'Permit2AllowanceIsFixedAtInfinity':
      return 'The Permit2 allowance cannot be changed.'
    case 'Panic':
      return args[0] === 0x11n
        ? "The amount is too large: the contracts' 256-bit arithmetic would overflow."
        : `The contract panicked (code ${String(args[0])}).`
    case 'CallbackTargetNotContract':
    case 'InvalidCallbackReturn':
      return 'The flash-swap receiver did not accept the callback.'
    default:
      return `${name}(${args.map((arg) => String(arg)).join(', ')})`
  }
}

/** Decodes raw revert data against the protocol's error ABI. */
export function decodeRevertData(data: Hex, ctx: ErrorContext = {}): DecodedError | null {
  try {
    const decoded = decodeErrorResult({ abi: ammErrorsAbi, data })
    const args = decoded.args ?? []
    return { name: decoded.errorName, args, message: describeError(decoded.errorName, args, ctx) }
  } catch {
    return null
  }
}

/** Extracts the most specific explanation from anything viem, wagmi or a wallet can throw. */
export function decodeError(error: unknown, ctx: ErrorContext = {}): DecodedError {
  // viem's ChainMismatchError (a write pinned to the deployment chain) or wagmi's ConnectorChainMismatchError.
  if (
    (error instanceof BaseError && error.walk((e) => e instanceof ChainMismatchError)) ||
    (error instanceof Error && error.name === 'ConnectorChainMismatchError')
  ) {
    return { name: 'WrongNetwork', args: [], message: WRONG_NETWORK_MESSAGE }
  }
  if (error instanceof BaseError) {
    const rejected = error.walk((e) => e instanceof UserRejectedRequestError)
    if (rejected) return { name: 'UserRejected', args: [], message: 'You rejected the request in your wallet.' }

    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError)
    if (reverted instanceof ContractFunctionRevertedError) {
      if (reverted.data?.errorName) {
        const args = reverted.data.args ?? []
        return { name: reverted.data.errorName, args, message: describeError(reverted.data.errorName, args, ctx) }
      }
      if (reverted.raw) {
        const decoded = decodeRevertData(reverted.raw, ctx)
        if (decoded) return decoded
      }
      if (reverted.reason) return { name: 'Revert', args: [], message: reverted.reason }
    }
    return { name: error.name, args: [], message: error.shortMessage }
  }
  return { name: 'Error', args: [], message: error instanceof Error ? error.message : String(error) }
}
