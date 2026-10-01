// SPDX-License-Identifier: MIT
// Durable solver state in node:sqlite. Every side effect the solver takes on-chain is journaled here BEFORE it is
// broadcast (the signed raw transaction, its hash and its nonce), in the same database transaction as the order's
// state change, so a crash at any point can be recovered by re-reading the journal and asking the chains what
// happened. Nonces come from the journal too, so a transaction that was journaled but never broadcast keeps its nonce
// and cannot be overtaken by a later one.
import { DatabaseSync } from "node:sqlite";

import type { Address, Hex } from "viem";

import type { SettlementMode } from "./pricing.ts";

/** Every state of an order in the solver's state machine, in lifecycle order. */
export const ORDER_STATES = [
  "DISCOVERED", // Open event seen, not evaluated yet
  "WAITING", // profitable later (decay or exclusivity); re-quoted at wait_until
  "FILL_SIGNED", // fill transaction signed and journaled, maybe not broadcast
  "FILL_SENT", // fill broadcast, receipt pending
  "FILLED", // fill mined; settlement not started or being retried
  "SETTLE_SENT", // settlement transaction journaled/broadcast (report, claim, finalize or prove)
  "AWAITING_REPAYMENT", // report delivered by the mailbox or claim in its challenge window
  "SETTLED", // escrow released to us (terminal)
  "SKIPPED", // not worth filling (terminal)
  "EXPIRED", // fill deadline passed before we filled (terminal)
  "LOST", // someone else filled, or the escrow was refunded or repaid to someone else (terminal)
] as const;

/** A state of the order state machine. */
export type OrderState = (typeof ORDER_STATES)[number];

/** States in which the solver has nothing left to do for an order. */
export const TERMINAL_STATES: ReadonlySet<OrderState> = new Set(["SETTLED", "SKIPPED", "EXPIRED", "LOST"]);

/** Legal transitions. Anything else is a bug and throws. */
export const TRANSITIONS: Readonly<Record<OrderState, readonly OrderState[]>> = {
  DISCOVERED: ["WAITING", "FILL_SIGNED", "SKIPPED", "EXPIRED", "LOST"],
  WAITING: ["WAITING", "FILL_SIGNED", "SKIPPED", "EXPIRED", "LOST"],
  FILL_SIGNED: ["FILL_SENT", "FILLED", "DISCOVERED", "EXPIRED", "LOST"],
  FILL_SENT: ["FILLED", "DISCOVERED", "EXPIRED", "LOST"],
  // FILLED -> AWAITING_REPAYMENT: someone else already posted exactly our optimistic claim.
  FILLED: ["SETTLE_SENT", "AWAITING_REPAYMENT", "SETTLED", "LOST"],
  SETTLE_SENT: ["AWAITING_REPAYMENT", "SETTLED", "FILLED", "LOST"],
  AWAITING_REPAYMENT: ["SETTLE_SENT", "SETTLED", "FILLED", "LOST"],
  SETTLED: [],
  SKIPPED: [],
  EXPIRED: [],
  LOST: [],
};

/** Which settlement transaction an order row journals. */
export type SettleKind = "report" | "claim" | "finalize" | "prove";

/** One order as the solver tracks it. Timestamps are chain seconds; blocks are destination block numbers. */
export interface OrderRow {
  orderId: Hex;
  /** ABI-encoded Intent, as emitted in the Open event. */
  originData: Hex;
  mode: SettlementMode;
  state: OrderState;
  /** WAITING: destination time at which to re-quote. */
  waitUntil: number | null;
  /** Hash and raw bytes of the journaled fill transaction. */
  fillTx: Hex | null;
  fillRaw: Hex | null;
  /** Destination block and timestamp of the mined fill. */
  fillBlock: number | null;
  filledAt: number | null;
  /** Journaled settlement transaction (report, claim, finalize or prove). */
  settleKind: SettleKind | null;
  settleTx: Hex | null;
  settleRaw: Hex | null;
  /** Optimistic mode: end of our claim's challenge window (origin time). */
  challengeDeadline: number | null;
  /** Mailbox mode: origin time after which an undelivered report is sent again. */
  recheckAt: number | null;
  /** Human-readable reason of the last transition, for operators. */
  reason: string | null;
}

