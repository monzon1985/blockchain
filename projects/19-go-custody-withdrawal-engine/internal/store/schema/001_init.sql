-- SPDX-License-Identifier: MIT
-- Initial schema. Amounts are base-10 strings of arbitrary-precision integers (wei, token base
-- units): SQLite INTEGER is 64-bit and 18-decimal tokens overflow it after ~9.2 tokens.
-- Timestamps are Unix nanoseconds (UTC).

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) STRICT;

-- Double-entry ledger ---------------------------------------------------------------------------

CREATE TABLE ledger_entries (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ref        TEXT    NOT NULL UNIQUE,   -- idempotency key of the business event
    kind       TEXT    NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE ledger_postings (
    entry_id INTEGER NOT NULL REFERENCES ledger_entries (id),
    account  TEXT    NOT NULL,
    asset    TEXT    NOT NULL,
    amount   TEXT    NOT NULL             -- signed; positive = debit, negative = credit
) STRICT;
CREATE INDEX ledger_postings_entry ON ledger_postings (entry_id);
CREATE INDEX ledger_postings_account ON ledger_postings (account, asset);

CREATE TABLE ledger_balances (
    account TEXT NOT NULL,
    asset   TEXT NOT NULL,
    balance TEXT NOT NULL,                -- sum of the account's postings, debit-positive
    PRIMARY KEY (account, asset)
) STRICT;

-- Withdrawals -----------------------------------------------------------------------------------

CREATE TABLE withdrawals (
    id                 TEXT PRIMARY KEY,
    client_id          TEXT    NOT NULL,
    account_id         TEXT    NOT NULL,
    asset              TEXT    NOT NULL,
    amount             TEXT    NOT NULL,
    destination        TEXT    NOT NULL,
    status             TEXT    NOT NULL CHECK (status IN
        ('requested', 'approved', 'signed', 'broadcast', 'mined', 'confirmed', 'failed', 'replaced')),
    approvals_required INTEGER NOT NULL,
    nonce              INTEGER,
    tx_hash            TEXT,
    failure_reason     TEXT,
    created_at         INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL
) STRICT;
CREATE INDEX withdrawals_velocity ON withdrawals (account_id, asset, created_at);
CREATE INDEX withdrawals_status ON withdrawals (status);

CREATE TABLE withdrawal_transitions (
    withdrawal_id TEXT    NOT NULL REFERENCES withdrawals (id),
    seq           INTEGER NOT NULL,
    from_status   TEXT    NOT NULL,
    to_status     TEXT    NOT NULL,
    reason        TEXT    NOT NULL,
    at            INTEGER NOT NULL,
    PRIMARY KEY (withdrawal_id, seq)
) STRICT;

CREATE TABLE approvals (
    withdrawal_id TEXT    NOT NULL REFERENCES withdrawals (id),
    approver_id   TEXT    NOT NULL,
    decision      TEXT    NOT NULL CHECK (decision IN ('approve', 'reject')),
    created_at    INTEGER NOT NULL,
    PRIMARY KEY (withdrawal_id, approver_id)
) STRICT;

CREATE TABLE idempotency_keys (
    client_id     TEXT    NOT NULL,
    key           TEXT    NOT NULL,
    request_hash  TEXT    NOT NULL,
    status_code   INTEGER NOT NULL,
    response_body BLOB    NOT NULL,
    created_at    INTEGER NOT NULL,
    PRIMARY KEY (client_id, key)
) STRICT;

CREATE TABLE allowlist (
    account_id TEXT    NOT NULL,
    address    TEXT    NOT NULL,          -- checksummed hex
    label      TEXT    NOT NULL,
    added_at   INTEGER NOT NULL,
    active_at  INTEGER NOT NULL,          -- added_at + cool-down
    PRIMARY KEY (account_id, address)
) STRICT;

-- Transactional outbox: every state transition commits the intent of its side effect here.
CREATE TABLE outbox (
    seq        INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT    NOT NULL,
    ref_id     TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    not_before INTEGER NOT NULL,
    attempts   INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    done_at    INTEGER
) STRICT;
CREATE INDEX outbox_pending ON outbox (done_at, not_before, seq);

-- Outgoing transactions -------------------------------------------------------------------------

-- One row per hot-wallet nonce in use. Released reservations delete their row, so allocation
-- is always "lowest free nonce at or above the floor", which keeps the sequence contiguous.
CREATE TABLE nonce_slots (
    nonce               INTEGER PRIMARY KEY,
    purpose             TEXT    NOT NULL CHECK (purpose IN ('withdrawal', 'sweep', 'filler')),
    ref_id              TEXT    NOT NULL,
    state               TEXT    NOT NULL CHECK (state IN ('reserved', 'pending', 'included', 'final')),
    included_hash       TEXT,
    included_block      INTEGER,
    included_block_hash TEXT,
    inclusion_ref       TEXT,             -- ledger ref of the current inclusion entry
    inclusion_epoch     INTEGER NOT NULL DEFAULT 0, -- bumped per inclusion so refs never repeat
    last_broadcast_head INTEGER NOT NULL DEFAULT 0,
    cancel_requested    INTEGER NOT NULL DEFAULT 0,
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,
    UNIQUE (purpose, ref_id)
) STRICT;
CREATE INDEX nonce_slots_state ON nonce_slots (state);

-- Every signed transaction is persisted here before it is ever broadcast (write-ahead).
CREATE TABLE tx_attempts (
    hash         TEXT PRIMARY KEY,
    nonce        INTEGER NOT NULL REFERENCES nonce_slots (nonce),
    seq          INTEGER NOT NULL,
    kind         TEXT    NOT NULL CHECK (kind IN ('original', 'bump', 'cancel')),
    raw          BLOB    NOT NULL,
    to_addr      TEXT    NOT NULL,
    value        TEXT    NOT NULL,
    data         BLOB    NOT NULL,
    gas_limit    INTEGER NOT NULL,
    max_fee      TEXT    NOT NULL,
    tip          TEXT    NOT NULL,
    status       TEXT    NOT NULL CHECK (status IN ('signed', 'sent', 'rejected')),
    created_at   INTEGER NOT NULL,
    sent_at      INTEGER,
    UNIQUE (nonce, seq)
) STRICT;

-- Deposits ---------------------------------------------------------------------------------------

CREATE TABLE deposit_addresses (
    account_id TEXT PRIMARY KEY,
    salt       TEXT    NOT NULL UNIQUE,
    address    TEXT    NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE deposits (
    tx_hash      TEXT    NOT NULL,
    log_index    INTEGER NOT NULL,
    block_number INTEGER NOT NULL,
    block_hash   TEXT    NOT NULL,
    account_id   TEXT    NOT NULL,
    forwarder    TEXT    NOT NULL,
    asset        TEXT    NOT NULL,
    sender       TEXT    NOT NULL,
    amount       TEXT    NOT NULL,
    status       TEXT    NOT NULL CHECK (status IN ('pending', 'credited')),
    swept_by     TEXT,
    seen_at      INTEGER NOT NULL,
    credited_at  INTEGER,
    PRIMARY KEY (tx_hash, log_index)
) STRICT;
CREATE INDEX deposits_status ON deposits (status, block_number);

CREATE TABLE scanned_blocks (
    number INTEGER PRIMARY KEY,
    hash   TEXT NOT NULL
) STRICT;

CREATE TABLE sweeps (
    id         TEXT PRIMARY KEY,
    asset      TEXT    NOT NULL,
    status     TEXT    NOT NULL CHECK (status IN ('pending', 'done', 'failed')),
    swept      TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE sweep_items (
    sweep_id  TEXT NOT NULL REFERENCES sweeps (id),
    salt      TEXT NOT NULL,
    forwarder TEXT NOT NULL,
    PRIMARY KEY (sweep_id, forwarder)
) STRICT;

-- Reconciliation and audit -------------------------------------------------------------------------

CREATE TABLE reconciliations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    block_number INTEGER NOT NULL,
    block_hash   TEXT    NOT NULL,
    ok           INTEGER NOT NULL,
    report       TEXT    NOT NULL,        -- JSON
    created_at   INTEGER NOT NULL
) STRICT;

CREATE TABLE audit_events (
    seq     INTEGER PRIMARY KEY AUTOINCREMENT,
    at      INTEGER NOT NULL,
    type    TEXT    NOT NULL,
    actor   TEXT    NOT NULL,
    subject TEXT    NOT NULL,
    data    TEXT    NOT NULL              -- JSON object
) STRICT;
