// SPDX-License-Identifier: MIT
import {
  decodeEventLog,
  encodeFunctionData,
  getAddress,
  hexToBytes,
  isAddressEqual,
  numberToHex,
  toFunctionSelector,
  type Address,
  type Hex,
  type Log,
  type PublicClient,
  type WalletClient,
} from 'viem'
import { entryPoint09Abi } from 'viem/account-abstraction'
import { recoverAuthorizationAddress } from 'viem/utils'

import { RpcError, RpcErrorCode } from './errors.ts'
import { Simulator, entryPointRevertToRpcError, revertData, type CallFrame, type StateOverride } from './simulation.ts'
import {
  isEip7702Factory,
  packUserOperation,
  parseRpcUserOperation,
  toRpcUserOperation,
  userOperationHash,
  type UserOp,
} from './userop.ts'
import { checkEntryPointAccess, checkOpcodeRules, type Violation } from './validation/opcodeRules.ts'

export interface BundlerConfig {
  readonly publicClient: PublicClient
  readonly walletClient: WalletClient
  /** Unlocked (or local) account that signs `handleOps` transactions. */
  readonly bundlerAccount: Address
  readonly entryPoint: Address
  /** Runtime code of EntryPointSimulations v0.9 (never deployed; used as an `eth_call` code override). */
  readonly simulationsCode: Hex
  readonly beneficiary?: Address
  /** Reject EIP-7702 authorizations with chain id 0 (default true; see the H03 hazard). */
  readonly rejectCrossChainAuthorizations?: boolean
  /** Minimum paymaster stake when it reads its own storage (ERC-7562 STO-031). Default 0.1 ether equivalent wei. */
  readonly minPaymasterStake?: bigint
  readonly minUnstakeDelay?: bigint
}

export interface GasEstimate {
  readonly preVerificationGas: bigint
  readonly verificationGasLimit: bigint
  readonly callGasLimit: bigint
  readonly paymasterVerificationGasLimit?: bigint
  readonly paymasterPostOpGasLimit?: bigint
}

interface StoredOp {
  readonly op: UserOp
  readonly hash: Hex
  readonly transactionHash: Hex
  readonly blockNumber: Hex
  readonly blockHash: Hex
  readonly receipt: Record<string, unknown>
}

const SELECTOR_VALIDATE_PAYMASTER = toFunctionSelector(
  'validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)',
)
const SELECTOR_POST_OP = toFunctionSelector('postOp(uint8,bytes,uint256,uint256)')
const SELECTOR_INNER_HANDLE_OP = toFunctionSelector(
  'innerHandleOp(bytes,((address,uint256,uint256,uint256,uint256,uint256,uint256,address,uint256,uint256),bytes32,uint256,uint256,uint256),bytes)',
)

/** Default postOp gas used while estimating when the client leaves it empty. */
const DEFAULT_ESTIMATION_POST_OP_GAS = 150_000n
const PER_AUTHORIZATION_GAS = 25_000n
const TX_BASE_GAS = 21_000n
const ENTRYPOINT_PER_OP_OVERHEAD = 15_000n
const WORST_CASE_GAS_FIELD = 10_000_000n

/** Seconds of validity an operation must have left beyond the chain head, so it cannot expire before inclusion. */
export const VALIDITY_MARGIN_SECONDS = 30n
/** Same margin for block-number validity ranges (EntryPoint v0.9). */
export const VALIDITY_MARGIN_BLOCKS = 2n
const UINT48_MAX = (1n << 48n) - 1n
const VALIDITY_BLOCK_RANGE_FLAG = 0x800000000000n
const VALIDITY_BLOCK_RANGE_MASK = 0x7fffffffffffn

export interface ParsedValidationData {
  /** 0 = valid signature, 1 = signature failure, otherwise an aggregator address. */
  readonly aggregator: bigint
  readonly validAfter: bigint
  readonly validUntil: bigint
  /** Both bounds carry the block-range flag: they are block numbers, not timestamps. */
  readonly blockRange: boolean
}

