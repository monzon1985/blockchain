// SPDX-License-Identifier: MIT
// The protocol on two fake chains (see fakechain.ts): just enough of OriginSettler, DestinationSettler, the mailbox
// pieces, the optimistic module, the HeaderStore and the tokens for the off-chain actors to run their real code.
// Contract rules follow src/ (write-once fill records, deadlines, keyed claims); proofs are not verified, the fake
// optimistic module only checks which block a challenge uses and whether the claim disagrees with the record.
import {
  type Address,
  type Hex,
  decodeAbiParameters,
  encodeAbiParameters,
  encodeErrorResult,
  erc20Abi,
  keccak256,
  pad,
  parseEther,
  zeroAddress,
  zeroHash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  destinationSettlerAbi,
  headerStoreAbi,
  mailboxFillReporterAbi,
  mockMailboxAbi,
  optimisticSettlementModuleAbi,
  originSettlerAbi,
} from "../src/abi.ts";
import type { Deployment, SolverConfig } from "../src/config.ts";
import {
  type GaslessCrossChainOrder,
  INTENT_ORDER_DATA_TYPEHASH,
  type Intent,
  type IntentOrderData,
  encodeOrderData,
  encodeOriginData,
  gaslessIntent,
  onchainIntent,
  orderIdOf,
} from "../src/orders.ts";
import type { PricingConfig } from "../src/pricing.ts";
import { type CallContext, FakeNode, Revert, fakeContract } from "./fakechain.ts";

const ORIGIN = 1001;
const DEST = 1002;

/** Deterministic test key for `label`. */
export function keyOf(label: string): Hex {
  return keccak256(`0x${Buffer.from(label).toString("hex")}`);
}

/** Address of the deterministic key for `label`. */
export function addressOf(label: string): Address {
  return privateKeyToAccount(keyOf(label)).address;
}

const addr = (n: number): Address => `0x${n.toString(16).padStart(40, "0")}`;

/** Fixed addresses of the fake deployment. */
export const A = {
  originSettler: addr(0x1001),
  permit2: addr(0x1002),
  headerStore: addr(0x1003),
  originMailbox: addr(0x1004),
  mailboxModule: addr(0x1005),
  optimisticModule: addr(0x1006),
  proofModule: addr(0x1007),
  bondToken: addr(0x1008),
  inputToken: addr(0x1009),
  destinationSettler: addr(0x2001),
  destMailbox: addr(0x2002),
  reporter: addr(0x2003),
  outputToken: addr(0x2004),
};

interface Escrow {
  user: Address;
  fillDeadline: number;
  status: number;
  inputToken: Address;
  inputAmount: bigint;
  settlementModule: Address;
  destinationChainId: bigint;
}

interface FillRecord {
  filler: Address;
  filledAt: bigint;
  fillHash: Hex;
}

interface ClaimState {
  claimant: Address;
  challengeDeadline: bigint;
  fillHash: Hex;
}

const MESSAGE = {
  type: "tuple",
  components: [
    { name: "nonce", type: "uint64" },
    { name: "originDomain", type: "uint256" },
    { name: "sender", type: "address" },
    { name: "destinationDomain", type: "uint256" },
    { name: "recipient", type: "address" },
    { name: "body", type: "bytes" },
  ],
} as const;

const claimKey = (orderId: Hex, filler: Address, filledAt: bigint): string =>
  `${orderId}:${filler.toLowerCase()}:${filledAt.toString()}`;

/** Order terms of the fake tests. */
export interface FakeTerms {
  mode: "mailbox" | "optimistic" | "proof";
  /** Overrides the module of `mode` (an unknown module makes the order unsupported). */
  module?: Address;
  destinationSettler?: Address;
  fillWindow?: bigint;
  outputStart?: bigint;
  outputEnd?: bigint;
  exclusiveFiller?: Address;
  exclusivityWindow?: bigint;
}

/** Both fake chains with the protocol deployed, plus helpers to drive them. */
export class FakeWorld {
  readonly origin = new FakeNode(ORIGIN);
  readonly dest = new FakeNode(DEST);
  readonly deployment: Deployment;
  private userNonce = 0n;

