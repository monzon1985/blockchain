// SPDX-License-Identifier: MIT

package report

import (
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/common/math"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/signer/core/apitypes"
)

var (
	testDomain = Domain{ChainID: big.NewInt(31337), Verifier: common.HexToAddress("0x5FbDB2315678afecb367f032d93F642f64180aa3")}
	ethUSD     = MarketID("ETH-USD")
)

func wad(v int64) *big.Int { return new(big.Int).Mul(big.NewInt(v), big.NewInt(1e18)) }

func mustKey(t *testing.T, seed byte) *ecdsa.PrivateKey {
	t.Helper()
	key, err := crypto.ToECDSA(common.LeftPadBytes([]byte{seed}, 32))
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// Differential test: our hand-rolled EIP-712 digest equals go-ethereum's generic typed-data implementation.
func TestDigestMatchesGethTypedData(t *testing.T) {
	cases := []struct {
		price *big.Int
		ts    uint64
	}{
		{wad(3000), 1_700_000_000},
		{big.NewInt(1), 0},
		{new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1)), ^uint64(0)},
	}
	for _, c := range cases {
		td := apitypes.TypedData{
			Types: apitypes.Types{
				"EIP712Domain": {
					{Name: "name", Type: "string"},
					{Name: "version", Type: "string"},
					{Name: "chainId", Type: "uint256"},
					{Name: "verifyingContract", Type: "address"},
				},
				"PriceReport": {
					{Name: "marketId", Type: "bytes32"},
					{Name: "price", Type: "uint256"},
					{Name: "timestamp", Type: "uint64"},
				},
			},
			PrimaryType: "PriceReport",
			Domain: apitypes.TypedDataDomain{
				Name:              "PerpsOracle",
				Version:           "1",
				ChainId:           (*math.HexOrDecimal256)(testDomain.ChainID),
				VerifyingContract: testDomain.Verifier.Hex(),
			},
			Message: apitypes.TypedDataMessage{
				"marketId":  hexutil.Encode(ethUSD[:]),
				"price":     c.price.String(),
				"timestamp": new(big.Int).SetUint64(c.ts).String(),
			},
		}
		want, _, err := apitypes.TypedDataAndHash(td)
		if err != nil {
			t.Fatal(err)
		}
		if got := Digest(testDomain, ethUSD, c.price, c.ts); got != common.BytesToHash(want) {
			t.Fatalf("digest mismatch for price %s: got %s want %x", c.price, got, want)
		}
	}
}

