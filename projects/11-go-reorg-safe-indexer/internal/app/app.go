// SPDX-License-Identifier: MIT

package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/api"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fetch"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/indexer"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/metrics"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

// Exit codes.
const (
	ExitOK      = 0
	ExitDiff    = 1 // verify found differences
	ExitFailure = 2 // usage or runtime error
	ExitStale   = 3 // verify: the database tip is no longer canonical
)

const usage = `indexer: reorg-safe EVM event indexer

Usage:
  indexer index  [flags]   index the chain (serves /healthz, /readyz, /metrics)
  indexer serve  [flags]   serve the REST + SSE API (and index, unless --readonly)
  indexer verify [flags]   reindex from scratch into a temporary database and diff

Every flag can also be set through its environment variable: --rpc-url is INDEXER_RPC_URL.
Run "indexer <command> -h" for the flags of a command.
`

// Env reads environment variables (tests substitute a map).
type Env func(string) string

// Main runs the command line and returns the process exit code.
func Main(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	return MainEnv(ctx, args, stdout, stderr, getenv)
}

// MainEnv is Main with an explicit environment.
func MainEnv(ctx context.Context, args []string, stdout, stderr io.Writer, env Env) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return ExitFailure
	}
	var o options
	fs := flag.NewFlagSet("indexer "+args[0], flag.ContinueOnError)
	fs.SetOutput(stderr)
	var run func(context.Context, *options, *slog.Logger, io.Writer) (int, error)
	switch args[0] {
	case "index":
		o.registerCommon(fs)
		o.registerRPC(fs)
		o.registerIndexer(fs)
		o.registerHTTP(fs)
		run = runIndex
	case "serve":
		o.registerCommon(fs)
		o.registerRPC(fs)
		o.registerIndexer(fs)
		o.registerHTTP(fs)
		fs.BoolVar(&o.readonly, "readonly", false, "serve an existing database without indexing (another process runs `indexer index`)")
		run = runServe
	case "verify":
		o.registerCommon(fs)
		o.registerRPC(fs)
		fs.IntVar(&o.maxDiffs, "max-diffs", 20, "differences printed before truncating the list (the count is always exact)")
		run = runVerify
	case "-h", "--help", "help":
		fmt.Fprint(stdout, usage)
		return ExitOK
	default:
		fmt.Fprintf(stderr, "unknown command %q\n\n%s", args[0], usage)
		return ExitFailure
	}
	if err := parse(fs, args[1:], env); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return ExitOK
		}
		fmt.Fprintln(stderr, "error:", err)
		return ExitFailure
	}
	log, err := newLogger(stderr, o.logLevel, o.logFormat)
	if err != nil {
		fmt.Fprintln(stderr, "error:", err)
		return ExitFailure
	}
	code, err := run(ctx, &o, log, stdout)
	if err != nil {
		log.Error("fatal", "command", args[0], "err", err)
		if code == ExitOK {
			code = ExitFailure
		}
	}
	return code
}

// deps are the components shared by index and serve.
type deps struct {
	st      store.Store
	src     *chain.RPCSource
	m       *metrics.Metrics
	engine  *indexer.Engine
	chainID uint64
}

func (d *deps) close() {
	if d.src != nil {
		d.src.Close()
	}
	if d.st != nil {
		_ = d.st.Close()
	}
}

func (o *options) fetchConfig() fetch.Config {
	return fetch.Config{
		InitialSpan: o.initialRange,
		MaxSpan:     o.maxRange,
		Concurrency: o.concurrency,
		BloomCheck:  o.bloomCheck,
	}
}

func (o *options) dial(ctx context.Context, m *metrics.Metrics) (*chain.RPCSource, error) {
	if o.rpcURL == "" {
		return nil, errors.New("--rpc-url (or INDEXER_RPC_URL) is required")
	}
	opts := chain.RPCOptions{CallTimeout: o.rpcTimeout, HeaderBatch: o.headerBatch}
	if m != nil {
		opts.Observe = m.ObserveRPC
	}
	return chain.Dial(ctx, o.rpcURL, opts)
}

// setup opens the store, dials the node and builds the engine.
func setup(ctx context.Context, o *options, log *slog.Logger) (*deps, error) {
	d := &deps{m: metrics.New()}
	var err error
	if d.st, err = openStore(ctx, o.db); err != nil {
		return d, err
	}
	if d.src, err = o.dial(ctx, d.m); err != nil {
		return d, err
	}
	contracts, err := o.contracts(ctx, d.src)
	if err != nil {
		return d, err
	}
	cfg := indexer.Config{
		Start:          o.startBlock,
		Confirmations:  o.confirmations,
		PollInterval:   o.pollInterval,
		ReorgWindow:    o.reorgWindow,
		EventRetention: o.retention,
		Contracts:      contracts,
		Fetch:          o.fetchConfig(),
	}
	if d.engine, err = indexer.New(ctx, cfg, d.src, d.st, d.m, log); err != nil {
		return d, err
	}
	d.chainID = d.engine.ChainID()
	return d, nil
}

