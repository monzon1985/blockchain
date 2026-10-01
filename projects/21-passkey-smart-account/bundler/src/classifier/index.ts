// SPDX-License-Identifier: MIT
// Defensive EIP-7702 delegation-target classifier. It only reads bytecode; it never builds or deploys anything.
import { analyze, type AnalyzerBudget, type CallerGuard, type FindingKind, type RawFinding } from './analyzer.ts'

export { CANONICAL_ENTRY_POINTS, type CallerGuard } from './analyzer.ts'

export type Verdict = 'safe' | 'review' | 'malicious'

export interface Finding {
  readonly kind: FindingKind | 'NO_CODE' | 'NESTED_DELEGATION' | 'ANALYSIS_INCOMPLETE'
  readonly severity: 'critical' | 'warning'
  readonly pc: number
  /** Hardcoded destination (0x-prefixed, 20 bytes) when the finding has one. */
  readonly target?: string
  /** `fallback/receive`, or the 4-byte selector of the function the path entered. */
  readonly context: string
  /** The caller check the path passed before reaching the finding (see {@link CallerGuard}). */
  readonly guard: CallerGuard
  readonly description: string
}

export interface Classification {
  readonly verdict: Verdict
  readonly findings: readonly Finding[]
  readonly codeSize: number
  readonly steps: number
  readonly paths: number
}

export interface ClassifierOptions {
  readonly budget?: AnalyzerBudget
  /**
   * Callers a `CALLER == x` check may trust besides the EOA itself, typically the EntryPoint the wallet uses (the
   * canonical v0.6 to v0.9 EntryPoints are always trusted). Code reachable only by these callers is owner-controlled.
   */
  readonly trustedCallers?: readonly string[]
}

const DESCRIPTIONS: Record<FindingKind, string> = {
  VALUE_FORWARD_TO_HARDCODED_ADDRESS: 'forwards incoming ETH (CALLVALUE) to an address baked into the code',
  VALUE_FORWARD_TO_DYNAMIC_ADDRESS: 'forwards incoming ETH (CALLVALUE) to an address read at run time (storage, calldata)',
  VALUE_TRANSFER_TO_HARDCODED_ADDRESS: 'sends the account ETH to an address baked into the code',
  VALUE_TRANSFER_TO_CALLER: 'sends the account ETH, in an amount the caller influences, to whoever calls',
  BALANCE_DRAIN_TO_HARDCODED_ADDRESS: 'sends the whole account balance (SELFBALANCE) to an address baked into the code',
  BALANCE_DRAIN_TO_DYNAMIC_ADDRESS: 'sends the whole account balance (SELFBALANCE) to an address computed at run time',
  BALANCE_DRAIN_TO_CALLER: 'sends the whole account balance (SELFBALANCE) to whoever calls',
  ARBITRARY_CALL: 'makes the account call a target (and send a value) chosen at run time, e.g. an open executor',
  TOKEN_TRANSFER_TO_HARDCODED_ADDRESS: 'calls transfer/transferFrom/approve on a hardcoded token with a hardcoded counterparty',
  TOKEN_TRANSFER_ANYONE_CAN_TRIGGER: 'calls transfer/transferFrom/approve on a hardcoded token from a path anyone can trigger',
  SELFDESTRUCT_TO_HARDCODED_ADDRESS: 'SELFDESTRUCT with a hardcoded beneficiary (still moves the whole balance after Cancun)',
  SELFDESTRUCT_TO_DYNAMIC_ADDRESS: 'SELFDESTRUCT with a beneficiary chosen at run time (moves the whole balance)',
  DELEGATECALL_TO_HARDCODED_ADDRESS: 'DELEGATECALLs code at a hardcoded address that can be swapped for anything',
  DELEGATECALL_TO_DYNAMIC_ADDRESS: 'DELEGATECALLs code whose address is read at run time (storage, a beacon, calldata)',
  USER_OPERATIONS_UNVERIFIED:
    'validateUserOp returns without any signature check (no ecrecover, P256VERIFY or verifier call), so anyone can submit operations for the EOA',
}

/**
 * Findings that make a target malicious when their path is open (no caller check, or a check against a hardcoded
 * third party), wherever they are reached. The others (forwarding the caller's own payment, a delegatecall to fixed
 * logic such as a linked library) are critical only when every incoming transfer or unknown call triggers them, i.e.
 * from fallback/receive.
 */
