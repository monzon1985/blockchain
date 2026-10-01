// SPDX-License-Identifier: MIT
// Corpus measurement of the delegation-target classifier on 20 contracts compiled by `forge build`, plus hand-assembled
// programs for the caller-guard semantics.
import { describe, expect, it } from 'vitest'

import { loadArtifact } from '../src/devnet/artifacts.ts'
import { analyze } from '../src/classifier/analyzer.ts'
import { disassemble, hexToBytes } from '../src/classifier/disassembler.ts'
import { classifyDelegationTarget, type Verdict } from '../src/classifier/index.ts'
import { checkAuthorizationPolicy } from '../src/policy/authorization.ts'

interface Sample {
  readonly file: string
  readonly contract: string
  readonly label: 'malicious' | 'benign'
  readonly expected: Verdict
  /** Finding kind that must explain the verdict. */
  readonly kind?: string
}

const C = 'ClassifierCorpus.sol'
const CORPUS: readonly Sample[] = [
  { file: C, contract: 'SweeperReceiveForward', label: 'malicious', expected: 'malicious', kind: 'BALANCE_DRAIN_TO_HARDCODED_ADDRESS' },
  { file: C, contract: 'SweeperStorageRecipient', label: 'malicious', expected: 'malicious', kind: 'BALANCE_DRAIN_TO_DYNAMIC_ADDRESS' },
  { file: C, contract: 'SweeperSelfdestruct', label: 'malicious', expected: 'malicious', kind: 'SELFDESTRUCT_TO_HARDCODED_ADDRESS' },
  { file: C, contract: 'SweeperTokenDrain', label: 'malicious', expected: 'malicious', kind: 'TOKEN_TRANSFER_TO_HARDCODED_ADDRESS' },
  { file: C, contract: 'SweeperWithDecoyExecutor', label: 'malicious', expected: 'malicious', kind: 'VALUE_FORWARD_TO_HARDCODED_ADDRESS' },
  { file: C, contract: 'SweeperDelegatecall', label: 'malicious', expected: 'malicious', kind: 'DELEGATECALL_TO_HARDCODED_ADDRESS' },
  { file: C, contract: 'SweeperToCaller', label: 'malicious', expected: 'malicious', kind: 'BALANCE_DRAIN_TO_CALLER' },
  { file: C, contract: 'OpenExecutor', label: 'malicious', expected: 'malicious', kind: 'ARBITRARY_CALL' },
  { file: C, contract: 'AttackerOwnedExecutor', label: 'malicious', expected: 'malicious', kind: 'ARBITRARY_CALL' },
  { file: C, contract: 'BeaconProxyDelegate', label: 'malicious', expected: 'malicious', kind: 'DELEGATECALL_TO_DYNAMIC_ADDRESS' },
  { file: C, contract: 'ForwardValueToStorage', label: 'malicious', expected: 'malicious', kind: 'VALUE_FORWARD_TO_DYNAMIC_ADDRESS' },
  { file: C, contract: 'UnverifiedUserOpAccount', label: 'malicious', expected: 'malicious', kind: 'USER_OPERATIONS_UNVERIFIED' },
  { file: 'PasskeyAccount.sol', contract: 'PasskeyAccount', label: 'benign', expected: 'safe' },
  { file: 'Simple7702Account.sol', contract: 'Simple7702Account', label: 'benign', expected: 'safe' },
  { file: 'TestUSD.sol', contract: 'TestUSD', label: 'benign', expected: 'safe' },
  { file: C, contract: 'MinimalBatchExecutor', label: 'benign', expected: 'safe' },
  { file: C, contract: 'ColdStorageForwarder', label: 'benign', expected: 'review', kind: 'BALANCE_DRAIN_TO_HARDCODED_ADDRESS' },
  { file: C, contract: 'EmptyEoaMimic', label: 'benign', expected: 'safe' },
  { file: C, contract: 'RefundToSender', label: 'benign', expected: 'safe' },
  { file: C, contract: 'EcdsaEntryPointAccount', label: 'benign', expected: 'safe' },
]

const TARGET = '0x3333333333333333333333333333333333333333'

