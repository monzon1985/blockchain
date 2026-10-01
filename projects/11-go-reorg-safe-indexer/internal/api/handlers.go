// SPDX-License-Identifier: MIT

package api

import (
	"fmt"
	"math/big"
	"net/http"
	"slices"

	"github.com/ethereum/go-ethereum/common"
	"github.com/go-chi/chi/v5"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/indexer"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

// Meta describes the snapshot a page was read from.
type Meta struct {
	View      View            `json:"view"`
	Tip       *chain.BlockRef `json:"tip"`
	SafeHead  *uint64         `json:"safeHead"`
	ChainHead uint64          `json:"chainHead"`
	// AtBlock is set when balances were requested as of a past block (?atBlock=N).
	AtBlock *uint64 `json:"atBlock,omitempty"`
}

// Page describes pagination state.
type Page struct {
	Limit      int    `json:"limit"`
	HasMore    bool   `json:"hasMore"`
	NextCursor string `json:"nextCursor,omitempty"`
}

// ListResponse is the envelope of every list endpoint.
type ListResponse[T any] struct {
	Data []T  `json:"data"`
	Page Page `json:"page"`
	Meta Meta `json:"meta"`
}

func (s *Server) meta(r store.Reader, view View) (Meta, error) {
	cp, err := r.Checkpoint()
	if err != nil {
		return Meta{}, err
	}
	return Meta{View: view, Tip: cp.Tip, ChainHead: cp.ChainHead,
		SafeHead: indexer.SafeHead(cp.Tip, cp.ChainHead, s.cfg.Confirmations)}, nil
}

// visibleTo returns the highest block a view may see (nil: no bound), and false when the view
// sees nothing at all (safe view before any block is safe).
func visibleTo(m Meta) (*uint64, bool) {
	if m.View == ViewLatest {
		return nil, true
	}
	if m.SafeHead == nil {
		return nil, false
	}
	return m.SafeHead, true
}

// balanceBound returns the block balances must be computed at (nil: the tip) for a view and an
// optional ?atBlock. A block the view cannot see yet is rejected rather than silently replaced
// by an older one.
func balanceBound(m *Meta, at *uint64) (*uint64, error) {
	bound, _ := visibleTo(*m)
	if at == nil {
		return bound, nil
	}
	switch {
	case m.Tip == nil || *at > m.Tip.Number:
		return nil, badRequest("block_not_indexed", fmt.Sprintf("atBlock %d is above the indexed tip", *at))
	case bound != nil && *at > *bound:
		return nil, badRequest("block_not_safe", fmt.Sprintf("atBlock %d is above the safe head %d", *at, *bound))
	}
	m.AtBlock = at
	return at, nil
}

func capBlock(to, bound *uint64) *uint64 {
	if bound == nil {
		return to
	}
	if to == nil || *to > *bound {
		v := *bound
		return &v
	}
	return to
}

// --- status -----------------------------------------------------------------------------------

type statusResponse struct {
	ChainID       uint64          `json:"chainId"`
	Backend       string          `json:"backend"`
	Tip           *chain.BlockRef `json:"tip"`
	ChainHead     uint64          `json:"chainHead"`
	SafeHead      *uint64         `json:"safeHead"`
	Confirmations uint64          `json:"confirmations"`
	Reorgs        int64           `json:"reorgs"`
	LastReorg     *model.Reorg    `json:"lastReorg"`
	Events        struct {
		Oldest uint64 `json:"oldest"`
		Newest uint64 `json:"newest"`
	} `json:"events"`
	Ready     bool   `json:"ready"`
	NotReady  string `json:"notReadyReason,omitempty"`
	Contracts struct {
		Tokens []common.Address                  `json:"tokens"`
		Vaults map[common.Address]common.Address `json:"vaults"`
	} `json:"contracts"`
}

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	var out statusResponse
	err := s.st.View(r.Context(), func(rd store.Reader) error {
		m, err := s.meta(rd, ViewLatest)
		if err != nil {
			return err
		}
		out.Tip, out.ChainHead, out.SafeHead = m.Tip, m.ChainHead, m.SafeHead
		if out.Reorgs, err = rd.ReorgCount(); err != nil {
			return err
		}
		if out.LastReorg, _, err = rd.LastReorg(); err != nil {
			return err
		}
		out.Events.Oldest, out.Events.Newest, err = rd.EventBounds()
		return err
	})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out.ChainID, out.Backend, out.Confirmations = s.cfg.ChainID, s.st.Backend(), s.cfg.Confirmations
	out.Contracts.Tokens = s.cfg.Contracts.Addresses()
	out.Contracts.Vaults = s.cfg.Contracts.Vaults
	if rd, err := s.readiness(r.Context()); err == nil {
		out.Ready, out.NotReady = rd.Ready, rd.Reason
	}
	writeJSON(w, http.StatusOK, out)
}