/** Splits validation data exactly like EntryPoint v0.9 `_parseValidationData` / `_getValidationData`. */
export function parseValidationData(validationData: bigint): ParsedValidationData {
  const aggregator = validationData & ((1n << 160n) - 1n)
  let validUntil = (validationData >> 160n) & UINT48_MAX
  if (validUntil === 0n) validUntil = UINT48_MAX
  const validAfter = (validationData >> 208n) & UINT48_MAX
  if (validAfter >= VALIDITY_BLOCK_RANGE_FLAG && validUntil >= VALIDITY_BLOCK_RANGE_FLAG) {
    return {
      aggregator,
      validAfter: validAfter & VALIDITY_BLOCK_RANGE_MASK,
      validUntil: validUntil & VALIDITY_BLOCK_RANGE_MASK,
      blockRange: true,
    }
  }
  return { aggregator, validAfter, validUntil, blockRange: false }
}

/**
 * Rejects (-32503) validation data whose validity window does not contain the next block with some margin to spare.
 * The EntryPoint accepts an operation when `validAfter < now <= validUntil` (timestamps, or block numbers in block-range
 * mode); the next block comes after `head`, so an operation is not due if `validAfter` is beyond the head, and is
 * refused if it expires within {@link VALIDITY_MARGIN_SECONDS} (or {@link VALIDITY_MARGIN_BLOCKS}) of it.
 */
export function checkValidityWindow(
  validationData: bigint,
  head: { readonly timestamp: bigint; readonly number: bigint },
  who: 'account' | 'paymaster',
): void {
  if (validationData === 0n) return
  const { validAfter, validUntil, blockRange } = parseValidationData(validationData)
  const unit = blockRange ? 'block' : 'timestamp'
  const now = blockRange ? head.number : head.timestamp
  const margin = blockRange ? VALIDITY_MARGIN_BLOCKS : VALIDITY_MARGIN_SECONDS
  if (validAfter > now) {
    throw new RpcError(RpcErrorCode.OutOfTimeRange, `${who} validity starts after ${unit} ${validAfter} (head ${now}): not due`, {
      validAfter: numberToHex(validAfter),
      validUntil: numberToHex(validUntil),
    })
  }
  if (validUntil < now + margin) {
    throw new RpcError(RpcErrorCode.OutOfTimeRange, `${who} validity ends at ${unit} ${validUntil} (head ${now}): expired or expiring`, {
      validAfter: numberToHex(validAfter),
      validUntil: numberToHex(validUntil),
    })
  }
}

function max(a: bigint, b: bigint): bigint {
  return a > b ? a : b
}

function withMargin(used: bigint, percent: bigint, flat: bigint): bigint {
  return (used * (100n + percent)) / 100n + flat
}

function findFrames(root: CallFrame, predicate: (f: CallFrame) => boolean, out: CallFrame[] = []): CallFrame[] {
  if (predicate(root)) out.push(root)
  for (const child of root.calls ?? []) findFrames(child, predicate, out)
  return out
}

function lower(a: string | undefined): string {
  return (a ?? '').toLowerCase()
}

/** Same length as `data`, every byte non-zero: the most expensive calldata a signature of that length can be. */
function nonZeroLike(data: Hex): Hex {
  return `0x${'ff'.repeat(Math.max(0, (data.length - 2) / 2))}`
}

/** EIP-2028 calldata cost (16 gas per non-zero byte, 4 per zero byte). */
export function calldataGas(data: Hex): bigint {
  let gas = 0n
  for (const byte of hexToBytes(data)) gas += byte === 0 ? 4n : 16n
  return gas
}

/**
 * bundler-lite: a single-node ERC-4337 v0.9 bundler for local development. Every accepted user operation is
 * simulated (EntryPointSimulations through a code override), checked against the ERC-7562 opcode rules on a real
 * `debug_traceCall`, and then submitted in its own `handleOps` transaction (type 4 when it carries an EIP-7702
 * authorization).
 */
export class BundlerLite {
  readonly config: BundlerConfig
  readonly simulator: Simulator
  private readonly ops = new Map<string, StoredOp>()
  private queue: Promise<unknown> = Promise.resolve()
  private chainIdCache: number | undefined
  private senderCreatorCache: Address | undefined

  constructor(config: BundlerConfig) {
    this.config = config
    this.simulator = new Simulator(config.publicClient, config.entryPoint, config.simulationsCode)
  }

  async chainId(): Promise<number> {
    this.chainIdCache ??= await this.config.publicClient.getChainId()
    return this.chainIdCache
  }

