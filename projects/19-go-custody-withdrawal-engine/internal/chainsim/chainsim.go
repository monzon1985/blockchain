// SPDX-License-Identifier: MIT

// Package chainsim is a deterministic, in-memory Ethereum-like chain that implements
// chain.Client. It exists for the simulation tests: thousands of randomized schedules of fee
// spikes, dropped transactions, reorgs and process crashes run against it in seconds, while
// the anvil integration suite checks the same engine against a real node.
//
// Modelled faithfully: per-sender nonces, EIP-1559 base-fee evolution and fee accounting
// (gasUsed x (baseFee + min(tip, feeCap - baseFee))), txpool replacement (+10 % on both fee
// fields, like geth), rejection below the pending base fee, eviction of underpriced transactions
// when a block is mined (anvil's behaviour), receipts and logs with block hashes, and reorgs
// that replace the last N blocks with new ones (new hashes), optionally re-including their
// transactions. Contract execution is limited to what the engine calls: ERC-20 transfer and
// balanceOf, and the ForwarderFactory view functions and flushMany.
package chainsim

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"maps"
	"math/big"
	"slices"
	"sync"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/bindings"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/deposit"
)

// Gas used by the simulated operations.
const (
	TransferGas      = 21_000
	TokenTransferGas = 51_000
	FlushBaseGas     = 30_000
	FlushPerItemGas  = 45_000
	blockGasLimit    = 30_000_000
)

// Factory describes the simulated ForwarderFactory.
type Factory struct {
	Address        common.Address
	Implementation common.Address
	Destination    common.Address
	Owner          common.Address
	Token          common.Address // the only token flushMany accepts in the simulator
}

// Config configures a Chain.
type Config struct {
	ChainID          *big.Int
	GenesisBaseFee   *big.Int
	MinBaseFee       *big.Int // floor for the EIP-1559 update (keeps fees meaningful over long runs)
	EvictUnderpriced bool     // drop pool txs whose fee cap is below a mined block's base fee
	Tokens           []common.Address
	Factory          *Factory
	EthAlloc         map[common.Address]*big.Int
	TokenAlloc       map[common.Address]map[common.Address]*big.Int
}

type state struct {
	eth   map[common.Address]*big.Int
	nonce map[common.Address]uint64
	tok   map[common.Address]map[common.Address]*big.Int
	code  map[common.Address]bool // deployed forwarders
}

func (s *state) clone() *state {
	c := &state{eth: map[common.Address]*big.Int{}, nonce: maps.Clone(s.nonce), tok: map[common.Address]map[common.Address]*big.Int{},
		code: maps.Clone(s.code)}
	for k, v := range s.eth {
		c.eth[k] = new(big.Int).Set(v)
	}
	for t, m := range s.tok {
		c.tok[t] = map[common.Address]*big.Int{}
		for k, v := range m {
			c.tok[t][k] = new(big.Int).Set(v)
		}
	}
	return c
}

func (s *state) ethOf(a common.Address) *big.Int {
	if v, ok := s.eth[a]; ok {
		return v
	}
	v := new(big.Int)
	s.eth[a] = v
	return v
}

func (s *state) tokOf(t, a common.Address) *big.Int {
	m, ok := s.tok[t]
	if !ok {
		m = map[common.Address]*big.Int{}
		s.tok[t] = m
	}
	if v, ok := m[a]; ok {
		return v
	}
	v := new(big.Int)
	m[a] = v
	return v
}

type block struct {
	number   uint64
	hash     common.Hash
	parent   common.Hash
	baseFee  *big.Int
	gasUsed  uint64
	txs      []*types.Transaction
	externs  []External
	receipts []*types.Receipt
	tips     []*big.Int
	post     *state
}

// External is a token transfer made by someone outside the engine (a customer deposit).
type External struct {
	Token, From, To common.Address
	Amount          *big.Int
	id              uint64
	late            bool // mined after the block's pool transactions instead of before them
}

