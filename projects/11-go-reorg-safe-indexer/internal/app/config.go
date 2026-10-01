// SPDX-License-Identifier: MIT

// Package app wires the indexer's components into the `indexer` command: flag and environment
// parsing, logging, store selection, and the index / serve / verify subcommands.
package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/bindings"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/postgres"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlstore"
)

// EnvPrefix prefixes the environment variable of every flag: --rpc-url is INDEXER_RPC_URL.
const EnvPrefix = "INDEXER_"

// listFlag is a repeatable flag that also accepts comma-separated values.
type listFlag []string

func (l *listFlag) String() string { return strings.Join(*l, ",") }

func (l *listFlag) Set(v string) error {
	for part := range strings.SplitSeq(v, ",") {
		if p := strings.TrimSpace(part); p != "" {
			*l = append(*l, p)
		}
	}
	return nil
}

// options holds every flag; each subcommand registers the subset it uses.
type options struct {
	rpcURL        string
	db            string
	tokens        listFlag
	vaults        listFlag
	startBlock    uint64
	confirmations uint64
	pollInterval  time.Duration
	reorgWindow   int
	retention     uint64
	concurrency   int
	initialRange  uint64
	maxRange      uint64
	headerBatch   int
	rpcTimeout    time.Duration
	bloomCheck    bool
	listen        string
	maxLag        uint64
	staleAfter    time.Duration
	readonly      bool
	maxDiffs      int
	logLevel      string
	logFormat     string
}

func (o *options) registerCommon(fs *flag.FlagSet) {
	fs.StringVar(&o.db, "db", "indexer.db", "SQLite file path (in-memory databases are rejected), or a postgres:// URL")
	fs.StringVar(&o.logLevel, "log-level", "info", "debug, info, warn or error")
	fs.StringVar(&o.logFormat, "log-format", "json", "json or text")
}

func (o *options) registerRPC(fs *flag.FlagSet) {
	fs.StringVar(&o.rpcURL, "rpc-url", "", "JSON-RPC endpoint of the node (required)")
	fs.DurationVar(&o.rpcTimeout, "rpc-timeout", 20*time.Second, "timeout of each JSON-RPC request")
	fs.IntVar(&o.headerBatch, "header-batch", 100, "eth_getBlockByNumber calls per JSON-RPC batch")
	fs.IntVar(&o.concurrency, "concurrency", 4, "segments fetched in parallel during backfill")
	fs.Uint64Var(&o.initialRange, "initial-range", 100, "initial eth_getLogs block span")
	fs.Uint64Var(&o.maxRange, "max-range", 2000, "maximum eth_getLogs block span")
	fs.BoolVar(&o.bloomCheck, "bloom-check", false, "re-query range-mode blocks whose bloom matches but which came back without any logs (repairs whole-block omissions by the provider; partial omissions need indexer verify against another endpoint)")
	fs.Uint64Var(&o.confirmations, "confirmations", 12, "blocks after which data counts as safe; blocks inside this window are fetched per block by hash")
}

func (o *options) registerIndexer(fs *flag.FlagSet) {
	fs.Var(&o.tokens, "token", "ERC-20 token address to index (repeatable, or comma-separated)")
	fs.Var(&o.vaults, "vault", "ERC-4626 vault to index, as 0xVAULT (asset read on chain) or 0xVAULT=0xASSET (repeatable)")
	fs.Uint64Var(&o.startBlock, "start-block", 0, "first block to index (the contracts' deployment block)")
	fs.DurationVar(&o.pollInterval, "poll-interval", 2*time.Second, "head polling interval once caught up")
	fs.IntVar(&o.reorgWindow, "reorg-window", 1024, "recent headers kept to locate fork points (the deepest reorg handled automatically)")
	fs.Uint64Var(&o.retention, "event-retention", 100_000, "SSE outbox events kept for resumption")
}

