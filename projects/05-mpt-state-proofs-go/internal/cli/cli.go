// SPDX-License-Identifier: MIT

// Package cli implements the trie command. It is a package (not main) so that golden tests
// and the fixture recorder can run commands in-process.
package cli

import (
	"bufio"
	"context"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/inspect"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
)

// Exit codes.
const (
	ExitVerified = 0 // every check passed (warnings allowed unless --strict)
	ExitFailed   = 1 // a check failed: the node's data does not verify
	ExitUsage    = 2 // bad arguments, unreachable node, or another error that prevented checking
)

// DefaultRPC is used when neither --rpc nor ETH_RPC_URL is set.
const DefaultRPC = "http://127.0.0.1:8545"

const usage = `trie: verify what an Ethereum node reports, from raw data

Usage:
  trie verify-block  [flags] <block>                     block hash, transactionsRoot, receiptsRoot, bloom, ...
  trie verify-proof  [flags] --address A [--slot S]...    eth_getProof account and storage proofs
  trie storage-root  [flags] --address A --slots-file F   rebuild a contract's storage trie
  trie rlp <hex>                                          decode and print an RLP item (offline)

<block> and --block take a number (decimal or 0x-hex) or latest, earliest, pending, safe,
finalized. Slots are decimal or 0x-hex, left-padded to 32 bytes.

Flags of the node commands:
  --rpc URL       JSON-RPC endpoint (default $ETH_RPC_URL, else ` + DefaultRPC + `)
  --block B       block to check against (verify-proof, storage-root; default latest)
  --json          print the report as JSON
  --strict        exit 1 on warnings too
  --timeout D     give up after D (default 60s)
  --verbose       log RPC progress to stderr

Exit status: 0 verified, 1 verification failed, 2 usage or connection error.
`

// Run executes the command line args (without the program name) and returns the exit code.
func Run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return ExitUsage
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "verify-block", "verify-proof", "storage-root":
		return runNode(ctx, cmd, rest, stdout, stderr)
	case "rlp":
		return runRLP(rest, stdout, stderr)
	case "help", "-h", "--help", "-help":
		fmt.Fprint(stdout, usage)
		return ExitVerified
	default:
		fmt.Fprintf(stderr, "trie: unknown command %q\n\n%s", cmd, usage)
		return ExitUsage
	}
}

// stringList is a repeatable flag.
type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

// options are the parsed flags of the node commands.
type options struct {
	rpc, address, block, slotsFile string
	slots                          stringList
	json, strict, verbose          bool
	timeout                        time.Duration
	positional                     []string
}

// parse accepts flags before and after positional arguments.
func parse(cmd string, args []string) (*options, error) {
	o := &options{}
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	defaultRPC := os.Getenv("ETH_RPC_URL")
	if defaultRPC == "" {
		defaultRPC = DefaultRPC
	}
	fs.StringVar(&o.rpc, "rpc", defaultRPC, "")
	fs.StringVar(&o.address, "address", "", "")
	fs.StringVar(&o.block, "block", "latest", "")
	fs.StringVar(&o.slotsFile, "slots-file", "", "")
	fs.Var(&o.slots, "slot", "")
	fs.BoolVar(&o.json, "json", false, "")
	fs.BoolVar(&o.strict, "strict", false, "")
	fs.BoolVar(&o.verbose, "verbose", false, "")
	fs.DurationVar(&o.timeout, "timeout", 60*time.Second, "")
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		if fs.NArg() == 0 {
			break
		}
		o.positional = append(o.positional, fs.Arg(0))
		args = fs.Args()[1:]
	}
	return o, nil
}