const CRITICAL_WHEN_OPEN = new Set<FindingKind>([
  'VALUE_TRANSFER_TO_HARDCODED_ADDRESS',
  'VALUE_TRANSFER_TO_CALLER',
  'BALANCE_DRAIN_TO_HARDCODED_ADDRESS',
  'BALANCE_DRAIN_TO_DYNAMIC_ADDRESS',
  'BALANCE_DRAIN_TO_CALLER',
  'ARBITRARY_CALL',
  'TOKEN_TRANSFER_TO_HARDCODED_ADDRESS',
  'TOKEN_TRANSFER_ANYONE_CAN_TRIGGER',
  'SELFDESTRUCT_TO_HARDCODED_ADDRESS',
  'SELFDESTRUCT_TO_DYNAMIC_ADDRESS',
  'DELEGATECALL_TO_DYNAMIC_ADDRESS',
])

function hex20(value: bigint): string {
  return `0x${value.toString(16).padStart(40, '0')}`
}

function toFinding(raw: RawFinding): Finding {
  // An open path is one anyone can take (no caller check) or one a hardcoded third party controls. Behind the EOA's
  // own check or a trusted EntryPoint the owner decides, and behind a storage-loaded address nobody can tell who
  // decides: both are reported as warnings, which the signing policy still refuses without an explicit trust entry.
  const open = raw.guard === 'none' || raw.guard === 'foreign'
  // An account that accepts unsigned user operations hands the EntryPoint path, and with it the EOA, to anyone.
  const critical = raw.kind === 'USER_OPERATIONS_UNVERIFIED' || (open && (raw.fromFallback || CRITICAL_WHEN_OPEN.has(raw.kind)))
  return {
    kind: raw.kind,
    severity: critical ? 'critical' : 'warning',
    pc: raw.pc,
    ...(raw.target === undefined ? {} : { target: hex20(raw.target) }),
    context: raw.fromFallback ? 'fallback/receive' : `0x${(raw.selector ?? 0).toString(16).padStart(8, '0')}`,
    guard: raw.guard,
    description: DESCRIPTIONS[raw.kind],
  }
}

function special(kind: 'NO_CODE' | 'NESTED_DELEGATION', codeSize: number, description: string): Classification {
  return {
    verdict: 'review',
    codeSize,
    steps: 0,
    paths: 0,
    findings: [{ kind, severity: 'warning', pc: 0, context: 'n/a', guard: 'none', description }],
  }
}

/**
 * Classifies the runtime bytecode of a would-be EIP-7702 delegation target.
 *
 * - `malicious`: at least one critical finding (value, tokens or control can leave the EOA on a path anyone, or a
 *   hardcoded third party, can trigger).
 * - `review`: only warnings (e.g. a hardcoded payout behind the EOA's own check, or a caller check against a
 *   storage-loaded address), no code at all, a nested delegation, or an exploration that hit its budget.
 * - `safe`: no finding and complete exploration.
 *
 * This is a heuristic for a pre-signing warning, not a proof of safety.
 */
export function classifyDelegationTarget(runtimeCode: string, options: ClassifierOptions = {}): Classification {
  const clean = runtimeCode.toLowerCase()
  const codeSize = clean === '0x' || clean === '' ? 0 : (clean.length - (clean.startsWith('0x') ? 2 : 0)) / 2
  if (codeSize === 0) {
    return special('NO_CODE', codeSize, 'no code at the target yet; whatever is deployed there later would control the EOA')
  }
  if (clean.startsWith('0xef0100')) {
    return special('NESTED_DELEGATION', codeSize, 'the target is itself a delegated EOA; delegation chains are not followed')
  }
  const result = analyze(runtimeCode, {
    ...(options.budget ?? {}),
    ...(options.trustedCallers === undefined ? {} : { trustedCallers: options.trustedCallers }),
  })
  const findings: Finding[] = result.findings.map(toFinding)
  if (result.truncated) {
    findings.push({
      kind: 'ANALYSIS_INCOMPLETE',
      severity: 'warning',
      pc: 0,
      context: 'n/a',
      guard: 'none',
      description: 'exploration budget exhausted before every path was covered',
    })
  }
  const verdict: Verdict = findings.some((f) => f.severity === 'critical')
    ? 'malicious'
    : findings.length > 0
      ? 'review'
      : 'safe'
  return { verdict, findings, codeSize, steps: result.steps, paths: result.paths }
}