  // contract states, exposed for assertions
  readonly escrows = fakeContract<{ escrows: Record<string, Escrow> }>(originSettlerAbi, { escrows: {} }, {
    escrowOf: (s, _c, [orderId]) =>
      s.escrows[orderId as string] ?? {
        user: zeroAddress,
        fillDeadline: 0,
        status: 0,
        inputToken: zeroAddress,
        inputAmount: 0n,
        settlementModule: zeroAddress,
        destinationChainId: 0n,
      },
    REFUND_GRACE: () => 600n,
    openFor: (s, ctx, [order]) => {
      const intent = gaslessIntent(order as GaslessCrossChainOrder);
      const orderId = orderIdOf(encodeOriginData(intent));
      if (s.escrows[orderId] !== undefined) throw new Revert("0xfa1e000d", "OrderAlreadyExists");
      this.register(ctx, intent);
      return undefined;
    },
  });
  readonly fills = fakeContract<{ records: Record<string, FillRecord> }>(destinationSettlerAbi, { records: {} }, {
    fillRecord: (s, _c, [orderId]) =>
      s.records[orderId as string] ?? { filler: zeroAddress, filledAt: 0n, fillHash: zeroHash },
    fillWithRepayment: (s, ctx, [orderId, originData, repayment]) => {
      const id = orderId as Hex;
      if (orderIdOf(originData as Hex) !== id) throw new Revert("0xfa1e0001", "OrderIdMismatch");
      const existing = s.records[id];
      if (existing !== undefined) {
        throw new Revert(
          encodeErrorResult({ abi: destinationSettlerAbi, errorName: "AlreadyFilled", args: [id, existing.filler] }),
        );
      }
      const deadline = this.intents.get(id)?.fillDeadline ?? 0;
      if (ctx.node.time > BigInt(deadline)) {
        throw new Revert(
          encodeErrorResult({
            abi: destinationSettlerAbi,
            errorName: "FillDeadlinePassed",
            args: [deadline, ctx.node.time],
          }),
        );
      }
      s.records[id] = { filler: repayment as Address, filledAt: ctx.node.time, fillHash: keccak256(originData as Hex) };
      return undefined;
    },
  });
  readonly reporter = fakeContract(mailboxFillReporterAbi, { nonce: 0n }, {
    report: (s, ctx, [orderId, originChainId]) => {
      const record = this.fills.state.records[orderId as string];
      if (record === undefined) {
        throw new Revert(encodeErrorResult({ abi: mailboxFillReporterAbi, errorName: "OrderNotFilled", args: [orderId as Hex] }));
      }
      const body = encodeAbiParameters(
        [{ type: "bytes32" }, { type: "address" }, { type: "bytes32" }, { type: "uint64" }],
        [orderId as Hex, record.filler, record.fillHash, record.filledAt],
      );
      const message = encodeAbiParameters(
        [MESSAGE],
        [
          {
            nonce: s.nonce++,
            originDomain: BigInt(DEST),
            sender: A.reporter,
            destinationDomain: originChainId as bigint,
            recipient: A.mailboxModule,
            body,
          },
        ],
      );
      const messageId = keccak256(message);
      ctx.emit(A.destMailbox, mockMailboxAbi, "Dispatch", {
        messageId,
        sender: A.reporter,
        destinationDomain: originChainId,
        message,
      });
      return messageId;
    },
  });
  readonly originMailbox = fakeContract<{ delivered: Record<string, boolean> }>(mockMailboxAbi, { delivered: {} }, {
    delivered: (s, _c, [id]) => s.delivered[id as string] === true,
    process: (s, ctx, [message]) => {
      const id = keccak256(message as Hex);
      if (s.delivered[id] === true) throw new Revert("0xfa1e0002", "AlreadyDelivered");
      const [decoded] = decodeAbiParameters([MESSAGE], message as Hex);
      if (decoded.sender.toLowerCase() !== A.reporter.toLowerCase()) throw new Revert("0xfa1e0003", "UntrustedReporter");
      const [orderId, filler] = decodeAbiParameters(
        [{ type: "bytes32" }, { type: "address" }, { type: "bytes32" }, { type: "uint64" }],
        decoded.body,
      );
      s.delivered[id] = true;
      this.settle(ctx, orderId, filler, A.mailboxModule);
      return undefined;
    },
  });
  readonly optimistic = fakeContract<{ claims: Record<string, ClaimState>; lastChallengeBlock: bigint }>(
    optimisticSettlementModuleAbi,
    { claims: {}, lastChallengeBlock: 0n },
    {
    claimOf: (s, _c, [orderId, filler, filledAt]) =>
      s.claims[claimKey(orderId as Hex, filler as Address, filledAt as bigint)] ?? {
        claimant: zeroAddress,
        challengeDeadline: 0n,
        fillHash: zeroHash,
      },
    claim: (s, ctx, [orderId, filler, filledAt, fillHash]) => {
      const key = claimKey(orderId as Hex, filler as Address, filledAt as bigint);
      if (s.claims[key] !== undefined) throw new Revert("0xfa1e0004", "ClaimAlreadyPending");
      if (this.escrows.state.escrows[orderId as string]?.status !== 1) throw new Revert("0xfa1e0005", "OrderNotClaimable");
      const challengeDeadline = ctx.node.time + 300n;
      s.claims[key] = { claimant: ctx.from, challengeDeadline, fillHash: fillHash as Hex };
      ctx.emit(A.optimisticModule, optimisticSettlementModuleAbi, "Claimed", {
        orderId,
        claimant: ctx.from,
        filler,
        filledAt,
        challengeDeadline,
      });
      return keccak256(encodeAbiParameters([{ type: "string" }], [key]));
    },
    finalize: (s, ctx, [orderId, filler, filledAt]) => {
      const key = claimKey(orderId as Hex, filler as Address, filledAt as bigint);
      const pending = s.claims[key];
      if (pending === undefined) throw new Revert("0xfa1e0006", "NoPendingClaim");
      if (ctx.node.time <= pending.challengeDeadline) throw new Revert("0xfa1e0007", "ChallengeWindowOpen");
      Reflect.deleteProperty(s.claims, key);
      if (this.escrows.state.escrows[orderId as string]?.status === 1) {
        this.settle(ctx, orderId as Hex, filler as Address, A.optimisticModule);
      }
      return undefined;
    },
    challenge: (s, ctx, [orderId, filler, filledAt, blockNumber, accountProof]) => {
      const key = claimKey(orderId as Hex, filler as Address, filledAt as bigint);
      if (s.claims[key] === undefined) throw new Revert("0xfa1e0006", "NoPendingClaim");
      if (this.unchallengeable.has(orderId as Hex)) throw new Revert("0xfa1e0008", "fake: proof rejected");
      const header = this.headers.get(blockNumber as bigint);
      if (header === undefined || header <= (filledAt as bigint)) throw new Revert("0xfa1e0009", "HeaderNotAfterFill");
      const proofBlock = BigInt((accountProof as Hex[])[0] ?? "0x0");
      if (proofBlock !== blockNumber) throw new Revert("0xfa1e000a", "fake: proof of another block");
      const record = this.fills.state.records[orderId as string];
      if (record?.filler.toLowerCase() === (filler as Address).toLowerCase() && record.filledAt === filledAt) {
        throw new Revert("0xfa1e000b", "ClaimNotFraudulent");
      }
      Reflect.deleteProperty(s.claims, key);
      s.lastChallengeBlock = blockNumber;
      return undefined;
    },
  });
  readonly outputToken = erc20();
  readonly bondToken = erc20();

