// SPDX-License-Identifier: MIT

package fakechain

import (
	"math/big"
	"math/rand/v2"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
)

// TopicApproval is keccak256("Approval(address,address,uint256)"), used as undecoded noise.
var TopicApproval = crypto.Keccak256Hash([]byte("Approval(address,address,uint256)"))

// World generates semantically valid token and vault traffic for the fake chain: balances never
// go negative on the canonical chain, vault deposits and withdrawals emit the same three logs
// OpenZeppelin's ERC4626 emits, and a fraction of the logs is noise the indexer must store raw
// but never decode (Approvals, ERC-721-shaped Transfers, dirty address topics, and logs of a
// contract nobody watches).
type World struct {
	Tokens    []common.Address
	Asset     common.Address
	Vault     common.Address
	Holders   []common.Address
	Unwatched common.Address

	mu sync.Mutex
	// cache holds the state after every block replayed from genesis, by block hash. A hash
	// commits to its parent, so it identifies the whole history and the cache never goes stale
	// across reorgs; it only saves replaying the chain from genesis for every new block.
	cache map[common.Hash]*state
}

// NewWorld returns a world with two plain tokens, one vault over a third token, and holders.
func NewWorld(holders int) *World {
	addr := func(prefix byte, i int) common.Address {
		var a common.Address
		a[0], a[19] = prefix, byte(i+1)
		return a
	}
	w := &World{
		Tokens:    []common.Address{addr(0x70, 0), addr(0x70, 1)},
		Asset:     addr(0xa5, 0),
		Vault:     addr(0x7a, 0),
		Unwatched: addr(0xee, 0),
	}
	for i := range holders {
		w.Holders = append(w.Holders, addr(0x40, i))
	}
	return w
}

// Contracts returns the watched set the indexer should be configured with.
func (w *World) Contracts() decode.Contracts {
	return decode.Contracts{
		Tokens: append(append([]common.Address{}, w.Tokens...), w.Asset),
		Vaults: map[common.Address]common.Address{w.Vault: w.Asset},
	}
}

type balKey struct{ token, holder common.Address }

// state is the world's view of the canonical chain, rebuilt by replay.
type state struct {
	bal    map[balKey]*big.Int
	assets *big.Int // vault's asset balance
	supply *big.Int // vault share supply
}

func (s *state) get(token, holder common.Address) *big.Int {
	if v, ok := s.bal[balKey{token, holder}]; ok {
		return v
	}
	return new(big.Int)
}

func (s *state) add(token, holder common.Address, delta *big.Int) {
	s.bal[balKey{token, holder}] = new(big.Int).Add(s.get(token, holder), delta)
}

func (s *state) clone() *state {
	c := &state{bal: make(map[balKey]*big.Int, len(s.bal)), assets: new(big.Int).Set(s.assets), supply: new(big.Int).Set(s.supply)}
	for k, v := range s.bal {
		c.bal[k] = v // balance values are replaced on update, never mutated in place
	}
	return c
}

// apply moves balances, vault assets and share supply for every canonical Transfer in logs.
func (w *World) apply(st *state, logs []types.Log) {
	for i := range logs {
		t, err := decode.DecodeTransfer(&logs[i])
		if err != nil || t.Token == w.Unwatched {
			continue
		}
		v := t.Value.Big()
		if t.From != (common.Address{}) {
			st.add(t.Token, t.From, new(big.Int).Neg(v))
		}
		if t.To != (common.Address{}) {
			st.add(t.Token, t.To, v)
		}
		if t.Token == w.Asset && t.To == w.Vault {
			st.assets.Add(st.assets, v)
		}
		if t.Token == w.Asset && t.From == w.Vault {
			st.assets.Sub(st.assets, v)
		}
		if t.Token == w.Vault && t.From == (common.Address{}) {
			st.supply.Add(st.supply, v)
		}
		if t.Token == w.Vault && t.To == (common.Address{}) {
			st.supply.Sub(st.supply, v)
		}
	}
}

