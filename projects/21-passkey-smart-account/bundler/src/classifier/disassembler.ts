// SPDX-License-Identifier: MIT
// Dependency-free EVM disassembler (Osaka opcode set). Shared with the Next.js wallet.

export interface OpcodeInfo {
  readonly name: string
  /** Stack items consumed. */
  readonly pops: number
  /** Stack items produced. */
  readonly pushes: number
}

export interface Instruction {
  readonly pc: number
  readonly opcode: number
  readonly name: string
  /** Immediate data of PUSH1..PUSH32 as a bigint (0 for PUSH0). */
  readonly immediate?: bigint
  /** Byte length of the immediate. */
  readonly immediateSize: number
}

const table = new Map<number, OpcodeInfo>()

function def(opcode: number, name: string, pops: number, pushes: number): void {
  table.set(opcode, { name, pops, pushes })
}

// prettier-ignore
const simple: readonly (readonly [number, string, number, number])[] = [
  [0x00, 'STOP', 0, 0], [0x01, 'ADD', 2, 1], [0x02, 'MUL', 2, 1], [0x03, 'SUB', 2, 1], [0x04, 'DIV', 2, 1],
  [0x05, 'SDIV', 2, 1], [0x06, 'MOD', 2, 1], [0x07, 'SMOD', 2, 1], [0x08, 'ADDMOD', 3, 1], [0x09, 'MULMOD', 3, 1],
  [0x0a, 'EXP', 2, 1], [0x0b, 'SIGNEXTEND', 2, 1], [0x10, 'LT', 2, 1], [0x11, 'GT', 2, 1], [0x12, 'SLT', 2, 1],
  [0x13, 'SGT', 2, 1], [0x14, 'EQ', 2, 1], [0x15, 'ISZERO', 1, 1], [0x16, 'AND', 2, 1], [0x17, 'OR', 2, 1],
  [0x18, 'XOR', 2, 1], [0x19, 'NOT', 1, 1], [0x1a, 'BYTE', 2, 1], [0x1b, 'SHL', 2, 1], [0x1c, 'SHR', 2, 1],
  [0x1d, 'SAR', 2, 1], [0x1e, 'CLZ', 1, 1], [0x20, 'KECCAK256', 2, 1], [0x30, 'ADDRESS', 0, 1],
  [0x31, 'BALANCE', 1, 1], [0x32, 'ORIGIN', 0, 1], [0x33, 'CALLER', 0, 1], [0x34, 'CALLVALUE', 0, 1],
  [0x35, 'CALLDATALOAD', 1, 1], [0x36, 'CALLDATASIZE', 0, 1], [0x37, 'CALLDATACOPY', 3, 0], [0x38, 'CODESIZE', 0, 1],
  [0x39, 'CODECOPY', 3, 0], [0x3a, 'GASPRICE', 0, 1], [0x3b, 'EXTCODESIZE', 1, 1], [0x3c, 'EXTCODECOPY', 4, 0],
  [0x3d, 'RETURNDATASIZE', 0, 1], [0x3e, 'RETURNDATACOPY', 3, 0], [0x3f, 'EXTCODEHASH', 1, 1],
  [0x40, 'BLOCKHASH', 1, 1], [0x41, 'COINBASE', 0, 1], [0x42, 'TIMESTAMP', 0, 1], [0x43, 'NUMBER', 0, 1],
  [0x44, 'PREVRANDAO', 0, 1], [0x45, 'GASLIMIT', 0, 1], [0x46, 'CHAINID', 0, 1], [0x47, 'SELFBALANCE', 0, 1],
  [0x48, 'BASEFEE', 0, 1], [0x49, 'BLOBHASH', 1, 1], [0x4a, 'BLOBBASEFEE', 0, 1], [0x50, 'POP', 1, 0],
  [0x51, 'MLOAD', 1, 1], [0x52, 'MSTORE', 2, 0], [0x53, 'MSTORE8', 2, 0], [0x54, 'SLOAD', 1, 1],
  [0x55, 'SSTORE', 2, 0], [0x56, 'JUMP', 1, 0], [0x57, 'JUMPI', 2, 0], [0x58, 'PC', 0, 1], [0x59, 'MSIZE', 0, 1],
  [0x5a, 'GAS', 0, 1], [0x5b, 'JUMPDEST', 0, 0], [0x5c, 'TLOAD', 1, 1], [0x5d, 'TSTORE', 2, 0],
  [0x5e, 'MCOPY', 3, 0], [0x5f, 'PUSH0', 0, 1], [0xf0, 'CREATE', 3, 1], [0xf1, 'CALL', 7, 1],
  [0xf2, 'CALLCODE', 7, 1], [0xf3, 'RETURN', 2, 0], [0xf4, 'DELEGATECALL', 6, 1], [0xf5, 'CREATE2', 4, 1],
  [0xfa, 'STATICCALL', 6, 1], [0xfd, 'REVERT', 2, 0], [0xfe, 'INVALID', 0, 0], [0xff, 'SELFDESTRUCT', 1, 0],
]
for (const [op, name, pops, pushes] of simple) def(op, name, pops, pushes)
for (let n = 1; n <= 32; n++) def(0x5f + n, `PUSH${n}`, 0, 1)
for (let n = 1; n <= 16; n++) def(0x7f + n, `DUP${n}`, n, n + 1)
for (let n = 1; n <= 16; n++) def(0x8f + n, `SWAP${n}`, n + 1, n + 1)
for (let n = 0; n <= 4; n++) def(0xa0 + n, `LOG${n}`, n + 2, 0)

export function opcodeInfo(opcode: number): OpcodeInfo | undefined {
  return table.get(opcode)
}

/** Parses hex (with or without 0x) into bytes. Throws on malformed input. */
export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.startsWith('0x') || hex.startsWith('0X') ? hex.slice(2) : hex
  if (clean.length % 2 !== 0 || /[^0-9a-fA-F]/.test(clean)) throw new Error('bytecode must be even-length hex')
  const out = new Uint8Array(clean.length / 2)
  for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(clean.slice(i * 2, i * 2 + 2), 16)
  return out
}

/** Linear sweep disassembly. PUSH immediates are skipped, so JUMPDEST bytes inside them are not jump targets. */
export function disassemble(code: Uint8Array): { instructions: Instruction[]; jumpdests: Set<number>; byPc: Map<number, number> } {
  const instructions: Instruction[] = []
  const jumpdests = new Set<number>()
  const byPc = new Map<number, number>()
  let pc = 0
  while (pc < code.length) {
    const opcode = code[pc] ?? 0
    const info = table.get(opcode)
    const name = info?.name ?? `UNKNOWN_0x${opcode.toString(16).padStart(2, '0')}`
    let immediateSize = 0
    let immediate: bigint | undefined
    if (opcode >= 0x60 && opcode <= 0x7f) {
      immediateSize = opcode - 0x5f
      let value = 0n
      for (let i = 1; i <= immediateSize; i++) value = (value << 8n) | BigInt(code[pc + i] ?? 0)
      immediate = value
    } else if (opcode === 0x5f) {
      immediate = 0n
    }
    if (opcode === 0x5b) jumpdests.add(pc)
    byPc.set(pc, instructions.length)
    instructions.push(immediate === undefined ? { pc, opcode, name, immediateSize } : { pc, opcode, name, immediate, immediateSize })
    pc += 1 + immediateSize
  }
  return { instructions, jumpdests, byPc }
}