type txLoc struct {
	block uint64
	index int
}

// Chain is the simulator. All methods are safe for concurrent use.
type Chain struct {
	mu        sync.Mutex
	cfg       Config
	signer    types.Signer
	blocks    []*block
	pool      map[common.Hash]*types.Transaction
	sender    map[common.Hash]common.Address
	index     map[common.Hash]txLoc
	nextFee   *big.Int
	fork      uint64
	tokens    map[common.Address]bool
	externals []External
	extSeq    uint64
	ffABI     *bindings.ForwarderFactory
	// sendFault, when set, can fail a send before it reaches the pool (transient RPC errors).
	sendFault func(tx *types.Transaction) error
	// readFault, when set, is consulted at the start of every read call (by method name) and
	// can fail it, simulating a flaky or overloaded node.
	readFault func(method string) error
	// FlushReverts makes flushMany revert (for example a paused token), consuming gas.
	FlushReverts bool
	// highest is the greatest block number the chain has ever had, across reorgs and
	// truncations: the furthest any observer can have seen.
	highest uint64
}

// SetSendFault installs (or, with nil, removes) a hook that can fail SendTransaction before the
// transaction reaches the pool. It is safe to call while other goroutines use the chain.
func (c *Chain) SetSendFault(f func(tx *types.Transaction) error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sendFault = f
}

// SetReadFault installs (or, with nil, removes) a hook consulted by every read call with its
// method name; a non-nil error fails the call. It is safe to call concurrently.
func (c *Chain) SetReadFault(f func(method string) error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.readFault = f
}

// fault runs the read-fault hook; the caller holds c.mu.
func (c *Chain) fault(method string) error {
	if c.readFault != nil {
		return c.readFault(method)
	}
	return nil
}

// New creates a chain with a genesis block holding the allocations.
func New(cfg Config) *Chain {
	if cfg.GenesisBaseFee == nil {
		cfg.GenesisBaseFee = big.NewInt(1_000_000_000)
	}
	if cfg.MinBaseFee == nil {
		cfg.MinBaseFee = new(big.Int)
	}
	st := &state{eth: map[common.Address]*big.Int{}, nonce: map[common.Address]uint64{}, tok: map[common.Address]map[common.Address]*big.Int{}, code: map[common.Address]bool{}}
	for a, v := range cfg.EthAlloc {
		st.eth[a] = new(big.Int).Set(v)
	}
	for t, m := range cfg.TokenAlloc {
		for a, v := range m {
			st.tokOf(t, a).Set(v)
		}
	}
	c := &Chain{cfg: cfg, signer: types.LatestSignerForChainID(cfg.ChainID), pool: map[common.Hash]*types.Transaction{},
		sender: map[common.Hash]common.Address{}, index: map[common.Hash]txLoc{}, tokens: map[common.Address]bool{},
		ffABI: bindings.NewForwarderFactory()}
	for _, t := range cfg.Tokens {
		c.tokens[t] = true
	}
	g := &block{number: 0, baseFee: new(big.Int).Set(cfg.GenesisBaseFee), post: st}
	g.hash = c.blockHash(g)
	c.blocks = []*block{g}
	return c
}

func (c *Chain) blockHash(b *block) common.Hash {
	var buf bytes.Buffer
	buf.Write(b.parent.Bytes())
	binary.Write(&buf, binary.BigEndian, b.number)
	binary.Write(&buf, binary.BigEndian, c.fork)
	for _, tx := range b.txs {
		buf.Write(tx.Hash().Bytes())
	}
	for _, e := range b.externs {
		binary.Write(&buf, binary.BigEndian, e.id)
	}
	return crypto.Keccak256Hash(buf.Bytes())
}

func (c *Chain) tip() *block { return c.blocks[len(c.blocks)-1] }

