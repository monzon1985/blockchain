// SPDX-License-Identifier: MIT

// Package devnet runs a local anvil node for the integration tests and the fixture recorder.
// The node listens on an OS-assigned port (anvil --port 0), mines only on request, and is
// stopped by PID; nothing here depends on a fixed port or on other anvil processes.
package devnet

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/rpc"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// Options configures a node.
type Options struct {
	// Hardfork is passed to anvil --hardfork ("" keeps anvil's default).
	Hardfork string
	// GenesisTimestamp fixes the genesis block's timestamp (0 keeps anvil's wall clock).
	// Together with Node.Mine's explicit timestamps it makes a chain reproducible.
	GenesisTimestamp uint64
	// Binary is the anvil executable ("anvil" on PATH by default).
	Binary string
}

// Node is a running anvil process.
type Node struct {
	URL      string
	RPC      *rpc.Client
	Accounts []keccak.Address

	cmd     *exec.Cmd
	mu      sync.Mutex
	logTail []string
	done    chan struct{}
	closed  bool
}

// ChainID is the chain id of every devnet.
const ChainID = 31337

var listenRe = regexp.MustCompile(`Listening on (\S+)`)

// Start launches anvil and waits until it reports its listening address.
func Start(ctx context.Context, opts Options) (*Node, error) {
	bin := opts.Binary
	if bin == "" {
		bin = "anvil"
	}
	args := []string{"--port", "0", "--chain-id", strconv.Itoa(ChainID), "--no-mining", "--accounts", "4", "--order", "fifo"}
	if opts.Hardfork != "" {
		args = append(args, "--hardfork", opts.Hardfork)
	}
	if opts.GenesisTimestamp != 0 {
		args = append(args, "--timestamp", strconv.FormatUint(opts.GenesisTimestamp, 10))
	}
	cmd := exec.Command(bin, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("devnet: start %s (is Foundry installed?): %w", bin, err)
	}
	n := &Node{cmd: cmd, done: make(chan struct{})}
	addr := make(chan string, 1)
	go func() {
		defer close(n.done)
		sc := bufio.NewScanner(stdout)
		sent := false
		for sc.Scan() { // drain everything so anvil never blocks on a full pipe
			line := sc.Text()
			n.mu.Lock()
			n.logTail = append(n.logTail, line)
			if len(n.logTail) > 40 {
				n.logTail = n.logTail[1:]
			}
			n.mu.Unlock()
			if m := listenRe.FindStringSubmatch(line); m != nil && !sent {
				addr <- m[1]
				sent = true
			}
		}
	}()
	select {
	case a := <-addr:
		n.URL = "http://" + a
	case <-n.done:
		_ = n.Close()
		return nil, fmt.Errorf("devnet: anvil exited before listening:\n%s", n.Log())
	case <-time.After(60 * time.Second):
		_ = n.Close()
		return nil, fmt.Errorf("devnet: anvil did not report a listening address:\n%s", n.Log())
	case <-ctx.Done():
		_ = n.Close()
		return nil, ctx.Err()
	}
	if n.RPC, err = rpc.DialContext(ctx, n.URL); err != nil {
		_ = n.Close()
		return nil, err
	}
	var accts []string
	if err := n.RPC.CallContext(ctx, &accts, "eth_accounts"); err != nil {
		_ = n.Close()
		return nil, err
	}
	for _, s := range accts {
		a, err := keccak.ParseAddress(s)
		if err != nil {
			_ = n.Close()
			return nil, err
		}
		n.Accounts = append(n.Accounts, a)
	}
	return n, nil
}

// Log returns the last lines anvil printed.
func (n *Node) Log() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return strings.Join(n.logTail, "\n")
}

// Close stops the process (by PID) and waits for it to exit. It is idempotent.
func (n *Node) Close() error {
	n.mu.Lock()
	if n.closed {
		n.mu.Unlock()
		return nil
	}
	n.closed = true
	n.mu.Unlock()
	if n.RPC != nil {
		n.RPC.Close()
	}
	_ = n.cmd.Process.Kill() // by PID; an already-exited process is fine
	_ = n.cmd.Wait()
	<-n.done
	return nil
}

