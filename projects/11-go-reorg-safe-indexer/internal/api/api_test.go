// SPDX-License-Identifier: MIT

package api_test

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/api"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/decode"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fakechain"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/fetch"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/indexer"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/metrics"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store/sqlite"
)

const confirmations = 4

// fixture is an indexed fake chain (with reorgs behind it) served by the API.
type fixture struct {
	t      *testing.T
	fc     *fakechain.Chain
	w      *fakechain.World
	st     store.Store
	eng    *indexer.Engine
	m      *metrics.Metrics
	server *api.Server
	url    string
	rng    *rand.Rand

	// health is swapped by TestHealthAndReadiness while the server reads it.
	healthMu sync.Mutex
	health   func(context.Context) (api.Health, error)
}

func (f *fixture) setHealth(h func(context.Context) (api.Health, error)) {
	f.healthMu.Lock()
	f.health = h
	f.healthMu.Unlock()
}

func (f *fixture) currentHealth(ctx context.Context) (api.Health, error) {
	f.healthMu.Lock()
	h := f.health
	f.healthMu.Unlock()
	return h(ctx)
}

func newFixture(t *testing.T, blocks int, cfgFn func(*api.Config)) *fixture {
	t.Helper()
	ctx := context.Background()
	f := &fixture{t: t, fc: fakechain.New(31337), w: fakechain.NewWorld(8), m: metrics.New(), rng: rand.New(rand.NewPCG(42, 43))}
	for range blocks {
		f.mine()
	}
	st, err := sqlite.Open(ctx, filepath.Join(t.TempDir(), "api.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	f.st = st
	f.eng, err = indexer.New(ctx, indexer.Config{
		Start: 1, Confirmations: confirmations, PollInterval: time.Millisecond, ReorgWindow: 64, EventRetention: 1 << 40,
		Contracts: f.w.Contracts(),
		Fetch:     fetch.Config{InitialSpan: 8, MaxSpan: 64, Concurrency: 2, Backoff: time.Millisecond},
	}, f.fc, st, f.m, nil)
	if err != nil {
		t.Fatal(err)
	}
	f.sync()
	f.setHealth(func(context.Context) (api.Health, error) {
		s := f.eng.Status()
		return api.Health{Tip: s.Tip, ChainHead: s.ChainHead, UpdatedAt: s.LastSync, LastError: s.LastError}, nil
	})
	cfg := api.Config{ChainID: 31337, Confirmations: confirmations, Contracts: f.w.Contracts(), MaxLag: 2,
		StaleAfter: time.Minute, PollInterval: 20 * time.Millisecond, Heartbeat: time.Hour}
	if cfgFn != nil {
		cfgFn(&cfg)
	}
	f.server = api.New(cfg, st, f.currentHealth, f.m, nil, nil)
	f.eng.OnCommit = f.server.Hub().Notify
	srv := httptest.NewServer(f.server.Handler())
	t.Cleanup(srv.Close)
	t.Cleanup(f.server.CloseStreams)
	f.url = srv.URL
	return f
}

func (f *fixture) mine() {
	f.fc.Mine(f.w.Block(f.rng, f.fc.Canonical(0), f.rng.IntN(7)))
}

func (f *fixture) reorg(depth int) {
	canon := f.fc.Canonical(0)
	base := canon[:len(canon)-depth]
	var blocks [][]fakechain.LogSpec
	for range depth + 1 {
		blocks = append(blocks, f.w.BlockAfter(f.rng, base, blocks, f.rng.IntN(7)))
	}
	if err := f.fc.Reorg(depth, blocks); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) sync() {
	f.t.Helper()
	if err := f.eng.SyncUntil(context.Background(), f.fc.Head().Number); err != nil {
		f.t.Fatal(err)
	}
}

// get fetches path and decodes the JSON body into out (when non-nil).
func (f *fixture) get(path string, out any) int {
	f.t.Helper()
	resp, err := http.Get(f.url + path)
	if err != nil {
		f.t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			f.t.Fatalf("GET %s: %v: %s", path, err, body)
		}
	}
	return resp.StatusCode
}

type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type page[T any] struct {
	Data []T `json:"data"`
	Page struct {
		Limit      int    `json:"limit"`
		HasMore    bool   `json:"hasMore"`
		NextCursor string `json:"nextCursor"`
	} `json:"page"`
	Meta api.Meta `json:"meta"`
}

// all pages through path with the given limit and returns every row.
func all[T any](f *fixture, path string, limit int) ([]T, api.Meta) {
	f.t.Helper()
	var out []T
	var meta api.Meta
	cursor := ""
	for pages := 0; ; pages++ {
		if pages > 10_000 {
			f.t.Fatal("pagination does not terminate")
		}
		u := path + sep(path) + "limit=" + strconv.Itoa(limit)
		if cursor != "" {
			u += "&cursor=" + url.QueryEscape(cursor)
		}
		var p page[T]
		if code := f.get(u, &p); code != http.StatusOK {
			f.t.Fatalf("GET %s: %d", u, code)
		}
		if len(p.Data) > limit || p.Page.Limit != limit {
			f.t.Fatalf("page of %d rows for limit %d", len(p.Data), limit)
		}
		if p.Page.HasMore != (p.Page.NextCursor != "") {
			f.t.Fatalf("hasMore %v with cursor %q", p.Page.HasMore, p.Page.NextCursor)
		}
		if p.Page.HasMore && len(p.Data) != limit {
			f.t.Fatalf("short page (%d of %d) claims more data", len(p.Data), limit)
		}
		out = append(out, p.Data...)
		meta = p.Meta
		if !p.Page.HasMore {
			return out, meta
		}
		cursor = p.Page.NextCursor
	}
}

func sep(path string) string {
	if strings.Contains(path, "?") {
		return "&"
	}
	return "?"
}

func (f *fixture) storedTransfers() []model.Transfer {
	f.t.Helper()
	var out []model.Transfer
	if err := f.st.View(context.Background(), func(r store.Reader) error {
		var err error
		out, err = r.TransfersFrom(0)
		return err
	}); err != nil {
		f.t.Fatal(err)
	}
	return out
}

func key(t model.Transfer) string { return fmt.Sprintf("%d/%d", t.Block.Number, t.LogIndex) }

func keys(ts []model.Transfer) []string {
	out := make([]string, len(ts))
	for i, t := range ts {
		out[i] = key(t)
	}
	return out
}

// replayBalances computes every balance of token at block `at` from the stored transfers.
func replayBalances(ts []model.Transfer, token common.Address, at uint64) map[common.Address]*big.Int {
	bal := map[common.Address]*big.Int{}
	add := func(a common.Address, v *big.Int) {
		if a == (common.Address{}) {
			return
		}
		if bal[a] == nil {
			bal[a] = new(big.Int)
		}
		bal[a].Add(bal[a], v)
	}
	for _, t := range ts {
		if t.Token != token || t.Block.Number > at {
			continue
		}
		add(t.To, t.Value.Big())
		add(t.From, new(big.Int).Neg(t.Value.Big()))
	}
	for a, v := range bal {
		if v.Sign() == 0 {
			delete(bal, a)
		}
	}
	return bal
}

func TestTransfersPaginationIsCompleteForEveryFilter(t *testing.T) {
	f := newFixture(t, 60, nil)
	f.reorg(5)
	f.sync()
	stored := f.storedTransfers()
	if len(stored) < 50 {
		t.Fatalf("fixture too small: %d transfers", len(stored))
	}
	alice := f.w.Holders[1]
	tip := f.eng.Status().Tip.Number
	safe := tip - confirmations
	cases := []struct {
		query string
		keep  func(model.Transfer) bool
	}{
		{"", func(model.Transfer) bool { return true }},
		{"token=" + f.w.Asset.Hex(), func(t model.Transfer) bool { return t.Token == f.w.Asset }},
		{"address=" + alice.Hex(), func(t model.Transfer) bool { return t.From == alice || t.To == alice }},
		{"from=" + alice.Hex(), func(t model.Transfer) bool { return t.From == alice }},
		{"to=" + strings.ToLower(alice.Hex()), func(t model.Transfer) bool { return t.To == alice }},
		{"fromBlock=10&toBlock=30", func(t model.Transfer) bool { return t.Block.Number >= 10 && t.Block.Number <= 30 }},
		{"token=" + f.w.Vault.Hex() + "&address=" + alice.Hex() + "&fromBlock=5", func(t model.Transfer) bool {
			return t.Token == f.w.Vault && (t.From == alice || t.To == alice) && t.Block.Number >= 5
		}},
		{"view=safe", func(t model.Transfer) bool { return t.Block.Number <= safe }},
		{"view=safe&toBlock=" + strconv.FormatUint(tip, 10), func(t model.Transfer) bool { return t.Block.Number <= safe }},
	}
	for _, tc := range cases {
		t.Run(tc.query, func(t *testing.T) {
			var want []model.Transfer
			for _, tr := range stored {
				if tc.keep(tr) {
					want = append(want, tr)
				}
			}
			for _, limit := range []int{1, 3, 7, 1000} {
				got, meta := all[model.Transfer](f, "/v1/transfers?"+tc.query, limit)
				if !slices.Equal(keys(got), keys(want)) {
					t.Fatalf("limit %d: got %d transfers, want %d", limit, len(got), len(want))
				}
				if meta.Tip == nil || meta.Tip.Number != tip || meta.SafeHead == nil || *meta.SafeHead != safe {
					t.Fatalf("meta %+v", meta)
				}
			}
		})
	}
	// A transfer is the exact stored object, uint256 values as decimal strings.
	var p page[model.Transfer]
	f.get("/v1/transfers?limit=1", &p)
	b1, _ := json.Marshal(p.Data[0])
	b2, _ := json.Marshal(stored[0])
	if string(b1) != string(b2) {
		t.Fatalf("API transfer %s differs from stored %s", b1, b2)
	}
}

func TestRequestValidation(t *testing.T) {
	f := newFixture(t, 10, nil)
	var p page[model.Transfer]
	f.get("/v1/transfers?limit=2", &p)
	cursor := url.QueryEscape(p.Page.NextCursor)
	stranger := "0x" + strings.Repeat("ab", 20)
	cases := []struct {
		path   string
		status int
		code   string
	}{
		{"/v1/transfers?limit=0", 400, "invalid_limit"},
		{"/v1/transfers?limit=1001", 400, "invalid_limit"},
		{"/v1/transfers?limit=ten", 400, "invalid_limit"},
		{"/v1/transfers?address=0x1234", 400, "invalid_address"},
		{"/v1/transfers?from=" + strings.Repeat("ab", 20), 400, "invalid_address"},
		{"/v1/transfers?fromBlock=-1", 400, "invalid_block"},
		{"/v1/transfers?fromBlock=9&toBlock=3", 400, "invalid_block_range"},
		{"/v1/transfers?view=final", 400, "invalid_view"},
		{"/v1/transfers?token=" + stranger, 404, "not_indexed"},
		{"/v1/transfers?cursor=!!!", 400, "invalid_cursor"},
		{"/v1/transfers?cursor=bm90IGpzb24", 400, "invalid_cursor"},
		{"/v1/transfers?limit=2&cursor=" + cursor + "&token=" + f.w.Asset.Hex(), 400, "cursor_mismatch"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/events?cursor=" + cursor, 400, "cursor_mismatch"},
		{"/v1/tokens/" + stranger + "/balances", 404, "not_indexed"},
		{"/v1/tokens/nope/balances", 400, "invalid_address"},
		{"/v1/tokens/" + f.w.Asset.Hex() + "/balances?holder=x", 400, "invalid_address"},
		{"/v1/tokens/" + f.w.Asset.Hex() + "/balances?view=x", 400, "invalid_view"},
		{"/v1/tokens/" + f.w.Asset.Hex() + "/balances?limit=0", 400, "invalid_limit"},
		{"/v1/tokens/" + f.w.Asset.Hex() + "/balances?atBlock=x", 400, "invalid_block"},
		{"/v1/tokens/" + f.w.Asset.Hex() + "/balances?atBlock=11", 400, "block_not_indexed"},
		{"/v1/tokens/" + f.w.Asset.Hex() + "/balances?view=safe&atBlock=" + strconv.Itoa(10-confirmations+1), 400, "block_not_safe"},
		{"/v1/accounts/0x12/balances", 400, "invalid_address"},
		{"/v1/accounts/" + stranger + "/balances?view=x", 400, "invalid_view"},
		{"/v1/accounts/" + stranger + "/balances?atBlock=99", 400, "block_not_indexed"},
		{"/v1/accounts/" + stranger + "/balances?atBlock=-3", 400, "invalid_block"},
		{"/v1/vaults/" + f.w.Asset.Hex() + "/events", 404, "not_indexed"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/events?view=x", 400, "invalid_view"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/events?limit=x", 400, "invalid_limit"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/events?fromBlock=x", 400, "invalid_block"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/share-prices?toBlock=x", 400, "invalid_block"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/share-prices?view=x", 400, "invalid_view"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/share-prices?limit=x", 400, "invalid_limit"},
		{"/v1/vaults/" + f.w.Vault.Hex() + "/share-prices?cursor=e30", 400, "invalid_cursor"},
		{"/v1/vaults/zz/share-prices", 400, "invalid_address"},
		{"/v1/nothing", 404, "not_found"},
	}
	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			var e errorBody
			if got := f.get(tc.path, &e); got != tc.status || e.Error.Code != tc.code || e.Error.Message == "" {
				t.Fatalf("status %d code %q (%s), want %d %q", got, e.Error.Code, e.Error.Message, tc.status, tc.code)
			}
		})
	}
	resp, err := http.Post(f.url+"/v1/transfers", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST: %d", resp.StatusCode)
	}
}

