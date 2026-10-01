// SPDX-License-Identifier: MIT

// Command mutationcheck proves that the test suite catches the bugs this engine has had: it
// copies the module to a temporary directory, re-introduces one bug at a time (each mutant is
// an exact source replacement that must apply), runs the tests that are supposed to catch it,
// and requires them to fail. A mutant that survives, or that does not compile, fails the check.
//
//	go run ./internal/tools/mutationcheck            # every mutant
//	go run ./internal/tools/mutationcheck -list      # names only
//	go run ./internal/tools/mutationcheck -only a,b  # a subset
//
// The originals are never touched: every mutant runs in its own copy.
package main

import (
	"bufio"
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

// edit is one exact replacement; Old must occur exactly once in File.
type edit struct {
	File, Old, New string
}

// mutant is a bug and the tests that must catch it.
type mutant struct {
	Name    string
	Bug     string
	Edits   []edit
	Pkg     string   // package to test
	Run     string   // -run pattern
	Env     []string // extra environment
	Timeout time.Duration
}

var mutants = []mutant{
	{
		Name: "refund-in-follow-up-tx",
		Bug:  "the refund of a replaced withdrawal is committed in a second transaction after the state change",
		Edits: []edit{{File: "internal/withdrawal/dispatcher.go",
			Old: "		if err := transition(ctx, tx, o.s.metrics, now, &w, Replaced, \"engine\", \"cancellation mined at the same nonce\"); err != nil {\n			return err\n		}\n		return refund(ctx, tx, now, w)",
			New: "		if err := transition(ctx, tx, o.s.metrics, now, &w, Replaced, \"engine\", \"cancellation mined at the same nonce\"); err != nil {\n			return err\n		}\n		tx.OnCommit(func() { _ = o.s.db.WithTx(ctx, func(tx2 *store.Tx) error { return refund(ctx, tx2, now, w) }) })\n		return nil"}},
		Pkg: "./internal/app/", Run: "^TestStorageFaultInjection$", Env: []string{"CUSTODY_FAULT_STRIDE=1"}, Timeout: 40 * time.Minute,
	},
	{
		Name: "scanner-trusts-shorter-head",
		Bug:  "after the head moves backwards the scanner rewinds to the new head without checking the blocks below it",
		Edits: []edit{{File: "internal/deposit/scanner.go",
			Old: "	fork, anchor, err := sc.findFork(ctx, top)\n	if err != nil {\n		return cursor, err\n	}\n",
			New: "	fork, anchor, err := sc.findFork(ctx, top)\n	if err != nil {\n		return cursor, err\n	}\n	if cursor > head.Number {\n		fork, anchor = head.Number, head.Hash\n	}\n"}},
		Pkg: "./internal/app/", Run: "^TestScenarioShorterForkReplacingBlocksBelowTheHead$",
	},
	{
		Name: "credit-stalls-on-stale-row",
		Bug:  "crediting returns silently at the first pending deposit whose block is no longer canonical",
		Edits: []edit{{File: "internal/deposit/scanner.go",
			Old: "			sc.metrics.DepositsStale.Inc()\n",
			New: "			if true {\n				return nil\n			}\n			sc.metrics.DepositsStale.Inc()\n"}},
		Pkg: "./internal/app/", Run: "^TestScenarioStalePendingDepositIsRescanned$",
	},
	{
		Name: "prune-drops-the-anchor",
		Bug:  "pruning forgets every hash below the window, so a long scan range leaves nothing to rewind to",
		Edits: []edit{{File: "internal/deposit/scanner.go",
			Old: "`DELETE FROM scanned_blocks WHERE number < (SELECT MAX(number) FROM scanned_blocks WHERE number <= ?)`",
			New: "`DELETE FROM scanned_blocks WHERE number < ?`"}},
		Pkg: "./internal/app/", Run: "^TestScenarioReorgRightAfterALongScanRange$",
	},
	{
		Name: "reservation-kept-on-failed-estimate",
		Bug:  "a retry whose gas estimate fails leaves the reservation of an interrupted run in place",
		Edits: []edit{{File: "internal/txmgr/manager.go",
			Old: "if relErr := m.releaseUnsigned(ctx, purpose, ref, \"gas estimation failed on retry\"); relErr != nil {",
			New: "if relErr := error(nil); relErr != nil {"}},
		Pkg: "./internal/app/", Run: "^(TestScenarioCrashBeforeSignThenLiquidityDrop|TestScenarioReservationDoesNotDeadlockSweeps)$",
	},
	{
		Name: "aborted-signature-ends-the-intent",
		Bug:  "a signature discarded because the reservation was reclaimed marks the signing intent done",
		Edits: []edit{{File: "internal/withdrawal/dispatcher.go",
			Old: "			if cur.Status == Approved {\n				retry = true\n				return nil\n			}\n",
			New: "			_, _ = cur, retry\n"}},
		Pkg: "./internal/app/", Run: "^TestScenarioReservationReclaimedWhileSigning$",
	},
	{
		Name: "abandoned-filler-kept",
		Bug:  "a gap filler reservation abandoned before signing is never released",
		Edits: []edit{{File: "internal/txmgr/gaps.go",
			Old: "if u.r.purpose == signer.PurposeFiller || stale {",
			New: "if stale {"}},
		Pkg: "./internal/app/", Run: "^TestScenarioAbandonedFillerReservationIsReclaimed$",
	},
	{
		Name: "no-stale-reservation-safety-net",
		Bug:  "a reservation nothing will ever retry is kept forever",
		Edits: []edit{{File: "internal/txmgr/gaps.go",
			Old: "stale := head.Number >= first+m.cfg.GapGraceBlocks && now.Sub(u.created) >= ReservationTTL",
			New: "stale := head.Number >= first+m.cfg.GapGraceBlocks && now.Sub(u.created) >= ReservationTTL && false"}},
		Pkg: "./internal/app/", Run: "^TestScenarioStaleReservationIsReclaimed$",
	},
	{
		Name: "ledger-check-outside-a-snapshot",
		Bug:  "reconciliation reads the postings and the cached balances in separate statements",
		Edits: []edit{
			{File: "internal/ledger/check.go",
				Old: "		err := db.ReadTx(ctx, func(q store.Querier) error {\n			f, err := readEntries(ctx, q, c.cursor, math.MaxInt64, c.chunk())",
				New: "		err := func(q store.Querier) error {\n			f, err := readEntries(ctx, q, c.cursor, math.MaxInt64, c.chunk())"},
			{File: "internal/ledger/check.go",
				Old: "				snap, err = Balances(ctx, q)\n			}\n			return err\n		})",
				New: "				snap, err = Balances(ctx, q)\n			}\n			return err\n		}(db)"},
		},
		Pkg: "./internal/app/", Run: "^TestReconciliationUnderConcurrentWrites$",
	},
	{
		Name: "empty-sweep-claims-later-deposits",
		Bug:  "a sweep that moved nothing attributes every deposit of its own block to itself",
		Edits: []edit{{File: "internal/deposit/sweeper.go",
			Old: "sameBlockBefore := int64(-1)",
			New: "sameBlockBefore := int64(^uint(0) >> 1)"}},
		Pkg: "./internal/app/", Run: "^TestScenarioEmptySweepDoesNotClaimLaterDeposits$",
	},
	{
		Name: "audit-appends-to-damaged-log",
		Bug:  "the audit shipper appends to a log whose chain does not verify",
		Edits: []edit{{File: "internal/audit/audit.go",
			Old: "	res, last, err := verify(bytes.NewReader(complete), nil)\n	if err != nil {",
			New: "	res, last, err := verify(bytes.NewReader(complete), nil)\n	if err != nil && false {"}},
		Pkg: "./internal/audit/", Run: "^TestShipRefusesADamagedFile$",
	},
	{
		Name: "token-hash-length-only",
		Bug:  "configuration accepts any 64-character token hash, which then never authenticates",
		Edits: []edit{{File: "internal/config/config.go",
			Old: "	return err == nil && len(b) == sha256.Size && s == strings.ToLower(s)",
			New: "	return len(s) == 64 || (err == nil && len(b) == sha256.Size)"}},
		Pkg: "./internal/config/", Run: "^TestParseRejects$",
	},
	{
		Name: "fee-bump-rounds-down",
		Bug:  "a replacement raises its fees by 12.5 % rounded down",
		Edits: []edit{{File: "internal/fees/fees.go",
			Old: "	if rem.Sign() != 0 {\n		out.Add(out, big.NewInt(1))\n	}",
			New: "	_ = rem"}},
		Pkg: "./internal/fees/", Run: "^FuzzBump$",
	},
}

func main() {
	list := flag.Bool("list", false, "list the mutants and exit")
	only := flag.String("only", "", "comma-separated mutant names to run (default: all)")
	flag.Parse()
	if *list {
		for _, m := range mutants {
			fmt.Printf("%-36s %s\n", m.Name, m.Bug)
		}
		return
	}
	root, err := os.Getwd()
	if err != nil {
		fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		fatal(fmt.Errorf("run from the module root: %w", err))
	}
	selected := mutants
	if *only != "" {
		names := strings.Split(*only, ",")
		selected = slices.DeleteFunc(slices.Clone(mutants), func(m mutant) bool { return !slices.Contains(names, m.Name) })
		if len(selected) != len(names) {
			fatal(fmt.Errorf("unknown mutant in %q (see -list)", *only))
		}
	}
	survivors := 0
	for _, m := range selected {
		start := time.Now()
		caught, detail, err := run(root, m)
		switch {
		case err != nil:
			survivors++
			fmt.Printf("ERROR     %-36s %v\n", m.Name, err)
		case caught:
			fmt.Printf("caught    %-36s %s (%s)\n", m.Name, detail, time.Since(start).Round(time.Second))
		default:
			survivors++
			fmt.Printf("SURVIVED  %-36s %s\n", m.Name, detail)
		}
	}
	fmt.Printf("%d of %d mutants caught\n", len(selected)-survivors, len(selected))
	if survivors > 0 {
		os.Exit(1)
	}
}

var failLine = regexp.MustCompile(`(?m)^\s*--- FAIL: (\S+)`)

// run applies m to a fresh copy of the module and runs its tests. A mutant is caught when the
// tests compile and at least one of them fails.
func run(root string, m mutant) (bool, string, error) {
	tmp, err := os.MkdirTemp("", "custody-mutant-")
	if err != nil {
		return false, "", err
	}
	defer os.RemoveAll(tmp)
	if err := copyModule(root, tmp); err != nil {
		return false, "", err
	}
	for _, e := range m.Edits {
		p := filepath.Join(tmp, filepath.FromSlash(e.File))
		b, err := os.ReadFile(p)
		if err != nil {
			return false, "", err
		}
		if n := bytes.Count(b, []byte(e.Old)); n != 1 {
			return false, "", fmt.Errorf("%s: the mutation applies %d times, want exactly once (the code moved?)", e.File, n)
		}
		if err := os.WriteFile(p, bytes.Replace(b, []byte(e.Old), []byte(e.New), 1), 0o600); err != nil {
			return false, "", err
		}
	}
	timeout := m.Timeout
	if timeout == 0 {
		timeout = 10 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout+time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "go", "test", "-count=1", "-timeout", timeout.String(), "-v", "-run", m.Run, m.Pkg)
	cmd.Dir = tmp
	cmd.Env = append(append(os.Environ(), "CGO_ENABLED=0"), m.Env...)
	out, runErr := cmd.CombinedOutput()
	if strings.Contains(string(out), "[build failed]") || strings.Contains(string(out), "[setup failed]") {
		return false, "", fmt.Errorf("the mutant does not compile:\n%s", tail(out))
	}
	var failed []string
	for _, f := range failLine.FindAllStringSubmatch(string(out), -1) {
		failed = append(failed, f[1])
	}
	if runErr == nil || len(failed) == 0 {
		return false, "every test passed", nil
	}
	leaves := 0
	for _, f := range failed {
		if strings.Contains(f, "/") || !hasChild(failed, f) {
			leaves++
		}
	}
	return true, fmt.Sprintf("%d failing test(s), e.g. %s", leaves, failed[0]), nil
}

func hasChild(names []string, parent string) bool {
	for _, n := range names {
		if strings.HasPrefix(n, parent+"/") {
			return true
		}
	}
	return false
}

// copyModule copies the Go module (sources, go.mod, go.sum) without the Foundry project and
// local build or run artifacts.
func copyModule(src, dst string) error {
	skip := map[string]bool{"contracts": true, ".devnet": true, "bin": true, ".coverage": true, "covdata": true, ".git": true}
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		if d.IsDir() {
			if skip[rel] {
				return filepath.SkipDir
			}
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		if !d.Type().IsRegular() {
			return nil
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.Create(filepath.Join(dst, rel))
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, in); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	})
}

func tail(b []byte) string {
	sc := bufio.NewScanner(bytes.NewReader(b))
	var lines []string
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if len(lines) > 25 {
		lines = lines[len(lines)-25:]
	}
	return strings.Join(lines, "\n")
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "mutationcheck:", err)
	os.Exit(2)
}
