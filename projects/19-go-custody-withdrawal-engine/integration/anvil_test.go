// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/bindings"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/policy"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
)

// deployerKey is anvil's first pre-funded development account (public test key, local chain only).
const deployerKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

const (
	chainID = 31337
	gwei    = int64(1_000_000_000)
)

// Anvil is a running anvil process on a free port.
type Anvil struct {
	t   testing.TB
	cmd *exec.Cmd
	URL string
	RPC *chain.RPC
	mu  sync.Mutex
}

var listenRe = regexp.MustCompile(`Listening on (\S+)`)

// StartAnvil launches anvil on an OS-assigned port (--port 0) with manual mining, reads the
// bound address from its output and kills it (by PID) when the test ends.
func StartAnvil(t testing.TB) *Anvil {
	t.Helper()
	cmd := exec.Command("anvil", "--port", "0", "--chain-id", fmt.Sprint(chainID), "--no-mining")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		t.Fatalf("start anvil (is Foundry installed?): %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	addrCh := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		sent := false
		for sc.Scan() {
			if m := listenRe.FindStringSubmatch(sc.Text()); m != nil && !sent {
				addrCh <- m[1]
				sent = true
			}
		}
	}()
	var addr string
	select {
	case addr = <-addrCh:
	case <-time.After(30 * time.Second):
		t.Fatal("anvil did not report its listening address")
	}
	a := &Anvil{t: t, cmd: cmd, URL: "http://" + addr}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if a.RPC, err = chain.Dial(ctx, a.URL); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(a.RPC.Close)
	return a
}

// Call invokes a raw JSON-RPC method.
func (a *Anvil) Call(method string, params ...any) json.RawMessage {
	a.t.Helper()
	var out json.RawMessage
	if err := a.RPC.Raw().CallContext(context.Background(), &out, method, params...); err != nil {
		a.t.Fatalf("%s: %v", method, err)
	}
	return out
}

// Mine mines n blocks (evm_mine), serialised so a background miner and a test cannot interleave.
func (a *Anvil) Mine(n int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for range n {
		a.Call("evm_mine")
	}
}

// SetNextBaseFee forces the next block's base fee.
func (a *Anvil) SetNextBaseFee(wei int64) {
	a.Call("anvil_setNextBlockBaseFeePerGas", hexutil.EncodeBig(big.NewInt(wei)))
}

// MineWithBaseFee mines one block at the given base fee.
func (a *Anvil) MineWithBaseFee(wei int64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.SetNextBaseFee(wei)
	a.Call("evm_mine")
}

// Drop removes a transaction from anvil's pool.
func (a *Anvil) Drop(h common.Hash) { a.Call("anvil_dropTransaction", h) }

// Reorg replaces the last depth blocks (anvil_reorg); txs are (raw hex, block offset) pairs to
// include in the new blocks.
func (a *Anvil) Reorg(depth int, txs [][]any) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if txs == nil {
		txs = [][]any{}
	}
	a.Call("anvil_reorg", depth, txs)
}

// SetBalance sets an account's ETH balance.
func (a *Anvil) SetBalance(addr common.Address, wei *big.Int) {
	a.Call("anvil_setBalance", addr, hexutil.EncodeBig(wei))
}

// Head returns the latest block number.
func (a *Anvil) Head() uint64 {
	h, err := a.RPC.Head(context.Background())
	if err != nil {
		a.t.Fatal(err)
	}
	return h.Number
}

// Miner mines a block every interval until the returned stop function is called.
func (a *Anvil) Miner(interval time.Duration) (stop func()) {
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				a.mu.Lock()
				var out json.RawMessage
				_ = a.RPC.Raw().CallContext(context.Background(), &out, "evm_mine")
				a.mu.Unlock()
			}
		}
	}()
	var once sync.Once
	return func() {
		once.Do(func() {
			close(done)
			<-finished
		})
	}
}