  supportedEntryPoints(): Address[] {
    return [getAddress(this.config.entryPoint)]
  }

  private assertEntryPoint(ep: unknown): void {
    if (typeof ep !== 'string' || !isAddressEqual(ep as Address, this.config.entryPoint)) {
      throw new RpcError(RpcErrorCode.InvalidParams, `unsupported EntryPoint ${String(ep)}`)
    }
  }

  private async senderCreator(): Promise<Address> {
    this.senderCreatorCache ??= await this.config.publicClient.readContract({
      address: this.config.entryPoint,
      abi: entryPoint09Abi,
      functionName: 'senderCreator',
    })
    return this.senderCreatorCache
  }

  /**
   * EIP-7702 checks: the authorization must be signed by the sender, carry the current account nonce and a chain id
   * that is either this chain or (only if allowed) 0. Returns the delegate to simulate with.
   */
  private async checkAuthorization(op: UserOp): Promise<Address | undefined> {
    const auth = op.authorization
    if (auth === undefined) {
      if (op.factory !== undefined && isEip7702Factory(op.factory)) {
        const code = await this.config.publicClient.getCode({ address: op.sender })
        if (!code?.startsWith('0xef0100')) {
          throw new RpcError(RpcErrorCode.InvalidParams, 'EIP-7702 marker without eip7702Auth on an undelegated sender')
        }
      }
      return undefined
    }
    const chainId = await this.chainId()
    if (auth.chainId === 0 && (this.config.rejectCrossChainAuthorizations ?? true)) {
      throw new RpcError(RpcErrorCode.InvalidParams, 'eip7702Auth with chainId 0 is valid on every chain; refused')
    }
    if (auth.chainId !== 0 && auth.chainId !== chainId) {
      throw new RpcError(RpcErrorCode.InvalidParams, `eip7702Auth chainId ${auth.chainId} does not match ${chainId}`)
    }
    const authority = await recoverAuthorizationAddress({ authorization: auth })
    if (!isAddressEqual(authority, op.sender)) {
      throw new RpcError(RpcErrorCode.InvalidParams, `eip7702Auth is signed by ${authority}, not by the sender`)
    }
    const nonce = await this.config.publicClient.getTransactionCount({ address: op.sender, blockTag: 'pending' })
    if (nonce !== auth.nonce) {
      throw new RpcError(RpcErrorCode.InvalidParams, `eip7702Auth nonce ${auth.nonce} != sender nonce ${nonce}`)
    }
    return auth.address
  }

  /** Current delegate of a 7702 sender (used for hashing ops that carry the marker but no authorization). */
  private async currentDelegate(sender: Address): Promise<Address | undefined> {
    const code = await this.config.publicClient.getCode({ address: sender })
    return code?.startsWith('0xef0100') === true ? getAddress(`0x${code.slice(8, 48)}`) : undefined
  }

  async hashOf(op: UserOp): Promise<Hex> {
    const delegate = op.authorization?.address ?? (await this.currentDelegate(op.sender))
    return userOperationHash(op, this.config.entryPoint, await this.chainId(), delegate)
  }

  requiredPreVerificationGas(op: UserOp): bigint {
    const beneficiary = this.config.beneficiary ?? this.config.bundlerAccount
    const data = encodeFunctionData({
      abi: entryPoint09Abi,
      functionName: 'handleOps',
      args: [[packUserOperation(op)], beneficiary],
    })
    return (
      TX_BASE_GAS +
      calldataGas(data) +
      (op.authorization === undefined ? 0n : PER_AUTHORIZATION_GAS) +
      ENTRYPOINT_PER_OP_OVERHEAD
    )
  }

  // -------------------------------------------------------------------------------------------------------- estimate

