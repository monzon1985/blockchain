// SPDX-License-Identifier: MIT

package app

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/indexer"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
)

// VerifyResult is the outcome of a verification.
type VerifyResult struct {
	Tip         string
	Counts      map[string]int
	Differences []store.Difference
	Stale       bool
	Elapsed     time.Duration
}

// Verify snapshots the database behind st, reindexes the same chain from scratch up to the
// snapshot's tip into a temporary SQLite database, and diffs the two. Contracts, start block and
// chain id come from the database's fingerprint, so verification cannot silently use a
// different configuration than the indexer did.
func Verify(ctx context.Context, st store.Store, o *options, log *slog.Logger) (*VerifyResult, error) {
	started := time.Now()
	fp, found, err := indexer.ReadFingerprint(ctx, st)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, fmt.Errorf("database has never been indexed")
	}
	var original *store.Snapshot
	if err := st.View(ctx, func(r store.Reader) error {
		var err error
		original, err = r.Snapshot()
		return err
	}); err != nil {
		return nil, err
	}
	res := &VerifyResult{Tip: "none", Counts: original.Counts()}
	if original.Tip == nil {
		res.Elapsed = time.Since(started)
		return res, nil
	}
	res.Tip = original.Tip.String()

	src, err := o.dial(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer src.Close()
	chainID, err := src.ChainID(ctx)
	if err != nil {
		return nil, err
	}
	if chainID != fp.ChainID {
		return nil, fmt.Errorf("node is chain %d, database was indexed from chain %d", chainID, fp.ChainID)
	}

	dir, err := os.MkdirTemp("", "indexer-verify-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	fresh, err := sqlite.Open(ctx, filepath.Join(dir, "reindex.db"))
	if err != nil {
		return nil, err
	}
	defer fresh.Close()

	stop := original.Tip.Number
	cfg := indexer.Config{
		Start:          fp.Start,
		Confirmations:  o.confirmations,
		PollInterval:   50 * time.Millisecond,
		ReorgWindow:    1 << 20,
		EventRetention: 1 << 40,
		StopAt:         &stop,
		Contracts:      fp.Contracts(),
		Fetch:          o.fetchConfig(),
	}
	eng, err := indexer.New(ctx, cfg, src, fresh, nil, log)
	if err != nil {
		return nil, err
	}
	log.Info("reindexing from scratch", "start", fp.Start, "tip", res.Tip)
	if err := eng.SyncUntil(ctx, stop); err != nil {
		return nil, fmt.Errorf("reindex: %w", err)
	}
	var reindexed *store.Snapshot
	if err := fresh.View(ctx, func(r store.Reader) error {
		var err error
		reindexed, err = r.Snapshot()
		return err
	}); err != nil {
		return nil, err
	}
	if reindexed.Tip == nil || reindexed.Tip.Hash != original.Tip.Hash {
		res.Stale = true
	} else {
		res.Differences = store.Diff(original, reindexed)
	}
	res.Elapsed = time.Since(started)
	return res, nil
}

func runVerify(ctx context.Context, o *options, log *slog.Logger, stdout io.Writer) (int, error) {
	st, err := openStore(ctx, o.db)
	if err != nil {
		return ExitFailure, err
	}
	defer st.Close()
	res, err := Verify(ctx, st, o, log)
	if err != nil {
		return ExitFailure, err
	}
	fmt.Fprintf(stdout, "database tip: %s\n", res.Tip)
	tables := slices.Clone(store.SnapshotTables)
	for _, t := range tables {
		fmt.Fprintf(stdout, "  %-13s %d rows\n", t, res.Counts[t])
	}
	switch {
	case res.Stale:
		fmt.Fprintln(stdout, "STALE: the database tip is no longer on the canonical chain (a reorg the indexer has not processed yet); run verify again")
		return ExitStale, nil
	case len(res.Differences) == 0:
		fmt.Fprintf(stdout, "OK: identical to a from-scratch reindex of the canonical chain (%s)\n", res.Elapsed.Round(time.Millisecond))
		return ExitOK, nil
	}
	fmt.Fprintf(stdout, "MISMATCH: %d differences against a from-scratch reindex\n", len(res.Differences))
	for i, d := range res.Differences {
		if i == o.maxDiffs {
			fmt.Fprintf(stdout, "  ... %d more\n", len(res.Differences)-i)
			break
		}
		fmt.Fprintf(stdout, "  %s\n", d)
	}
	return ExitDiff, nil
}
