// SPDX-License-Identifier: MIT

package indexer

import (
	"context"
	"fmt"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/rpcfault"
)

// scenario drives a fake chain through random blocks, reorgs of random depth (shorter, equal
// and longer replacement forks), and engine restarts, interleaved with partial syncs.
type scenario struct {
	rng   *rand.Rand
	fc    *fakechain.Chain
	world *fakechain.World
	// maxHead is the highest block number the chain ever reached: no engine can have indexed
	// anything above it.
	maxHead uint64
}

func newScenario(seed uint64) *scenario {
	return &scenario{
		rng:   rand.New(rand.NewPCG(seed, seed*0x9e3779b97f4a7c15+1)),
		fc:    fakechain.New(31337),
		world: fakechain.NewWorld(6),
	}
}

func (s *scenario) mine() {
	n := 1 + s.rng.IntN(3)
	for range n {
		s.fc.Mine(s.world.Block(s.rng, s.fc.Canonical(0), s.rng.IntN(6)))
	}
	s.maxHead = max(s.maxHead, s.fc.Head().Number)
}

// outgrow mines until the head is above every block the chain ever had. A node whose head is an
// ancestor of the indexed tip is indistinguishable from a lagging node, so the engine waits for
// a conflicting block; past maxHead, every stale indexed block is contradicted.
func (s *scenario) outgrow() {
	for target := s.maxHead; s.fc.Head().Number <= target; {
		s.mine()
	}
}

// reorg replaces up to maxDepth blocks. Returns the depth used.
func (s *scenario) reorg(maxDepth int) int {
	head := int(s.fc.Head().Number)
	if head < 2 {
		return 0
	}
	depth := 1 + s.rng.IntN(min(maxDepth, head-1))
	replacement := max(0, depth-1+s.rng.IntN(4)) // shorter, equal or longer fork
	canonical := s.fc.Canonical(0)
	base := canonical[:len(canonical)-depth]
	var blocks [][]fakechain.LogSpec
	for range replacement {
		blocks = append(blocks, s.world.BlockAfter(s.rng, base, blocks, s.rng.IntN(6)))
	}
	if err := s.fc.Reorg(depth, blocks); err != nil {
		panic(err)
	}
	s.maxHead = max(s.maxHead, s.fc.Head().Number)
	return depth
}

// seedCount reads the number of seeds from an environment variable (CI runs deeper), falling
// back to def, or to short under -short.
func seedCount(env string, def, short int) int {
	if v, err := strconv.Atoi(os.Getenv(env)); err == nil && v > 0 {
		return v
	}
	if testing.Short() {
		return short
	}
	return def
}

// TestIncrementalEqualsReindex is the core property on the in-memory chain: after any sequence
// of blocks, reorgs, restarts and partial syncs, the incrementally maintained database equals
// (1) a from-scratch reindex of the canonical chain and (2) an independent oracle, and an SSE
// consumer that applies `transfer` and undoes `retract` events ends with exactly the stored
// transfers.
func TestIncrementalEqualsReindex(t *testing.T) {
	seeds := seedCount("INDEXER_PROP_SEEDS", 40, 8)
	total := newTally(t, "TestIncrementalEqualsReindex")
	for seed := range uint64(seeds) {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			t.Parallel()
			s := newScenario(seed)
			cfg := testConfig(s.world)
			st := openStore(t)
			eng := newEngine(t, cfg, s.fc, st)
			cons := newConsumer()
			reorgs, restarts := 0, 0
			for range 70 {
				switch op := s.rng.IntN(10); {
				case op < 5:
					s.mine()
				case op < 8:
					if s.reorg(12) > 0 {
						reorgs++
					}
				case op == 8:
					eng = newEngine(t, cfg, s.fc, st) // restart: state comes from the database only
					restarts++
				default:
					cons.drain(t, st)
				}
				if s.rng.IntN(3) > 0 {
					syncToHead(t, eng, s.fc)
				}
			}
			s.outgrow()
			syncToTip(t, eng, s.fc)
			cons.drain(t, st)

			incremental := snapshot(t, st)
			fresh := openStore(t)
			syncToTip(t, newEngine(t, cfg, s.fc, fresh), s.fc)
			requireSame(t, "incremental vs reindex", incremental, snapshot(t, fresh))
			requireSame(t, "incremental vs oracle", incremental, oracleSnapshot(t, s.fc, cfg.Contracts, cfg.Start))
			cons.requireMatches(t, st)
			if incremental.Rows() == 0 {
				t.Fatal("scenario indexed nothing")
			}
			t.Logf("rows=%d reorgs=%d restarts=%d retracted=%d tip=%d", incremental.Rows(), reorgs, restarts, cons.retracted, s.fc.Head().Number)
			total.add("seeds", 1)
			total.add("rows_compared", int64(incremental.Rows()))
			total.add("reorgs", int64(reorgs))
			total.add("restarts", int64(restarts))
			total.add("transfer_retractions", int64(cons.retracted))
			total.add("chain_blocks", int64(s.fc.Head().Number))
		})
	}
}