  async estimateUserOperationGas(rawOp: unknown, entryPoint: unknown, extraOverrides?: unknown): Promise<GasEstimate> {
    this.assertEntryPoint(entryPoint)
    const op = parseRpcUserOperation(rawOp, true)
    const delegate = await this.checkAuthorization(op)
    const hasPaymaster = op.paymaster !== undefined
    // Generous limits and zero fees: the simulation measures consumption without any prefund requirement.
    const probe: UserOp = {
      ...op,
      verificationGasLimit: 5_000_000n,
      callGasLimit: 10_000_000n,
      preVerificationGas: 0n,
      maxFeePerGas: 0n,
      maxPriorityFeePerGas: 0n,
      signature: op.signature === '0x' ? '0x00' : op.signature,
      ...(hasPaymaster
        ? {
            paymasterVerificationGasLimit: 2_000_000n,
            paymasterPostOpGasLimit:
              op.paymasterPostOpGasLimit !== undefined && op.paymasterPostOpGasLimit > 0n
                ? op.paymasterPostOpGasLimit
                : DEFAULT_ESTIMATION_POST_OP_GAS,
          }
        : {}),
    }
    const overrides = this.simulator.overrides(op.sender, delegate, (extraOverrides ?? {}) as StateOverride)
    let trace: CallFrame
    try {
      trace = await this.simulator.traceHandleOp(packUserOperation(probe), overrides)
    } catch (error) {
      throw entryPointRevertToRpcError(revertData(error), 'estimation simulation failed')
    }
    if (trace.error !== undefined) {
      throw entryPointRevertToRpcError(trace.output, `estimation simulation reverted: ${trace.error}`)
    }
    const { preOpGas } = this.simulator.decodeExecutionResult(trace.output ?? '0x')
    const ep = lower(this.config.entryPoint)
    const sender = lower(op.sender)
    const pm = lower(op.paymaster)

    const pmValidation = findFrames(trace, (f) => lower(f.to) === pm && f.input.startsWith(SELECTOR_VALIDATE_PAYMASTER))[0]
    const inner = findFrames(trace, (f) => lower(f.to) === ep && f.input.startsWith(SELECTOR_INNER_HANDLE_OP))[0]
    const execution =
      inner === undefined ? undefined : findFrames(inner, (f) => lower(f.from) === ep && lower(f.to) === sender)[0]
    const postOp =
      inner === undefined ? undefined : findFrames(inner, (f) => lower(f.to) === pm && f.input.startsWith(SELECTOR_POST_OP))[0]
    if (execution?.error !== undefined) {
      throw new RpcError(RpcErrorCode.ExecutionReverted, `execution reverted: ${execution.error}`, {
        revertData: execution.output,
      })
    }
    const pmUsed = pmValidation === undefined ? 0n : BigInt(pmValidation.gasUsed)
    // preOpGas covers the whole validation stage (account + factory + EntryPoint bookkeeping + paymaster).
    const accountSide = preOpGas > pmUsed ? preOpGas - pmUsed : preOpGas
    // Signatures are not final yet: price their bytes as non-zero, so any real signature of the same length fits.
    // Gas fields are priced at 10M (three non-zero bytes each), an upper bound for any realistic limit.
    const worstCase: UserOp = {
      ...op,
      verificationGasLimit: WORST_CASE_GAS_FIELD,
      callGasLimit: WORST_CASE_GAS_FIELD,
      preVerificationGas: WORST_CASE_GAS_FIELD,
      ...(hasPaymaster
        ? { paymasterVerificationGasLimit: WORST_CASE_GAS_FIELD, paymasterPostOpGasLimit: WORST_CASE_GAS_FIELD }
        : {}),
      signature: nonZeroLike(op.signature),
      ...(op.paymasterSignature === undefined ? {} : { paymasterSignature: nonZeroLike(op.paymasterSignature) }),
    }
    const estimate: GasEstimate = {
      preVerificationGas: this.requiredPreVerificationGas(worstCase),
      verificationGasLimit: withMargin(accountSide, 20n, 10_000n),
      callGasLimit: withMargin(execution === undefined ? 0n : BigInt(execution.gasUsed), 20n, 10_000n),
      ...(hasPaymaster
        ? {
            // A paymaster that checks its own signature short-circuits on the stub one, so the caller may pass a
            // floor (e.g. from its paymaster service); the estimate never goes below it.
            paymasterVerificationGasLimit: max(withMargin(pmUsed, 20n, 15_000n), op.paymasterVerificationGasLimit ?? 0n),
            paymasterPostOpGasLimit: postOp === undefined ? probe.paymasterPostOpGasLimit : withMargin(BigInt(postOp.gasUsed), 30n, 10_000n),
          }
        : {}),
    }
    return estimate
  }

  // ---------------------------------------------------------------------------------------------------------- send