func runNode(ctx context.Context, cmd string, args []string, stdout, stderr io.Writer) int {
	o, err := parse(cmd, args)
	if err != nil {
		fmt.Fprintf(stderr, "trie %s: %v\n", cmd, err)
		return ExitUsage
	}
	level := slog.LevelWarn
	if o.verbose {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: level}))

	ctx, cancel := context.WithTimeout(ctx, o.timeout)
	defer cancel()

	// Validate arguments before touching the network.
	var (
		ref   ethrpc.BlockRef
		addr  keccak.Address
		slots []keccak.Hash
	)
	switch cmd {
	case "verify-block":
		if len(o.positional) != 1 {
			fmt.Fprintln(stderr, "trie verify-block: expected exactly one block argument")
			return ExitUsage
		}
		ref, err = ethrpc.ParseBlockRef(o.positional[0])
	default:
		if len(o.positional) != 0 {
			fmt.Fprintf(stderr, "trie %s: unexpected argument %q\n", cmd, o.positional[0])
			return ExitUsage
		}
		if ref, err = ethrpc.ParseBlockRef(o.block); err == nil {
			addr, slots, err = addressAndSlots(cmd, o)
		}
	}
	if err != nil {
		fmt.Fprintf(stderr, "trie %s: %v\n", cmd, err)
		return ExitUsage
	}

	log.Debug("connecting", "rpc", o.rpc)
	client, err := ethrpc.Dial(ctx, o.rpc)
	if err != nil {
		fmt.Fprintf(stderr, "trie %s: %v\n", cmd, err)
		return ExitUsage
	}
	defer client.Close()
	if v, err := client.ClientVersion(ctx); err == nil {
		log.Debug("connected", "client", v)
	}

	var (
		checks inspect.Checks
		report interface{ WriteText(io.Writer) }
	)
	switch cmd {
	case "verify-block":
		log.Debug("verifying block", "block", ref)
		var r *inspect.BlockReport
		if r, err = inspect.VerifyBlock(ctx, client, ref); err == nil {
			checks, report = r.Checks, r
		}
	case "verify-proof":
		log.Debug("verifying proof", "address", addr, "slots", len(slots), "block", ref)
		var r *inspect.ProofReport
		if r, err = inspect.VerifyProof(ctx, client, addr, slots, ref); err == nil {
			checks, report = r.Checks, r
		}
	case "storage-root":
		log.Debug("rebuilding storage", "address", addr, "slots", len(slots), "block", ref)
		var r *inspect.StorageReport
		if r, err = inspect.RebuildStorage(ctx, client, addr, slots, ref); err == nil {
			checks, report = r.Checks, r
		}
	}
	if err != nil {
		fmt.Fprintf(stderr, "trie %s: %v\n", cmd, err)
		return ExitUsage
	}
	if o.json {
		if err := inspect.WriteJSON(stdout, report); err != nil {
			fmt.Fprintf(stderr, "trie %s: %v\n", cmd, err)
			return ExitUsage
		}
	} else {
		report.WriteText(stdout)
	}
	if !checks.OK(o.strict) {
		return ExitFailed
	}
	return ExitVerified
}

func addressAndSlots(cmd string, o *options) (keccak.Address, []keccak.Hash, error) {
	if o.address == "" {
		return keccak.Address{}, nil, errors.New("--address is required")
	}
	addr, err := keccak.ParseAddress(o.address)
	if err != nil {
		return keccak.Address{}, nil, err
	}
	raw := []string(o.slots)
	if cmd == "storage-root" {
		if o.slotsFile == "" || len(raw) > 0 {
			return keccak.Address{}, nil, errors.New("storage-root takes --slots-file (and no --slot)")
		}
		if raw, err = readSlotsFile(o.slotsFile); err != nil {
			return keccak.Address{}, nil, err
		}
	} else if o.slotsFile != "" {
		return keccak.Address{}, nil, errors.New("--slots-file applies to storage-root only")
	}
	slots := make([]keccak.Hash, 0, len(raw))
	seen := map[keccak.Hash]bool{}
	for _, s := range raw {
		slot, err := ethrpc.ParseSlot(s)
		if err != nil {
			return keccak.Address{}, nil, err
		}
		if seen[slot] {
			return keccak.Address{}, nil, fmt.Errorf("slot %s is listed twice", slot)
		}
		seen[slot] = true
		slots = append(slots, slot)
	}
	return addr, slots, nil
}

// readSlotsFile reads one slot per line; blank lines and lines starting with # are skipped.
func readSlotsFile(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s lists no slots", path)
	}
	return out, nil
}

func runRLP(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "trie rlp: expected one hex argument")
		return ExitUsage
	}
	in := strings.TrimPrefix(strings.TrimPrefix(args[0], "0x"), "0X")
	b, err := hex.DecodeString(in)
	if err != nil {
		fmt.Fprintf(stderr, "trie rlp: %v\n", err)
		return ExitUsage
	}
	v, err := rlp.Decode(b)
	if err != nil {
		fmt.Fprintf(stderr, "trie rlp: %v\n", err)
		return ExitFailed
	}
	printValue(stdout, v, 0)
	return ExitVerified
}

func printValue(w io.Writer, v rlp.Value, depth int) {
	indent := strings.Repeat("  ", depth)
	if v.Kind == rlp.List {
		fmt.Fprintf(w, "%slist, %d items, %d bytes encoded\n", indent, len(v.Items), len(v.Encode()))
		for _, it := range v.Items {
			printValue(w, it, depth+1)
		}
		return
	}
	switch {
	case len(v.Bytes) == 0:
		fmt.Fprintf(w, "%sstring, empty (0, or no value)\n", indent)
	case printable(v.Bytes):
		fmt.Fprintf(w, "%sstring, %d bytes: 0x%x %q\n", indent, len(v.Bytes), v.Bytes, v.Bytes)
	default:
		fmt.Fprintf(w, "%sstring, %d bytes: 0x%x\n", indent, len(v.Bytes), v.Bytes)
	}
}

func printable(b []byte) bool {
	for _, c := range b {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}