func (c *Chain) calcNextBaseFee() *big.Int {
	if c.nextFee != nil {
		return new(big.Int).Set(c.nextFee)
	}
	p := c.tip()
	target := uint64(blockGasLimit / 2)
	base := new(big.Int).Set(p.baseFee)
	switch {
	case p.gasUsed > target:
		d := new(big.Int).Mul(base, new(big.Int).SetUint64(p.gasUsed-target))
		d.Div(d, new(big.Int).SetUint64(target))
		d.Div(d, big.NewInt(8))
		if d.Sign() == 0 {
			d.SetInt64(1)
		}
		base.Add(base, d)
	case p.gasUsed < target:
		d := new(big.Int).Mul(base, new(big.Int).SetUint64(target-p.gasUsed))
		d.Div(d, new(big.Int).SetUint64(target))
		d.Div(d, big.NewInt(8))
		base.Sub(base, d)
	}
	if base.Cmp(c.cfg.MinBaseFee) < 0 {
		base.Set(c.cfg.MinBaseFee)
	}
	return base
}

// ---------------------------------------------------------------- chain.Client

// ChainID implements chain.Client.
func (c *Chain) ChainID(context.Context) (*big.Int, error) {
	return new(big.Int).Set(c.cfg.ChainID), nil
}

func ref(b *block) chain.BlockRef {
	return chain.BlockRef{Number: b.number, Hash: b.hash, BaseFee: new(big.Int).Set(b.baseFee)}
}

// Head implements chain.Client.
func (c *Chain) Head(context.Context) (chain.BlockRef, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("Head"); err != nil {
		return chain.BlockRef{}, err
	}
	return ref(c.tip()), nil
}

// BlockByNumber implements chain.Client.
func (c *Chain) BlockByNumber(_ context.Context, n uint64) (chain.BlockRef, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("BlockByNumber"); err != nil {
		return chain.BlockRef{}, err
	}
	if n >= uint64(len(c.blocks)) {
		return chain.BlockRef{}, chain.ErrNotFound
	}
	return ref(c.blocks[n]), nil
}

func (c *Chain) poolBySenderNonce(from common.Address, nonce uint64) (common.Hash, *types.Transaction) {
	for h, tx := range c.pool {
		if c.sender[h] == from && tx.Nonce() == nonce {
			return h, tx
		}
	}
	return common.Hash{}, nil
}

func pct110(v *big.Int) *big.Int {
	out := new(big.Int).Mul(v, big.NewInt(110))
	return out.Div(out, big.NewInt(100))
}

// SendTransaction implements chain.Client with geth-like validation and error wording.
func (c *Chain) SendTransaction(_ context.Context, tx *types.Transaction) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.sendFault != nil {
		if err := c.sendFault(tx); err != nil {
			return err
		}
	}
	from, err := types.Sender(c.signer, tx)
	if err != nil {
		return fmt.Errorf("invalid sender: %w", err)
	}
	h := tx.Hash()
	if _, ok := c.pool[h]; ok {
		return errors.New("already known")
	}
	if _, ok := c.index[h]; ok {
		return errors.New("already known")
	}
	st := c.tip().post
	if tx.Nonce() < st.nonce[from] {
		return errors.New("nonce too low")
	}
	if tx.GasFeeCap().Cmp(c.calcNextBaseFee()) < 0 {
		return errors.New("max fee per gas less than block base fee")
	}
	cost := new(big.Int).Mul(tx.GasFeeCap(), new(big.Int).SetUint64(tx.Gas()))
	cost.Add(cost, tx.Value())
	if st.ethOf(from).Cmp(cost) < 0 {
		return errors.New("insufficient funds for gas * price + value")
	}
	if oh, old := c.poolBySenderNonce(from, tx.Nonce()); old != nil {
		if tx.GasTipCap().Cmp(pct110(old.GasTipCap())) < 0 || tx.GasFeeCap().Cmp(pct110(old.GasFeeCap())) < 0 {
			return errors.New("replacement transaction underpriced")
		}
		delete(c.pool, oh)
		delete(c.sender, oh)
	}
	c.pool[h] = tx
	c.sender[h] = from
	return nil
}