describe('classifier corpus (20 compiled fixtures)', () => {
  const results = CORPUS.map((sample) => {
    const code = loadArtifact(sample.file, sample.contract).deployedBytecode
    const policy = checkAuthorizationPolicy({ chainId: 31337, address: TARGET, nonce: 0 }, { currentChainId: 31337, targetCode: code })
    return { sample, classification: policy.classification, signed: policy.allowed }
  })

  for (const { sample, classification } of results) {
    it(`${sample.contract} → ${sample.expected}${sample.kind === undefined ? '' : ` (${sample.kind})`}`, () => {
      expect(classification.verdict).toBe(sample.expected)
      if (sample.kind !== undefined) expect(classification.findings.map((f) => f.kind)).toContain(sample.kind)
    })
  }

  it('verdict view (flagged = verdict malicious): TP 12, FP 0, TN 8, FN 0', () => {
    const m = { tp: 0, fp: 0, tn: 0, fn: 0 }
    for (const { sample, classification } of results) {
      const flagged = classification.verdict === 'malicious'
      if (sample.label === 'malicious') {
        if (flagged) m.tp++
        else m.fn++
      } else if (flagged) m.fp++
      else m.tn++
    }
    expect(m).toEqual({ tp: 12, fp: 0, tn: 8, fn: 0 })
  })

  it('signing view (refused = the wallet policy will not sign): 12/12 drainers and 1/8 benign refused', () => {
    // The policy refuses anything that is not `safe` (review included), so the near miss ColdStorageForwarder is refused.
    const refusedMalicious = results.filter((r) => r.sample.label === 'malicious' && !r.signed).length
    const refusedBenign = results.filter((r) => r.sample.label === 'benign' && !r.signed).map((r) => r.sample.contract)
    expect(refusedMalicious).toBe(12)
    expect(refusedBenign).toEqual(['ColdStorageForwarder'])
  })

  it('explains each malicious verdict with a critical finding on an open path', () => {
    for (const { sample, classification } of results) {
      if (sample.label !== 'malicious') continue
      const critical = classification.findings.filter((f) => f.severity === 'critical')
      expect(critical.length, sample.contract).toBeGreaterThan(0)
      for (const f of critical) {
        const open = f.guard === 'none' || f.guard === 'foreign'
        expect(open || f.kind === 'USER_OPERATIONS_UNVERIFIED', `${sample.contract} ${f.kind}`).toBe(true)
      }
    }
  })

  it('does not flag the account the wallet actually delegates to', () => {
    const passkey = results.find((r) => r.sample.contract === 'PasskeyAccount')
    expect(passkey?.classification.findings).toEqual([])
  })
})

// ------------------------------------------------------------------------------------------------ hand-assembled code

type Item = string | readonly ['push', string] | readonly ['label', string] | readonly ['pushLabel', string]

const OPCODES: Record<string, number> = {
  STOP: 0x00, EQ: 0x14, ISZERO: 0x15, OR: 0x17, XOR: 0x18, ADDRESS: 0x30, CALLER: 0x33, CALLVALUE: 0x34,
  CALLDATALOAD: 0x35, SELFBALANCE: 0x47, SLOAD: 0x54, JUMPI: 0x57, JUMPDEST: 0x5b, PUSH0: 0x5f, GAS: 0x5a,
  CALL: 0xf1, DELEGATECALL: 0xf4, REVERT: 0xfd,
}

/** Two-pass assembler: opcodes by name, `['push', hex]` (PUSH1..PUSH32), labels and `['pushLabel', name]` (PUSH1). */
function asm(...items: readonly Item[]): string {
  const size = (it: Item): number =>
    typeof it === 'string' ? 1 : it[0] === 'push' ? 1 + it[1].length / 2 : it[0] === 'pushLabel' ? 2 : 0
  const labels = new Map<string, number>()
  let pc = 0
  for (const it of items) {
    if (typeof it !== 'string' && it[0] === 'label') labels.set(it[1], pc)
    pc += size(it)
  }
  let out = '0x'
  for (const it of items) {
    if (typeof it === 'string') {
      const op = OPCODES[it]
      if (op === undefined) throw new Error(`unknown opcode ${it}`)
      out += op.toString(16).padStart(2, '0')
    } else if (it[0] === 'push') {
      out += (0x5f + it[1].length / 2).toString(16) + it[1]
    } else if (it[0] === 'pushLabel') {
      out += `60${(labels.get(it[1]) ?? 0).toString(16).padStart(2, '0')}`
    } else {
      out += '5b' // JUMPDEST at every label
    }
  }
  return out
}

const RET4: Item[] = ['PUSH0', 'PUSH0', 'PUSH0', 'PUSH0'] // retLen, retOff, argsLen, argsOff
/** CALL(gas, calldata[4:36], SELFBALANCE): sweep the whole balance to an address chosen by the caller. */
const SWEEP_TO_CALLDATA: Item[] = [...RET4, 'SELFBALANCE', ['push', '04'], 'CALLDATALOAD', 'GAS', 'CALL', 'STOP']
const ATTACKER = 'badbadbadbadbadbadbadbadbadbadbadbadbad0'
const TRUSTED_EP = '5fbdb2315678afecb367f032d93f642f64180aa3'