// replay rebuilds the state from canonical blocks plus pending (not yet mined) blocks. Only
// Transfers move balances. When blocks start at genesis, it resumes from the newest cached
// block instead of replaying everything.
func (w *World) replay(blocks []*Block, pending [][]LogSpec) *state {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.cache == nil {
		w.cache = map[common.Hash]*state{}
	}
	st := &state{bal: map[balKey]*big.Int{}, assets: new(big.Int), supply: new(big.Int)}
	fromGenesis := len(blocks) > 0 && blocks[0].Header.Number == 0
	start := 0
	if fromGenesis {
		for i := len(blocks) - 1; i >= 0; i-- {
			if c, ok := w.cache[blocks[i].Header.Hash]; ok {
				st, start = c.clone(), i+1
				break
			}
		}
	}
	for _, b := range blocks[start:] {
		w.apply(st, b.Logs)
		if fromGenesis {
			w.cache[b.Header.Hash] = st.clone()
		}
	}
	for _, specs := range pending {
		logs := make([]types.Log, len(specs))
		for i, sp := range specs {
			logs[i] = types.Log{Address: sp.Address, Topics: sp.Topics, Data: sp.Data}
		}
		w.apply(st, logs)
	}
	return st
}

func word(v *big.Int) []byte { return common.LeftPadBytes(v.Bytes(), 32) }

func addrTopic(a common.Address) common.Hash { return common.BytesToHash(a.Bytes()) }

func transferLog(tx uint, token, from, to common.Address, v *big.Int) LogSpec {
	return LogSpec{Tx: tx, Address: token, Topics: []common.Hash{decode.TopicTransfer, addrTopic(from), addrTopic(to)}, Data: word(v)}
}

// amount draws a value spread over many magnitudes, including values far above 2^64.
func amount(rng *rand.Rand) *big.Int {
	v := new(big.Int).SetUint64(rng.Uint64N(1_000_000) + 1)
	return v.Lsh(v, uint(rng.IntN(96)))
}

// part draws a value in [1, max] (max must be positive).
func part(rng *rand.Rand, maximum *big.Int) *big.Int {
	if maximum.IsUint64() {
		return new(big.Int).SetUint64(rng.Uint64N(maximum.Uint64()) + 1)
	}
	// Scale a random fraction of maximum; exact uniformity is irrelevant here.
	v := new(big.Int).Mul(maximum, big.NewInt(int64(rng.IntN(1000)+1)))
	return v.Quo(v, big.NewInt(1000))
}

// Block generates the logs of one block on top of the given canonical chain. txs bounds the
// number of transactions (0 yields an empty block).
func (w *World) Block(rng *rand.Rand, canonical []*Block, txs int) []LogSpec {
	return w.BlockAfter(rng, canonical, nil, txs)
}