func TestSignVerifyRoundTrip(t *testing.T) {
	k := mustKey(t, 1)
	r, err := Sign(k, testDomain, ethUSD, wad(3000), 123)
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Signature) != 65 || (r.Signature[64] != 27 && r.Signature[64] != 28) {
		t.Fatalf("unexpected signature encoding %x", r.Signature)
	}
	if err := Verify(testDomain, ethUSD, r); err != nil {
		t.Fatalf("verify: %v", err)
	}

	tests := []struct {
		name   string
		mutate func(*Report)
		domain Domain
		market [32]byte
		want   error
	}{
		{"tampered price", func(r *Report) { r.Price = wad(3001) }, testDomain, ethUSD, ErrBadSignature},
		{"tampered timestamp", func(r *Report) { r.Timestamp++ }, testDomain, ethUSD, ErrBadSignature},
		{"claimed other signer", func(r *Report) { r.Signer = common.HexToAddress("0x01") }, testDomain, ethUSD, ErrBadSignature},
		{"other chain", func(*Report) {}, Domain{big.NewInt(1), testDomain.Verifier}, ethUSD, ErrBadSignature},
		{"other verifier", func(*Report) {}, Domain{testDomain.ChainID, common.HexToAddress("0x02")}, ethUSD, ErrBadSignature},
		{"other market", func(*Report) {}, testDomain, MarketID("BTC-USD"), ErrWrongMarket},
		{"short signature", func(r *Report) { r.Signature = r.Signature[:64] }, testDomain, ethUSD, ErrInvalidReport},
		// OpenZeppelin's ECDSA (and so the verifier) only accepts v in {27, 28}: a raw 0/1 recovery id recovers the
		// right key in geth but reverts on-chain with InvalidSignature.
		{"raw recovery id", func(r *Report) { r.Signature[64] -= 27 }, testDomain, ethUSD, ErrBadSignature},
		{"recovery id 29", func(r *Report) { r.Signature[64] = 29 }, testDomain, ethUSD, ErrBadSignature},
		// The high-s twin of a valid signature recovers the same signer but is malleable; OpenZeppelin rejects it.
		{"high s", toHighS, testDomain, ethUSD, ErrBadSignature},
		{"zero r", func(r *Report) { clear(r.Signature[:32]) }, testDomain, ethUSD, ErrBadSignature},
		{"zero price", func(r *Report) { r.Price = big.NewInt(0) }, testDomain, ethUSD, ErrInvalidReport},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c := r
			c.Signature = append([]byte(nil), r.Signature...)
			tc.mutate(&c)
			if err := Verify(tc.domain, tc.market, c); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

// toHighS rewrites a signature into its malleable twin: s' = n - s and the other recovery id.
func toHighS(r *Report) {
	n := crypto.S256().Params().N
	s := new(big.Int).SetBytes(r.Signature[32:64])
	copy(r.Signature[32:64], common.LeftPadBytes(new(big.Int).Sub(n, s).Bytes(), 32))
	r.Signature[64] = 27 + 28 - r.Signature[64] // 27 <-> 28
}

func TestHighSTwinRecoversTheSameSigner(t *testing.T) {
	k := mustKey(t, 4)
	r, _ := Sign(k, testDomain, ethUSD, wad(3000), 7)
	toHighS(&r)
	sig := append([]byte(nil), r.Signature...)
	sig[64] -= 27
	pub, err := crypto.SigToPub(Digest(testDomain, ethUSD, r.Price, r.Timestamp).Bytes(), sig)
	if err != nil || crypto.PubkeyToAddress(*pub) != r.Signer {
		t.Fatalf("the twin should recover the signer (that is why it must be rejected explicitly): %v", err)
	}
}

func TestSignRejectsNonPositivePrice(t *testing.T) {
	k := mustKey(t, 2)
	for _, p := range []*big.Int{nil, big.NewInt(0), big.NewInt(-1)} {
		if _, err := Sign(k, testDomain, ethUSD, p, 1); !errors.Is(err, ErrInvalidReport) {
			t.Fatalf("price %v: got %v", p, err)
		}
	}
}

func TestJSONRoundTrip(t *testing.T) {
	k := mustKey(t, 3)
	r, _ := Sign(k, testDomain, ethUSD, wad(2999), 99)
	raw, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var back Report
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.Price.Cmp(r.Price) != 0 || back.Timestamp != r.Timestamp || back.Signer != r.Signer ||
		back.MarketID != r.MarketID || hexutil.Encode(back.Signature) != hexutil.Encode(r.Signature) {
		t.Fatalf("round trip changed the report: %s", raw)
	}
	if err := json.Unmarshal([]byte(`{"price":"abc"}`), &back); !errors.Is(err, ErrInvalidReport) {
		t.Fatalf("bad price accepted: %v", err)
	}
}

func TestMedianAndSpread(t *testing.T) {
	tests := []struct {
		name   string
		prices []int64
		median int64
		spread uint16
		within bool
	}{
		{"odd", []int64{3003, 2999, 3001}, 3001, 50, true},
		{"even floors the mean", []int64{3000, 3001}, 3000, 50, true},
		{"single", []int64{42}, 42, 1, true},
		{"too wide", []int64{3000, 3016}, 3008, 50, false},
		{"exactly at limit", []int64{10000, 10050}, 10025, 50, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ps := make([]*big.Int, len(tc.prices))
			for i, p := range tc.prices {
				ps[i] = big.NewInt(p)
			}
			if got := Median(ps); got.Int64() != tc.median {
				t.Fatalf("median %v want %d", got, tc.median)
			}
			if got := WithinSpread(ps, tc.spread); got != tc.within {
				t.Fatalf("within %v want %v", got, tc.within)
			}
		})
	}
	if Median(nil) != nil || WithinSpread(nil, 50) {
		t.Fatal("empty input must be rejected")
	}
}