  /** Destination headers stored in the fake HeaderStore: block number -> timestamp. */
  readonly headers = new Map<bigint, bigint>();
  /** Orders whose challenges the fake module rejects whatever the proof (a poisoned claim). */
  readonly unchallengeable = new Set<Hex>();
  readonly intents = new Map<Hex, Intent>();

  constructor() {
    this.origin.deploy(A.originSettler, this.escrows);
    this.origin.deploy(A.originMailbox, this.originMailbox);
    this.origin.deploy(A.optimisticModule, this.optimistic);
    this.origin.deploy(A.bondToken, this.bondToken);
    this.dest.deploy(A.destinationSettler, this.fills);
    this.dest.deploy(A.reporter, this.reporter);
    this.dest.deploy(A.outputToken, this.outputToken);
    this.deployment = {
      origin: {
        chainId: ORIGIN,
        rpcUrl: "http://fake.invalid",
        originSettler: A.originSettler,
        permit2: A.permit2,
        headerStore: A.headerStore,
        mailbox: A.originMailbox,
        mailboxModule: A.mailboxModule,
        optimisticModule: A.optimisticModule,
        proofModule: A.proofModule,
        bondToken: A.bondToken,
      },
      destination: {
        chainId: DEST,
        rpcUrl: "http://fake.invalid",
        destinationSettler: A.destinationSettler,
        mailbox: A.destMailbox,
        reporter: A.reporter,
      },
    };
  }