  /** Full validation pipeline: authorization checks, simulateValidation, stake and opcode rules. */
  async validate(op: UserOp): Promise<{ hash: Hex; violations: readonly Violation[] }> {
    const delegate = await this.checkAuthorization(op)
    if (op.preVerificationGas < this.requiredPreVerificationGas(op)) {
      throw new RpcError(
        RpcErrorCode.InvalidParams,
        `preVerificationGas ${op.preVerificationGas} below required ${this.requiredPreVerificationGas(op)}`,
      )
    }
    const packed = packUserOperation(op)
    const overrides = this.simulator.overrides(op.sender, delegate)
    const result = await this.simulator.simulateValidation(packed, overrides)
    const head = await this.config.publicClient.getBlock({ blockTag: 'latest' })
    this.checkValidationData(result.accountValidationData, false, head)
    if (op.paymaster !== undefined) {
      this.checkValidationData(result.paymasterValidationData, true, head)
      // bundler-lite does not replay the ERC-7562 storage rules; it only accepts staked paymasters instead.
      const minStake = this.config.minPaymasterStake ?? 100_000_000_000_000_000n
      const minDelay = this.config.minUnstakeDelay ?? 86_400n
      if (result.paymasterStake < minStake || result.paymasterUnstakeDelay < minDelay) {
        throw new RpcError(RpcErrorCode.InsufficientStake, 'paymaster stake or unstake delay too low')
      }
    }

    const logs = await this.simulator.traceValidation(packed, overrides)
    const report = checkOpcodeRules(logs, {
      entryPoint: this.config.entryPoint,
      senderCreator: await this.senderCreator(),
      sender: op.sender,
      paymaster: op.paymaster,
    })
    const violations: Violation[] = [...report.violations]
    // OP-052/053/054: which EntryPoint functions an entity called, and from where, is read from the call tree.
    const calls = await this.simulator.traceValidationCalls(packed, overrides)
    violations.push(
      ...checkEntryPointAccess(calls, {
        entryPoint: this.config.entryPoint,
        senderCreator: await this.senderCreator(),
        sender: op.sender,
        paymaster: op.paymaster,
        factory: op.factory === undefined || isEip7702Factory(op.factory) ? undefined : op.factory,
      }),
    )
    // OP-041: validation may not call addresses without code (the sender itself is exempt).
    for (const [target, entity] of report.callTargets) {
      if (lower(target) === lower(op.sender)) continue
      const code = await this.config.publicClient.getCode({ address: target as Address })
      if (code === undefined || code === '0x') {
        violations.push({ rule: 'OP-041', entity, opcode: 'CALL', pc: 0, detail: `call to ${target}, which has no code` })
      }
    }
    return { hash: await this.hashOf(op), violations }
  }

  /** Signature result first (-32507, aggregators unsupported), then the validity window (-32503). */
  private checkValidationData(
    validationData: bigint,
    isPaymaster: boolean,
    head: { readonly timestamp: bigint; readonly number: bigint },
  ): void {
    const { aggregator } = parseValidationData(validationData)
    if (aggregator === 1n) {
      throw new RpcError(RpcErrorCode.InvalidSignature, isPaymaster ? 'paymaster signature invalid' : 'account signature invalid')
    }
    if (aggregator !== 0n) {
      throw new RpcError(-32506, 'signature aggregators are not supported')
    }
    checkValidityWindow(validationData, head, isPaymaster ? 'paymaster' : 'account')
  }

  async sendUserOperation(rawOp: unknown, entryPoint: unknown): Promise<Hex> {
    this.assertEntryPoint(entryPoint)
    const op = parseRpcUserOperation(rawOp)
    const { hash, violations } = await this.validate(op)
    if (violations.length > 0) {
      throw new RpcError(
        RpcErrorCode.BannedOpcode,
        `ERC-7562 violation: ${violations.map((v) => `${v.rule} ${v.entity} ${v.opcode}`).join(', ')}`,
        { violations },
      )
    }
    const run = this.queue.then(() => this.submit(op, hash))
    this.queue = run.catch(() => undefined)
    await run
    return hash
  }