// Deployment is the on-chain fixture of a test: token, factory and the hot-wallet key.
type Deployment struct {
	Token, Factory, Implementation common.Address
	HotKey                         *ecdsa.PrivateKey
	Hot                            common.Address
	deployer                       *ecdsa.PrivateKey
}

// sendAs signs and sends a transaction from key and mines it, returning the receipt.
func (a *Anvil) sendAs(key *ecdsa.PrivateKey, to *common.Address, data []byte) *types.Receipt {
	a.t.Helper()
	ctx := context.Background()
	from := crypto.PubkeyToAddress(key.PublicKey)
	var nonceHex hexutil.Uint64
	if err := a.RPC.Raw().CallContext(ctx, &nonceHex, "eth_getTransactionCount", from, "pending"); err != nil {
		a.t.Fatal(err)
	}
	tx := types.NewTx(&types.DynamicFeeTx{ChainID: big.NewInt(chainID), Nonce: uint64(nonceHex), GasTipCap: big.NewInt(gwei),
		GasFeeCap: big.NewInt(100 * gwei), Gas: 6_000_000, To: to, Value: new(big.Int), Data: data})
	signed, err := types.SignTx(tx, types.LatestSignerForChainID(big.NewInt(chainID)), key)
	if err != nil {
		a.t.Fatal(err)
	}
	if err := a.RPC.SendTransaction(ctx, signed); err != nil {
		a.t.Fatalf("send: %v", err)
	}
	a.Mine(1)
	r, err := a.RPC.TransactionReceipt(ctx, signed.Hash())
	if err != nil || r.Status != types.ReceiptStatusSuccessful {
		a.t.Fatalf("transaction %s failed: %v %+v", signed.Hash(), err, r)
	}
	return r
}

// Deploy creates a fresh hot-wallet key, funds it with ETH, and deploys TestToken and a
// ForwarderFactory whose destination and owner are the hot wallet.
func Deploy(t testing.TB, a *Anvil) Deployment {
	t.Helper()
	dk, _ := crypto.HexToECDSA(deployerKey)
	hk, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	d := Deployment{HotKey: hk, Hot: crypto.PubkeyToAddress(hk.PublicKey), deployer: dk}
	a.SetBalance(d.Hot, new(big.Int).Mul(big.NewInt(100), big.NewInt(1e18)))
	tokenBin := common.FromHex(bindings.TestTokenMetaData.Bin)
	d.Token = a.sendAs(dk, nil, tokenBin).ContractAddress
	ff := bindings.NewForwarderFactory()
	factoryBin := append(common.FromHex(bindings.ForwarderFactoryMetaData.Bin), ff.PackConstructor(d.Hot, d.Hot)...)
	d.Factory = a.sendAs(dk, nil, factoryBin).ContractAddress
	out, err := a.RPC.CallContractAtHash(context.Background(), callMsg(d.Factory, ff.PackIMPLEMENTATION()), headHash(t, a))
	if err != nil {
		t.Fatal(err)
	}
	if d.Implementation, err = ff.UnpackIMPLEMENTATION(out); err != nil {
		t.Fatal(err)
	}
	return d
}

// Mint mints test tokens to `to` (a deposit when `to` is a forwarder address).
func (d Deployment) Mint(a *Anvil, to common.Address, amount *big.Int) {
	a.sendAs(d.deployer, &d.Token, bindings.NewTestToken().PackMint(to, amount))
}