// BlockAfter is Block on top of canonical followed by pending, not yet mined, blocks (used to
// build multi-block replacement forks).
func (w *World) BlockAfter(rng *rand.Rand, canonical []*Block, pending [][]LogSpec, txs int) []LogSpec {
	st := w.replay(canonical, pending)
	var out []LogSpec
	zero := common.Address{}
	allTokens := append(append([]common.Address{}, w.Tokens...), w.Asset)
	for tx := range uint(txs) {
		holder := w.Holders[rng.IntN(len(w.Holders))]
		other := w.Holders[rng.IntN(len(w.Holders))]
		token := allTokens[rng.IntN(len(allTokens))]
		switch rng.IntN(12) {
		case 0, 1: // mint
			v := amount(rng)
			out = append(out, transferLog(tx, token, zero, holder, v))
			st.add(token, holder, v)
		case 2, 3, 4: // transfer (possibly to self)
			bal := st.get(token, holder)
			if bal.Sign() <= 0 {
				continue
			}
			v := part(rng, bal)
			out = append(out, transferLog(tx, token, holder, other, v))
			st.add(token, holder, new(big.Int).Neg(v))
			st.add(token, other, v)
		case 5: // burn
			bal := st.get(token, holder)
			if bal.Sign() <= 0 {
				continue
			}
			v := part(rng, bal)
			out = append(out, transferLog(tx, token, holder, zero, v))
			st.add(token, holder, new(big.Int).Neg(v))
		case 6: // vault deposit: asset in, shares minted, Deposit event
			bal := st.get(w.Asset, holder)
			if bal.Sign() <= 0 {
				continue
			}
			a := part(rng, bal)
			shares := new(big.Int).Mul(a, new(big.Int).Add(st.supply, big.NewInt(1000)))
			shares.Quo(shares, new(big.Int).Add(st.assets, big.NewInt(1)))
			if shares.Sign() == 0 {
				continue
			}
			out = append(out,
				transferLog(tx, w.Asset, holder, w.Vault, a),
				transferLog(tx, w.Vault, zero, holder, shares),
				LogSpec{Tx: tx, Address: w.Vault, Topics: []common.Hash{decode.TopicDeposit, addrTopic(holder), addrTopic(holder)},
					Data: append(word(a), word(shares)...)})
			st.add(w.Asset, holder, new(big.Int).Neg(a))
			st.add(w.Asset, w.Vault, a)
			st.add(w.Vault, holder, shares)
			st.assets.Add(st.assets, a)
			st.supply.Add(st.supply, shares)
		case 7: // vault withdraw: shares burned, asset out, Withdraw event
			sh := st.get(w.Vault, holder)
			if sh.Sign() <= 0 || st.supply.Sign() == 0 {
				continue
			}
			s := part(rng, sh)
			a := new(big.Int).Mul(s, new(big.Int).Add(st.assets, big.NewInt(1)))
			a.Quo(a, new(big.Int).Add(st.supply, big.NewInt(1000)))
			if a.Cmp(st.assets) > 0 {
				a.Set(st.assets)
			}
			out = append(out,
				transferLog(tx, w.Vault, holder, zero, s),
				transferLog(tx, w.Asset, w.Vault, other, a),
				LogSpec{Tx: tx, Address: w.Vault, Topics: []common.Hash{decode.TopicWithdraw, addrTopic(holder), addrTopic(other), addrTopic(holder)},
					Data: append(word(a), word(s)...)})
			st.add(w.Vault, holder, new(big.Int).Neg(s))
			st.add(w.Asset, w.Vault, new(big.Int).Neg(a))
			st.add(w.Asset, other, a)
			st.assets.Sub(st.assets, a)
			st.supply.Sub(st.supply, s)
		case 8: // donation: asset sent straight to the vault (raises the share price)
			bal := st.get(w.Asset, holder)
			if bal.Sign() <= 0 {
				continue
			}
			a := part(rng, bal)
			out = append(out, transferLog(tx, w.Asset, holder, w.Vault, a))
			st.add(w.Asset, holder, new(big.Int).Neg(a))
			st.add(w.Asset, w.Vault, a)
			st.assets.Add(st.assets, a)
		case 9: // noise the indexer stores raw: an Approval
			out = append(out, LogSpec{Tx: tx, Address: token, Topics: []common.Hash{TopicApproval, addrTopic(holder), addrTopic(other)}, Data: word(amount(rng))})
		case 10: // malformed Transfers: ERC-721 shape (4 topics) or a dirty address topic
			if rng.IntN(2) == 0 {
				out = append(out, LogSpec{Tx: tx, Address: token, Topics: []common.Hash{decode.TopicTransfer, addrTopic(holder), addrTopic(other), common.BigToHash(big.NewInt(int64(rng.IntN(1000))))}})
			} else {
				dirty := addrTopic(holder)
				dirty[0] = 0xff
				out = append(out, LogSpec{Tx: tx, Address: token, Topics: []common.Hash{decode.TopicTransfer, dirty, addrTopic(other)}, Data: word(big.NewInt(1))})
			}
		case 11: // a contract nobody watches: never requested, never indexed
			out = append(out, transferLog(tx, w.Unwatched, holder, other, amount(rng)))
		}
	}
	return out
}