describe('classifier caller guards (hand-assembled)', () => {
  it('flags SELFBALANCE sent to msg.sender with no guard (any caller withdraws everything)', () => {
    const c = classifyDelegationTarget(asm(...RET4, 'SELFBALANCE', 'CALLER', 'GAS', 'CALL', 'STOP'))
    expect(c.verdict).toBe('malicious')
    expect(c.findings[0]?.kind).toBe('BALANCE_DRAIN_TO_CALLER')
  })

  it('treats returning msg.value to msg.sender as benign (refund pattern)', () => {
    expect(classifyDelegationTarget(asm(...RET4, 'CALLVALUE', 'CALLER', 'GAS', 'CALL', 'STOP')).verdict).toBe('safe')
  })

  it('treats `CALLER == ADDRESS` as the owner guard: a sweep behind it is the owner deciding', () => {
    const code = asm('CALLER', 'ADDRESS', 'EQ', ['pushLabel', 'ok'], 'JUMPI', 'STOP', ['label', 'ok'], ...SWEEP_TO_CALLDATA)
    expect(classifyDelegationTarget(code).verdict).toBe('safe')
  })

  it('reads branch polarity: the fall-through of `CALLER == ADDRESS` is the unguarded side', () => {
    // if (caller == address) stop; else sweep: the sweep runs for every caller except the EOA itself.
    const code = asm('CALLER', 'ADDRESS', 'EQ', ['pushLabel', 'owner'], 'JUMPI', ...SWEEP_TO_CALLDATA, ['label', 'owner'], 'STOP')
    const c = classifyDelegationTarget(code)
    expect(c.verdict).toBe('malicious')
    expect(c.findings[0]).toMatchObject({ kind: 'BALANCE_DRAIN_TO_DYNAMIC_ADDRESS', guard: 'none' })
  })

  it('reads `iszero(eq(...))` and `xor` forms of the same check', () => {
    const viaIszero = asm('CALLER', 'ADDRESS', 'EQ', 'ISZERO', ['pushLabel', 'deny'], 'JUMPI', ...SWEEP_TO_CALLDATA, ['label', 'deny'], 'STOP')
    expect(classifyDelegationTarget(viaIszero).verdict).toBe('safe')
    const viaXor = asm('CALLER', 'ADDRESS', 'XOR', ['pushLabel', 'deny'], 'JUMPI', ...SWEEP_TO_CALLDATA, ['label', 'deny'], 'STOP')
    expect(classifyDelegationTarget(viaXor).verdict).toBe('safe')
  })

  it('treats a hardcoded third-party caller as attacker-controlled, not as a guard', () => {
    const code = asm('CALLER', ['push', ATTACKER], 'EQ', ['pushLabel', 'ok'], 'JUMPI', 'STOP', ['label', 'ok'], ...SWEEP_TO_CALLDATA)
    const c = classifyDelegationTarget(code)
    expect(c.verdict).toBe('malicious')
    expect(c.findings[0]?.guard).toBe('foreign')
  })

  it('trusts a hardcoded caller only when it is a known EntryPoint', () => {
    const code = asm('CALLER', ['push', TRUSTED_EP], 'EQ', ['pushLabel', 'ok'], 'JUMPI', 'STOP', ['label', 'ok'], ...SWEEP_TO_CALLDATA)
    expect(classifyDelegationTarget(code).verdict).toBe('malicious')
    expect(classifyDelegationTarget(code, { trustedCallers: [`0x${TRUSTED_EP}`] }).verdict).toBe('safe')
  })

  it('needs every alternative of an `||` check to be trusted', () => {
    // caller == address(this) || caller == ATTACKER: the attacker alternative makes the path open.
    const code = asm(
      'CALLER', 'ADDRESS', 'EQ', 'CALLER', ['push', ATTACKER], 'EQ', 'OR', ['pushLabel', 'ok'], 'JUMPI', 'STOP',
      ['label', 'ok'], ...SWEEP_TO_CALLDATA,
    )
    expect(classifyDelegationTarget(code).findings[0]?.guard).toBe('foreign')
  })

  it('asks for review when the caller is compared with a storage-loaded address', () => {
    const code = asm('CALLER', 'PUSH0', 'SLOAD', 'EQ', ['pushLabel', 'ok'], 'JUMPI', 'STOP', ['label', 'ok'], ...SWEEP_TO_CALLDATA)
    const c = classifyDelegationTarget(code)
    expect(c.verdict).toBe('review')
    expect(c.findings[0]?.guard).toBe('dynamic')
  })

  it('prunes branches that need `CALLER == 0` (nobody calls from address 0; also unset immutables)', () => {
    const code = asm('CALLER', 'PUSH0', 'EQ', ['pushLabel', 'ok'], 'JUMPI', 'STOP', ['label', 'ok'], ...SWEEP_TO_CALLDATA)
    expect(classifyDelegationTarget(code).verdict).toBe('safe')
  })

  it('flags an unguarded call with a caller-chosen target and value (open executor)', () => {
    const code = asm(...RET4, ['push', '24'], 'CALLDATALOAD', ['push', '04'], 'CALLDATALOAD', 'GAS', 'CALL', 'STOP')
    expect(classifyDelegationTarget(code).findings[0]).toMatchObject({ kind: 'ARBITRARY_CALL', severity: 'critical' })
  })

  it('flags CALLVALUE forwarded to a storage-loaded recipient from fallback/receive', () => {
    const code = asm(...RET4, 'CALLVALUE', 'PUSH0', 'SLOAD', 'GAS', 'CALL', 'STOP')
    expect(classifyDelegationTarget(code).findings[0]).toMatchObject({ kind: 'VALUE_FORWARD_TO_DYNAMIC_ADDRESS', severity: 'critical' })
  })

  it('flags DELEGATECALL to a non-constant target', () => {
    const code = asm('PUSH0', 'PUSH0', 'PUSH0', 'PUSH0', 'PUSH0', 'SLOAD', 'GAS', 'DELEGATECALL', 'STOP')
    expect(classifyDelegationTarget(code).findings[0]).toMatchObject({ kind: 'DELEGATECALL_TO_DYNAMIC_ADDRESS', severity: 'critical' })
  })
})