  private async submit(op: UserOp, hash: Hex): Promise<void> {
    const { publicClient, walletClient, bundlerAccount, entryPoint } = this.config
    const beneficiary = this.config.beneficiary ?? bundlerAccount
    const args = [[packUserOperation(op)], beneficiary] as const
    // Last line of defence: run the exact transaction as a call first.
    try {
      await publicClient.simulateContract({
        address: entryPoint,
        abi: entryPoint09Abi,
        functionName: 'handleOps',
        args,
        account: bundlerAccount,
        ...(op.authorization === undefined ? {} : { authorizationList: [op.authorization] }),
      })
    } catch (error) {
      throw entryPointRevertToRpcError(revertData(error), 'handleOps simulation reverted')
    }
    const gas =
      op.verificationGasLimit +
      op.callGasLimit +
      (op.paymasterVerificationGasLimit ?? 0n) +
      (op.paymasterPostOpGasLimit ?? 0n) +
      op.preVerificationGas +
      100_000n
    const txHash = await walletClient.writeContract({
      address: entryPoint,
      abi: entryPoint09Abi,
      functionName: 'handleOps',
      args,
      account: bundlerAccount,
      chain: walletClient.chain,
      gas,
      ...(op.authorization === undefined ? {} : { authorizationList: [op.authorization] }),
    })
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash })
    if (receipt.status !== 'success') throw new RpcError(RpcErrorCode.Internal, `handleOps transaction ${txHash} reverted`)
    const rawReceipt = (await publicClient.request({
      method: 'eth_getTransactionReceipt',
      params: [txHash],
    })) as unknown as Record<string, unknown>
    this.ops.set(hash.toLowerCase(), {
      op,
      hash,
      transactionHash: txHash,
      blockHash: receipt.blockHash,
      blockNumber: numberToHex(receipt.blockNumber),
      receipt: this.buildReceipt(hash, receipt.logs, rawReceipt),
    })
  }

  private buildReceipt(hash: Hex, logs: readonly Log[], rawReceipt: Record<string, unknown>): Record<string, unknown> {
    const ep = lower(this.config.entryPoint)
    let start = 0
    let result: Record<string, unknown> | undefined
    let reason: Hex | undefined
    for (let i = 0; i < logs.length; i++) {
      const log = logs[i]
      if (log === undefined || lower(log.address) !== ep) continue
      let decoded: ReturnType<typeof decodeEventLog<typeof entryPoint09Abi>>
      try {
        decoded = decodeEventLog({ abi: entryPoint09Abi, data: log.data, topics: log.topics })
      } catch {
        continue
      }
      if (decoded.eventName === 'BeforeExecution') start = i + 1
      if (decoded.eventName === 'UserOperationRevertReason' && lower(decoded.args.userOpHash) === lower(hash)) {
        reason = decoded.args.revertReason
      }
      if (decoded.eventName === 'UserOperationEvent') {
        if (lower(decoded.args.userOpHash) === lower(hash)) {
          const rawLogs = (rawReceipt['logs'] as unknown[]).slice(start, i)
          result = {
            userOpHash: hash,
            entryPoint: getAddress(this.config.entryPoint),
            sender: decoded.args.sender,
            nonce: numberToHex(decoded.args.nonce),
            paymaster: decoded.args.paymaster,
            actualGasCost: numberToHex(decoded.args.actualGasCost),
            actualGasUsed: numberToHex(decoded.args.actualGasUsed),
            success: decoded.args.success,
            ...(reason === undefined ? {} : { reason }),
            logs: rawLogs,
            receipt: rawReceipt,
          }
        }
        start = i + 1
      }
    }
    if (result === undefined) throw new RpcError(RpcErrorCode.Internal, 'UserOperationEvent not found in receipt')
    return result
  }

  getUserOperationReceipt(hash: unknown): Record<string, unknown> | null {
    if (typeof hash !== 'string') throw new RpcError(RpcErrorCode.InvalidParams, 'hash must be a string')
    return this.ops.get(hash.toLowerCase())?.receipt ?? null
  }

  getUserOperationByHash(hash: unknown): Record<string, unknown> | null {
    if (typeof hash !== 'string') throw new RpcError(RpcErrorCode.InvalidParams, 'hash must be a string')
    const stored = this.ops.get(hash.toLowerCase())
    if (stored === undefined) return null
    return {
      userOperation: toRpcUserOperation(stored.op),
      entryPoint: getAddress(this.config.entryPoint),
      transactionHash: stored.transactionHash,
      blockHash: stored.blockHash,
      blockNumber: stored.blockNumber,
    }
  }
}
