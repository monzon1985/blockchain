// SPDX-License-Identifier: MIT

// Package cli implements the custodyd command line so that every subcommand, including the
// server's start-up and graceful shutdown, can be exercised from tests.
package cli

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/api"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/app"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/audit"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/failpoint"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/store"
)

// Usage lists the subcommands.
const Usage = `usage: custodyd <command> [flags]

commands:
  serve -config custody.json                          run the service (default)
  hash-token                                          read a bearer token on stdin, print its SHA-256
  keystore-new -out FILE -password-file FILE [-light] create an encrypted hot-wallet keystore
  audit-verify -file audit.jsonl [-db custody.db]     verify the audit log's hash chain and, with -db,
                                                      that it holds exactly the database's events

CUSTODY_FAILPOINT=<name> crashes the process at a named point of the withdrawal state machine
(chaos testing only).`

// IO bundles the process streams.
type IO struct {
	In       io.Reader
	Out, Err io.Writer
}

// Run executes the command line in args and returns the process exit code. ctx is cancelled on
// SIGINT/SIGTERM by main; cancelling it shuts the server down gracefully.
func Run(ctx context.Context, args []string, stdio IO) int {
	cmd := "serve"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve(ctx, args, stdio)
	case "hash-token":
		err = hashToken(stdio)
	case "keystore-new":
		err = keystoreNew(args, stdio)
	case "audit-verify":
		err = auditVerify(ctx, args, stdio)
	case "help", "-h", "--help":
		fmt.Fprintln(stdio.Out, Usage)
		return 0
	default:
		err = fmt.Errorf("unknown command %q\n%s", cmd, Usage)
	}
	if err != nil {
		fmt.Fprintln(stdio.Err, "custodyd:", err)
		return 1
	}
	return 0
}

func newFlags(name string, stdio IO) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stdio.Err)
	return fs
}

func serve(ctx context.Context, args []string, stdio IO) error {
	fs := newFlags("serve", stdio)
	cfgPath := fs.String("config", "custody.json", "configuration file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		return err
	}
	log := slog.New(slog.NewJSONHandler(stdio.Err, &slog.HandlerOptions{Level: slog.LevelInfo}))
	fp, err := failpoint.FromEnv()
	if err != nil {
		return err
	}
	if fp.Armed() {
		log.Warn("failpoints armed: this process will crash on purpose", "env", os.Getenv(failpoint.EnvVar))
	}
	node, err := chain.Dial(ctx, cfg.Chain.RPCURL)
	if err != nil {
		return err
	}
	defer node.Close()
	key, err := signer.LoadKeystore(cfg.HotWallet.Keystore, cfg.HotWallet.PasswordFile)
	if err != nil {
		return err
	}
	a, err := app.New(ctx, cfg, app.Deps{Chain: node, Signer: key, Clock: clock.Real{}, Failpoints: fp, Log: log})
	if err != nil {
		return err
	}
	defer a.Close()
	return a.Serve(ctx, api.NewRouter(a), cfg.HTTP.Listen, cfg.HTTP.AddrFile)
}

func hashToken(stdio IO) error {
	sc := bufio.NewScanner(stdio.In)
	if !sc.Scan() {
		return errors.New("expected a token on stdin")
	}
	tok := strings.TrimSpace(sc.Text())
	if tok == "" {
		return errors.New("empty token")
	}
	fmt.Fprintln(stdio.Out, policy.HashToken(tok))
	return nil
}

func keystoreNew(args []string, stdio IO) error {
	fs := newFlags("keystore-new", stdio)
	out := fs.String("out", "", "keystore file to create")
	passFile := fs.String("password-file", "", "file holding the keystore password")
	light := fs.Bool("light", false, "use light scrypt parameters (tests and demos only)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *out == "" || *passFile == "" {
		return errors.New("-out and -password-file are required")
	}
	if _, err := os.Stat(*out); err == nil {
		return fmt.Errorf("%s already exists; refusing to overwrite a key", *out)
	}
	pass, err := os.ReadFile(*passFile)
	if err != nil {
		return err
	}
	password := strings.TrimRight(string(pass), "\r\n")
	if len(password) < 8 {
		return errors.New("keystore password must be at least 8 characters")
	}
	key, err := crypto.GenerateKey()
	if err != nil {
		return err
	}
	blob, err := signer.EncryptKeystore(key, password, *light)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(*out, blob, 0o600); err != nil {
		return err
	}
	fmt.Fprintln(stdio.Out, crypto.PubkeyToAddress(key.PublicKey).Hex())
	return nil
}

func auditVerify(ctx context.Context, args []string, stdio IO) error {
	fs := newFlags("audit-verify", stdio)
	file := fs.String("file", "audit.jsonl", "audit log to verify")
	dbPath := fs.String("db", "", "custodyd database to compare every line with (opened read-only)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	f, err := os.Open(*file)
	if err != nil {
		return err
	}
	defer f.Close()
	if *dbPath == "" {
		res, err := audit.Verify(f)
		if err != nil {
			return err
		}
		fmt.Fprintf(stdio.Out, "ok: %d lines, last sequence %d, hash chain intact (not compared with the database: pass -db)\n", res.Lines, res.LastSeq)
		return nil
	}
	db, err := store.OpenReadOnly(ctx, *dbPath)
	if err != nil {
		return err
	}
	defer db.Close()
	var res audit.VerifyResult
	if err := db.ReadTx(ctx, func(q store.Querier) error {
		var err error
		res, err = audit.VerifyAgainst(ctx, f, q)
		return err
	}); err != nil {
		return err
	}
	fmt.Fprintf(stdio.Out, "ok: %d lines, last sequence %d, hash chain intact, identical to the database's audit events\n", res.Lines, res.LastSeq)
	return nil
}
