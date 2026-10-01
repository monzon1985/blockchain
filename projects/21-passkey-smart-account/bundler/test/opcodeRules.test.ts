// SPDX-License-Identifier: MIT
// ERC-7562 opcode rules on synthetic struct logs (the integration tests cover real anvil traces).
import { describe, expect, it } from 'vitest'

import {
  checkEntryPointAccess,
  checkOpcodeRules,
  DEPOSIT_TO_SELECTOR,
  isKnownPrecompile,
  type StructLog,
  type TraceFrame,
} from '../src/validation/opcodeRules.ts'

const EP = '0x00000000000000000000000000000000000000e0'
const SC = '0x00000000000000000000000000000000000000c0'
const SENDER = '0x0000000000000000000000000000000000005e00'
const PM = '0x000000000000000000000000000000000000fa00'
const CTX = { entryPoint: EP, senderCreator: SC, sender: SENDER, paymaster: PM } as const

let pc = 0
function step(op: string, depth: number, stack: string[] = []): StructLog {
  return { pc: pc++, op, gas: 1_000_000, gasCost: 3, depth, stack }
}

/** A CALL from `depth` to `target` (stack top = gas, then address, value, ...). */
function call(depth: number, target: string, value = '0x0', op = 'CALL'): StructLog {
  const stack = op === 'CALL' ? ['0x0', '0x0', '0x0', '0x0', value, target, '0xffff'] : ['0x0', '0x0', '0x0', '0x0', target, '0xffff']
  return step(op, depth, stack)
}

function enter(entity: string, body: StructLog[]): StructLog[] {
  return [call(1, entity), ...body, step('STOP', 2), step('POP', 1)]
}

describe('ERC-7562 opcode rules', () => {
  it('ignores banned opcodes executed by the EntryPoint itself', () => {
    const logs = [step('TIMESTAMP', 1), step('NUMBER', 1), step('GAS', 1), step('POP', 1)]
    expect(checkOpcodeRules(logs, CTX).violations).toEqual([])
  })

  it('attributes frames to account, paymaster and factory by the address the EntryPoint called', () => {
    const logs = [
      ...enter(SENDER, [step('TIMESTAMP', 2)]),
      ...enter(PM, [step('NUMBER', 2)]),
      ...enter(SC, [call(2, '0x000000000000000000000000000000000000f00d'), step('BLOCKHASH', 3), step('STOP', 3)]),
    ]
    const { violations } = checkOpcodeRules(logs, CTX)
    expect(violations.map((v) => [v.rule, v.entity, v.opcode])).toEqual([
      ['OP-011', 'account', 'TIMESTAMP'],
      ['OP-011', 'paymaster', 'NUMBER'],
      ['OP-011', 'factory', 'BLOCKHASH'],
    ])
  })

  it.each(['GASPRICE', 'GASLIMIT', 'PREVRANDAO', 'BASEFEE', 'SELFBALANCE', 'BALANCE', 'ORIGIN', 'CREATE', 'COINBASE', 'SELFDESTRUCT', 'BLOBHASH', 'BLOBBASEFEE'])(
    'bans %s in validation (OP-011)',
    (opcode) => {
      const { violations } = checkOpcodeRules(enter(SENDER, [step(opcode, 2)]), CTX)
      expect(violations).toHaveLength(1)
      expect(violations[0]?.rule).toBe('OP-011')
    },
  )

  it('allows GAS only right before a CALL-family opcode (OP-012)', () => {
    const ok = enter(SENDER, [step('GAS', 2), call(2, '0x0000000000000000000000000000000000000100', '0x0', 'STATICCALL')])
    expect(checkOpcodeRules(ok, CTX).violations).toEqual([])
    const bad = enter(SENDER, [step('GAS', 2), step('POP', 2)])
    expect(checkOpcodeRules(bad, CTX).violations[0]?.rule).toBe('OP-012')
  })

  it('allows a single CREATE2, only from the factory frame (OP-031)', () => {
    const factoryOnce = enter(SC, [step('CREATE2', 2)])
    expect(checkOpcodeRules(factoryOnce, CTX).violations).toEqual([])
    const twice = enter(SC, [step('CREATE2', 2), step('CREATE2', 2)])
    expect(checkOpcodeRules(twice, CTX).violations.map((v) => v.rule)).toEqual(['OP-031'])
    const fromAccount = enter(SENDER, [step('CREATE2', 2)])
    expect(checkOpcodeRules(fromAccount, CTX).violations.map((v) => v.rule)).toEqual(['OP-031'])
  })

  it('allows value only towards the EntryPoint (OP-061); EntryPoint calls are left to the call-tree check', () => {
    const prefund = enter(SENDER, [call(2, EP, '0x10')])
    expect(checkOpcodeRules(prefund, CTX).violations).toEqual([])
    const leak = enter(SENDER, [call(2, '0x000000000000000000000000000000000000dead', '0x1')])
    expect(checkOpcodeRules(leak, CTX).violations.map((v) => v.rule)).toEqual(['OP-061'])
  })

  it('allows known precompiles, including P256VERIFY at 0x100, and rejects others (OP-062)', () => {
    expect(isKnownPrecompile(0x100n)).toBe(true)
    expect(isKnownPrecompile(0x02n)).toBe(true)
    expect(isKnownPrecompile(0x12n)).toBe(false)
    const unknown = enter(SENDER, [call(2, '0x0000000000000000000000000000000000000055', '0x0', 'STATICCALL')])
    expect(checkOpcodeRules(unknown, CTX).violations.map((v) => v.rule)).toEqual(['OP-062'])
  })

  it('reports external call targets for the OP-041 code check', () => {
    const target = '0x000000000000000000000000000000000000beef'
    const { callTargets } = checkOpcodeRules(enter(SENDER, [call(2, target, '0x0', 'STATICCALL')]), CTX)
    expect([...callTargets.entries()]).toEqual([[target, 'account']])
  })

  it('keeps attributing nested frames to the entity that owns them', () => {
    const logs = [
      call(1, SENDER),
      call(2, '0x000000000000000000000000000000000000abcd', '0x0', 'STATICCALL'),
      step('TIMESTAMP', 3),
      step('STOP', 3),
      step('STOP', 2),
      step('STOP', 1),
    ]
    const { violations } = checkOpcodeRules(logs, CTX)
    expect(violations).toEqual([expect.objectContaining({ rule: 'OP-011', entity: 'account', opcode: 'TIMESTAMP' })])
  })
})