func engineHealth(e *indexer.Engine) api.HealthFunc {
	return func(context.Context) (api.Health, error) {
		s := e.Status()
		return api.Health{Tip: s.Tip, ChainHead: s.ChainHead, UpdatedAt: s.LastSync, LastError: s.LastError}, nil
	}
}

func storeHealth(st store.Store) api.HealthFunc {
	return func(ctx context.Context) (api.Health, error) {
		var h api.Health
		err := st.View(ctx, func(r store.Reader) error {
			cp, err := r.Checkpoint()
			if err != nil {
				return err
			}
			h.Tip, h.ChainHead = cp.Tip, cp.ChainHead
			if cp.UpdatedAt > 0 {
				h.UpdatedAt = time.UnixMilli(cp.UpdatedAt)
			}
			return nil
		})
		return h, err
	}
}

// serveHTTP listens on addr and serves h until ctx ends, then shuts down gracefully.
func serveHTTP(ctx context.Context, addr string, h http.Handler, onShutdown func(), log *slog.Logger) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", addr, err)
	}
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 2 * time.Minute}
	if onShutdown != nil {
		srv.RegisterOnShutdown(onShutdown)
	}
	log.Info("http listening", "addr", ln.Addr().String())
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(ln) }()
	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("http shutdown: %w", err)
	}
	if err := <-errCh; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	log.Info("http stopped")
	return nil
}

// runBoth runs the engine (if any) and the HTTP server until ctx ends or one of them fails.
func runBoth(ctx context.Context, engine *indexer.Engine, addr string, srv *api.Server, log *slog.Logger) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var (
		wg       sync.WaitGroup
		mu       sync.Mutex
		firstErr error
	)
	record := func(err error) {
		if err == nil {
			return
		}
		mu.Lock()
		if firstErr == nil {
			firstErr = err
		}
		mu.Unlock()
		cancel()
	}
	if engine != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			record(engine.Run(ctx))
			cancel()
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		record(serveHTTP(ctx, addr, srv.Handler(), srv.CloseStreams, log))
	}()
	wg.Wait()
	return firstErr
}

func runIndex(ctx context.Context, o *options, log *slog.Logger, _ io.Writer) (int, error) {
	d, err := setup(ctx, o, log)
	defer d.close()
	if err != nil {
		return ExitFailure, err
	}
	srv := api.New(api.Config{ChainID: d.chainID, Confirmations: o.confirmations, Contracts: d.engine.Config().Contracts,
		MaxLag: o.maxLag, StaleAfter: o.staleAfter, OpsOnly: true}, d.st, engineHealth(d.engine), d.m, nil, log)
	return ExitOK, runBoth(ctx, d.engine, o.listen, srv, log)
}

func runServe(ctx context.Context, o *options, log *slog.Logger, _ io.Writer) (int, error) {
	if o.readonly {
		return serveReadonly(ctx, o, log)
	}
	d, err := setup(ctx, o, log)
	defer d.close()
	if err != nil {
		return ExitFailure, err
	}
	srv := api.New(api.Config{ChainID: d.chainID, Confirmations: o.confirmations, Contracts: d.engine.Config().Contracts,
		MaxLag: o.maxLag, StaleAfter: o.staleAfter, PollInterval: time.Second}, d.st, engineHealth(d.engine), d.m, nil, log)
	d.engine.OnCommit = srv.Hub().Notify
	return ExitOK, runBoth(ctx, d.engine, o.listen, srv, log)
}

// serveReadonly serves a database another process indexes; contracts and chain come from the
// database's fingerprint.
func serveReadonly(ctx context.Context, o *options, log *slog.Logger) (int, error) {
	st, err := openStore(ctx, o.db)
	if err != nil {
		return ExitFailure, err
	}
	defer st.Close()
	fp, found, err := indexer.ReadFingerprint(ctx, st)
	if err != nil {
		return ExitFailure, err
	}
	if !found {
		return ExitFailure, fmt.Errorf("%s has never been indexed; run `indexer index` first", o.db)
	}
	m := metrics.New()
	srv := api.New(api.Config{ChainID: fp.ChainID, Confirmations: o.confirmations, Contracts: fp.Contracts(),
		MaxLag: o.maxLag, StaleAfter: o.staleAfter, PollInterval: 500 * time.Millisecond}, st, storeHealth(st), m, nil, log)
	return ExitOK, runBoth(ctx, nil, o.listen, srv, log)
}