func TestAggregateDropsOutlierAndChecksQuorum(t *testing.T) {
	k1, k2, k3 := mustKey(t, 11), mustKey(t, 12), mustKey(t, 13)
	honest1, _ := Sign(k1, testDomain, ethUSD, wad(3000), 10)
	honest2, _ := Sign(k2, testDomain, ethUSD, wad(3001), 11)
	rogue, _ := Sign(k3, testDomain, ethUSD, wad(6000), 12)
	close3, _ := Sign(k3, testDomain, ethUSD, wad(3002), 12)

	batch, median, err := Aggregate([]Report{honest1, rogue, honest2}, 2, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(batch) != 2 || median.Cmp(new(big.Int).Div(new(big.Int).Add(wad(3000), wad(3001)), big.NewInt(2))) != 0 {
		t.Fatalf("outlier not dropped: %d reports, median %s", len(batch), median)
	}

	batch, median, err = Aggregate([]Report{honest1, close3, honest2}, 2, 50)
	if err != nil || len(batch) != 3 || median.Cmp(wad(3001)) != 0 {
		t.Fatalf("all three should be used: %v %d %s", err, len(batch), median)
	}
	if OldestTimestamp(batch) != 10 {
		t.Fatalf("oldest timestamp %d", OldestTimestamp(batch))
	}

	if _, _, err := Aggregate([]Report{honest1}, 2, 50); !errors.Is(err, ErrNotEnough) {
		t.Fatalf("quorum not enforced: %v", err)
	}
	// Two copies of one signer's report count once: they cannot make a quorum on their own...
	if _, _, err := Aggregate([]Report{honest1, honest1}, 2, 50); !errors.Is(err, ErrNotEnough) {
		t.Fatalf("a duplicate counted twice: %v", err)
	}
	if _, _, err := Aggregate([]Report{honest1, rogue}, 2, 50); !errors.Is(err, ErrSpreadTooWide) {
		t.Fatalf("spread not enforced: %v", err)
	}
}

// Regression: a third URL that echoes signer 1's report used to make Aggregate fail the whole batch
// (ErrDuplicateOwner), so nothing was ever submitted. The echo is now deduplicated and the honest pair settles.
func TestCandidatesDeduplicateAnEchoingSigner(t *testing.T) {
	k1, k2 := mustKey(t, 21), mustKey(t, 22)
	r1, _ := Sign(k1, testDomain, ethUSD, wad(3000), 100)
	r2, _ := Sign(k2, testDomain, ethUSD, wad(3001), 100)
	older1, _ := Sign(k1, testDomain, ethUSD, wad(2990), 90)

	batch, median, err := Aggregate([]Report{r1, r2, r1}, 2, 50)
	if err != nil || len(batch) != 2 {
		t.Fatalf("echo blocked the batch: %v (%d reports)", err, len(batch))
	}
	if median.Cmp(new(big.Int).Div(new(big.Int).Add(wad(3000), wad(3001)), big.NewInt(2))) != 0 {
		t.Fatalf("median %s", median)
	}
	// Of two reports by the same signer, the newer one is kept whatever the order.
	for _, in := range [][]Report{{older1, r1, r2}, {r1, older1, r2}} {
		got := Dedupe(in)
		if len(got) != 2 || got[0].Timestamp != 100 {
			t.Fatalf("dedupe kept %+v", got)
		}
	}
}

func TestCandidatesOrderFallbacksBestFirst(t *testing.T) {
	k1, k2, k3 := mustKey(t, 31), mustKey(t, 32), mustKey(t, 33)
	a, _ := Sign(k1, testDomain, ethUSD, wad(3000), 1)
	b, _ := Sign(k2, testDomain, ethUSD, wad(3006), 1)
	c, _ := Sign(k3, testDomain, ethUSD, wad(3003), 1)
	batches, err := Candidates([]Report{a, b, c}, 2, 50)
	if err != nil {
		t.Fatal(err)
	}
	// All three first, then the pairs by spread: (a,c) and (b,c) at 3, then (a,b) at 6.
	if len(batches) != 4 || len(batches[0].Reports) != 3 {
		t.Fatalf("got %d batches", len(batches))
	}
	spreadOfBatch := func(bt Batch) *big.Int { return spreadOf(pricesOf(bt.Reports)) }
	for i := 2; i < len(batches); i++ {
		if spreadOfBatch(batches[i-1]).Cmp(spreadOfBatch(batches[i])) > 0 {
			t.Fatalf("pairs not ordered by spread at %d", i)
		}
	}
	if spreadOfBatch(batches[3]).Cmp(wad(6)) != 0 {
		t.Fatalf("widest pair last, got spread %s", spreadOfBatch(batches[3]))
	}
	for _, bt := range batches {
		for i := 1; i < len(bt.Reports); i++ {
			if bt.Reports[i-1].Signer.Cmp(bt.Reports[i].Signer) >= 0 {
				t.Fatal("batch not sorted by signer")
			}
		}
	}
	if _, err := Candidates([]Report{a, b}, 0, 50); !errors.Is(err, ErrNotEnough) {
		t.Fatalf("quorum 0 accepted: %v", err)
	}
	var many []Report
	for i := range 17 {
		k := mustKey(t, byte(100+i))
		r, _ := Sign(k, testDomain, ethUSD, wad(3000), 1)
		many = append(many, r)
	}
	if _, err := Candidates(many, 2, 50); !errors.Is(err, ErrInvalidReport) {
		t.Fatalf("more signers than the verifier allows: %v", err)
	}
}

func FuzzReportJSON(f *testing.F) {
	f.Add(`{"signer":"0x0000000000000000000000000000000000000001","marketId":"0x00","price":"1","timestamp":1,"signature":"0x00"}`)
	f.Add(`{"price":"-5"}`)
	f.Add(`not json`)
	f.Fuzz(func(t *testing.T, s string) {
		var r Report
		if err := json.Unmarshal([]byte(s), &r); err != nil {
			return
		}
		// Anything that decodes must re-encode and decode to the same value.
		if r.Price == nil {
			t.Fatal("decoded report without price")
		}
		raw, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		var back Report
		if err := json.Unmarshal(raw, &back); err != nil || back.Price.Cmp(r.Price) != 0 {
			t.Fatalf("unstable round trip: %v", err)
		}
		_ = Verify(testDomain, ethUSD, r) // must not panic on arbitrary input
	})
}
