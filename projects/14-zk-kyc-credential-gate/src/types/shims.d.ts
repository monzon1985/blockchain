// SPDX-License-Identifier: MIT
// Minimal ambient declarations for the untyped iden3 tool-chain packages we use.
// We only declare the surface this project actually touches.

declare module "circomlibjs" {
  export type FElement = Uint8Array;

  export interface FField {
    e(v: bigint | number | string | FElement): FElement;
    toObject(v: FElement): bigint;
    add(a: FElement, b: FElement): FElement;
    zero: FElement;
    one: FElement;
    isZero(v: FElement): boolean;
    eq(a: FElement, b: FElement): boolean;
  }

  export interface PoseidonFn {
    (inputs: Array<bigint | number | FElement>): FElement;
    F: FField;
  }

  export interface BabyJub {
    F: FField;
    Base8: [FElement, FElement];
    mulPointEscalar(p: [FElement, FElement], e: bigint): [FElement, FElement];
  }

  export interface Signature {
    R8: [FElement, FElement];
    S: bigint;
  }

  export interface Eddsa {
    babyJub: BabyJub;
    poseidon: PoseidonFn;
    F: FField;
    prv2pub(prv: Uint8Array): [FElement, FElement];
    signPoseidon(prv: Uint8Array, msg: FElement): Signature;
    verifyPoseidon(msg: FElement, sig: Signature, pub: [FElement, FElement]): boolean;
  }

  export interface SmtFindResult {
    found: boolean;
    siblings: FElement[];
    foundValue?: FElement;
    notFoundKey?: FElement;
    notFoundValue?: FElement;
    isOld0: boolean;
  }

  export interface Smt {
    F: FField;
    root: FElement;
    insert(key: bigint | number, value: bigint | number): Promise<unknown>;
    find(key: bigint | number | FElement): Promise<SmtFindResult>;
  }

  export function buildEddsa(): Promise<Eddsa>;
  export function buildPoseidon(): Promise<PoseidonFn>;
  export function newMemEmptyTrie(): Promise<Smt>;
}

declare module "snarkjs" {
  export const groth16: {
    fullProve(input: unknown, wasm: string, zkey: string): Promise<{ proof: unknown; publicSignals: string[] }>;
    prove(zkey: string, wtns: string): Promise<{ proof: unknown; publicSignals: string[] }>;
    verify(vkey: unknown, publicSignals: string[], proof: unknown): Promise<boolean>;
    exportSolidityCallData(proof: unknown, publicSignals: string[]): Promise<string>;
  };
  export const plonk: {
    setup(r1cs: string, ptau: string, zkey: string, logger?: unknown): Promise<unknown>;
    fullProve(input: unknown, wasm: string, zkey: string): Promise<{ proof: unknown; publicSignals: string[] }>;
    prove(zkey: string, wtns: string): Promise<{ proof: unknown; publicSignals: string[] }>;
    verify(vkey: unknown, publicSignals: string[], proof: unknown): Promise<boolean>;
    exportSolidityCallData(proof: unknown, publicSignals: string[]): Promise<string>;
  };
  export const powersOfTau: {
    newAccumulator(curve: unknown, power: number, file: string, logger?: unknown): Promise<unknown>;
    contribute(oldPtau: string, newPtau: string, name: string, entropy: string, logger?: unknown): Promise<unknown>;
    preparePhase2(oldPtau: string, newPtau: string, logger?: unknown): Promise<unknown>;
    verify(ptau: string, logger?: unknown): Promise<boolean>;
    beacon(oldPtau: string, newPtau: string, name: string, beaconHash: string, numIterationsExp: number, logger?: unknown): Promise<unknown>;
  };
  export const zKey: {
    newZKey(r1cs: string, ptau: string, zkey: string, logger?: unknown): Promise<unknown>;
    contribute(oldZkey: string, newZkey: string, name: string, entropy: string, logger?: unknown): Promise<string>;
    beacon(oldZkey: string, newZkey: string, name: string, beaconHash: string, numIterationsExp: number, logger?: unknown): Promise<string>;
    exportVerificationKey(zkey: string, logger?: unknown): Promise<unknown>;
    exportSolidityVerifier(zkey: string, templates: Record<string, string>, logger?: unknown): Promise<string>;
  };
  export const wtns: {
    calculate(input: unknown, wasm: string, wtns: string): Promise<void>;
    check(r1cs: string, wtns: string, logger?: unknown): Promise<boolean>;
    exportJson(wtns: string): Promise<bigint[]>;
  };
  export const r1cs: {
    info(r1cs: string, logger?: unknown): Promise<unknown>;
  };
}

declare module "@iden3/binfileutils" {
  /** fastfile handle, as returned by readBinFile/createBinFile. */
  export interface BinFd {
    pos: number;
    readULE32(): Promise<number>;
    writeULE32(v: number): Promise<void>;
    write(buf: Uint8Array, pos?: number): Promise<void>;
    close(): Promise<void>;
  }
  export type Sections = Array<Array<{ p: number; size: number }>>;
  export function readBinFile(
    fileName: string,
    type: string,
    maxVersion: number,
    cacheSize?: number,
    pageSize?: number,
  ): Promise<{ fd: BinFd; sections: Sections }>;
  export function createBinFile(
    fileName: string,
    type: string,
    version: number,
    nSections: number,
    cacheSize?: number,
    pageSize?: number,
  ): Promise<BinFd>;
  export function startReadUniqueSection(fd: BinFd, sections: Sections, idSection: number): Promise<void>;
  export function endReadSection(fd: BinFd, noCheck?: boolean): Promise<void>;
  export function readSection(
    fd: BinFd,
    sections: Sections,
    idSection: number,
    offset?: number,
    length?: number,
  ): Promise<Uint8Array>;
  export function readBigInt(fd: BinFd, n8: number, pos?: number): Promise<bigint>;
  export function writeBigInt(fd: BinFd, n: bigint, n8: number, pos?: number): Promise<void>;
  export function startWriteSection(fd: BinFd, idSection: number): Promise<void>;
  export function endWriteSection(fd: BinFd): Promise<void>;
}

declare module "circom_tester" {
  export interface WasmTester {
    calculateWitness(input: Record<string, unknown>, sanityCheck?: boolean): Promise<bigint[]>;
    checkConstraints(witness: bigint[]): Promise<void>;
    loadSymbols(): Promise<void>;
    getOutput(witness: bigint[], output: Record<string, unknown>): Promise<Record<string, bigint>>;
    symbols?: Record<string, { varIdx: number }>;
  }
  export function wasm(circomInput: string, options?: unknown): Promise<WasmTester>;
  const _default: { wasm: typeof wasm };
  export default _default;
}

declare module "ffjavascript" {
  export const Scalar: {
    e(v: bigint | number | string): bigint;
    fromRprLE(buff: Uint8Array, offset: number, len: number): bigint;
    toRprLE(buff: Uint8Array, offset: number, n: bigint, len: number): void;
  };
  export function getCurveFromName(name: string, single?: boolean): Promise<unknown>;
}
