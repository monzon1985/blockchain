// SPDX-License-Identifier: MIT
// Path-sensitive abstract interpretation of EVM bytecode, tuned to find "sweeper" behaviour in EIP-7702
// delegation targets. Dependency-free so the wallet can run it in the browser before signing an authorization.
import { disassemble, hexToBytes, opcodeInfo, type Instruction } from './disassembler.ts'

/** Abstract stack value. */
export type Val =
  | { readonly k: 'const'; readonly v: bigint }
  | { readonly k: 'selfbalance' }
  | { readonly k: 'callvalue' }
  | { readonly k: 'caller' }
  | { readonly k: 'address' }
  | { readonly k: 'calldata0' }
  | { readonly k: 'calldatasize' }
  | { readonly k: 'selector' }
  | { readonly k: 'eq'; readonly a: Val; readonly b: Val }
  | { readonly k: 'iszero'; readonly a: Val }
  | { readonly k: 'or'; readonly a: Val; readonly b: Val }
  | { readonly k: 'and'; readonly a: Val; readonly b: Val }
  | { readonly k: 'unknown' }

const UNKNOWN: Val = { k: 'unknown' }
const U256 = (1n << 256n) - 1n
const ADDRESS_MASK = (1n << 160n) - 1n

/**
 * Who the caller is known to be on a path, from `CALLER == x` checks that path passed:
 * - `none`: no caller check.
 * - `self`: the EOA itself (`CALLER == ADDRESS`), i.e. the owner's own key.
 * - `trusted`: a caller the wallet trusts, such as the EntryPoint (which only calls after `validateUserOp`).
 * - `foreign`: a hardcoded third-party address. Whoever holds that key controls every delegating EOA.
 * - `dynamic`: an address loaded from storage or calldata. Who set it cannot be told from the code.
 */
export type CallerGuard = 'none' | 'self' | 'trusted' | 'foreign' | 'dynamic'

export type FindingKind =
  | 'VALUE_FORWARD_TO_HARDCODED_ADDRESS'
  | 'VALUE_FORWARD_TO_DYNAMIC_ADDRESS'
  | 'VALUE_TRANSFER_TO_HARDCODED_ADDRESS'
  | 'VALUE_TRANSFER_TO_CALLER'
  | 'BALANCE_DRAIN_TO_HARDCODED_ADDRESS'
  | 'BALANCE_DRAIN_TO_DYNAMIC_ADDRESS'
  | 'BALANCE_DRAIN_TO_CALLER'
  | 'ARBITRARY_CALL'
  | 'TOKEN_TRANSFER_TO_HARDCODED_ADDRESS'
  | 'TOKEN_TRANSFER_ANYONE_CAN_TRIGGER'
  | 'SELFDESTRUCT_TO_HARDCODED_ADDRESS'
  | 'SELFDESTRUCT_TO_DYNAMIC_ADDRESS'
  | 'DELEGATECALL_TO_HARDCODED_ADDRESS'
  | 'DELEGATECALL_TO_DYNAMIC_ADDRESS'
  | 'USER_OPERATIONS_UNVERIFIED'

export interface RawFinding {
  readonly kind: FindingKind
  readonly pc: number
  /** Hardcoded destination, or undefined when it is computed at run time (storage, calldata, return data). */
  readonly target: bigint | undefined
  /** Reached without matching any function selector: fallback or receive. */
  readonly fromFallback: boolean
  /** The caller check the path passed before reaching the finding. */
  readonly guard: CallerGuard
  /** Selector of the function the path entered, if any. */
  readonly selector: number | undefined
}

export interface AnalysisResult {
  readonly findings: readonly RawFinding[]
  readonly steps: number
  readonly paths: number
  /** True when the exploration budget ran out before every path was explored. */
  readonly truncated: boolean
}

interface PathState {
  pc: number
  stack: Val[]
  selector: number | undefined
  guard: CallerGuard
  /** Constants written to memory on this path (offsets are usually symbolic, so only values are kept). */
  memConsts: bigint[]
  visits: Map<number, number>
}

export interface AnalyzerBudget {
  readonly maxSteps?: number
  readonly maxPaths?: number
  readonly maxVisitsPerJumpdest?: number
}