/** Columns a transition may update. */
export type OrderPatch = Partial<Omit<OrderRow, "orderId" | "originData" | "mode" | "state">>;

/** Status of a journaled transaction. */
export type TxStatus = "pending" | "mined" | "replaced";

/** A signed transaction as the journal keeps it. */
export interface JournaledTx {
  hash: Hex;
  raw: Hex;
  chainId: number;
  sender: Address;
  nonce: number;
  /** What it does: `fill`, `report`, `claim`, `finalize`, `prove`, `open`, `approve`. */
  purpose: string;
}

/** A journaled transaction and its status. */
export interface JournalRow extends JournaledTx {
  status: TxStatus;
}

interface RawRow {
  order_id: string;
  origin_data: string;
  mode: string;
  state: string;
  wait_until: number | null;
  fill_tx: string | null;
  fill_raw: string | null;
  fill_block: number | null;
  filled_at: number | null;
  settle_kind: string | null;
  settle_tx: string | null;
  settle_raw: string | null;
  challenge_deadline: number | null;
  recheck_at: number | null;
  reason: string | null;
}

interface RawTx {
  hash: string;
  raw: string;
  chain_id: number;
  sender: string;
  nonce: number;
  purpose: string;
  status: string;
}

const COLUMNS: Record<keyof OrderPatch, string> = {
  waitUntil: "wait_until",
  fillTx: "fill_tx",
  fillRaw: "fill_raw",
  fillBlock: "fill_block",
  filledAt: "filled_at",
  settleKind: "settle_kind",
  settleTx: "settle_tx",
  settleRaw: "settle_raw",
  challengeDeadline: "challenge_deadline",
  recheckAt: "recheck_at",
  reason: "reason",
};

/** Thrown for a transition that TRANSITIONS forbids, or when the order is no longer in the expected state. */
export class IllegalTransitionError extends Error {
  readonly orderId: Hex;
  readonly from: OrderState;
  readonly to: OrderState;

  constructor(orderId: Hex, from: OrderState, to: OrderState) {
    super(`illegal transition ${from} -> ${to} for ${orderId}`);
    this.name = "IllegalTransitionError";
    this.orderId = orderId;
    this.from = from;
    this.to = to;
  }
}

/**
 * The solver's journal: orders and their state machine, every signed transaction with its nonce, event cursors and
 * the gasless-order feed. Writes are synchronous and durable (WAL, `synchronous = FULL`).
 */
export class SolverStore {
  private readonly db: DatabaseSync;