// TransactionReceipt implements chain.Client.
func (c *Chain) TransactionReceipt(_ context.Context, h common.Hash) (*types.Receipt, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("TransactionReceipt"); err != nil {
		return nil, err
	}
	loc, ok := c.index[h]
	if !ok {
		return nil, chain.ErrNotFound
	}
	r := *c.blocks[loc.block].receipts[loc.index]
	return &r, nil
}

// TransactionKnown implements chain.Client.
func (c *Chain) TransactionKnown(_ context.Context, h common.Hash) (bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("TransactionKnown"); err != nil {
		return false, err
	}
	_, inPool := c.pool[h]
	_, mined := c.index[h]
	return inPool || mined, nil
}

// NonceAt implements chain.Client (latest block).
func (c *Chain) NonceAt(_ context.Context, a common.Address) (uint64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("NonceAt"); err != nil {
		return 0, err
	}
	return c.tip().post.nonce[a], nil
}

// FeeHistory implements chain.Client.
func (c *Chain) FeeHistory(_ context.Context, count uint64, last *big.Int, pcts []float64) (*ethereum.FeeHistory, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("FeeHistory"); err != nil {
		return nil, err
	}
	if last != nil {
		return nil, errors.New("chainsim: only lastBlock=latest is supported")
	}
	tip := c.tip().number
	if count > tip+1 {
		count = tip + 1
	}
	oldest := tip + 1 - count
	fh := &ethereum.FeeHistory{OldestBlock: new(big.Int).SetUint64(oldest)}
	for n := oldest; n <= tip; n++ {
		b := c.blocks[n]
		fh.BaseFee = append(fh.BaseFee, new(big.Int).Set(b.baseFee))
		fh.GasUsedRatio = append(fh.GasUsedRatio, float64(b.gasUsed)/blockGasLimit)
		row := make([]*big.Int, len(pcts))
		tips := slices.Clone(b.tips)
		slices.SortFunc(tips, func(x, y *big.Int) int { return x.Cmp(y) })
		for i, p := range pcts {
			if len(tips) == 0 {
				row[i] = new(big.Int)
				continue
			}
			idx := int(float64(len(tips)-1) * p / 100)
			row[i] = new(big.Int).Set(tips[idx])
		}
		fh.Reward = append(fh.Reward, row)
	}
	fh.BaseFee = append(fh.BaseFee, c.calcNextBaseFee())
	return fh, nil
}

// EstimateGas implements chain.Client for the calls the engine makes.
func (c *Chain) EstimateGas(_ context.Context, msg ethereum.CallMsg) (uint64, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("EstimateGas"); err != nil {
		return 0, err
	}
	st := c.tip().post.clone()
	gas, ok, err := c.execute(st, msg.From, msg.To, msg.Data, &[]*types.Log{})
	if err != nil {
		return 0, err
	}
	if !ok {
		return 0, errors.New("execution reverted")
	}
	return gas, nil
}

func (c *Chain) canonicalByHash(h common.Hash) (*block, error) {
	for i := len(c.blocks) - 1; i >= 0; i-- {
		if c.blocks[i].hash == h {
			return c.blocks[i], nil
		}
	}
	return nil, fmt.Errorf("header for hash %s not found", h)
}

// BalanceAtHash implements chain.Client.
func (c *Chain) BalanceAtHash(_ context.Context, a common.Address, h common.Hash) (*big.Int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("BalanceAtHash"); err != nil {
		return nil, err
	}
	b, err := c.canonicalByHash(h)
	if err != nil {
		return nil, err
	}
	return new(big.Int).Set(b.post.ethOf(a)), nil
}