func (o *options) registerHTTP(fs *flag.FlagSet) {
	fs.StringVar(&o.listen, "listen", "127.0.0.1:8080", "HTTP listen address (port 0 picks a free port)")
	fs.Uint64Var(&o.maxLag, "max-lag", 10, "largest head lag in blocks at which /readyz reports ready")
	fs.DurationVar(&o.staleAfter, "stale-after", time.Minute, "/readyz fails when the last successful sync is older than this")
}

// parse parses args, then fills every flag not given on the command line from its
// environment variable.
func parse(fs *flag.FlagSet, args []string, env func(string) string) error {
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	var err error
	fs.VisitAll(func(f *flag.Flag) {
		if set[f.Name] || err != nil {
			return
		}
		name := EnvPrefix + strings.ToUpper(strings.ReplaceAll(f.Name, "-", "_"))
		if v := env(name); v != "" {
			if e := fs.Set(f.Name, v); e != nil {
				err = fmt.Errorf("%s: %w", name, e)
			}
		}
	})
	return err
}

func newLogger(w io.Writer, level, format string) (*slog.Logger, error) {
	var lvl slog.Level
	if err := lvl.UnmarshalText([]byte(level)); err != nil {
		return nil, fmt.Errorf("invalid --log-level %q", level)
	}
	opts := &slog.HandlerOptions{Level: lvl}
	switch format {
	case "json":
		return slog.New(slog.NewJSONHandler(w, opts)), nil
	case "text":
		return slog.New(slog.NewTextHandler(w, opts)), nil
	default:
		return nil, fmt.Errorf("invalid --log-format %q (json or text)", format)
	}
}

// openStore opens SQLite or PostgreSQL depending on the DSN. On failure it returns a nil
// interface, never a typed nil pointer wrapped in one (callers compare the result with nil).
func openStore(ctx context.Context, dsn string) (store.Store, error) {
	open := func(ctx context.Context, dsn string) (*sqlstore.Store, error) { return sqlite.Open(ctx, dsn) }
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		open = postgres.Open
	}
	s, err := open(ctx, dsn)
	if err != nil {
		return nil, err
	}
	return s, nil
}

func parseAddress(flagName, s string) (common.Address, error) {
	if !common.IsHexAddress(s) {
		return common.Address{}, fmt.Errorf("--%s: %q is not a hex address", flagName, s)
	}
	return common.HexToAddress(s), nil
}

// contracts resolves --token and --vault into the watched set, reading each vault's asset()
// on chain unless it was given explicitly.
func (o *options) contracts(ctx context.Context, src *chain.RPCSource) (decode.Contracts, error) {
	c := decode.Contracts{Vaults: map[common.Address]common.Address{}}
	for _, t := range o.tokens {
		a, err := parseAddress("token", t)
		if err != nil {
			return c, err
		}
		c.Tokens = append(c.Tokens, a)
	}
	vault := bindings.NewFixtureVault()
	for _, v := range o.vaults {
		vs, as, explicit := strings.Cut(v, "=")
		va, err := parseAddress("vault", vs)
		if err != nil {
			return c, err
		}
		if explicit {
			aa, err := parseAddress("vault", as)
			if err != nil {
				return c, err
			}
			c.Vaults[va] = aa
			continue
		}
		var out []byte
		err = chain.Retry(ctx, chain.RetryPolicy{Attempts: 10}, func() error {
			var err error
			out, err = src.Eth().CallContract(ctx, ethereum.CallMsg{To: &va, Data: vault.PackAsset()}, nil)
			return err
		})
		if err != nil {
			return c, fmt.Errorf("--vault %s: read asset(): %w", va, err)
		}
		asset, err := vault.UnpackAsset(out)
		if err != nil {
			return c, fmt.Errorf("--vault %s: decode asset(): %w (is it an ERC-4626 vault?)", va, err)
		}
		c.Vaults[va] = asset
	}
	if len(c.Addresses()) == 0 {
		return c, errors.New("nothing to index: pass at least one --token or --vault")
	}
	return c, nil
}

func getenv(name string) string { return os.Getenv(name) }