  /** Opens (or creates) the journal at `path` (`:memory:` for tests). */
  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL;");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS orders (
        order_id TEXT PRIMARY KEY,
        origin_data TEXT NOT NULL,
        mode TEXT NOT NULL,
        state TEXT NOT NULL,
        wait_until INTEGER,
        fill_tx TEXT,
        fill_raw TEXT,
        fill_block INTEGER,
        filled_at INTEGER,
        settle_kind TEXT,
        settle_tx TEXT,
        settle_raw TEXT,
        challenge_deadline INTEGER,
        recheck_at INTEGER,
        reason TEXT,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS transitions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id TEXT NOT NULL,
        from_state TEXT NOT NULL,
        to_state TEXT NOT NULL,
        at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS txs (
        hash TEXT PRIMARY KEY,
        raw TEXT NOT NULL,
        chain_id INTEGER NOT NULL,
        sender TEXT NOT NULL,
        nonce INTEGER NOT NULL,
        purpose TEXT NOT NULL,
        status TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS txs_by_account ON txs (chain_id, sender, nonce);
      CREATE TABLE IF NOT EXISTS cursors (name TEXT PRIMARY KEY, block INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS feed (name TEXT PRIMARY KEY, status TEXT NOT NULL, tx TEXT, raw TEXT);
    `);
  }

  /** Closes the database. */
  close(): void {
    this.db.close();
  }

  /** Inserts a newly discovered order; returns false if it was already known. */
  discover(orderId: Hex, originData: Hex, mode: SettlementMode): boolean {
    const result = this.db
      .prepare(
        "INSERT OR IGNORE INTO orders (order_id, origin_data, mode, state, updated_at) VALUES (?, ?, ?, 'DISCOVERED', ?)",
      )
      .run(orderId, originData, mode, Date.now());
    return result.changes > 0;
  }

  /** The order `orderId`, if known. */
  get(orderId: Hex): OrderRow | undefined {
    const row = this.db.prepare("SELECT * FROM orders WHERE order_id = ?").get(orderId) as RawRow | undefined;
    return row === undefined ? undefined : toRow(row);
  }

  /** Orders that still need work, oldest first. */
  active(): OrderRow[] {
    const terminal = [...TERMINAL_STATES].map((s) => `'${s}'`).join(",");
    const rows = this.db
      .prepare(`SELECT * FROM orders WHERE state NOT IN (${terminal}) ORDER BY rowid`)
      .all() as unknown as RawRow[];
    return rows.map(toRow);
  }

  /** Every known order, oldest first. */
  all(): OrderRow[] {
    return (this.db.prepare("SELECT * FROM orders ORDER BY rowid").all() as unknown as RawRow[]).map(toRow);
  }

  /**
   * Moves `orderId` from `from` to `to` and applies `patch`, atomically, together with journaling `journal` (the
   * signed transaction this transition records) when given. Throws if the order is not in `from` (another step
   * already moved it) or if the transition is not in TRANSITIONS; then nothing is written, the transaction included.
   */
  transition(orderId: Hex, from: OrderState, to: OrderState, patch: OrderPatch = {}, journal?: JournaledTx): void {
    if (!TRANSITIONS[from].includes(to)) throw new IllegalTransitionError(orderId, from, to);
    const sets = ["state = ?", "updated_at = ?"];
    const values: (string | number | null)[] = [to, Date.now()];
    for (const [key, column] of Object.entries(COLUMNS) as [keyof OrderPatch, string][]) {
      if (key in patch) {
        sets.push(`${column} = ?`);
        values.push(patch[key] ?? null);
      }
    }
    this.atomically(() => {
      const result = this.db
        .prepare(`UPDATE orders SET ${sets.join(", ")} WHERE order_id = ? AND state = ?`)
        .run(...values, orderId, from);
      if (result.changes !== 1) throw new IllegalTransitionError(orderId, from, to);
      this.db
        .prepare("INSERT INTO transitions (order_id, from_state, to_state, at) VALUES (?, ?, ?, ?)")
        .run(orderId, from, to, Date.now());
      if (journal !== undefined) this.insertTx(journal);
    });
  }

  /** Every transition of `orderId`, in order. */
  history(orderId: Hex): { from: OrderState; to: OrderState }[] {
    return (
      this.db
        .prepare("SELECT from_state, to_state FROM transitions WHERE order_id = ? ORDER BY id")
        .all(orderId) as unknown as { from_state: OrderState; to_state: OrderState }[]
    ).map((r) => ({ from: r.from_state, to: r.to_state }));
  }

  // ----------------------------------------------------------------------------------------------------------------
  // Transaction journal
  // ----------------------------------------------------------------------------------------------------------------

  /** Journals a transaction that belongs to no order transition (an approval). */
  journalTx(tx: JournaledTx): void {
    this.atomically(() => {
      this.insertTx(tx);
    });
  }

  /**
   * Nonce the next transaction of `sender` on `chainId` must use: one past the highest journaled nonce, or the
   * node's pending nonce if that is higher (for example after transactions sent outside this journal).
   */
  nextNonce(chainId: number, sender: Address, chainPendingNonce: number): number {
    const row = this.db
      .prepare("SELECT MAX(nonce) AS n FROM txs WHERE chain_id = ? AND sender = ?")
      .get(chainId, sender.toLowerCase()) as { n: number | null };
    return row.n === null ? chainPendingNonce : Math.max(chainPendingNonce, row.n + 1);
  }

  /** Journaled transactions of `sender` on `chainId` still waiting for a receipt, by nonce. */
  pendingTxs(chainId: number, sender: Address): JournalRow[] {
    const rows = this.db
      .prepare("SELECT * FROM txs WHERE chain_id = ? AND sender = ? AND status = 'pending' ORDER BY nonce")
      .all(chainId, sender.toLowerCase()) as unknown as RawTx[];
    return rows.map(toTx);
  }

  /** The journaled transaction `hash`, if any. */
  tx(hash: Hex): JournalRow | undefined {
    const row = this.db.prepare("SELECT * FROM txs WHERE hash = ?").get(hash) as RawTx | undefined;
    return row === undefined ? undefined : toTx(row);
  }

  /** Records what happened to a journaled transaction. */
  setTxStatus(hash: Hex, status: TxStatus): void {
    this.db.prepare("UPDATE txs SET status = ? WHERE hash = ?").run(status, hash);
  }

  // ----------------------------------------------------------------------------------------------------------------
  // Cursors and feed
  // ----------------------------------------------------------------------------------------------------------------

  /** Next block to scan for the event stream `name`. */
  cursor(name: string): number | undefined {
    const row = this.db.prepare("SELECT block FROM cursors WHERE name = ?").get(name) as { block: number } | undefined;
    return row?.block;
  }

  /** Stores the next block to scan for `name`. */
  setCursor(name: string, block: number): void {
    this.db.prepare("INSERT INTO cursors (name, block) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET block = ?").run(
      name,
      block,
      block,
    );
  }

  /** What the solver did with the feed file `name`. */
  feedStatus(name: string): { status: string; tx: Hex | null; raw: Hex | null } | undefined {
    const row = this.db.prepare("SELECT status, tx, raw FROM feed WHERE name = ?").get(name) as
      | { status: string; tx: string | null; raw: string | null }
      | undefined;
    return row === undefined ? undefined : { status: row.status, tx: row.tx as Hex | null, raw: row.raw as Hex | null };
  }

  /** Records a feed file's status, journaling `journal` (its openFor transaction) atomically when given. */
  setFeedStatus(name: string, status: string, tx: Hex | null = null, raw: Hex | null = null, journal?: JournaledTx): void {
    this.atomically(() => {
      this.db
        .prepare(
          "INSERT INTO feed (name, status, tx, raw) VALUES (?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET status = ?, tx = ?, raw = ?",
        )
        .run(name, status, tx, raw, status, tx, raw);
      if (journal !== undefined) this.insertTx(journal);
    });
  }

  /** Forgets a feed file so that it is evaluated again. */
  clearFeedStatus(name: string): void {
    this.db.prepare("DELETE FROM feed WHERE name = ?").run(name);
  }

  private insertTx(tx: JournaledTx): void {
    this.db
      .prepare(
        "INSERT INTO txs (hash, raw, chain_id, sender, nonce, purpose, status) VALUES (?, ?, ?, ?, ?, ?, 'pending')",
      )
      .run(tx.hash, tx.raw, tx.chainId, tx.sender.toLowerCase(), tx.nonce, tx.purpose);
  }

  private atomically(body: () => void): void {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      body();
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }
}

function toRow(r: RawRow): OrderRow {
  return {
    orderId: r.order_id as Hex,
    originData: r.origin_data as Hex,
    mode: r.mode as SettlementMode,
    state: r.state as OrderState,
    waitUntil: r.wait_until,
    fillTx: r.fill_tx as Hex | null,
    fillRaw: r.fill_raw as Hex | null,
    fillBlock: r.fill_block,
    filledAt: r.filled_at,
    settleKind: r.settle_kind as SettleKind | null,
    settleTx: r.settle_tx as Hex | null,
    settleRaw: r.settle_raw as Hex | null,
    challengeDeadline: r.challenge_deadline,
    recheckAt: r.recheck_at,
    reason: r.reason,
  };
}

function toTx(r: RawTx): JournalRow {
  return {
    hash: r.hash as Hex,
    raw: r.raw as Hex,
    chainId: r.chain_id,
    sender: r.sender as Address,
    nonce: r.nonce,
    purpose: r.purpose,
    status: r.status as TxStatus,
  };
}