// CallContractAtHash implements chain.Client for balanceOf and the factory view functions.
func (c *Chain) CallContractAtHash(_ context.Context, msg ethereum.CallMsg, h common.Hash) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("CallContractAtHash"); err != nil {
		return nil, err
	}
	b, err := c.canonicalByHash(h)
	if err != nil {
		return nil, err
	}
	if msg.To == nil || len(msg.Data) < 4 {
		return nil, errors.New("chainsim: unsupported call")
	}
	to, data := *msg.To, msg.Data
	if c.tokens[to] && bytes.Equal(data[:4], chain.BalanceOfSelector) && len(data) == 36 {
		return common.LeftPadBytes(b.post.tokOf(to, common.BytesToAddress(data[4:36])).Bytes(), 32), nil
	}
	if f := c.cfg.Factory; f != nil && to == f.Address {
		word := func(a common.Address) []byte { return common.LeftPadBytes(a.Bytes(), 32) }
		switch {
		case bytes.Equal(data, c.ffABI.PackIMPLEMENTATION()):
			return word(f.Implementation), nil
		case bytes.Equal(data, c.ffABI.PackDESTINATION()):
			return word(f.Destination), nil
		case bytes.Equal(data, c.ffABI.PackOwner()):
			return word(f.Owner), nil
		case len(data) == 36 && bytes.Equal(data[:4], c.ffABI.PackForwarderAddress([32]byte{})[:4]):
			return word(deposit.ForwarderAddress(f.Address, f.Implementation, common.BytesToHash(data[4:36]))), nil
		}
	}
	return nil, errors.New("execution reverted: chainsim does not implement this call")
}

// FilterLogs implements chain.Client over canonical blocks.
func (c *Chain) FilterLogs(_ context.Context, q ethereum.FilterQuery) ([]types.Log, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.fault("FilterLogs"); err != nil {
		return nil, err
	}
	from, to := uint64(0), c.tip().number
	if q.FromBlock != nil {
		from = q.FromBlock.Uint64()
	}
	if q.ToBlock != nil && q.ToBlock.Uint64() < to {
		to = q.ToBlock.Uint64()
	}
	var out []types.Log
	for n := from; n <= to && n < uint64(len(c.blocks)); n++ {
		for _, r := range c.blocks[n].receipts {
			for _, l := range r.Logs {
				if matchLog(l, q) {
					out = append(out, *l)
				}
			}
		}
	}
	return out, nil
}

