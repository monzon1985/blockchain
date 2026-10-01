#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Runs the PostgreSQL adapter tests (`-tags postgres`) against a throwaway cluster: initdb into a
# temporary directory, start it on a free port with trust authentication on 127.0.0.1 (TCP only:
# no Unix socket, so nothing is written to /var/run/postgresql), run the tests, stop the cluster
# (by its data directory) and delete it. Nothing touches an existing server. CI uses a postgres
# service container instead and runs the same `go test` command.
#
# The port is probed by binding port 0 and released before PostgreSQL binds it, so another
# process can take it in between; a start that fails to bind is retried on a new port.
#
# Usage: bash script/test-postgres.sh [extra go test flags]
#        bash script/test-postgres.sh -- <command...>   (run any command with the DSN exported,
#                                                        e.g. -- bash script/coverage.sh postgres)
# Env:   PG_BIN  directory holding initdb/pg_ctl (default: found on PATH). Debian and Ubuntu
#                keep them out of PATH: PG_BIN=/usr/lib/postgresql/<major>/bin
set -euo pipefail

cd "$(dirname "$0")/.."
bin() { if [[ -n "${PG_BIN:-}" ]]; then printf '%s/%s' "$PG_BIN" "$1"; else command -v "$1"; fi; }
INITDB=$(bin initdb) || { echo "initdb not found (set PG_BIN)" >&2; exit 1; }
PGCTL=$(bin pg_ctl) || { echo "pg_ctl not found (set PG_BIN)" >&2; exit 1; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

DATA=$(mktemp -d)
LOG="$DATA/server.log"
cleanup() {
  "$PGCTL" -D "$(native "$DATA")" -m fast stop >/dev/null 2>&1 || true
  rm -rf "$DATA"
}
trap cleanup EXIT

"$INITDB" -D "$(native "$DATA")" -U postgres -A trust -E UTF8 >/dev/null
started=""
for attempt in 1 2 3 4 5; do
  PORT=$(go run ./internal/tools/freeport)
  # `unix_socket_directories=` (empty) disables the Unix socket: the DSN uses TCP, and the
  # packaged default (/var/run/postgresql on Debian) is not writable by an ordinary user.
  # `lc_messages=C` keeps the server log in English, so the bind failure below is recognisable.
  if "$PGCTL" -D "$(native "$DATA")" -l "$(native "$LOG")" -w \
    -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c lc_messages=C" start >/dev/null; then
    started=1
    break
  fi
  if ! grep -qiE 'could not bind|could not create listen socket|address already in use' "$LOG" 2>/dev/null; then
    cat "$LOG" >&2 || true
    exit 1
  fi
  echo "test-postgres: port $PORT was taken before PostgreSQL bound it (attempt $attempt); retrying" >&2
  : >"$LOG"
done
[[ -n "$started" ]] || { echo "test-postgres: could not start PostgreSQL" >&2; exit 1; }

export INDEXER_TEST_POSTGRES_DSN="postgres://postgres@127.0.0.1:${PORT}/postgres?sslmode=disable"
if [[ "${1:-}" == "--" ]]; then
  shift
  "$@"
else
  CGO_ENABLED=0 go test -count=1 -tags postgres "$@" ./internal/store/postgres/...
fi