// TestBalancesMatchAReplayOfTransfers checks the latest view, the safe view and ?atBlock against
// balances recomputed from scratch from the stored transfers, for both balance endpoints and
// with small pages (the safe view rewinds holders touched above the safe head, whose position in
// the latest ordering differs).
func TestBalancesMatchAReplayOfTransfers(t *testing.T) {
	f := newFixture(t, 70, nil)
	stored := f.storedTransfers()
	tip := f.eng.Status().Tip.Number
	safe := tip - confirmations
	tokens := f.w.Contracts().Addresses()
	views := []struct {
		query string
		at    uint64
	}{
		{"", tip},
		{"view=safe", safe},
		{"atBlock=" + strconv.FormatUint(tip, 10), tip},
		{"atBlock=1", 1},
		{"atBlock=33", 33},
		{"view=safe&atBlock=20", 20},
	}
	for _, v := range views {
		for _, token := range tokens {
			want := replayBalances(stored, token, v.at)
			for _, limit := range []int{1, 2, 5, 1000} {
				got, meta := all[model.Balance](f, "/v1/tokens/"+token.Hex()+"/balances?"+v.query, limit)
				if len(got) != len(want) {
					t.Fatalf("%s %s limit %d: %d holders, want %d", token, v.query, limit, len(got), len(want))
				}
				for i, b := range got {
					if i > 0 && got[i-1].Holder.Cmp(b.Holder) >= 0 {
						t.Fatalf("holders out of order")
					}
					if w := want[b.Holder]; w == nil || w.Cmp(b.Balance.Big()) != 0 || b.Token != token {
						t.Fatalf("%s %s: %s holds %s, replay says %v", token, v.query, b.Holder, b.Balance, w)
					}
				}
				if strings.Contains(v.query, "atBlock") && (meta.AtBlock == nil || *meta.AtBlock != v.at) {
					t.Fatalf("meta.atBlock %v", meta.AtBlock)
				}
			}
			// The holder filter returns exactly that holder's row.
			for _, h := range f.w.Holders[:3] {
				var p page[model.Balance]
				f.get("/v1/tokens/"+token.Hex()+"/balances?holder="+h.Hex()+sep("?")+v.query, &p)
				if w := want[h]; (w == nil) != (len(p.Data) == 0) || (w != nil && p.Data[0].Balance.Big().Cmp(w) != 0) {
					t.Fatalf("holder filter %s %s: %+v, want %v", h, v.query, p.Data, w)
				}
			}
		}
		// The zero address (the mint source and burn sink) never holds a balance, in any view.
		for _, h := range append(slices.Clone(f.w.Holders), common.Address{}) {
			var p page[model.Balance]
			if code := f.get("/v1/accounts/"+h.Hex()+"/balances?"+v.query, &p); code != 200 {
				t.Fatalf("account balances: %d", code)
			}
			n := 0
			for _, token := range tokens {
				if w := replayBalances(stored, token, v.at)[h]; w != nil {
					n++
					i := slices.IndexFunc(p.Data, func(b model.Balance) bool { return b.Token == token })
					if i < 0 || p.Data[i].Balance.Big().Cmp(w) != 0 || p.Data[i].Holder != h {
						t.Fatalf("account %s %s token %s: %+v, want %s", h, v.query, token, p.Data, w)
					}
				}
			}
			if len(p.Data) != n {
				t.Fatalf("account %s %s: %d balances, want %d", h, v.query, len(p.Data), n)
			}
		}
	}
}