func matchLog(l *types.Log, q ethereum.FilterQuery) bool {
	if len(q.Addresses) > 0 && !slices.Contains(q.Addresses, l.Address) {
		return false
	}
	for i, set := range q.Topics {
		if len(set) == 0 {
			continue
		}
		if i >= len(l.Topics) || !slices.Contains(set, l.Topics[i]) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------- execution

// execute applies a call's effects to st. It returns gas used and success.
func (c *Chain) execute(st *state, from common.Address, to *common.Address, data []byte, logs *[]*types.Log) (uint64, bool, error) {
	if to == nil {
		return 0, false, errors.New("chainsim: contract creation not supported")
	}
	if len(data) == 0 {
		return TransferGas, true, nil
	}
	if c.tokens[*to] {
		dest, amount, err := chain.DecodeTransfer(data)
		if err != nil {
			return 0, false, fmt.Errorf("chainsim: unsupported token call: %w", err)
		}
		bal := st.tokOf(*to, from)
		if bal.Cmp(amount) < 0 {
			return TokenTransferGas, false, nil
		}
		bal.Sub(bal, amount)
		st.tokOf(*to, dest).Add(st.tokOf(*to, dest), amount)
		*logs = append(*logs, transferLog(*to, from, dest, amount))
		return TokenTransferGas, true, nil
	}
	if f := c.cfg.Factory; f != nil && *to == f.Address {
		method := c.ffABI.GetABI().Methods["flushMany"]
		if len(data) < 4 || !bytes.Equal(data[:4], method.ID) {
			return 0, false, errors.New("chainsim: unsupported factory call")
		}
		args, err := method.Inputs.Unpack(data[4:])
		if err != nil {
			return 0, false, err
		}
		salts := args[0].([][32]byte)
		token := args[1].(common.Address)
		if from != f.Owner || len(salts) == 0 || token != f.Token || c.FlushReverts {
			return FlushBaseGas, false, nil
		}
		for _, s := range salts {
			fwd := deposit.ForwarderAddress(f.Address, f.Implementation, s)
			st.code[fwd] = true
			bal := st.tokOf(token, fwd)
			if bal.Sign() > 0 {
				amt := new(big.Int).Set(bal)
				bal.SetInt64(0)
				st.tokOf(token, f.Destination).Add(st.tokOf(token, f.Destination), amt)
				*logs = append(*logs, transferLog(token, fwd, f.Destination, amt))
			}
		}
		return FlushBaseGas + FlushPerItemGas*uint64(len(salts)), true, nil
	}
	return 0, false, fmt.Errorf("chainsim: call to unknown contract %s", to)
}

func transferLog(token, from, to common.Address, amount *big.Int) *types.Log {
	return &types.Log{
		Address: token,
		Topics:  []common.Hash{chain.TransferTopic, common.BytesToHash(from.Bytes()), common.BytesToHash(to.Bytes())},
		Data:    common.LeftPadBytes(amount.Bytes(), 32),
	}
}

// ---------------------------------------------------------------- test controls

// Mine produces one block from the pool and queued external transfers.
func (c *Chain) Mine() chain.BlockRef {
	c.mu.Lock()
	defer c.mu.Unlock()
	return ref(c.mineLocked())
}

// MineN mines n blocks.
func (c *Chain) MineN(n int) {
	for range n {
		c.Mine()
	}
}

func (c *Chain) mineLocked() *block {
	parent := c.tip()
	b := &block{number: parent.number + 1, parent: parent.hash, baseFee: c.calcNextBaseFee()}
	c.highest = max(c.highest, b.number)
	c.nextFee = nil
	st := parent.post.clone()
	logIndex := uint(0)
	type pending struct {
		r    *types.Receipt
		logs []*types.Log
	}
	var built []pending

	// Customer deposits are ordinary transfers from outside accounts. They come first in the
	// block, except those queued with ExternalTransferLate, which follow the pool transactions.
	external := func(late bool) {
		for _, e := range c.externals {
			if e.late != late {
				continue
			}
			st.tokOf(e.Token, e.To).Add(st.tokOf(e.Token, e.To), e.Amount)
			l := transferLog(e.Token, e.From, e.To, e.Amount)
			var idb [8]byte
			binary.BigEndian.PutUint64(idb[:], e.id)
			txh := crypto.Keccak256Hash([]byte("chainsim-external"), idb[:])
			r := &types.Receipt{Type: types.DynamicFeeTxType, Status: types.ReceiptStatusSuccessful, TxHash: txh, GasUsed: 0,
				EffectiveGasPrice: new(big.Int)}
			built = append(built, pending{r, []*types.Log{l}})
			b.externs = append(b.externs, e)
		}
	}
	external(false)

	senders := map[common.Address]bool{}
	for h := range c.pool {
		senders[c.sender[h]] = true
	}
	order := slices.SortedFunc(maps.Keys(senders), func(x, y common.Address) int { return x.Cmp(y) })
	for _, s := range order {
		for {
			h, tx := c.poolBySenderNonce(s, st.nonce[s])
			if tx == nil || tx.GasFeeCap().Cmp(b.baseFee) < 0 {
				break
			}
			var txLogs []*types.Log
			gas, ok, err := c.execute(st.clone(), s, tx.To(), tx.Data(), &txLogs)
			if err != nil || gas > tx.Gas() {
				// Invalid call or out of gas: consume the whole limit and revert.
				gas, ok, txLogs = tx.Gas(), false, nil
			}
			tipCap := new(big.Int).Sub(tx.GasFeeCap(), b.baseFee)
			if tx.GasTipCap().Cmp(tipCap) < 0 {
				tipCap.Set(tx.GasTipCap())
			}
			price := new(big.Int).Add(b.baseFee, tipCap)
			fee := new(big.Int).Mul(price, new(big.Int).SetUint64(gas))
			if st.ethOf(s).Cmp(new(big.Int).Add(fee, tx.Value())) < 0 {
				break
			}
			if ok {
				txLogs = txLogs[:0]
				_, _, _ = c.execute(st, s, tx.To(), tx.Data(), &txLogs)
				st.ethOf(*tx.To()).Add(st.ethOf(*tx.To()), tx.Value())
				st.ethOf(s).Sub(st.ethOf(s), tx.Value())
			}
			st.ethOf(s).Sub(st.ethOf(s), fee)
			st.nonce[s]++
			status := types.ReceiptStatusFailed
			if ok {
				status = types.ReceiptStatusSuccessful
			}
			b.gasUsed += gas
			b.txs = append(b.txs, tx)
			b.tips = append(b.tips, tipCap)
			r := &types.Receipt{Type: tx.Type(), Status: status, TxHash: h, GasUsed: gas, EffectiveGasPrice: price}
			built = append(built, pending{r, txLogs})
			delete(c.pool, h)
			delete(c.sender, h)
		}
	}
	external(true)
	c.externals = nil
	b.hash = c.blockHash(b)
	cum := uint64(0)
	for i, p := range built {
		cum += p.r.GasUsed
		p.r.CumulativeGasUsed = cum
		p.r.BlockHash = b.hash
		p.r.BlockNumber = new(big.Int).SetUint64(b.number)
		p.r.TransactionIndex = uint(i)
		for _, l := range p.logs {
			l.BlockNumber, l.BlockHash, l.TxHash, l.TxIndex, l.Index = b.number, b.hash, p.r.TxHash, uint(i), logIndex
			logIndex++
		}
		p.r.Logs = p.logs
		if p.r.Logs == nil {
			p.r.Logs = []*types.Log{}
		}
		p.r.Bloom = types.CreateBloom(p.r)
		b.receipts = append(b.receipts, p.r)
		c.index[p.r.TxHash] = txLoc{block: b.number, index: i}
	}
	b.post = st
	c.blocks = append(c.blocks, b)
	// Pool maintenance: stale nonces always go; underpriced transactions go when configured.
	for h, tx := range c.pool {
		s := c.sender[h]
		if tx.Nonce() < st.nonce[s] || (c.cfg.EvictUnderpriced && tx.GasFeeCap().Cmp(b.baseFee) < 0) {
			delete(c.pool, h)
			delete(c.sender, h)
		}
	}
	return b
}

// SetNextBaseFee forces the base fee of the next mined block (anvil_setNextBlockBaseFeePerGas).
func (c *Chain) SetNextBaseFee(v *big.Int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nextFee = new(big.Int).Set(v)
}

// Drop removes a transaction from the pool (anvil_dropTransaction). It reports whether it was there.
func (c *Chain) Drop(h common.Hash) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	_, ok := c.pool[h]
	delete(c.pool, h)
	delete(c.sender, h)
	return ok
}

// PoolHashes lists pending transactions (sorted, for deterministic selection).
func (c *Chain) PoolHashes() []common.Hash {
	c.mu.Lock()
	defer c.mu.Unlock()
	return slices.SortedFunc(maps.Keys(c.pool), func(x, y common.Hash) int { return x.Cmp(y) })
}

// Reorg replaces the last depth blocks with depth new blocks. With reinclude, the removed
// transactions (engine and customer ones alike) go back to the pool and may land in different
// blocks, or be replaced first; without, they vanish, like anvil_reorg with an empty
// transaction list.
func (c *Chain) Reorg(depth int, reinclude bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.removeTailLocked(depth, reinclude) {
		return
	}
	for range depth {
		c.mineLocked()
	}
}

// Height returns the current head number and the highest block number the chain ever had. It
// is a test control: it never consults the read-fault hook.
func (c *Chain) Height() (head, highest uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.tip().number, c.highest
}

// Truncate removes the last depth blocks without replacing them, so the head goes backwards:
// a reorg to a shorter fork, or a load-balanced RPC endpoint answering from a node that is
// behind the one it answered from before. The removed transactions and external transfers go
// back to the pool and land again when blocks are mined (in new blocks, with new hashes).
func (c *Chain) Truncate(depth int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.removeTailLocked(depth, true)
}

// removeTailLocked drops the last depth blocks and rebuilds the receipt index; with reinclude
// their transactions and external transfers are queued again. It reports whether it did
// anything (the genesis block is never removed).
func (c *Chain) removeTailLocked(depth int, reinclude bool) bool {
	if depth <= 0 || depth >= len(c.blocks) {
		return false
	}
	removed := c.blocks[len(c.blocks)-depth:]
	c.blocks = c.blocks[:len(c.blocks)-depth]
	c.fork++
	c.index = map[common.Hash]txLoc{}
	for _, b := range c.blocks {
		for i, r := range b.receipts {
			c.index[r.TxHash] = txLoc{block: b.number, index: i}
		}
	}
	for _, b := range removed {
		if !reinclude {
			continue
		}
		c.externals = append(c.externals, b.externs...)
		for _, tx := range b.txs {
			from, _ := types.Sender(c.signer, tx)
			if _, old := c.poolBySenderNonce(from, tx.Nonce()); old == nil {
				c.pool[tx.Hash()] = tx
				c.sender[tx.Hash()] = from
			}
		}
	}
	return true
}

// ExternalTransfer queues a token transfer from an outside account for the next block.
func (c *Chain) ExternalTransfer(token, from, to common.Address, amount *big.Int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.extSeq++
	c.externals = append(c.externals, External{Token: token, From: from, To: to, Amount: new(big.Int).Set(amount), id: c.extSeq})
}

// ExternalTransferLate is ExternalTransfer for a transfer that lands in the next block after
// the engine's transactions, for example right after a sweep in the same block.
func (c *Chain) ExternalTransferLate(token, from, to common.Address, amount *big.Int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.extSeq++
	c.externals = append(c.externals, External{Token: token, From: from, To: to, Amount: new(big.Int).Set(amount), id: c.extSeq, late: true})
}

// TransferEvent is a canonical Transfer log with its position on the chain.
type TransferEvent struct {
	chain.TransferLog
	TxHash    common.Hash
	LogIndex  uint
	Block     uint64
	BlockHash common.Hash
}

// TransferEvents returns every canonical Transfer log of token, in chain order: the ground truth
// the simulator compares the engine's deposit records with.
func (c *Chain) TransferEvents(token common.Address) []TransferEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []TransferEvent
	for _, b := range c.blocks {
		for _, r := range b.receipts {
			for _, l := range r.Logs {
				if tl, ok := chain.DecodeTransferLog(l); ok && tl.Token == token {
					out = append(out, TransferEvent{TransferLog: tl, TxHash: l.TxHash, LogIndex: l.Index, Block: l.BlockNumber, BlockHash: l.BlockHash})
				}
			}
		}
	}
	return out
}

// TokenBalance returns a token balance at the tip.
func (c *Chain) TokenBalance(token, a common.Address) *big.Int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return new(big.Int).Set(c.tip().post.tokOf(token, a))
}

// EthBalance returns a native balance at the tip.
func (c *Chain) EthBalance(a common.Address) *big.Int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return new(big.Int).Set(c.tip().post.ethOf(a))
}

// Transfers returns every canonical Transfer log of token from `from` (any sender when zero).
func (c *Chain) Transfers(token, from common.Address) []chain.TransferLog {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []chain.TransferLog
	for _, b := range c.blocks {
		for _, r := range b.receipts {
			for _, l := range r.Logs {
				if tl, ok := chain.DecodeTransferLog(l); ok && tl.Token == token && (from == (common.Address{}) || tl.From == from) {
					out = append(out, tl)
				}
			}
		}
	}
	return out
}
