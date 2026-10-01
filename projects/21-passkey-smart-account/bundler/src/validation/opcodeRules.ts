// SPDX-License-Identifier: MIT
import type { Address } from 'viem'

/** One step of a geth-style struct log (`debug_traceCall` with the default tracer). */
export interface StructLog {
  readonly pc: number
  readonly op: string
  readonly gas: number
  readonly gasCost: number
  readonly depth: number
  readonly stack?: readonly string[]
}

/** The ERC-4337 entity whose code a validation frame belongs to. */
export type Entity = 'factory' | 'account' | 'paymaster'

export interface RuleContext {
  readonly entryPoint: Address
  /** SenderCreator of the EntryPoint: frames below it run factory (or 7702 init) code. */
  readonly senderCreator: Address
  readonly sender: Address
  readonly paymaster?: Address | undefined
}

export interface Violation {
  /** ERC-7562 rule id, e.g. `OP-011`. */
  readonly rule: string
  readonly entity: Entity
  readonly opcode: string
  readonly pc: number
  readonly detail: string
}

export interface RuleReport {
  readonly violations: readonly Violation[]
  /** Addresses called from validation frames, for the OP-041 "target has code" check done by the caller. */
  readonly callTargets: ReadonlyMap<string, Entity>
}

/** OP-011: opcodes whose result an attacker or block builder can change between simulation and inclusion. */
export const BANNED_OPCODES: ReadonlySet<string> = new Set([
  'GASPRICE',
  'GASLIMIT',
  'DIFFICULTY',
  'PREVRANDAO',
  'TIMESTAMP',
  'BASEFEE',
  'BLOCKHASH',
  'NUMBER',
  'SELFBALANCE',
  'BALANCE',
  'ORIGIN',
  'CREATE',
  'COINBASE',
  'SELFDESTRUCT',
  'BLOBHASH',
  'BLOBBASEFEE',
  'INVALID',
])

const CALL_OPCODES: ReadonlySet<string> = new Set(['CALL', 'CALLCODE', 'DELEGATECALL', 'STATICCALL'])

/** Precompiles known on an Osaka chain: 0x01-0x11 plus EIP-7951 P256VERIFY at 0x100. */
export function isKnownPrecompile(addr: bigint): boolean {
  return (addr >= 1n && addr <= 0x11n) || addr === 0x100n
}

function isPrecompileRange(addr: bigint): boolean {
  return addr >= 1n && addr <= 0x1ffn
}

function stackItem(log: StructLog, fromTop: number): bigint | undefined {
  const stack = log.stack
  if (stack === undefined || stack.length <= fromTop) return undefined
  const raw = stack[stack.length - 1 - fromTop]
  return raw === undefined ? undefined : BigInt(raw)
}

function same(a: bigint | undefined, b: string | undefined): boolean {
  return a !== undefined && b !== undefined && a === BigInt(b)
}

interface Frame {
  readonly address: bigint | undefined
  readonly entity: Entity | undefined
}

/**
 * Applies the ERC-7562 opcode rules to the struct log of a validation simulation (`simulateValidation` executed at
 * the EntryPoint address). Frames are attributed to entities by the address the EntryPoint (depth 1) called.
 *
 * Enforced: OP-011 (banned opcodes), OP-012 (GAS only right before a *CALL), OP-031 (CREATE2 only once, only in the
 * factory frame), OP-061 (value only to the EntryPoint), OP-062 (only known precompiles). OP-041 is completed by the
 * caller with `callTargets`. Calls into the EntryPoint (OP-052/053/054) need the callee's selector and caller, which
 * struct logs without memory do not carry: {@link checkEntryPointAccess} checks them on the call tree instead.
 */