// --- transfers --------------------------------------------------------------------------------

func (s *Server) transfers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	resp, err := func() (*ListResponse[model.Transfer], error) {
		view, err := parseView(q)
		if err != nil {
			return nil, err
		}
		limit, err := parseLimit(q)
		if err != nil {
			return nil, err
		}
		f := store.TransferFilter{Limit: limit + 1}
		for _, p := range []struct {
			name string
			dst  **common.Address
		}{{"token", &f.Token}, {"address", &f.Address}, {"from", &f.From}, {"to", &f.To}} {
			if *p.dst, err = optAddress(q, p.name); err != nil {
				return nil, err
			}
		}
		if f.Token != nil && !s.tokens[*f.Token] {
			return nil, notFound("not_indexed", "token "+f.Token.Hex()+" is not indexed")
		}
		if f.FromBlock, f.ToBlock, err = blockRange(q); err != nil {
			return nil, err
		}
		fp := queryFingerprint("transfers", q)
		c, err := decodeCursor(q, "transfers", fp)
		if err != nil {
			return nil, err
		}
		if c != nil {
			f.After = &store.Position{Block: c.Block, LogIndex: c.LogIndex}
		}
		out := &ListResponse[model.Transfer]{Data: []model.Transfer{}, Page: Page{Limit: limit}}
		err = s.st.View(r.Context(), func(rd store.Reader) error {
			if out.Meta, err = s.meta(rd, view); err != nil {
				return err
			}
			bound, visible := visibleTo(out.Meta)
			if !visible {
				return nil
			}
			f.ToBlock = capBlock(f.ToBlock, bound)
			rows, err := rd.Transfers(f)
			if err != nil {
				return err
			}
			if len(rows) > limit {
				last := rows[limit-1]
				out.Page.HasMore = true
				out.Page.NextCursor = encodeCursor(cursor{Endpoint: "transfers", Query: fp, Block: last.Block.Number, LogIndex: last.LogIndex})
				rows = rows[:limit]
			}
			out.Data = rows
			return nil
		})
		return out, err
	}()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// --- vault events and share prices ------------------------------------------------------------

func (s *Server) vaultParam(r *http.Request) (common.Address, error) {
	v, err := parseAddress("vault", chi.URLParam(r, "vault"))
	if err != nil {
		return v, err
	}
	if !s.vaults[v] {
		return v, notFound("not_indexed", "vault "+v.Hex()+" is not indexed")
	}
	return v, nil
}

