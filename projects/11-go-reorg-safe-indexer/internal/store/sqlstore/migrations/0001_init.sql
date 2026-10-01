-- SPDX-License-Identifier: MIT
--
-- Shared by SQLite and PostgreSQL: only types and syntax both accept (BIGINT, TEXT,
-- ON CONFLICT, CREATE ... IF NOT EXISTS). Addresses and hashes are lower-case 0x hex, and
-- uint256 amounts are base-10 TEXT: neither backend has a native uint256, and exact integer
-- arithmetic happens in Go (math/big).

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Single-row progress marker, moved by compare-and-swap in the same transaction as the data.
-- tip_number = -1 means nothing is indexed.
CREATE TABLE IF NOT EXISTS checkpoint (
    id         INTEGER PRIMARY KEY,
    tip_number BIGINT  NOT NULL,
    tip_hash   TEXT    NOT NULL,
    chain_head BIGINT  NOT NULL,
    next_seq   BIGINT  NOT NULL,
    updated_at BIGINT  NOT NULL
);
INSERT INTO checkpoint (id, tip_number, tip_hash, chain_head, next_seq, updated_at)
VALUES (1, -1, '', 0, 1, 0)
ON CONFLICT (id) DO NOTHING;

-- Recent canonical headers (the reorg window); older rows are pruned.
CREATE TABLE IF NOT EXISTS blocks (
    number      BIGINT PRIMARY KEY,
    hash        TEXT   NOT NULL UNIQUE,
    parent_hash TEXT   NOT NULL,
    block_time  BIGINT NOT NULL
);

-- Every log emitted by a watched contract, decoded or not.
CREATE TABLE IF NOT EXISTS logs (
    block_hash   TEXT   NOT NULL,
    log_index    BIGINT NOT NULL,
    block_number BIGINT NOT NULL,
    tx_hash      TEXT   NOT NULL,
    tx_index     BIGINT NOT NULL,
    address      TEXT   NOT NULL,
    topics       TEXT   NOT NULL,
    data         TEXT   NOT NULL,
    PRIMARY KEY (block_hash, log_index)
);
CREATE INDEX IF NOT EXISTS logs_by_position ON logs (block_number, log_index);

CREATE TABLE IF NOT EXISTS transfers (
    block_hash   TEXT   NOT NULL,
    log_index    BIGINT NOT NULL,
    block_number BIGINT NOT NULL,
    block_time   BIGINT NOT NULL,
    tx_hash      TEXT   NOT NULL,
    token        TEXT   NOT NULL,
    from_addr    TEXT   NOT NULL,
    to_addr      TEXT   NOT NULL,
    value        TEXT   NOT NULL,
    PRIMARY KEY (block_hash, log_index)
);
CREATE INDEX IF NOT EXISTS transfers_by_position ON transfers (block_number, log_index);
CREATE INDEX IF NOT EXISTS transfers_by_token ON transfers (token, block_number, log_index);
CREATE INDEX IF NOT EXISTS transfers_by_from ON transfers (from_addr, block_number, log_index);
CREATE INDEX IF NOT EXISTS transfers_by_to ON transfers (to_addr, block_number, log_index);

CREATE TABLE IF NOT EXISTS vault_events (
    block_hash   TEXT   NOT NULL,
    log_index    BIGINT NOT NULL,
    block_number BIGINT NOT NULL,
    block_time   BIGINT NOT NULL,
    tx_hash      TEXT   NOT NULL,
    vault        TEXT   NOT NULL,
    kind         TEXT   NOT NULL,
    sender       TEXT   NOT NULL,
    owner        TEXT   NOT NULL,
    receiver     TEXT   NOT NULL,
    assets       TEXT   NOT NULL,
    shares       TEXT   NOT NULL,
    PRIMARY KEY (block_hash, log_index)
);
CREATE INDEX IF NOT EXISTS vault_events_by_vault ON vault_events (vault, block_number, log_index);
CREATE INDEX IF NOT EXISTS vault_events_by_position ON vault_events (block_number, log_index);

-- One point per (block, vault) in which the vault's total assets or total supply changed.
CREATE TABLE IF NOT EXISTS share_prices (
    block_hash   TEXT   NOT NULL,
    vault        TEXT   NOT NULL,
    block_number BIGINT NOT NULL,
    block_time   BIGINT NOT NULL,
    total_assets TEXT   NOT NULL,
    total_supply TEXT   NOT NULL,
    price_wad    TEXT,
    PRIMARY KEY (block_hash, vault)
);
CREATE INDEX IF NOT EXISTS share_prices_by_vault ON share_prices (vault, block_number);
CREATE INDEX IF NOT EXISTS share_prices_by_position ON share_prices (block_number);

-- Current (latest-view) balances; zero balances have no row.
CREATE TABLE IF NOT EXISTS balances (
    token   TEXT NOT NULL,
    holder  TEXT NOT NULL,
    balance TEXT NOT NULL,
    PRIMARY KEY (token, holder)
);
CREATE INDEX IF NOT EXISTS balances_by_holder ON balances (holder, token);

-- Supply derived from mints (Transfer from 0x0) and burns (Transfer to 0x0).
CREATE TABLE IF NOT EXISTS supplies (
    token  TEXT PRIMARY KEY,
    supply TEXT NOT NULL
);

-- Transactional outbox behind the SSE stream; written in the same transaction as the data.
CREATE TABLE IF NOT EXISTS events (
    seq          BIGINT PRIMARY KEY,
    kind         TEXT   NOT NULL,
    block_number BIGINT NOT NULL,
    payload      TEXT   NOT NULL
);

CREATE TABLE IF NOT EXISTS reorgs (
    id              BIGINT PRIMARY KEY,
    detected_at     BIGINT NOT NULL,
    old_tip_number  BIGINT NOT NULL,
    old_tip_hash    TEXT   NOT NULL,
    ancestor_number BIGINT NOT NULL,
    ancestor_hash   TEXT   NOT NULL,
    new_head_number BIGINT NOT NULL,
    new_head_hash   TEXT   NOT NULL,
    depth           BIGINT NOT NULL
);