export interface AnalyzerOptions extends AnalyzerBudget {
  /**
   * Callers a `CALLER == x` check may trust besides the EOA itself (lower-case 0x addresses), typically the
   * EntryPoint the wallet uses. The canonical EntryPoints (v0.6 to v0.9) are always trusted.
   */
  readonly trustedCallers?: readonly string[]
}

/** Canonical ERC-4337 EntryPoint deployments (v0.6, v0.7, v0.8, v0.9). */
export const CANONICAL_ENTRY_POINTS: readonly string[] = [
  '0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789',
  '0x0000000071727de22e5e9d8baf0edac6f37da032',
  '0x4337084d9e255ff0702461cf8895ce9e3b5ff108',
  '0x433709009b8330fda32311df1c2afa402ed8d009',
]

const TOKEN_SELECTORS = new Set<bigint>([
  0xa9059cbbn, // transfer(address,uint256)
  0x23b872ddn, // transferFrom(address,address,uint256)
  0x095ea7b3n, // approve(address,uint256)
  0x39509351n, // increaseAllowance(address,uint256)
])

/** `validateUserOp(PackedUserOperation,bytes32,uint256)`: the EntryPoint path is the owner's only if this verifies. */
export const VALIDATE_USER_OP_SELECTOR = 0x19822f7c

/** ecrecover (0x01) and the EIP-7951 P256VERIFY precompile (0x100). */
const SIGNATURE_PRECOMPILES = new Set<bigint>([0x01n, 0x100n])

/** Guard strength: lower is more restrictive. Two checks on one path both hold, so the stronger one wins. */
const GUARD_RANK: Record<CallerGuard, number> = { self: 0, trusted: 1, dynamic: 2, foreign: 3, none: 4 }

function isZero(v: Val): boolean {
  return v.k === 'const' && v.v === 0n
}

function mentionsCaller(v: Val): boolean {
  switch (v.k) {
    case 'caller':
      return true
    case 'eq':
    case 'or':
    case 'and':
      return mentionsCaller(v.a) || mentionsCaller(v.b)
    case 'iszero':
      return mentionsCaller(v.a)
    default:
      return false
  }
}

function isBooleanNode(v: Val): boolean {
  return v.k === 'eq' || v.k === 'iszero' || v.k === 'or' || v.k === 'and'
}

function selectorMatch(v: Val): number | undefined {
  if (v.k !== 'eq') return undefined
  if (v.a.k === 'selector' && v.b.k === 'const' && v.b.v <= 0xffffffffn) return Number(v.b.v)
  if (v.b.k === 'selector' && v.a.k === 'const' && v.a.v <= 0xffffffffn) return Number(v.a.v)
  return undefined
}

/**
 * What a branch condition says about the caller when it evaluates to `truth`: the caller equals one of the returned
 * values, or `undefined` when the branch carries no positive information about the caller.
 */
function callerAlternatives(cond: Val, truth: boolean): Val[] | undefined {
  switch (cond.k) {
    case 'eq': {
      if (!truth) return undefined
      if (cond.a.k === 'caller' && cond.b.k !== 'caller') return [cond.b]
      if (cond.b.k === 'caller' && cond.a.k !== 'caller') return [cond.a]
      return undefined
    }
    case 'iszero':
      return callerAlternatives(cond.a, !truth)
    case 'or': {
      const a = callerAlternatives(cond.a, truth)
      const b = callerAlternatives(cond.b, truth)
      // a || b true: the caller satisfies one of the disjuncts, so both must pin it down. False: both disjuncts false.
      if (truth) return a !== undefined && b !== undefined ? [...a, ...b] : undefined
      return a ?? b
    }
    case 'and': {
      const a = callerAlternatives(cond.a, truth)
      const b = callerAlternatives(cond.b, truth)
      // a && b true: both hold, either one pins the caller. False: one of them is false, so both must pin it down.
      if (truth) return a ?? b
      return a !== undefined && b !== undefined ? [...a, ...b] : undefined
    }
    default:
      return undefined
  }
}