func (s *Server) vaultEvents(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	resp, err := func() (*ListResponse[model.VaultEvent], error) {
		vault, err := s.vaultParam(r)
		if err != nil {
			return nil, err
		}
		view, err := parseView(q)
		if err != nil {
			return nil, err
		}
		limit, err := parseLimit(q)
		if err != nil {
			return nil, err
		}
		f := store.VaultEventFilter{Vault: vault, Limit: limit + 1}
		if f.FromBlock, f.ToBlock, err = blockRange(q); err != nil {
			return nil, err
		}
		fp := queryFingerprint("vault_events", q, vault.Hex())
		c, err := decodeCursor(q, "vault_events", fp)
		if err != nil {
			return nil, err
		}
		if c != nil {
			f.After = &store.Position{Block: c.Block, LogIndex: c.LogIndex}
		}
		out := &ListResponse[model.VaultEvent]{Data: []model.VaultEvent{}, Page: Page{Limit: limit}}
		err = s.st.View(r.Context(), func(rd store.Reader) error {
			if out.Meta, err = s.meta(rd, view); err != nil {
				return err
			}
			bound, visible := visibleTo(out.Meta)
			if !visible {
				return nil
			}
			f.ToBlock = capBlock(f.ToBlock, bound)
			rows, err := rd.VaultEvents(f)
			if err != nil {
				return err
			}
			if len(rows) > limit {
				last := rows[limit-1]
				out.Page.HasMore = true
				out.Page.NextCursor = encodeCursor(cursor{Endpoint: "vault_events", Query: fp, Block: last.Block.Number, LogIndex: last.LogIndex})
				rows = rows[:limit]
			}
			out.Data = rows
			return nil
		})
		return out, err
	}()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) sharePrices(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	resp, err := func() (*ListResponse[model.SharePrice], error) {
		vault, err := s.vaultParam(r)
		if err != nil {
			return nil, err
		}
		view, err := parseView(q)
		if err != nil {
			return nil, err
		}
		limit, err := parseLimit(q)
		if err != nil {
			return nil, err
		}
		f := store.SharePriceFilter{Vault: vault, Limit: limit + 1}
		if f.FromBlock, f.ToBlock, err = blockRange(q); err != nil {
			return nil, err
		}
		fp := queryFingerprint("share_prices", q, vault.Hex())
		c, err := decodeCursor(q, "share_prices", fp)
		if err != nil {
			return nil, err
		}
		if c != nil {
			after := c.Block
			f.After = &after
		}
		out := &ListResponse[model.SharePrice]{Data: []model.SharePrice{}, Page: Page{Limit: limit}}
		err = s.st.View(r.Context(), func(rd store.Reader) error {
			if out.Meta, err = s.meta(rd, view); err != nil {
				return err
			}
			bound, visible := visibleTo(out.Meta)
			if !visible {
				return nil
			}
			f.ToBlock = capBlock(f.ToBlock, bound)
			rows, err := rd.SharePrices(f)
			if err != nil {
				return err
			}
			if len(rows) > limit {
				last := rows[limit-1]
				out.Page.HasMore = true
				out.Page.NextCursor = encodeCursor(cursor{Endpoint: "share_prices", Query: fp, Block: last.Block.Number})
				rows = rows[:limit]
			}
			out.Data = rows
			return nil
		})
		return out, err
	}()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// --- balances ---------------------------------------------------------------------------------

// allTransfers pages through every transfer matching f (used to compute balances below the tip;
// internal reads are never truncated either).
func allTransfers(rd store.Reader, f store.TransferFilter) ([]model.Transfer, error) {
	const page = 5000
	var out []model.Transfer
	for {
		f.Limit = page
		rows, err := rd.Transfers(f)
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
		if len(rows) < page {
			return out, nil
		}
		last := rows[len(rows)-1]
		f.After = &store.Position{Block: last.Block.Number, LogIndex: last.LogIndex}
	}
}

// deltaAfter returns each holder's net balance change over the given transfers.
func deltaAfter(transfers []model.Transfer) map[common.Address]*big.Int {
	d := map[common.Address]*big.Int{}
	add := func(a common.Address, v *big.Int) {
		if a == (common.Address{}) {
			return
		}
		if d[a] == nil {
			d[a] = new(big.Int)
		}
		d[a].Add(d[a], v)
	}
	for _, t := range transfers {
		v := t.Value.Big()
		add(t.To, v)
		add(t.From, new(big.Int).Neg(v))
	}
	return d
}

// holderBatch bounds the holders looked up per query. SQLite accepts at most 32,766 bound
// variables per statement and PostgreSQL 65,535, and a busy token can have more holders touched
// above the requested block than that, so the lookup is split.
const holderBatch = 1000

// holderBalances returns the latest balances of the given holders of token, in batches.
func holderBalances(rd store.Reader, token common.Address, holders []common.Address) ([]model.Balance, error) {
	var out []model.Balance
	for batch := range slices.Chunk(holders, holderBatch) {
		rows, err := rd.Balances(store.BalanceFilter{Token: token, Holders: batch, Limit: len(batch)})
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
	}
	return out, nil
}

// balancesAt lists the holders of token as of block `at` (the safe head, or an ?atBlock below
// the tip), in address order, starting after `after`, returning at most limit+1 rows (the extra
// row signals hasMore).
//
// Stored balances are "latest". A holder's balance at `at` is its latest balance minus its net
// change in the blocks above `at`. Only holders touched above `at` (set A) can differ, and at
// most |A| of the first limit+|A|+1 latest holders belong to A, so those rows plus A contain the
// first limit+1 holders at `at`. The cost is proportional to the transfers above `at`.
func balancesAt(rd store.Reader, token common.Address, after *common.Address, holder *common.Address, limit int, at uint64) ([]model.Balance, error) {
	from := at + 1
	later, err := allTransfers(rd, store.TransferFilter{Token: &token, FromBlock: &from, Address: holder})
	if err != nil {
		return nil, err
	}
	delta := deltaAfter(later)
	affected := make([]common.Address, 0, len(delta))
	for a := range delta {
		if (after == nil || a.Cmp(*after) > 0) && (holder == nil || a == *holder) {
			affected = append(affected, a)
		}
	}
	f := store.BalanceFilter{Token: token, After: after, Limit: limit + len(affected) + 1}
	if holder != nil {
		f.Holders = []common.Address{*holder}
	}
	rows, err := rd.Balances(f)
	if err != nil {
		return nil, err
	}
	latest := map[common.Address]*big.Int{}
	for _, b := range rows {
		latest[b.Holder] = b.Balance.Big()
	}
	if len(affected) > 0 {
		more, err := holderBalances(rd, token, affected)
		if err != nil {
			return nil, err
		}
		for _, b := range more {
			latest[b.Holder] = b.Balance.Big()
		}
		for _, a := range affected {
			if latest[a] == nil {
				latest[a] = new(big.Int)
			}
		}
	}
	out := make([]model.Balance, 0, len(latest))
	for h, v := range latest {
		if d := delta[h]; d != nil {
			v = new(big.Int).Sub(v, d)
		}
		if v.Sign() != 0 {
			out = append(out, model.Balance{Token: token, Holder: h, Balance: model.NewAmount(v)})
		}
	}
	slices.SortFunc(out, func(a, b model.Balance) int { return a.Holder.Cmp(b.Holder) })
	if len(out) > limit+1 {
		out = out[:limit+1]
	}
	return out, nil
}

func (s *Server) tokenBalances(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	resp, err := func() (*ListResponse[model.Balance], error) {
		token, err := parseAddress("token", chi.URLParam(r, "token"))
		if err != nil {
			return nil, err
		}
		if !s.tokens[token] {
			return nil, notFound("not_indexed", "token "+token.Hex()+" is not indexed")
		}
		view, err := parseView(q)
		if err != nil {
			return nil, err
		}
		limit, err := parseLimit(q)
		if err != nil {
			return nil, err
		}
		holder, err := optAddress(q, "holder")
		if err != nil {
			return nil, err
		}
		at, err := optBlock(q, "atBlock")
		if err != nil {
			return nil, err
		}
		fp := queryFingerprint("balances", q, token.Hex())
		c, err := decodeCursor(q, "balances", fp)
		if err != nil {
			return nil, err
		}
		var after *common.Address
		if c != nil {
			a, err := parseAddress("cursor holder", c.Holder)
			if err != nil {
				return nil, badRequest("invalid_cursor", "cursor is malformed")
			}
			after = &a
		}
		out := &ListResponse[model.Balance]{Data: []model.Balance{}, Page: Page{Limit: limit}}
		err = s.st.View(r.Context(), func(rd store.Reader) error {
			if out.Meta, err = s.meta(rd, view); err != nil {
				return err
			}
			if _, visible := visibleTo(out.Meta); !visible {
				return nil
			}
			bound, err := balanceBound(&out.Meta, at)
			if err != nil {
				return err
			}
			var rows []model.Balance
			if bound == nil || (out.Meta.Tip != nil && *bound >= out.Meta.Tip.Number) {
				f := store.BalanceFilter{Token: token, After: after, Limit: limit + 1}
				if holder != nil {
					f.Holders = []common.Address{*holder}
				}
				rows, err = rd.Balances(f)
			} else {
				rows, err = balancesAt(rd, token, after, holder, limit, *bound)
			}
			if err != nil {
				return err
			}
			if len(rows) > limit {
				out.Page.HasMore = true
				out.Page.NextCursor = encodeCursor(cursor{Endpoint: "balances", Query: fp, Holder: rows[limit-1].Holder.Hex()})
				rows = rows[:limit]
			}
			out.Data = rows
			return nil
		})
		return out, err
	}()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// accountBalances lists every non-zero balance of one account across the indexed tokens. The
// result is bounded by the number of indexed tokens, so it is returned in one page. The zero
// address never holds a balance (mints and burns move supply, not a balance), in every view.
func (s *Server) accountBalances(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	resp, err := func() (*ListResponse[model.Balance], error) {
		account, err := parseAddress("address", chi.URLParam(r, "address"))
		if err != nil {
			return nil, err
		}
		view, err := parseView(q)
		if err != nil {
			return nil, err
		}
		at, err := optBlock(q, "atBlock")
		if err != nil {
			return nil, err
		}
		out := &ListResponse[model.Balance]{Data: []model.Balance{}, Page: Page{Limit: len(s.tokens)}}
		err = s.st.View(r.Context(), func(rd store.Reader) error {
			if out.Meta, err = s.meta(rd, view); err != nil {
				return err
			}
			if _, visible := visibleTo(out.Meta); !visible {
				return nil
			}
			bound, err := balanceBound(&out.Meta, at)
			if err != nil {
				return err
			}
			if account == (common.Address{}) {
				return nil
			}
			rows, err := rd.HolderBalances(account)
			if err != nil {
				return err
			}
			if bound == nil || (out.Meta.Tip != nil && *bound >= out.Meta.Tip.Number) {
				out.Data = rows
				return nil
			}
			from := *bound + 1
			later, err := allTransfers(rd, store.TransferFilter{Address: &account, FromBlock: &from})
			if err != nil {
				return err
			}
			byToken := map[common.Address]*big.Int{}
			for _, b := range rows {
				byToken[b.Token] = b.Balance.Big()
			}
			for _, t := range later {
				v := t.Value.Big()
				cur := byToken[t.Token]
				if cur == nil {
					cur = new(big.Int)
				}
				// Undo the transfer: the balance at `bound` excludes the blocks above it.
				if t.To == account {
					cur = new(big.Int).Sub(cur, v)
				}
				if t.From == account {
					cur = new(big.Int).Add(cur, v)
				}
				byToken[t.Token] = cur
			}
			for token, v := range byToken {
				if v.Sign() != 0 {
					out.Data = append(out.Data, model.Balance{Token: token, Holder: account, Balance: model.NewAmount(v)})
				}
			}
			slices.SortFunc(out.Data, func(a, b model.Balance) int { return a.Token.Cmp(b.Token) })
			return nil
		})
		return out, err
	}()
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}
