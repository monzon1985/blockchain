// SPDX-License-Identifier: MIT

package cli_test

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/cli"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

func run(t *testing.T, stdin string, args ...string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	code := cli.Run(context.Background(), args, cli.IO{In: strings.NewReader(stdin), Out: &out, Err: &errb})
	return code, out.String(), errb.String()
}

func TestHashToken(t *testing.T) {
	code, out, _ := run(t, "secret-token\n", "hash-token")
	if code != 0 || strings.TrimSpace(out) != policy.HashToken("secret-token") {
		t.Fatalf("code %d out %q", code, out)
	}
	if code, _, errOut := run(t, "", "hash-token"); code != 1 || !strings.Contains(errOut, "expected a token") {
		t.Fatalf("empty stdin: %d %s", code, errOut)
	}
	if code, _, _ := run(t, "   \n", "hash-token"); code != 1 {
		t.Fatal("blank token accepted")
	}
}

func TestKeystoreNew(t *testing.T) {
	dir := t.TempDir()
	pass := filepath.Join(dir, "pass")
	must(t, os.WriteFile(pass, []byte("long enough password\n"), 0o600))
	ks := filepath.Join(dir, "keys", "hot.json")
	code, out, errOut := run(t, "", "keystore-new", "-out", ks, "-password-file", pass, "-light")
	if code != 0 || !common.IsHexAddress(strings.TrimSpace(out)) {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	s, err := signer.LoadKeystore(ks, pass)
	if err != nil || s.Address() != common.HexToAddress(strings.TrimSpace(out)) {
		t.Fatalf("keystore does not decrypt to the printed address: %v", err)
	}
	if code, _, errOut := run(t, "", "keystore-new", "-out", ks, "-password-file", pass, "-light"); code != 1 || !strings.Contains(errOut, "refusing to overwrite") {
		t.Fatalf("overwrite allowed: %d %s", code, errOut)
	}
	short := filepath.Join(dir, "short")
	must(t, os.WriteFile(short, []byte("abc"), 0o600))
	if code, _, _ := run(t, "", "keystore-new", "-out", filepath.Join(dir, "k2.json"), "-password-file", short); code != 1 {
		t.Fatal("short password accepted")
	}
	if code, _, _ := run(t, "", "keystore-new"); code != 1 {
		t.Fatal("missing flags accepted")
	}
	if code, _, _ := run(t, "", "keystore-new", "-out", filepath.Join(dir, "k3.json"), "-password-file", filepath.Join(dir, "missing")); code != 1 {
		t.Fatal("missing password file accepted")
	}
	if code, _, _ := run(t, "", "keystore-new", "-bogus"); code != 1 {
		t.Fatal("unknown flag accepted")
	}
}

func TestAuditVerify(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "a.jsonl")
	must(t, os.WriteFile(empty, nil, 0o600))
	if code, out, _ := run(t, "", "audit-verify", "-file", empty); code != 0 || !strings.Contains(out, "0 lines") {
		t.Fatalf("%d %s", code, out)
	}
	bad := filepath.Join(dir, "b.jsonl")
	must(t, os.WriteFile(bad, []byte(`{"seq":1,"prev":"x","hash":"y"}`+"\n"), 0o600))
	if code, _, _ := run(t, "", "audit-verify", "-file", bad); code != 1 {
		t.Fatal("broken chain accepted")
	}
	if code, _, _ := run(t, "", "audit-verify", "-file", filepath.Join(dir, "missing")); code != 1 {
		t.Fatal("missing file accepted")
	}

	// With -db the file must hold exactly the database's events: lines cut from the end are
	// caught, which the bare chain cannot do.
	ctx := context.Background()
	dbPath, logPath := filepath.Join(dir, "custody.db"), filepath.Join(dir, "audit.jsonl")
	db, err := store.Open(ctx, dbPath)
	if err != nil {
		t.Fatal(err)
	}
	for i := range 3 {
		must(t, db.WithTx(ctx, func(tx *store.Tx) error {
			return audit.Record(ctx, tx, time.Unix(int64(i), 0), audit.Event{Type: "t", Actor: "a", Subject: "s"})
		}))
	}
	if _, err := audit.NewShipper(db, logPath, slog.New(slog.NewTextHandler(io.Discard, nil)), nil).Ship(ctx); err != nil {
		t.Fatal(err)
	}
	db.Close()
	if code, out, errOut := run(t, "", "audit-verify", "-file", logPath, "-db", dbPath); code != 0 || !strings.Contains(out, "identical to the database") {
		t.Fatalf("intact log: %d %s %s", code, out, errOut)
	}
	b, _ := os.ReadFile(logPath)
	lines := strings.SplitAfter(string(b), "\n")
	must(t, os.WriteFile(logPath, []byte(lines[0]+lines[1]), 0o600))
	if code, out, _ := run(t, "", "audit-verify", "-file", logPath); code != 0 || !strings.Contains(out, "not compared with the database") {
		t.Fatalf("the bare chain still verifies a cut file: %d %s", code, out)
	}
	if code, _, errOut := run(t, "", "audit-verify", "-file", logPath, "-db", dbPath); code != 1 || !strings.Contains(errOut, "database has events 3 to 3") {
		t.Fatalf("cut log accepted against the database: %d %s", code, errOut)
	}
	if code, _, errOut := run(t, "", "audit-verify", "-file", logPath, "-db", filepath.Join(dir, "nope.db")); code != 1 || errOut == "" {
		t.Fatalf("missing database accepted: %d %s", code, errOut)
	}
	if _, err := os.Stat(filepath.Join(dir, "nope.db")); err == nil {
		t.Fatal("audit-verify created a database")
	}
}