/**
 * Folds two operands. Constants are evaluated; comparisons that involve the caller stay symbolic so that branch
 * conditions can be read back; masks that Solidity uses for addresses, selectors and booleans keep the value.
 */
function fold(name: string, a: Val, b: Val): Val {
  if (a.k === 'const' && b.k === 'const') {
    const x = a.v
    const y = b.v
    switch (name) {
      case 'ADD':
        return { k: 'const', v: (x + y) & U256 }
      case 'SUB':
        return { k: 'const', v: (x - y) & U256 }
      case 'MUL':
        return { k: 'const', v: (x * y) & U256 }
      case 'DIV':
        return { k: 'const', v: y === 0n ? 0n : x / y }
      case 'MOD':
        return { k: 'const', v: y === 0n ? 0n : x % y }
      case 'EXP':
        return y > 256n ? UNKNOWN : { k: 'const', v: x ** y & U256 }
      case 'SHL':
        return { k: 'const', v: x >= 256n ? 0n : (y << x) & U256 }
      case 'SHR':
        return { k: 'const', v: x >= 256n ? 0n : y >> x }
      case 'AND':
        return { k: 'const', v: x & y }
      case 'OR':
        return { k: 'const', v: x | y }
      case 'XOR':
        return { k: 'const', v: x ^ y }
      case 'LT':
        return { k: 'const', v: x < y ? 1n : 0n }
      case 'GT':
        return { k: 'const', v: x > y ? 1n : 0n }
      case 'EQ':
        return { k: 'const', v: x === y ? 1n : 0n }
      default:
        return UNKNOWN
    }
  }
  if (name === 'AND') {
    const [mask, other] = a.k === 'const' ? [a.v, b] : b.k === 'const' ? [b.v, a] : [undefined, a]
    if (mask !== undefined) {
      // Solidity masks addresses with 2^160-1 and selectors with 2^32-1; a boolean keeps its truth under any odd mask.
      if (mask === ADDRESS_MASK || mask === 0xffffffffn || mask === U256) return other
      if (isBooleanNode(other) && (mask & 1n) === 1n) return other
      return UNKNOWN
    }
    if (mentionsCaller(a) || mentionsCaller(b)) return { k: 'and', a, b }
    return UNKNOWN
  }
  if (name === 'OR' && (mentionsCaller(a) || mentionsCaller(b))) return { k: 'or', a, b }
  // `xor(x, y)` and `sub(x, y)` are non-zero exactly when x != y: the optimizer's form of `iszero(eq(x, y))`.
  if ((name === 'XOR' || name === 'SUB') && (a.k === 'caller' || b.k === 'caller')) {
    return { k: 'iszero', a: { k: 'eq', a, b } }
  }
  if (name === 'SHR' && a.k === 'const' && a.v === 224n && b.k === 'calldata0') return { k: 'selector' }
  if (name === 'DIV' && b.k === 'const' && b.v === 1n << 224n && a.k === 'calldata0') return { k: 'selector' }
  if (name === 'EQ') return { k: 'eq', a, b }
  return UNKNOWN
}

function stackKey(state: PathState): string {
  const top = state.stack.map((v) => (v.k === 'const' ? v.v.toString(16) : v.k))
  return `${state.pc}|${state.selector ?? '-'}|${state.guard}|${state.stack.length}|${top.join(',')}`
}

type TargetClass = 'self' | 'precompile' | 'hardcoded' | 'caller' | 'dynamic'

function classifyTarget(v: Val): TargetClass {
  if (v.k === 'address') return 'self'
  if (v.k === 'caller') return 'caller'
  if (v.k === 'const') return v.v > 0x1ffn && v.v <= ADDRESS_MASK ? 'hardcoded' : 'precompile'
  return 'dynamic'
}

/**
 * Explores every feasible path from pc 0 (depth-first, bounded) and reports how value, tokens and control can leave
 * the delegating EOA: transfers and calls to hardcoded or run-time targets, balance drains (including to whoever
 * calls), forwarding of incoming ETH, self-destructs and delegatecalls, each tagged with the caller check the path
 * passed. Findings behind a `self` or `trusted` guard are only reported when the destination is hardcoded.
 */