  /** Solver config for `repayment`, journal at `dbPath`. */
  config(repayment: Address, dbPath: string, overrides: Partial<SolverConfig> = {}): SolverConfig {
    return { deployment: this.deployment, repaymentAddress: repayment, dbPath, pollIntervalMs: 1, pricing: pricing(), ...overrides };
  }

  /** Order data of `terms`, opened now. */
  orderData(terms: FakeTerms): { data: IntentOrderData; fillDeadline: number } {
    const now = this.origin.time;
    const module =
      terms.mode === "mailbox" ? A.mailboxModule : terms.mode === "optimistic" ? A.optimisticModule : A.proofModule;
    return {
      data: {
        inputToken: A.inputToken,
        inputAmount: parseEther("1000"),
        outputToken: A.outputToken,
        outputStartAmount: terms.outputStart ?? parseEther("995"),
        outputEndAmount: terms.outputEnd ?? parseEther("990"),
        recipient: addressOf("recipient"),
        destinationChainId: BigInt(DEST),
        destinationSettler: terms.destinationSettler ?? A.destinationSettler,
        exclusiveFiller: terms.exclusiveFiller ?? zeroAddress,
        exclusivityDeadline: Number(now + (terms.exclusivityWindow ?? 0n)),
        settlementModule: terms.module ?? module,
      },
      fillDeadline: Number(now + (terms.fillWindow ?? 900n)),
    };
  }

  /** Opens an order on the origin (escrow + Open event), as `OriginSettler.open` would. */
  open(terms: FakeTerms): { orderId: Hex; originData: Hex; intent: Intent } {
    const { data, fillDeadline } = this.orderData(terms);
    const intent = onchainIntent(A.originSettler, BigInt(ORIGIN), addressOf("user"), this.userNonce++, fillDeadline, data);
    this.origin.setup((ctx) => {
      this.register(ctx, intent);
    });
    const originData = encodeOriginData(intent);
    return { orderId: orderIdOf(originData), originData, intent };
  }

  /** A gasless order of `terms` (the fake settler does not check signatures). */
  gasless(terms: FakeTerms, nonce: bigint): GaslessCrossChainOrder {
    const { data, fillDeadline } = this.orderData(terms);
    return {
      originSettler: A.originSettler,
      user: addressOf("user"),
      nonce,
      originChainId: BigInt(ORIGIN),
      openDeadline: Number(this.origin.time + 600n),
      fillDeadline,
      orderDataType: INTENT_ORDER_DATA_TYPEHASH,
      orderData: encodeOrderData(data),
    };
  }

  /** Emits an Open event whose payload is `originData` but whose id is `orderId` (a malformed event). */
  emitOpen(orderId: Hex, originData: Hex): void {
    this.origin.setup((ctx) => {
      ctx.emit(A.originSettler, originSettlerAbi, "Open", {
        orderId,
        resolvedOrder: {
          user: zeroAddress,
          originChainId: BigInt(ORIGIN),
          openDeadline: 0,
          fillDeadline: 0,
          orderId,
          maxSpent: [],
          minReceived: [],
          fillInstructions: [{ destinationChainId: BigInt(DEST), destinationSettler: pad(A.destinationSettler), originData }],
        },
      });
    });
  }