// ---------------------------------------------------------------------------------------------- EntryPoint access

const FACTORY = '0x000000000000000000000000000000000000fac7'
const HELPER = '0x000000000000000000000000000000000000beef'

function frame(type: string, from: string, to: string, input = '0x', calls: TraceFrame[] = []): TraceFrame {
  return { type, from, to, input, calls }
}

function depositTo(account: string): string {
  return `${DEPOSIT_TO_SELECTOR}${account.slice(2).padStart(64, '0')}`
}

/** simulateValidation's call tree: the EntryPoint calls the given entity frames. */
function tree(...entityFrames: TraceFrame[]): TraceFrame {
  return frame('CALL', '0x0000000000000000000000000000000000000000', EP, '0xdeadbeef', entityFrames)
}

const ACCESS_CTX = { ...CTX, factory: FACTORY } as const

describe('ERC-7562 EntryPoint access on the call tree (OP-052/053/054)', () => {
  it('allows the prefund through the fallback, from the sender (OP-053)', () => {
    const t = tree(frame('CALL', EP, SENDER, '0x19822f7c', [frame('CALL', SENDER, EP, '0x')]))
    expect(checkEntryPointAccess(t, ACCESS_CTX)).toEqual([])
  })

  it('allows depositTo(sender) from the sender and from the factory (OP-052)', () => {
    const fromSender = tree(frame('CALL', EP, SENDER, '0x19822f7c', [frame('CALL', SENDER, EP, depositTo(SENDER))]))
    expect(checkEntryPointAccess(fromSender, ACCESS_CTX)).toEqual([])
    const fromFactory = tree(
      frame('CALL', EP, SC, '0x', [frame('CALL', SC, FACTORY, '0x', [frame('CALL', FACTORY, EP, depositTo(SENDER))])]),
    )
    expect(checkEntryPointAccess(fromFactory, ACCESS_CTX)).toEqual([])
  })

  it.each([
    ['incrementNonce', '0x0bd28e3b' + '7'.padStart(64, '0')],
    ['withdrawTo', '0x205c2878' + '0'.repeat(128)],
    ['addStake', '0x0396cb60' + '1'.padStart(64, '0')],
    ['depositTo(someone else)', depositTo(HELPER)],
  ])('rejects %s from the sender (OP-054)', (_name, input) => {
    const t = tree(frame('CALL', EP, SENDER, '0x19822f7c', [frame('CALL', SENDER, EP, input)]))
    expect(checkEntryPointAccess(t, ACCESS_CTX)).toEqual([expect.objectContaining({ rule: 'OP-054', entity: 'account' })])
  })

  it('rejects static and delegate calls into the EntryPoint, even for allowed selectors', () => {
    const t = tree(
      frame('CALL', EP, SENDER, '0x19822f7c', [
        frame('STATICCALL', SENDER, EP, '0x70a08231' + SENDER.slice(2).padStart(64, '0')),
        frame('DELEGATECALL', SENDER, EP, depositTo(SENDER)),
      ]),
    )
    expect(checkEntryPointAccess(t, ACCESS_CTX).map((v) => [v.rule, v.opcode])).toEqual([
      ['OP-054', 'STATICCALL'],
      ['OP-054', 'DELEGATECALL'],
    ])
  })

  it('rejects any EntryPoint call from the paymaster, and fallback calls that do not come from the sender', () => {
    const t = tree(
      frame('CALL', EP, PM, '0x52b7512c', [frame('CALL', PM, EP, depositTo(SENDER)), frame('CALL', PM, EP, '0x')]),
      frame('CALL', EP, SENDER, '0x19822f7c', [frame('CALL', SENDER, HELPER, '0x', [frame('CALL', HELPER, EP, '0x')])]),
    )
    expect(checkEntryPointAccess(t, ACCESS_CTX).map((v) => [v.rule, v.entity])).toEqual([
      ['OP-054', 'paymaster'],
      ['OP-054', 'paymaster'],
      ['OP-054', 'account'],
    ])
  })

  it('ignores the EntryPoint calling itself outside entity frames', () => {
    const t = frame('CALL', '0x0000000000000000000000000000000000000000', EP, '0x', [frame('CALL', EP, EP, '0x1234')])
    expect(checkEntryPointAccess(t, ACCESS_CTX)).toEqual([])
  })
})