export function analyze(bytecodeHex: string, options: AnalyzerOptions = {}): AnalysisResult {
  const code = hexToBytes(bytecodeHex)
  const { instructions, jumpdests, byPc } = disassemble(code)
  const maxSteps = options.maxSteps ?? 400_000
  const maxPaths = options.maxPaths ?? 20_000
  const maxVisits = options.maxVisitsPerJumpdest ?? 3
  const trusted = new Set<bigint>([...CANONICAL_ENTRY_POINTS, ...(options.trustedCallers ?? [])].map((a) => BigInt(a)))

  /** Guard a path gets from knowing the caller is one of `alternatives`; `infeasible` if none can be a caller. */
  const guardFor = (alternatives: readonly Val[]): CallerGuard | 'infeasible' => {
    let weakest: CallerGuard | undefined
    for (const alt of alternatives) {
      let g: CallerGuard | undefined
      if (alt.k === 'address') g = 'self'
      else if (alt.k === 'const') {
        // Nobody calls from address 0 (it also stands for unset immutables in compiled artifacts).
        if ((alt.v & ADDRESS_MASK) === 0n) continue
        g = trusted.has(alt.v & ADDRESS_MASK) ? 'trusted' : 'foreign'
      } else g = 'dynamic'
      if (weakest === undefined || GUARD_RANK[g] > GUARD_RANK[weakest]) weakest = g
    }
    return weakest ?? 'infeasible'
  }

  const refine = (current: CallerGuard, cond: Val, truth: boolean): CallerGuard | 'infeasible' => {
    const alternatives = callerAlternatives(cond, truth)
    if (alternatives === undefined) return current
    const g = guardFor(alternatives)
    if (g === 'infeasible') return g
    return GUARD_RANK[g] < GUARD_RANK[current] ? g : current
  }

  const findings = new Map<string, RawFinding>()
  const seen = new Set<string>()
  const work: PathState[] = [{ pc: 0, stack: [], selector: undefined, guard: 'none', memConsts: [], visits: new Map() }]
  let steps = 0
  let paths = 0
  let truncated = false
  // Trusting the EntryPoint path is only sound if validateUserOp checks a signature. Track whether some path returns
  // from validateUserOp and whether any path in it reaches a signature primitive (ecrecover, P256VERIFY, or a call
  // to an external verifier such as an ERC-1271 signer).
  let validateReturns = false
  let validateVerifies = false
  let validatePc = 0

  const record = (kind: FindingKind, state: PathState, pc: number, target: bigint | undefined): void => {
    const finding: RawFinding = {
      kind,
      pc,
      target,
      fromFallback: state.selector === undefined,
      guard: state.guard,
      selector: state.selector,
    }
    findings.set(`${kind}|${pc}|${finding.fromFallback}|${finding.guard}`, finding)
  }

  while (work.length > 0) {
    if (steps >= maxSteps || paths >= maxPaths) {
      truncated = true
      break
    }
    const state = work.pop() as PathState
    paths++
    for (;;) {
      if (steps++ >= maxSteps) {
        truncated = true
        break
      }
      const index = byPc.get(state.pc)
      if (index === undefined) break
      const ins = instructions[index] as Instruction
      const info = opcodeInfo(ins.opcode)
      if (info === undefined) break // undefined opcode: execution halts
      const pop = (): Val => state.stack.pop() ?? UNKNOWN
      const next = (): void => {
        state.pc = ins.pc + 1 + ins.immediateSize
      }
      const ownerControlled = state.guard === 'self' || state.guard === 'trusted'

      const name = ins.name
      if (name === 'RETURN' && state.selector === VALIDATE_USER_OP_SELECTOR) {
        validateReturns = true
        validatePc = ins.pc
      }
      if (name === 'STOP' || name === 'RETURN' || name === 'REVERT' || name === 'INVALID') break

      if (name.startsWith('PUSH')) {
        state.stack.push({ k: 'const', v: ins.immediate ?? 0n })
        next()
        continue
      }
      if (name.startsWith('DUP')) {
        const n = Number(name.slice(3))
        state.stack.push(state.stack[state.stack.length - n] ?? UNKNOWN)
        next()
        continue
      }
      if (name.startsWith('SWAP')) {
        const n = Number(name.slice(4))
        const top = state.stack.length - 1
        const other = top - n
        if (other >= 0) {
          const t = state.stack[top] as Val
          state.stack[top] = state.stack[other] as Val
          state.stack[other] = t
        }
        next()
        continue
      }

      switch (name) {
        case 'JUMPDEST': {
          const count = (state.visits.get(ins.pc) ?? 0) + 1
          state.visits.set(ins.pc, count)
          if (count > maxVisits) break
          const key = stackKey(state)
          if (seen.has(key)) break
          seen.add(key)
          next()
          continue
        }
        case 'JUMP': {
          const dest = pop()
          if (dest.k !== 'const' || !jumpdests.has(Number(dest.v))) break
          state.pc = Number(dest.v)
          continue
        }
        case 'JUMPI': {
          const dest = pop()
          const cond = pop()
          const fallthrough = ins.pc + 1
          const canJump = dest.k === 'const' && jumpdests.has(Number(dest.v))
          const matched = selectorMatch(cond)
          const takeJump = cond.k !== 'const' || cond.v !== 0n
          const takeFall = cond.k !== 'const' || cond.v === 0n
          if (canJump && takeJump) {
            const guard = refine(state.guard, cond, true)
            if (guard !== 'infeasible') {
              work.push({
                pc: Number(dest.v),
                stack: [...state.stack],
                selector: matched ?? state.selector,
                guard,
                memConsts: [...state.memConsts],
                visits: new Map(state.visits),
              })
            }
          }
          if (!takeFall) break
          const guard = refine(state.guard, cond, false)
          if (guard === 'infeasible') break
          state.pc = fallthrough
          state.guard = guard
          continue
        }
        case 'ADDRESS':
          state.stack.push({ k: 'address' })
          next()
          continue
        case 'CALLER':
          state.stack.push({ k: 'caller' })
          next()
          continue
        case 'CALLVALUE':
          state.stack.push({ k: 'callvalue' })
          next()
          continue
        case 'CALLDATASIZE':
          state.stack.push({ k: 'calldatasize' })
          next()
          continue
        case 'SELFBALANCE':
          state.stack.push({ k: 'selfbalance' })
          next()
          continue
        case 'BALANCE': {
          const who = pop()
          state.stack.push(who.k === 'address' ? { k: 'selfbalance' } : UNKNOWN)
          next()
          continue
        }
        case 'CALLDATALOAD': {
          const off = pop()
          state.stack.push(isZero(off) ? { k: 'calldata0' } : UNKNOWN)
          next()
          continue
        }
        case 'ISZERO': {
          const a = pop()
          state.stack.push(a.k === 'const' ? { k: 'const', v: a.v === 0n ? 1n : 0n } : { k: 'iszero', a })
          next()
          continue
        }
        case 'NOT': {
          const a = pop()
          state.stack.push(a.k === 'const' ? { k: 'const', v: ~a.v & U256 } : UNKNOWN)
          next()
          continue
        }
        case 'MSTORE': {
          pop()
          const value = pop()
          if (value.k === 'const') state.memConsts.push(value.v)
          next()
          continue
        }
        case 'SELFDESTRUCT': {
          const beneficiary = pop()
          const t = classifyTarget(beneficiary)
          if (t === 'hardcoded') record('SELFDESTRUCT_TO_HARDCODED_ADDRESS', state, ins.pc, (beneficiary as { v: bigint }).v)
          else if ((t === 'dynamic' || t === 'caller') && !ownerControlled) {
            record('SELFDESTRUCT_TO_DYNAMIC_ADDRESS', state, ins.pc, undefined)
          }
          break
        }
        case 'CALL':
        case 'CALLCODE': {
          pop() // gas
          const target = pop()
          const value = pop()
          state.stack.length = Math.max(0, state.stack.length - 4)
          const t = classifyTarget(target)
          if (state.selector === VALIDATE_USER_OP_SELECTOR) {
            const isSignaturePrecompile = target.k === 'const' && SIGNATURE_PRECOMPILES.has(target.v)
            if (isSignaturePrecompile || t === 'hardcoded' || t === 'dynamic') validateVerifies = true
          }
          if (t === 'hardcoded') {
            const addr = (target as { v: bigint }).v
            // Destinations baked into the code are reported whatever the guard: a payout the owner cannot redirect.
            if (value.k === 'selfbalance') record('BALANCE_DRAIN_TO_HARDCODED_ADDRESS', state, ins.pc, addr)
            else if (value.k === 'callvalue') record('VALUE_FORWARD_TO_HARDCODED_ADDRESS', state, ins.pc, addr)
            else if (!isZero(value)) record('VALUE_TRANSFER_TO_HARDCODED_ADDRESS', state, ins.pc, addr)
            const hasTokenSelector = state.memConsts.some((m) => TOKEN_SELECTORS.has(m >> 224n))
            if (hasTokenSelector) {
              const hasOtherAddress = state.memConsts.some((m) => m > 0x1ffn && m <= ADDRESS_MASK && m !== addr)
              if (hasOtherAddress) record('TOKEN_TRANSFER_TO_HARDCODED_ADDRESS', state, ins.pc, addr)
              else if (!ownerControlled) record('TOKEN_TRANSFER_ANYONE_CAN_TRIGGER', state, ins.pc, addr)
            }
          } else if (!ownerControlled && t === 'caller') {
            // CALLVALUE back to CALLER only returns the caller's own payment; anything else pays whoever calls.
            if (value.k === 'selfbalance') record('BALANCE_DRAIN_TO_CALLER', state, ins.pc, undefined)
            else if (value.k !== 'callvalue' && !isZero(value)) record('VALUE_TRANSFER_TO_CALLER', state, ins.pc, undefined)
          } else if (!ownerControlled && t === 'dynamic') {
            if (value.k === 'selfbalance') record('BALANCE_DRAIN_TO_DYNAMIC_ADDRESS', state, ins.pc, undefined)
            else if (value.k === 'callvalue') record('VALUE_FORWARD_TO_DYNAMIC_ADDRESS', state, ins.pc, undefined)
            else record('ARBITRARY_CALL', state, ins.pc, undefined)
          }
          state.stack.push(UNKNOWN)
          next()
          continue
        }
        case 'STATICCALL': {
          pop() // gas
          const target = pop()
          state.stack.length = Math.max(0, state.stack.length - 4)
          if (state.selector === VALIDATE_USER_OP_SELECTOR) {
            const t = classifyTarget(target)
            const isSignaturePrecompile = target.k === 'const' && SIGNATURE_PRECOMPILES.has(target.v)
            if (isSignaturePrecompile || t === 'hardcoded' || t === 'dynamic') validateVerifies = true
          }
          state.stack.push(UNKNOWN)
          next()
          continue
        }
        case 'DELEGATECALL': {
          pop()
          const target = pop()
          state.stack.length = Math.max(0, state.stack.length - 4)
          const t = classifyTarget(target)
          if (t === 'hardcoded') record('DELEGATECALL_TO_HARDCODED_ADDRESS', state, ins.pc, (target as { v: bigint }).v)
          else if ((t === 'dynamic' || t === 'caller') && !ownerControlled) {
            record('DELEGATECALL_TO_DYNAMIC_ADDRESS', state, ins.pc, undefined)
          }
          state.stack.push(UNKNOWN)
          next()
          continue
        }
        default: {
          if (info.pops === 2 && info.pushes === 1) {
            const a = pop()
            const b = pop()
            state.stack.push(fold(name, a, b))
          } else {
            for (let i = 0; i < info.pops; i++) pop()
            for (let i = 0; i < info.pushes; i++) state.stack.push(UNKNOWN)
          }
          next()
          continue
        }
      }
      break
    }
  }
  if (validateReturns && !validateVerifies && !truncated) {
    findings.set('USER_OPERATIONS_UNVERIFIED', {
      kind: 'USER_OPERATIONS_UNVERIFIED',
      pc: validatePc,
      target: undefined,
      fromFallback: false,
      guard: 'trusted',
      selector: VALIDATE_USER_OP_SELECTOR,
    })
  }
  return { findings: [...findings.values()], steps, paths, truncated }
}