export function checkOpcodeRules(logs: readonly StructLog[], ctx: RuleContext): RuleReport {
  const violations: Violation[] = []
  const callTargets = new Map<string, Entity>()
  const frames: Frame[] = [{ address: BigInt(ctx.entryPoint), entity: undefined }]
  let pendingCallee: { address: bigint | undefined; entity: Entity | undefined } | undefined
  let create2Count = 0
  const entryPoint = BigInt(ctx.entryPoint)

  for (let i = 0; i < logs.length; i++) {
    const log = logs[i]
    if (log === undefined) continue

    // Maintain the frame stack from depth transitions.
    while (frames.length > log.depth) frames.pop()
    if (frames.length < log.depth) {
      frames.push(pendingCallee ?? { address: undefined, entity: frames[frames.length - 1]?.entity })
    }
    pendingCallee = undefined
    const frame = frames[frames.length - 1]
    const entity = frame?.entity

    if (CALL_OPCODES.has(log.op) || log.op === 'CREATE' || log.op === 'CREATE2') {
      const target = CALL_OPCODES.has(log.op) ? stackItem(log, 1) : undefined
      let calleeEntity = entity
      if (log.depth === 1 && target !== undefined) {
        if (same(target, ctx.senderCreator)) calleeEntity = 'factory'
        else if (same(target, ctx.sender)) calleeEntity = 'account'
        else if (same(target, ctx.paymaster)) calleeEntity = 'paymaster'
        else calleeEntity = undefined
      }
      pendingCallee = { address: target, entity: calleeEntity }
    }

    if (entity === undefined) continue

    const violation = (rule: string, detail: string): void => {
      violations.push({ rule, entity, opcode: log.op, pc: log.pc, detail })
    }

    if (BANNED_OPCODES.has(log.op)) violation('OP-011', `${log.op} is banned during validation`)

    if (log.op === 'GAS') {
      const next = logs[i + 1]
      if (next?.depth !== log.depth || !CALL_OPCODES.has(next.op)) {
        violation('OP-012', 'GAS must be immediately followed by a CALL-family opcode')
      }
    }

    if (log.op === 'CREATE2') {
      create2Count++
      if (entity !== 'factory' || create2Count > 1) violation('OP-031', 'CREATE2 is allowed once, by the factory')
    }

    if (CALL_OPCODES.has(log.op)) {
      const target = stackItem(log, 1)
      if (target === undefined) continue
      const value = log.op === 'CALL' || log.op === 'CALLCODE' ? (stackItem(log, 2) ?? 0n) : 0n
      // Calls into the EntryPoint are judged by checkEntryPointAccess (OP-052/053/054), value included.
      if (target === entryPoint) continue
      if (value !== 0n) violation('OP-061', 'value may only be sent to the EntryPoint')
      if (isPrecompileRange(target)) {
        if (!isKnownPrecompile(target)) violation('OP-062', `unknown precompile 0x${target.toString(16)}`)
        continue
      }
      callTargets.set(`0x${target.toString(16).padStart(40, '0')}`, entity)
    }
  }
  return { violations, callTargets }
}

/** A `callTracer` frame (geth format), as returned by `debug_traceCall`. */
export interface TraceFrame {
  readonly type: string
  readonly from: string
  readonly to?: string
  readonly input: string
  readonly calls?: readonly TraceFrame[]
}

export interface EntryPointAccessContext extends RuleContext {
  /** The factory named in `initCode` (not the EIP-7702 marker), allowed to `depositTo(sender)`. */
  readonly factory?: Address | undefined
}

/** `depositTo(address)`. */
export const DEPOSIT_TO_SELECTOR = '0xb760faf9'

/**
 * ERC-7562 EntryPoint access rules on the call tree of `simulateValidation`. During validation an entity may reach the
 * EntryPoint only by calling `depositTo(sender)` from the sender or the factory (OP-052), or by calling its fallback
 * with empty calldata from the sender, e.g. to pay the prefund (OP-053). Any other access is an OP-054 violation:
 * other functions (`withdrawTo`, `addStake`, `incrementNonce`, ...), static or delegate calls, a deposit for someone
 * else, or any call from the paymaster.
 */
export function checkEntryPointAccess(root: TraceFrame, ctx: EntryPointAccessContext): Violation[] {
  const lower = (a: string | undefined): string => (a ?? '').toLowerCase()
  const entryPoint = lower(ctx.entryPoint)
  const sender = lower(ctx.sender)
  const factory = ctx.factory === undefined ? undefined : lower(ctx.factory)
  const violations: Violation[] = []

  const allowed = (frame: TraceFrame): boolean => {
    if (frame.type !== 'CALL') return false
    const from = lower(frame.from)
    const input = lower(frame.input)
    if (input === '0x' || input === '') return from === sender
    if (!input.startsWith(DEPOSIT_TO_SELECTOR) || input.length !== 2 + 8 + 64) return false
    const beneficiary = `0x${input.slice(-40)}`
    return beneficiary === sender && (from === sender || (factory !== undefined && from === factory))
  }

  const visit = (frame: TraceFrame, entity: Entity | undefined): void => {
    for (const child of frame.calls ?? []) {
      let childEntity = entity
      if (entity === undefined) {
        const to = lower(child.to)
        if (to === lower(ctx.senderCreator)) childEntity = 'factory'
        else if (to === sender) childEntity = 'account'
        else if (ctx.paymaster !== undefined && to === lower(ctx.paymaster)) childEntity = 'paymaster'
      }
      if (childEntity !== undefined && lower(child.to) === entryPoint && !allowed(child)) {
        const what = lower(child.input) === '0x' || child.input === '' ? 'empty calldata' : lower(child.input).slice(0, 10)
        violations.push({
          rule: 'OP-054',
          entity: childEntity,
          opcode: child.type,
          pc: 0,
          detail: `${child.type} into the EntryPoint (${what}) from ${child.from}; only depositTo(sender) or the fallback from the sender are allowed`,
        })
      }
      visit(child, childEntity)
    }
  }
  visit(root, undefined)
  return violations
}