// Call performs a JSON-RPC call.
func (n *Node) Call(ctx context.Context, result any, method string, args ...any) error {
	if err := n.RPC.CallContext(ctx, result, method, args...); err != nil {
		return fmt.Errorf("devnet: %s: %w", method, err)
	}
	return nil
}

// Tx is an eth_sendTransaction request, signed by anvil for one of its unlocked accounts.
type Tx struct {
	From keccak.Address
	To   *keccak.Address // nil deploys Data as init code
	Data []byte
	// Value in wei (nil for none).
	Value *big.Int
	// Gas limit; 0 lets the node estimate it (a call that reverts then fails to send).
	Gas uint64
	// Type selects the envelope: 0 legacy, 1 access list (EIP-2930), 2 dynamic fee (EIP-1559).
	Type uint8
	// AccessList is included for types 1 and 2.
	AccessList []AccessTuple
}

// AccessTuple is an EIP-2930 access list entry.
type AccessTuple struct {
	Address     keccak.Address `json:"address"`
	StorageKeys []keccak.Hash  `json:"storageKeys"`
}

func hexBig(v *big.Int) string { return "0x" + v.Text(16) }

// MarshalJSON renders the request in JSON-RPC form.
func (t Tx) MarshalJSON() ([]byte, error) {
	m := map[string]any{
		"from": t.From.Hex(),
		"data": "0x" + fmt.Sprintf("%x", t.Data),
		"type": fmt.Sprintf("0x%x", t.Type),
	}
	if t.To != nil {
		m["to"] = t.To.Hex()
	}
	if t.Value != nil {
		m["value"] = hexBig(t.Value)
	}
	if t.Gas != 0 {
		m["gas"] = fmt.Sprintf("0x%x", t.Gas)
	}
	switch t.Type {
	case 0:
		m["gasPrice"] = "0x77359400" // 2 gwei, above any devnet base fee
	case 1:
		m["gasPrice"] = "0x77359400"
		m["accessList"] = accessList(t.AccessList)
	case 2:
		m["maxFeePerGas"] = "0x77359400"
		m["maxPriorityFeePerGas"] = "0x3b9aca00"
		m["accessList"] = accessList(t.AccessList)
	default:
		return nil, fmt.Errorf("devnet: eth_sendTransaction cannot build type %d", t.Type)
	}
	return json.Marshal(m)
}

func accessList(l []AccessTuple) []AccessTuple {
	if l == nil {
		return []AccessTuple{}
	}
	return l
}

// Send submits a transaction to the pool; it is included by the next Mine.
func (n *Node) Send(ctx context.Context, tx Tx) (keccak.Hash, error) {
	var h keccak.Hash
	err := n.Call(ctx, &h, "eth_sendTransaction", tx)
	return h, err
}

// SendRaw submits a signed transaction envelope (network encoding).
func (n *Node) SendRaw(ctx context.Context, raw []byte) (keccak.Hash, error) {
	var h keccak.Hash
	err := n.Call(ctx, &h, "eth_sendRawTransaction", fmt.Sprintf("0x%x", raw))
	return h, err
}

// Mine mines one block with the given timestamp (0 lets anvil choose) and returns its number.
func (n *Node) Mine(ctx context.Context, timestamp uint64) (uint64, error) {
	if timestamp != 0 {
		if err := n.Call(ctx, nil, "evm_setNextBlockTimestamp", timestamp); err != nil {
			return 0, err
		}
	}
	if err := n.Call(ctx, nil, "evm_mine"); err != nil {
		return 0, err
	}
	var num string
	if err := n.Call(ctx, &num, "eth_blockNumber"); err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimPrefix(num, "0x"), 16, 64)
}

// Receipt is the part of a receipt the scenarios need.
type Receipt struct {
	Status          string          `json:"status"`
	BlockNumber     string          `json:"blockNumber"`
	ContractAddress *keccak.Address `json:"contractAddress"`
	Type            string          `json:"type"`
}

// Receipt fetches a mined transaction's receipt.
func (n *Node) Receipt(ctx context.Context, h keccak.Hash) (*Receipt, error) {
	var r *Receipt
	if err := n.Call(ctx, &r, "eth_getTransactionReceipt", h); err != nil {
		return nil, err
	}
	if r == nil {
		return nil, fmt.Errorf("devnet: no receipt for %s (not mined?)", h)
	}
	return r, nil
}
