// SPDX-License-Identifier: MIT

package indexer

import (
	"cmp"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"slices"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

// deriver applies decoded logs to the derived tables inside one store transaction. Balances and
// supplies are cached for the duration of the transaction and written once at the end.
//
// Idempotence: a derived row is keyed by (blockHash, logIndex); its balance and supply deltas
// are applied only when the insert actually created the row, so applying the same block twice
// changes nothing.
type deriver struct {
	tx          store.Tx
	vaults      map[common.Address]common.Address   // vault -> asset
	assetVaults map[common.Address][]common.Address // asset -> vaults

	balances map[balanceKey]*big.Int
	supplies map[common.Address]*big.Int
	dirtyBal map[balanceKey]bool
	dirtySup map[common.Address]bool

	stats applyStats
}

type balanceKey struct{ token, holder common.Address }

type applyStats struct {
	logs, undecodable, anomalies int
	events                       map[string]int
	retracted                    map[string]int
}

func newDeriver(tx store.Tx, c decode.Contracts) *deriver {
	d := &deriver{
		tx:          tx,
		vaults:      c.Vaults,
		assetVaults: map[common.Address][]common.Address{},
		balances:    map[balanceKey]*big.Int{},
		supplies:    map[common.Address]*big.Int{},
		dirtyBal:    map[balanceKey]bool{},
		dirtySup:    map[common.Address]bool{},
		stats:       applyStats{events: map[string]int{}, retracted: map[string]int{}},
	}
	for v, a := range c.Vaults {
		d.assetVaults[a] = append(d.assetVaults[a], v)
	}
	for a := range d.assetVaults {
		slices.SortFunc(d.assetVaults[a], func(x, y common.Address) int { return x.Cmp(y) })
	}
	return d
}

func (d *deriver) balance(token, holder common.Address) (*big.Int, error) {
	k := balanceKey{token, holder}
	if v, ok := d.balances[k]; ok {
		return v, nil
	}
	v, err := d.tx.Balance(token, holder)
	if err != nil {
		return nil, err
	}
	d.balances[k] = v
	return v, nil
}

func (d *deriver) supply(token common.Address) (*big.Int, error) {
	if v, ok := d.supplies[token]; ok {
		return v, nil
	}
	v, err := d.tx.Supply(token)
	if err != nil {
		return nil, err
	}
	d.supplies[token] = v
	return v, nil
}

func (d *deriver) addBalance(token, holder common.Address, delta *big.Int) error {
	v, err := d.balance(token, holder)
	if err != nil {
		return err
	}
	d.balances[balanceKey{token, holder}] = new(big.Int).Add(v, delta)
	d.dirtyBal[balanceKey{token, holder}] = true
	return nil
}

func (d *deriver) addSupply(token common.Address, delta *big.Int) error {
	v, err := d.supply(token)
	if err != nil {
		return err
	}
	d.supplies[token] = new(big.Int).Add(v, delta)
	d.dirtySup[token] = true
	return nil
}

// applyTransfer moves value from From to To (sign +1) or undoes that move (sign -1). The zero
// address is not a holder: a transfer from it is a mint, to it a burn.
func (d *deriver) applyTransfer(t *model.Transfer, sign int) error {
	v := t.Value.Big()
	if sign < 0 {
		v.Neg(v)
	}
	neg := new(big.Int).Neg(v)
	zero := common.Address{}
	if t.From != zero {
		if err := d.addBalance(t.Token, t.From, neg); err != nil {
			return err
		}
	} else if err := d.addSupply(t.Token, v); err != nil {
		return err
	}
	if t.To != zero {
		if err := d.addBalance(t.Token, t.To, v); err != nil {
			return err
		}
	} else if err := d.addSupply(t.Token, neg); err != nil {
		return err
	}
	return nil
}

// touchedVaults returns the vaults whose total assets or total supply a transfer changes.
func (d *deriver) touchedVaults(t *model.Transfer, into map[common.Address]bool) {
	zero := common.Address{}
	for _, v := range d.assetVaults[t.Token] {
		if t.From == v || t.To == v {
			into[v] = true
		}
	}
	if _, isVault := d.vaults[t.Token]; isVault && (t.From == zero || t.To == zero) {
		into[t.Token] = true
	}
}

func (d *deriver) flush() error {
	keys := make([]balanceKey, 0, len(d.dirtyBal))
	for k := range d.dirtyBal {
		keys = append(keys, k)
	}
	slices.SortFunc(keys, func(a, b balanceKey) int {
		return cmp.Or(a.token.Cmp(b.token), a.holder.Cmp(b.holder))
	})
	for _, k := range keys {
		v := d.balances[k]
		if v.Sign() < 0 {
			d.stats.anomalies++
		}
		if err := d.tx.SetBalance(k.token, k.holder, v); err != nil {
			return err
		}
	}
	tokens := make([]common.Address, 0, len(d.dirtySup))
	for t := range d.dirtySup {
		tokens = append(tokens, t)
	}
	slices.SortFunc(tokens, func(a, b common.Address) int { return a.Cmp(b) })
	for _, t := range tokens {
		if err := d.tx.SetSupply(t, d.supplies[t]); err != nil {
			return err
		}
	}
	clear(d.dirtyBal)
	clear(d.dirtySup)
	return nil
}

func (d *deriver) emit(kind string, block uint64, payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("indexer: encode %s event: %w", kind, err)
	}
	if _, err := d.tx.AppendEvent(kind, block, body); err != nil {
		return err
	}
	d.stats.events[kind]++
	return nil
}