describe('classifier edge cases', () => {
  it('asks for review when the target has no code yet', () => {
    const c = classifyDelegationTarget('0x')
    expect(c.verdict).toBe('review')
    expect(c.findings[0]?.kind).toBe('NO_CODE')
  })

  it('asks for review for a nested delegation designator', () => {
    const c = classifyDelegationTarget(`0xef0100${'ab'.repeat(20)}`)
    expect(c.verdict).toBe('review')
    expect(c.findings[0]?.kind).toBe('NESTED_DELEGATION')
  })

  it('flags handwritten bytecode: SELFBALANCE sent to a PUSH20 address on any call', () => {
    // PUSH0 PUSH0 PUSH0 PUSH0 SELFBALANCE PUSH20 <addr> GAS CALL STOP
    const code = `0x5f5f5f5f4773${'42'.repeat(20)}5af100`
    const c = classifyDelegationTarget(code)
    expect(c.verdict).toBe('malicious')
    expect(c.findings[0]?.kind).toBe('BALANCE_DRAIN_TO_HARDCODED_ADDRESS')
    expect(c.findings[0]?.target).toBe(`0x${'42'.repeat(20)}`)
  })

  it('folds constant arithmetic used to hide the recipient (XOR of two constants)', () => {
    // PUSH0 x4, SELFBALANCE, PUSH20 a, PUSH20 b, XOR, GAS, CALL, STOP
    const a = '11'.repeat(20)
    const b = '53'.repeat(20)
    const c = classifyDelegationTarget(`0x5f5f5f5f4773${a}73${b}185af100`)
    expect(c.verdict).toBe('malicious')
    expect(c.findings[0]?.target).toBe(`0x${'42'.repeat(20)}`)
  })

  it('reports an incomplete exploration instead of claiming safety', () => {
    const code = loadArtifact('PasskeyAccount.sol', 'PasskeyAccount').deployedBytecode
    const c = classifyDelegationTarget(code, { budget: { maxSteps: 500 } })
    expect(c.verdict).toBe('review')
    expect(c.findings.map((f) => f.kind)).toContain('ANALYSIS_INCOMPLETE')
  })
})

describe('disassembler', () => {
  it('does not treat 0x5b inside PUSH data as a jump destination', () => {
    // PUSH2 0x5b5b, JUMPDEST, STOP
    const { instructions, jumpdests } = disassemble(hexToBytes('0x615b5b5b00'))
    expect(instructions.map((i) => i.name)).toEqual(['PUSH2', 'JUMPDEST', 'STOP'])
    expect([...jumpdests]).toEqual([3])
  })

  it('handles truncated PUSH data at the end of code and unknown opcodes', () => {
    const { instructions } = disassemble(hexToBytes('0x0c7fff'))
    expect(instructions[0]?.name).toBe('UNKNOWN_0x0c')
    expect(instructions[1]?.name).toBe('PUSH32')
  })

  it('rejects malformed hex', () => {
    expect(() => hexToBytes('0x123')).toThrow()
    expect(() => hexToBytes('0xzz')).toThrow()
  })

  it('never jumps into invalid destinations', () => {
    // PUSH1 0x03 JUMP INVALID(0xfe placeholder) : jump target 3 is not a JUMPDEST
    const result = analyze('0x600356fe5f5f5f5f4773' + '42'.repeat(20) + '5af100')
    expect(result.findings).toEqual([])
  })
})