// TestConcurrentFaultyNode runs the engine in the background against the fake chain served over
// HTTP through the fault injector (latency, 5xx, JSON-RPC errors, truncated bodies, hung calls,
// provider log limits, silently dropped blocks with the bloom check on) while the chain mines
// and reorganises underneath it and the engine is restarted. The property must still hold.
func TestConcurrentFaultyNode(t *testing.T) {
	seeds := seedCount("INDEXER_FAULT_SEEDS", 6, 2)
	total := newTally(t, "TestConcurrentFaultyNode")
	for seed := range uint64(seeds) {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			t.Parallel()
			s := newScenario(1000 + seed)
			faults := rpcfault.New(nil, rpcfault.Config{
				Seed:          seed,
				HTTPErrorRate: 0.03,
				RPCErrorRate:  0.03,
				TruncateRate:  0.03,
				TimeoutRate:   0.01,
				MaxLatency:    2 * time.Millisecond,
				MaxLogs:       12,
				DropBlockRate: 0.1,
			})
			srv := httptest.NewServer(s.fc.Handler())
			t.Cleanup(srv.Close)
			ctx := context.Background()
			src, err := chain.Dial(ctx, srv.URL, chain.RPCOptions{
				HTTPClient:  &http.Client{Transport: faults},
				CallTimeout: 300 * time.Millisecond,
				HeaderBatch: 7,
			})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(src.Close)

			cfg := testConfig(s.world)
			cfg.Fetch.BloomCheck = true
			st := openStore(t)

			var (
				mu      sync.Mutex
				runErr  error
				cancel  context.CancelFunc
				stopped chan struct{}
			)
			start := func() {
				eng := newEngine(t, cfg, src, st)
				runCtx, c := context.WithCancel(ctx)
				done := make(chan struct{})
				mu.Lock()
				cancel, stopped = c, done
				mu.Unlock()
				go func() {
					defer close(done)
					if err := eng.Run(runCtx); err != nil {
						mu.Lock()
						runErr = err
						mu.Unlock()
					}
				}()
			}
			stop := func() {
				mu.Lock()
				c, done := cancel, stopped
				mu.Unlock()
				c()
				<-done
			}
			start()
			for range 60 {
				switch op := s.rng.IntN(10); {
				case op < 6:
					s.mine()
				case op < 9:
					s.reorg(10)
				default:
					stop()
					start()
				}
				time.Sleep(time.Duration(s.rng.IntN(15)) * time.Millisecond)
			}
			s.outgrow()
			head := s.fc.Head()
			// Wait for convergence with faults still on.
			deadline := time.Now().Add(60 * time.Second)
			for {
				var tip *chain.BlockRef
				cp, err := readCheckpoint(st)
				if err != nil {
					t.Fatal(err)
				}
				tip = cp
				if tip != nil && tip.Hash == head.Hash {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("engine did not converge to %s (tip %v, faults %v)", head.Ref(), tip, faults.Stats.Snapshot())
				}
				time.Sleep(10 * time.Millisecond)
			}
			stop()
			mu.Lock()
			if runErr != nil {
				t.Fatalf("engine stopped with %v", runErr)
			}
			mu.Unlock()

			incremental := snapshot(t, st)
			fresh := openStore(t)
			syncToTip(t, newEngine(t, cfg, s.fc, fresh), s.fc)
			requireSame(t, "incremental vs reindex", incremental, snapshot(t, fresh))
			requireSame(t, "incremental vs oracle", incremental, oracleSnapshot(t, s.fc, cfg.Contracts, cfg.Start))
			cons := newConsumer()
			cons.drain(t, st)
			cons.requireMatches(t, st)
			t.Logf("rows=%d retracted=%d faults=%v", incremental.Rows(), cons.retracted, faults.Stats.Snapshot())
			total.add("seeds", 1)
			total.add("rows_compared", int64(incremental.Rows()))
			total.add("transfer_retractions", int64(cons.retracted))
			total.addAll("fault_", faults.Stats.Snapshot())
		})
	}
}
