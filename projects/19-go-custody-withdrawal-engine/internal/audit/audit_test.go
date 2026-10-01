// SPDX-License-Identifier: MIT

package audit_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

func setup(t *testing.T) (*store.DB, string, *audit.Shipper) {
	t.Helper()
	dir := t.TempDir()
	db, err := store.OpenWith(context.Background(), filepath.Join(dir, "a.db"), store.Options{Synchronous: "OFF"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	path := filepath.Join(dir, "audit.jsonl")
	return db, path, audit.NewShipper(db, path, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
}

func record(t *testing.T, db *store.DB, n int) {
	t.Helper()
	for i := range n {
		err := db.WithTx(context.Background(), func(tx *store.Tx) error {
			return audit.Record(context.Background(), tx, time.Unix(int64(i), 0), audit.Event{
				Type: "test.event", Actor: "tester", Subject: "s", Data: map[string]any{"i": i}})
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func verifyFile(t *testing.T, path string) (audit.VerifyResult, error) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return audit.Verify(bytes.NewReader(b))
}

func TestShipAndVerify(t *testing.T) {
	db, path, sh := setup(t)
	record(t, db, 5)
	n, err := sh.Ship(context.Background())
	if err != nil || n != 5 {
		t.Fatalf("shipped %d, %v", n, err)
	}
	record(t, db, 3)
	if n, _ := sh.Ship(context.Background()); n != 3 {
		t.Fatalf("second ship %d", n)
	}
	if n, _ := sh.Ship(context.Background()); n != 0 {
		t.Fatalf("idle ship %d", n)
	}
	res, err := verifyFile(t, path)
	if err != nil || res.Lines != 8 || res.LastSeq != 8 {
		t.Fatalf("verify: %+v %v", res, err)
	}
}

// A new shipper (process restart) resumes from the file: nothing is duplicated or lost.
func TestShipResumesAfterRestart(t *testing.T) {
	db, path, sh := setup(t)
	record(t, db, 4)
	if _, err := sh.Ship(context.Background()); err != nil {
		t.Fatal(err)
	}
	record(t, db, 2)
	sh2 := audit.NewShipper(db, path, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	if n, err := sh2.Ship(context.Background()); err != nil || n != 2 {
		t.Fatalf("resumed ship %d %v", n, err)
	}
	if res, err := verifyFile(t, path); err != nil || res.Lines != 6 {
		t.Fatalf("%+v %v", res, err)
	}
}

// A crash in the middle of a write leaves a torn last line; the next shipper truncates it and
// re-ships that event, keeping the chain intact.
func TestShipRepairsTornTail(t *testing.T) {
	db, path, sh := setup(t)
	record(t, db, 3)
	if _, err := sh.Ship(context.Background()); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	lines := strings.SplitAfter(string(b), "\n")
	torn := lines[0] + lines[1] + lines[2][:len(lines[2])/2]
	if err := os.WriteFile(path, []byte(torn), 0o600); err != nil {
		t.Fatal(err)
	}
	sh2 := audit.NewShipper(db, path, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	if n, err := sh2.Ship(context.Background()); err != nil || n != 1 {
		t.Fatalf("repair ship %d %v", n, err)
	}
	if res, err := verifyFile(t, path); err != nil || res.Lines != 3 || res.LastSeq != 3 {
		t.Fatalf("%+v %v", res, err)
	}
}

func TestVerifyDetectsTampering(t *testing.T) {
	db, path, sh := setup(t)
	record(t, db, 4)
	if _, err := sh.Ship(context.Background()); err != nil {
		t.Fatal(err)
	}
	orig, _ := os.ReadFile(path)
	lines := strings.SplitAfter(string(orig), "\n")
	cases := map[string]string{
		"edited payload":  strings.Replace(string(orig), `"i":1`, `"i":9`, 1),
		"deleted line":    lines[0] + lines[2] + lines[3],
		"reordered lines": lines[1] + lines[0] + lines[2] + lines[3],
		"not json":        lines[0] + "garbage\n",
	}
	for name, content := range cases {
		if _, err := audit.Verify(strings.NewReader(content)); err == nil {
			t.Errorf("%s: tampering not detected", name)
		}
	}
	if _, err := audit.Verify(strings.NewReader("")); err != nil {
		t.Fatalf("empty log should verify: %v", err)
	}
}

func TestRunShipsOnShutdown(t *testing.T) {
	db, path, sh := setup(t)
	record(t, db, 2)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { sh.Run(ctx, time.Hour); close(done) }()
	cancel()
	<-done
	if res, err := verifyFile(t, path); err != nil || res.Lines != 2 {
		t.Fatalf("%+v %v", res, err)
	}
}

// A corrupt line in the middle of the file is not a torn write: the shipper must refuse to append
// and leave the file exactly as it found it (it used to cut everything from that line on and
// re-ship the database's copy, silently replacing the file's history).
func TestShipRefusesADamagedFile(t *testing.T) {
	cases := []struct {
		name   string
		damage func(lines []string) string
		want   string
	}{
		{"corrupt middle line", func(l []string) string { return l[0] + "garbage\n" + l[2] + l[3] }, "does not verify"},
		{"edited middle line", func(l []string) string { return l[0] + strings.Replace(l[1], `"i":1`, `"i":7`, 1) + l[2] + l[3] }, "does not verify"},
		{"chain recomputed over different content", func(l []string) string {
			return rechain(t, l, func(x *audit.Line) {
				if x.Seq == 4 {
					x.Subject = "forged"
				}
			})
		}, "differs from the database"},
		{"ahead of the database", func(l []string) string { return l[0] + l[1] + l[2] + l[3] + nextLine(t, l[3], 6) }, "which the database does not have"},
		{"last line not the database's", func(l []string) string { return l[0] + l[1] + l[2] + l[3] + nextLine(t, l[3], 5) }, "differs from the database"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			db, path, sh := setup(t)
			record(t, db, 4)
			if _, err := sh.Ship(context.Background()); err != nil {
				t.Fatal(err)
			}
			orig, _ := os.ReadFile(path)
			damaged := tc.damage(strings.SplitAfter(string(orig), "\n"))
			if err := os.WriteFile(path, []byte(damaged), 0o600); err != nil {
				t.Fatal(err)
			}
			record(t, db, 1)
			failures := prometheus.NewCounter(prometheus.CounterOpts{Name: "f"})
			sh2 := audit.NewShipper(db, path, slog.New(slog.NewTextHandler(io.Discard, nil)), failures)
			for range 2 {
				n, err := sh2.Ship(context.Background())
				if err == nil {
					t.Fatalf("shipped %d lines onto a damaged file", n)
				}
				if !strings.Contains(err.Error(), tc.want) {
					t.Fatalf("error %q, want it to say %q", err, tc.want)
				}
			}
			if after, _ := os.ReadFile(path); string(after) != damaged {
				t.Fatal("the shipper modified a damaged file")
			}
			if testutil.ToFloat64(failures) != 2 {
				t.Fatalf("failures counted %v, want 2", testutil.ToFloat64(failures))
			}
		})
	}
}

// nextLine returns a line with sequence seq, correctly chained after prev, whose content is not
// the database's.
func nextLine(t *testing.T, prev string, seq int64) string {
	t.Helper()
	var p audit.Line
	if err := json.Unmarshal([]byte(prev), &p); err != nil {
		t.Fatal(err)
	}
	l := audit.Line{Seq: seq, At: p.At, Type: "forged.event", Actor: "x", Subject: "y", Data: json.RawMessage(`{}`), Prev: p.Hash}
	b, _ := json.Marshal(l)
	sum := sha256.Sum256(b)
	l.Hash = hex.EncodeToString(sum[:])
	b, _ = json.Marshal(l)
	return string(b) + "\n"
}

// rechain rewrites lines after edit, recomputing every hash: what an attacker with write access
// to the file alone can do, since the chain is not keyed.
func rechain(t *testing.T, lines []string, edit func(*audit.Line)) string {
	t.Helper()
	prev := audit.Genesis
	var out strings.Builder
	for _, raw := range lines {
		if strings.TrimSpace(raw) == "" {
			continue
		}
		var l audit.Line
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			t.Fatal(err)
		}
		edit(&l)
		l.Prev, l.Hash = prev, ""
		b, _ := json.Marshal(l)
		sum := sha256.Sum256(b)
		l.Hash = hex.EncodeToString(sum[:])
		b, _ = json.Marshal(l)
		out.Write(b)
		out.WriteByte('\n')
		prev = l.Hash
	}
	return out.String()
}

// VerifyAgainst anchors the file to the database, which catches what the bare chain cannot:
// lines cut from the end, and a file rewritten with a recomputed chain.
func TestVerifyAgainstTheDatabase(t *testing.T) {
	db, path, sh := setup(t)
	record(t, db, 5)
	if _, err := sh.Ship(context.Background()); err != nil {
		t.Fatal(err)
	}
	orig, _ := os.ReadFile(path)
	lines := strings.SplitAfter(string(orig), "\n")
	check := func(content string) (audit.VerifyResult, error) {
		var res audit.VerifyResult
		err := db.ReadTx(context.Background(), func(q store.Querier) error {
			var err error
			res, err = audit.VerifyAgainst(context.Background(), strings.NewReader(content), q)
			return err
		})
		return res, err
	}
	if res, err := check(string(orig)); err != nil || !res.DatabaseChecked || res.Lines != 5 {
		t.Fatalf("intact file: %+v %v", res, err)
	}
	truncated := lines[0] + lines[1] + lines[2]
	if _, err := audit.Verify(strings.NewReader(truncated)); err != nil {
		t.Fatalf("the bare chain cannot tell (precondition): %v", err)
	}
	if _, err := check(truncated); err == nil || !strings.Contains(err.Error(), "database has events 4 to 5") {
		t.Fatalf("trailing lines deleted: %v", err)
	}
	forged := rechain(t, lines, func(l *audit.Line) {
		if l.Seq == 2 {
			l.Actor = "someone-else"
		}
	})
	if _, err := audit.Verify(strings.NewReader(forged)); err != nil {
		t.Fatalf("the bare chain cannot tell (precondition): %v", err)
	}
	if _, err := check(forged); err == nil || !strings.Contains(err.Error(), "differs from the database") {
		t.Fatalf("recomputed chain: %v", err)
	}
	dropped := rechain(t, append(lines[:1:1], lines[2:]...), func(*audit.Line) {})
	if _, err := check(dropped); err == nil || !strings.Contains(err.Error(), "deleted or inserted") {
		t.Fatalf("middle line dropped and chain recomputed: %v", err)
	}
}