func TestUsageAndErrors(t *testing.T) {
	if code, out, _ := run(t, "", "help"); code != 0 || !strings.Contains(out, "keystore-new") {
		t.Fatalf("help: %d %s", code, out)
	}
	if code, _, errOut := run(t, "", "frobnicate"); code != 1 || !strings.Contains(errOut, "unknown command") {
		t.Fatalf("unknown command: %d %s", code, errOut)
	}
	dir := t.TempDir()
	if code, _, _ := run(t, "", "serve", "-config", filepath.Join(dir, "missing.json")); code != 1 {
		t.Fatal("missing config accepted")
	}
	if code, _, _ := run(t, "", "-config", filepath.Join(dir, "missing.json")); code != 1 {
		t.Fatal("serve is not the default command")
	}
	cfg := filepath.Join(dir, "custody.json")
	must(t, os.WriteFile(cfg, []byte(validConfig), 0o600))
	t.Setenv(failpoint.EnvVar, "not_a_failpoint")
	if code, _, errOut := run(t, "", "serve", "-config", cfg); code != 1 || !strings.Contains(errOut, "unknown name") {
		t.Fatalf("bad failpoint: %d %s", code, errOut)
	}
	t.Setenv(failpoint.EnvVar, "")
	if code, _, errOut := run(t, "", "serve", "-config", cfg); code != 1 || !strings.Contains(errOut, "keystore") {
		t.Fatalf("missing keystore: %d %s", code, errOut)
	}
	if code, _, _ := run(t, "", "serve", "-nope"); code != 1 {
		t.Fatal("bad flag accepted")
	}
}

const validConfig = `{
  "chain": {"rpc_url": "http://127.0.0.1:1", "chain_id": 31337},
  "database": {"path": "custody.db"},
  "audit": {"path": "audit.jsonl"},
  "hot_wallet": {"keystore": "missing.json", "password_file": "missing.pass"},
  "fees": {"min_tip_wei": "1", "max_fee_wei": "100"},
  "assets": [{"symbol": "tUSD", "token": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
              "max_per_tx": "1", "velocity_24h": "1", "approval_threshold": "1"}],
  "policy": {"approvals_required": 1, "approvers": [{"id": "a", "token_sha256": "` + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" + `"}]},
  "clients": [{"id": "gw", "token_sha256": "` + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" + `"}],
  "deposits": {"factory": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"}
}`

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