// TestHistoricalBalancesOfABusyToken: ?atBlock on a token with more holders touched above the
// block than SQLite accepts bound variables in one statement (32,766) must still answer, and
// answer exactly. 33,000 holders each received 1 at block 1 and 2 at block 2.
func TestHistoricalBalancesOfABusyToken(t *testing.T) {
	if testing.Short() {
		t.Skip("writes 66,000 transfers")
	}
	const holders = 33_000
	ctx := context.Background()
	st, err := sqlite.Open(ctx, filepath.Join(t.TempDir(), "busy.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	token := common.Address{0x70, 1}
	holder := func(i int) common.Address {
		var a common.Address
		a[0] = 0xaa
		a[16], a[17], a[18], a[19] = byte(i>>24), byte(i>>16), byte(i>>8), byte(i)
		return a
	}
	blockRef := func(n uint64) chain.BlockRef { return chain.BlockRef{Number: n, Hash: common.Hash{byte(n)}} }
	err = st.Update(ctx, func(tx store.Tx) error {
		tip := blockRef(2)
		if err := tx.MoveTip(nil, &tip, 2, 0); err != nil {
			return err
		}
		for i := range holders {
			h := holder(i)
			for n, v := range map[uint64]int64{1: 1, 2: 2} {
				if _, err := tx.InsertTransfer(model.Transfer{Block: blockRef(n), LogIndex: uint64(i), Token: token, To: h,
					Value: model.NewAmount(big.NewInt(v))}); err != nil {
					return err
				}
			}
			if err := tx.SetBalance(token, h, big.NewInt(3)); err != nil {
				return err
			}
		}
		return tx.SetSupply(token, big.NewInt(3*holders))
	})
	if err != nil {
		t.Fatal(err)
	}
	server := api.New(api.Config{ChainID: 1, Contracts: decode.Contracts{Tokens: []common.Address{token}}}, st,
		func(context.Context) (api.Health, error) { return api.Health{}, nil }, metrics.New(), nil, nil)
	srv := httptest.NewServer(server.Handler())
	t.Cleanup(srv.Close)
	t.Cleanup(server.CloseStreams)
	f := &fixture{t: t, url: srv.URL}

	start := time.Now()
	var p page[model.Balance]
	if code := f.get("/v1/tokens/"+token.Hex()+"/balances?atBlock=1&limit=1000", &p); code != http.StatusOK {
		t.Fatalf("atBlock=1 on %d touched holders: HTTP %d", holders, code)
	}
	if len(p.Data) != 1000 || !p.Page.HasMore || p.Meta.AtBlock == nil || *p.Meta.AtBlock != 1 {
		t.Fatalf("first page: %d rows, hasMore %v, atBlock %v", len(p.Data), p.Page.HasMore, p.Meta.AtBlock)
	}
	for i, b := range p.Data {
		if b.Holder != holder(i) || b.Balance.Big().Int64() != 1 {
			t.Fatalf("row %d: %s holds %s at block 1, want %s holding 1", i, b.Holder, b.Balance, holder(i))
		}
	}
	// The holder filter and the account endpoint take the same path.
	last := holder(holders - 1)
	p = page[model.Balance]{}
	if code := f.get("/v1/tokens/"+token.Hex()+"/balances?atBlock=1&holder="+last.Hex(), &p); code != http.StatusOK ||
		len(p.Data) != 1 || p.Data[0].Balance.Big().Int64() != 1 {
		t.Fatalf("holder filter: HTTP %d, %+v", code, p.Data)
	}
	p = page[model.Balance]{}
	if code := f.get("/v1/accounts/"+last.Hex()+"/balances?atBlock=1", &p); code != http.StatusOK ||
		len(p.Data) != 1 || p.Data[0].Balance.Big().Int64() != 1 {
		t.Fatalf("account endpoint: HTTP %d, %+v", code, p.Data)
	}
	t.Logf("%d holders touched above the block: first page and lookups in %s", holders, time.Since(start).Round(time.Millisecond))
}

func TestVaultEndpoints(t *testing.T) {
	f := newFixture(t, 80, nil)
	var events []model.VaultEvent
	var prices []model.SharePrice
	if err := f.st.View(context.Background(), func(r store.Reader) error {
		var err error
		if events, err = r.VaultEventsFrom(0); err != nil {
			return err
		}
		prices, err = r.SharePricesFrom(0)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if len(events) < 3 || len(prices) < 3 {
		t.Fatalf("fixture has %d vault events and %d share prices", len(events), len(prices))
	}
	base := "/v1/vaults/" + f.w.Vault.Hex()
	for _, limit := range []int{1, 4, 1000} {
		gotE, _ := all[model.VaultEvent](f, base+"/events", limit)
		gotP, _ := all[model.SharePrice](f, base+"/share-prices", limit)
		if len(gotE) != len(events) || len(gotP) != len(prices) {
			t.Fatalf("limit %d: %d/%d events, %d/%d prices", limit, len(gotE), len(events), len(gotP), len(prices))
		}
		for i := range gotP {
			if gotP[i].Block != prices[i].Block || gotP[i].TotalAssets.String() != prices[i].TotalAssets.String() {
				t.Fatalf("price %d differs", i)
			}
		}
	}
	from := prices[1].Block.Number
	gotP, _ := all[model.SharePrice](f, base+"/share-prices?fromBlock="+strconv.FormatUint(from, 10), 2)
	if len(gotP) != len(prices)-1 {
		t.Fatalf("fromBlock: %d prices", len(gotP))
	}
	safe := f.eng.Status().Tip.Number - confirmations
	gotE, _ := all[model.VaultEvent](f, base+"/events?view=safe", 3)
	for _, e := range gotE {
		if e.Block.Number > safe {
			t.Fatalf("safe view returned block %d above the safe head %d", e.Block.Number, safe)
		}
	}
}

func TestSafeViewBeforeAnyBlockIsSafe(t *testing.T) {
	f := newFixture(t, 2, nil) // head 2 < confirmations: nothing is safe yet
	var p page[model.Transfer]
	if code := f.get("/v1/transfers?view=safe", &p); code != 200 || len(p.Data) != 0 || p.Meta.SafeHead != nil {
		t.Fatalf("status %d, %d rows, safe head %v", code, len(p.Data), p.Meta.SafeHead)
	}
	var b page[model.Balance]
	if code := f.get("/v1/tokens/"+f.w.Asset.Hex()+"/balances?view=safe", &b); code != 200 || len(b.Data) != 0 {
		t.Fatalf("balances: %d %d", code, len(b.Data))
	}
	if code := f.get("/v1/accounts/"+f.w.Holders[0].Hex()+"/balances?view=safe", &b); code != 200 || len(b.Data) != 0 {
		t.Fatalf("account balances: %d %d", code, len(b.Data))
	}
	var e page[model.VaultEvent]
	if code := f.get("/v1/vaults/"+f.w.Vault.Hex()+"/events?view=safe", &e); code != 200 || len(e.Data) != 0 {
		t.Fatalf("vault events: %d %d", code, len(e.Data))
	}
	var sp page[model.SharePrice]
	if code := f.get("/v1/vaults/"+f.w.Vault.Hex()+"/share-prices?view=safe", &sp); code != 200 || len(sp.Data) != 0 {
		t.Fatalf("share prices: %d %d", code, len(sp.Data))
	}
}

func TestStatusEndpoint(t *testing.T) {
	f := newFixture(t, 30, nil)
	f.reorg(3)
	f.sync()
	var s struct {
		ChainID       uint64          `json:"chainId"`
		Backend       string          `json:"backend"`
		Tip           *chain.BlockRef `json:"tip"`
		SafeHead      *uint64         `json:"safeHead"`
		Confirmations uint64          `json:"confirmations"`
		Reorgs        int64           `json:"reorgs"`
		LastReorg     *model.Reorg    `json:"lastReorg"`
		Events        struct{ Oldest, Newest uint64 }
		Ready         bool `json:"ready"`
		Contracts     struct {
			Tokens []common.Address                  `json:"tokens"`
			Vaults map[common.Address]common.Address `json:"vaults"`
		} `json:"contracts"`
	}
	if code := f.get("/v1/status", &s); code != 200 {
		t.Fatalf("status %d", code)
	}
	if s.ChainID != 31337 || s.Backend != "sqlite" || s.Tip == nil || s.Tip.Hash != f.fc.Head().Hash || s.Reorgs != 1 ||
		s.LastReorg == nil || s.LastReorg.Depth != 3 || s.Events.Newest == 0 || !s.Ready || s.Confirmations != confirmations ||
		len(s.Contracts.Tokens) != 4 || s.Contracts.Vaults[f.w.Vault] != f.w.Asset {
		t.Fatalf("status %+v", s)
	}
}

func TestHealthAndReadiness(t *testing.T) {
	f := newFixture(t, 10, nil)
	type ready struct {
		Ready  bool   `json:"ready"`
		Reason string `json:"reason"`
		Lag    uint64 `json:"lag"`
	}
	var h map[string]string
	if code := f.get("/healthz", &h); code != 200 || h["status"] != "ok" {
		t.Fatalf("healthz %d %v", code, h)
	}
	var r ready
	if code := f.get("/readyz", &r); code != 200 || !r.Ready {
		t.Fatalf("readyz %d %+v", code, r)
	}
	f.healthMu.Lock()
	base := f.health
	f.healthMu.Unlock()
	cases := []struct {
		name   string
		health func(context.Context) (api.Health, error)
		reason string
	}{
		{"nothing indexed", func(context.Context) (api.Health, error) { return api.Health{ChainHead: 5}, nil }, "nothing indexed yet"},
		{"behind", func(ctx context.Context) (api.Health, error) {
			hh, _ := base(ctx)
			hh.ChainHead = hh.Tip.Number + 3
			return hh, nil
		}, "indexer is behind the chain head"},
		{"stale", func(ctx context.Context) (api.Health, error) {
			hh, _ := base(ctx)
			hh.UpdatedAt = time.Now().Add(-time.Hour)
			return hh, nil
		}, "no successful sync within 1m0s"},
		{"unavailable", func(context.Context) (api.Health, error) { return api.Health{}, errors.New("db gone") }, "health unavailable: db gone"},
	}
	for _, tc := range cases {
		f.setHealth(tc.health)
		var r ready
		if code := f.get("/readyz", &r); code != http.StatusServiceUnavailable || r.Ready || r.Reason != tc.reason {
			t.Fatalf("%s: %d %+v", tc.name, code, r)
		}
	}
	f.setHealth(base)
	_ = f.st.Close()
	if code := f.get("/healthz", &h); code != http.StatusServiceUnavailable || h["status"] != "unhealthy" {
		t.Fatalf("healthz with a closed database: %d %v", code, h)
	}
	var e errorBody
	if code := f.get("/v1/transfers", &e); code != http.StatusInternalServerError || e.Error.Code != "internal" {
		t.Fatalf("query on a closed database: %d %+v", code, e)
	}
	for _, p := range []string{"/v1/status", "/v1/tokens/" + f.w.Asset.Hex() + "/balances", "/v1/accounts/" + f.w.Asset.Hex() + "/balances",
		"/v1/vaults/" + f.w.Vault.Hex() + "/events", "/v1/vaults/" + f.w.Vault.Hex() + "/share-prices", "/v1/stream"} {
		if code := f.get(p, nil); code != http.StatusInternalServerError {
			t.Fatalf("%s on a closed database: %d", p, code)
		}
	}
}

func TestMetricsAndOpsOnlyMode(t *testing.T) {
	f := newFixture(t, 5, func(c *api.Config) { c.OpsOnly = true })
	resp, err := http.Get(f.url + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), "indexer_indexed_head_block 5") {
		t.Fatalf("metrics %d:\n%.500s", resp.StatusCode, body)
	}
	if code := f.get("/v1/transfers", nil); code != http.StatusNotFound {
		t.Fatalf("ops-only server serves the data API: %d", code)
	}
	if code := f.get("/readyz", nil); code != 200 {
		t.Fatalf("ops-only readyz %d", code)
	}
}

// --- SSE -----------------------------------------------------------------------------------------

type sseEvent struct {
	ID   uint64
	Kind string
	Data string
}

// sse is a minimal SSE client reading in the background.
type sse struct {
	resp   *http.Response
	events chan sseEvent
	ping   chan struct{}
}

func openStream(t *testing.T, rawURL string, header map[string]string) (*sse, int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, rawURL, nil)
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		return nil, resp.StatusCode, string(body)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content type %q", ct)
	}
	s := &sse{resp: resp, events: make(chan sseEvent, 1<<16), ping: make(chan struct{}, 16)}
	t.Cleanup(func() { _ = resp.Body.Close() })
	go func() {
		defer close(s.events)
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		var ev sseEvent
		for sc.Scan() {
			line := sc.Text()
			switch {
			case line == "":
				if ev.Kind != "" {
					s.events <- ev
				}
				ev = sseEvent{}
			case line == ": ping":
				select {
				case s.ping <- struct{}{}:
				default:
				}
			case strings.HasPrefix(line, "id: "):
				ev.ID, _ = strconv.ParseUint(line[4:], 10, 64)
			case strings.HasPrefix(line, "event: "):
				ev.Kind = line[7:]
			case strings.HasPrefix(line, "data: "):
				ev.Data = line[6:]
			}
		}
	}()
	return s, 200, ""
}

func (s *sse) next(t *testing.T) sseEvent {
	t.Helper()
	select {
	case ev, ok := <-s.events:
		if !ok {
			t.Fatal("stream closed")
		}
		return ev
	case <-time.After(10 * time.Second):
		t.Fatal("no event within 10s")
	}
	return sseEvent{}
}

func newest(t *testing.T, st store.Store) (uint64, uint64) {
	t.Helper()
	var o, n uint64
	if err := st.View(context.Background(), func(r store.Reader) error {
		var err error
		o, n, err = r.EventBounds()
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return o, n
}

func TestStreamReplaysResumesAndFollowsLiveCommits(t *testing.T) {
	f := newFixture(t, 25, nil)
	_, n := newest(t, f.st)
	if n < 10 {
		t.Fatalf("only %d events", n)
	}
	// Full replay from the start, in order.
	s, code, _ := openStream(t, f.url+"/v1/stream?after=0", nil)
	if code != 200 {
		t.Fatal(code)
	}
	for want := uint64(1); want <= n; want++ {
		if ev := s.next(t); ev.ID != want || ev.Data == "" {
			t.Fatalf("event %+v, want id %d", ev, want)
		}
	}
	// Resume with Last-Event-ID in the middle.
	r, _, _ := openStream(t, f.url+"/v1/stream", map[string]string{"Last-Event-ID": strconv.FormatUint(n-3, 10)})
	if ev := r.next(t); ev.ID != n-2 {
		t.Fatalf("resumed at %d, want %d", ev.ID, n-2)
	}
	// Without a position, a client starts at the end and only sees new events.
	live, _, _ := openStream(t, f.url+"/v1/stream", nil)

	// A reorg: every stream receives the retractions and the reorg event, live.
	f.reorg(4)
	f.sync()
	_, n2 := newest(t, f.st)
	var kinds []string
	for want := n + 1; want <= n2; want++ {
		ev := live.next(t)
		if ev.ID != want {
			t.Fatalf("live stream: id %d, want %d", ev.ID, want)
		}
		kinds = append(kinds, ev.Kind)
		if ev2 := s.next(t); ev2.ID != want {
			t.Fatalf("replaying stream fell out of order: %d", ev2.ID)
		}
	}
	if !slices.Contains(kinds, model.EventRetract) || !slices.Contains(kinds, model.EventReorg) {
		t.Fatalf("live kinds after a reorg: %v", kinds)
	}
	// Shutdown closes every open stream.
	f.server.CloseStreams()
	for _, st := range []*sse{s, r, live} {
		deadline := time.After(10 * time.Second)
	drain:
		for {
			select {
			case _, ok := <-st.events:
				if !ok {
					break drain
				}
			case <-deadline:
				t.Fatal("stream not closed by CloseStreams")
			}
		}
	}
}

func TestStreamPositionErrorsAndReset(t *testing.T) {
	f := newFixture(t, 15, func(c *api.Config) { c.Heartbeat = 30 * time.Millisecond })
	_, n := newest(t, f.st)
	for _, tc := range []struct {
		query  string
		header string
		status int
		code   string
	}{
		{"after=abc", "", 400, "invalid_after"},
		{"", "-1", 400, "invalid_after"},
		{"after=" + strconv.FormatUint(n+1, 10), "", 400, "invalid_after"},
	} {
		h := map[string]string{}
		if tc.header != "" {
			h["Last-Event-ID"] = tc.header
		}
		_, status, body := openStream(t, f.url+"/v1/stream?"+tc.query, h)
		if status != tc.status || !strings.Contains(body, tc.code) {
			t.Fatalf("%q/%q: %d %s", tc.query, tc.header, status, body)
		}
	}
	// Heartbeats keep idle connections alive.
	s, _, _ := openStream(t, f.url+"/v1/stream", nil)
	select {
	case <-s.ping:
	case <-time.After(10 * time.Second):
		t.Fatal("no heartbeat")
	}
	// Pruned positions: 410 before streaming, `reset` during it.
	err := f.st.Update(context.Background(), func(tx store.Tx) error {
		for range 20 {
			if _, err := tx.AppendEvent("transfer", 1, []byte(`{}`)); err != nil {
				return err
			}
		}
		return tx.PruneEventsBelow(n + 10)
	})
	if err != nil {
		t.Fatal(err)
	}
	_, status, body := openStream(t, f.url+"/v1/stream?after=2", nil)
	if status != http.StatusGone || !strings.Contains(body, "events_pruned") {
		t.Fatalf("pruned position: %d %s", status, body)
	}
	// s was at n when the 20 events were appended and the first 9 pruned.
	ev := s.next(t)
	if ev.Kind != "reset" || !strings.Contains(ev.Data, `"resumeFrom":`+strconv.FormatUint(n+9, 10)) {
		t.Fatalf("lagging stream got %+v, want a reset", ev)
	}
}

func TestHubNotifyWakesWaiters(t *testing.T) {
	h := api.NewHub()
	w1, w2 := h.Wait(), h.Wait()
	h.Notify()
	for _, w := range []<-chan struct{}{w1, w2} {
		select {
		case <-w:
		default:
			t.Fatal("waiter not woken")
		}
	}
	select {
	case <-h.Wait():
		t.Fatal("a new waiter must wait for the next notify")
	default:
	}
}