// decodedLog pairs a raw log with its decoding (both nil when undecodable or untracked).
type decodedLog struct {
	raw      *types.Log
	transfer *model.Transfer
	vault    *model.VaultEvent
}

// applyBlock stores one header, its logs and everything derived from them.
func (d *deriver) applyBlock(h chain.Header, logs []decodedLog) error {
	if err := d.tx.InsertBlock(h); err != nil {
		return fmt.Errorf("indexer: insert block %d: %w", h.Number, err)
	}
	touched := map[common.Address]bool{}
	for _, l := range logs {
		raw := l.raw
		if _, err := d.tx.InsertLog(model.Log{
			Block: chain.BlockRef{Number: raw.BlockNumber, Hash: raw.BlockHash}, LogIndex: uint64(raw.Index),
			TxHash: raw.TxHash, TxIndex: uint64(raw.TxIndex), Address: raw.Address, Topics: raw.Topics, Data: raw.Data,
		}); err != nil {
			return err
		}
		d.stats.logs++
		switch {
		case l.transfer != nil:
			t := *l.transfer
			t.BlockTime = h.Time
			created, err := d.tx.InsertTransfer(t)
			if err != nil {
				return err
			}
			if !created {
				continue
			}
			if err := d.applyTransfer(&t, +1); err != nil {
				return err
			}
			d.touchedVaults(&t, touched)
			if err := d.emit(model.EventTransfer, h.Number, t); err != nil {
				return err
			}
		case l.vault != nil:
			v := *l.vault
			v.BlockTime = h.Time
			created, err := d.tx.InsertVaultEvent(v)
			if err != nil {
				return err
			}
			if created {
				if err := d.emit(model.EventVault, h.Number, v); err != nil {
					return err
				}
			}
		}
	}
	vaults := make([]common.Address, 0, len(touched))
	for v := range touched {
		vaults = append(vaults, v)
	}
	slices.SortFunc(vaults, func(a, b common.Address) int { return a.Cmp(b) })
	for _, v := range vaults {
		assets, err := d.balance(d.vaults[v], v)
		if err != nil {
			return err
		}
		supply, err := d.supply(v)
		if err != nil {
			return err
		}
		p := model.SharePrice{
			Block: h.Ref(), BlockTime: h.Time, Vault: v,
			TotalAssets: model.NewAmount(assets), TotalSupply: model.NewAmount(supply),
			PriceWad: model.ComputePriceWad(assets, supply),
		}
		if err := d.tx.InsertSharePrice(p); err != nil {
			return err
		}
		if err := d.emit(model.EventSharePrice, h.Number, p); err != nil {
			return err
		}
	}
	return nil
}

// retracted is one record removed by a rollback, with its position for ordering.
type retracted struct {
	block uint64
	order uint64 // log index; share prices sort after every log of their block
	kind  string
	item  any
}

// revertFrom undoes every indexed block with number >= from: balance and supply deltas are
// reversed, rows are deleted, and one `retract` event per removed record is appended to the
// outbox, newest first (the order in which a consumer must undo them).
func (d *deriver) revertFrom(from uint64) (store.Deleted, error) {
	transfers, err := d.tx.TransfersFrom(from)
	if err != nil {
		return store.Deleted{}, err
	}
	vaultEvents, err := d.tx.VaultEventsFrom(from)
	if err != nil {
		return store.Deleted{}, err
	}
	prices, err := d.tx.SharePricesFrom(from)
	if err != nil {
		return store.Deleted{}, err
	}
	var items []retracted
	for i := range transfers {
		t := &transfers[i]
		if err := d.applyTransfer(t, -1); err != nil {
			return store.Deleted{}, err
		}
		items = append(items, retracted{t.Block.Number, t.LogIndex, model.EventTransfer, *t})
	}
	for _, v := range vaultEvents {
		items = append(items, retracted{v.Block.Number, v.LogIndex, model.EventVault, v})
	}
	for _, p := range prices {
		items = append(items, retracted{p.Block.Number, math.MaxUint64, model.EventSharePrice, p})
	}
	slices.SortStableFunc(items, func(a, b retracted) int {
		return cmp.Or(cmp.Compare(b.block, a.block), cmp.Compare(b.order, a.order))
	})
	for _, it := range items {
		if err := d.emit(model.EventRetract, it.block, model.Retraction{Type: it.kind, Item: it.item}); err != nil {
			return store.Deleted{}, err
		}
		d.stats.retracted[it.kind]++
	}
	deleted, err := d.tx.DeleteFrom(from)
	if err != nil {
		return store.Deleted{}, err
	}
	return deleted, d.flush()
}