  /** Escrow + Open event of `intent`. */
  private register(ctx: CallContext, intent: Intent): void {
    const originData = encodeOriginData(intent);
    const orderId = orderIdOf(originData);
    this.intents.set(orderId, intent);
    this.escrows.state.escrows[orderId] = {
      user: intent.user,
      fillDeadline: intent.fillDeadline,
      status: 1,
      inputToken: intent.data.inputToken,
      inputAmount: intent.data.inputAmount,
      settlementModule: intent.data.settlementModule,
      destinationChainId: BigInt(DEST),
    };
    ctx.emit(A.originSettler, originSettlerAbi, "Open", {
      orderId,
      resolvedOrder: {
        user: intent.user,
        originChainId: BigInt(ORIGIN),
        openDeadline: intent.openDeadline,
        fillDeadline: intent.fillDeadline,
        orderId,
        maxSpent: [],
        minReceived: [],
        fillInstructions: [{ destinationChainId: BigInt(DEST), destinationSettler: pad(A.destinationSettler), originData }],
      },
    });
  }

  /** Repays an order to `filler` directly (as a settlement through any module would). */
  repay(orderId: Hex, filler: Address): void {
    this.origin.setup((ctx) => {
      const escrow = this.escrows.state.escrows[orderId];
      if (escrow === undefined) return;
      this.settle(ctx, orderId, filler, escrow.settlementModule);
    });
  }

  /** Stores a destination header (block number, timestamp) in the fake HeaderStore, as relayed or imported. */
  storeHeader(blockNumber: bigint, timestamp: bigint): void {
    this.headers.set(blockNumber, timestamp);
    this.origin.setup((ctx) => {
      ctx.emit(A.headerStore, headerStoreAbi, "HeaderStored", {
        chainId: BigInt(DEST),
        blockNumber,
        blockHash: keccak256(pad(`0x${blockNumber.toString(16)}`)),
        stateRoot: zeroHash,
        timestamp,
        viaAncestry: false,
      });
    });
  }

  /** Refunds an order directly (as `OriginSettler.refund` after the grace period). */
  refund(orderId: Hex): void {
    const escrow = this.escrows.state.escrows[orderId];
    if (escrow !== undefined) escrow.status = 3;
  }

  private settle(ctx: CallContext, orderId: Hex, filler: Address, module: Address) {
    const escrow = this.escrows.state.escrows[orderId];
    if (escrow?.status !== 1) {
      throw new Revert(encodeErrorResult({ abi: originSettlerAbi, errorName: "OrderNotOpen", args: [orderId, escrow?.status ?? 0] }));
    }
    if (escrow.settlementModule.toLowerCase() !== module.toLowerCase()) throw new Revert("0xfa1e000c", "UnauthorizedModule");
    escrow.status = 2;
    ctx.emit(A.originSettler, originSettlerAbi, "OrderSettled", {
      orderId,
      module,
      filler,
      token: escrow.inputToken,
      amount: escrow.inputAmount,
    });
  }
}

function erc20() {
  return fakeContract<{ balances: Record<string, bigint>; allowances: Record<string, bigint> }>(
    erc20Abi,
    { balances: {}, allowances: {} },
    {
    balanceOf: (s, _c, [who]) => s.balances[(who as Address).toLowerCase()] ?? 0n,
    allowance: (s, _c, [owner, spender]) =>
      s.allowances[`${(owner as Address).toLowerCase()}:${(spender as Address).toLowerCase()}`] ?? 0n,
    approve: (s, ctx, [spender, amount]) => {
      s.allowances[`${ctx.from.toLowerCase()}:${(spender as Address).toLowerCase()}`] = amount as bigint;
      return true;
    },
  });
}

/** The pricing policy of the e2e suite. */
export function pricing(): PricingConfig {
  return {
    tokenPrices: { [A.inputToken.toLowerCase()]: 1n, [A.outputToken.toLowerCase()]: 1n },
    nativePriceOrigin: 3000n,
    nativePriceDest: 3000n,
    gas: { open: 250_000n, fill: 150_000n, settle: { mailbox: 100_000n, optimistic: 300_000n, proof: 350_000n } },
    capitalCostBpsPerHour: 1n,
    modeRiskBps: { mailbox: 5n, optimistic: 10n, proof: 2n },
    settlementDelaySec: { mailbox: 60n, optimistic: 300n, proof: 30n },
    settlementLatencySec: { mailbox: 60n, optimistic: 30n, proof: 60n },
    minProfit: parseEther("1"),
    fillSafetyMarginSec: 5n,
  };
}