// TokenBalance reads balanceOf at the head.
func (d Deployment) TokenBalance(t testing.TB, a *Anvil, holder common.Address) *big.Int {
	v, err := chain.TokenBalanceAtHash(context.Background(), a.RPC, d.Token, holder, headHash(t, a))
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// TransfersFromHot returns every Transfer log of the token sent by the hot wallet, over the
// whole chain: the ground truth for "exactly one on-chain transfer per withdrawal".
func (d Deployment) TransfersFromHot(t testing.TB, a *Anvil) []chain.TransferLog {
	t.Helper()
	logs, err := a.RPC.FilterLogs(context.Background(), filterAll(d.Token, d.Hot))
	if err != nil {
		t.Fatal(err)
	}
	var out []chain.TransferLog
	for i := range logs {
		if tl, ok := chain.DecodeTransferLog(&logs[i]); ok {
			out = append(out, tl)
		}
	}
	return out
}

func callMsg(to common.Address, data []byte) ethereum.CallMsg {
	return ethereum.CallMsg{To: &to, Data: data}
}

func headHash(t testing.TB, a *Anvil) common.Hash {
	t.Helper()
	h, err := a.RPC.Head(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return h.Hash
}

func filterAll(token, from common.Address) ethereum.FilterQuery {
	return ethereum.FilterQuery{FromBlock: big.NewInt(0), Addresses: []common.Address{token},
		Topics: [][]common.Hash{{chain.TransferTopic}, {common.BytesToHash(from.Bytes())}}}
}

// Tokens used by the engine configuration in integration tests.
const (
	ClientToken = "integration-client-token"
)

// ApproverTokens are the three approvers' bearer tokens.
var ApproverTokens = []string{"approver-token-a", "approver-token-b", "approver-token-c"}

// WriteConfig writes a keystore, its password file and a custodyd configuration into dir.
func WriteConfig(t testing.TB, dir string, a *Anvil, d Deployment, overrides map[string]any) string {
	t.Helper()
	blob, err := signer.EncryptKeystore(d.HotKey, "integration-password", true)
	if err != nil {
		t.Fatal(err)
	}
	must(t, os.WriteFile(filepath.Join(dir, "hot.json"), blob, 0o600))
	must(t, os.WriteFile(filepath.Join(dir, "hot.pass"), []byte("integration-password\n"), 0o600))
	approvers := make([]map[string]string, len(ApproverTokens))
	for i, tok := range ApproverTokens {
		approvers[i] = map[string]string{"id": fmt.Sprintf("approver-%d", i), "token_sha256": policy.HashToken(tok)}
	}
	cfg := map[string]any{
		"chain":      map[string]any{"rpc_url": a.URL, "chain_id": chainID, "confirmations": 3, "poll_interval": "50ms"},
		"database":   map[string]any{"path": "custody.db"},
		"http":       map[string]any{"listen": "127.0.0.1:0", "addr_file": "addr.txt"},
		"audit":      map[string]any{"path": "audit.jsonl", "ship_interval": "200ms"},
		"hot_wallet": map[string]any{"keystore": "hot.json", "password_file": "hot.pass"},
		"fees":       map[string]any{"min_tip_wei": fmt.Sprint(gwei), "max_fee_wei": fmt.Sprint(2000 * gwei), "bump_after_blocks": 3},
		"assets": []map[string]any{{"symbol": "tUSD", "token": d.Token.Hex(), "max_per_tx": "1000000000000",
			"velocity_24h": "10000000000000", "approval_threshold": "500000000000"}},
		"policy":    map[string]any{"allowlist_cooldown": "0s", "approvals_required": 2, "approvers": approvers},
		"clients":   []map[string]string{{"id": "gateway", "token_sha256": policy.HashToken(ClientToken)}},
		"deposits":  map[string]any{"factory": d.Factory.Hex(), "scan_interval": "100ms", "sweep_interval": "300ms", "start_block": 0},
		"reconcile": map[string]any{"every_rounds": 5},
	}
	for k, v := range overrides {
		cfg[k] = v
	}
	raw, _ := json.MarshalIndent(cfg, "", "  ")
	p := filepath.Join(dir, "custody.json")
	must(t, os.WriteFile(p, raw, 0o600))
	return p
}

func must(t testing.TB, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// syncBuffer is a goroutine-safe log sink for child processes.
type syncBuffer struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

var _ io.Writer = (*syncBuffer)(nil)
