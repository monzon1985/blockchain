// SPDX-License-Identifier: MIT

package model

import (
	"encoding/json"
	"math/big"
	"testing"
)

func TestAmountJSONRoundTrip(t *testing.T) {
	maxU256 := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
	for _, v := range []*big.Int{big.NewInt(0), big.NewInt(1), big.NewInt(-5), maxU256} {
		a := NewAmount(v)
		b, err := json.Marshal(a)
		if err != nil {
			t.Fatal(err)
		}
		if string(b) != `"`+v.String()+`"` {
			t.Fatalf("marshal %s = %s (amounts are JSON strings)", v, b)
		}
		var back Amount
		if err := json.Unmarshal(b, &back); err != nil || back.Big().Cmp(v) != 0 {
			t.Fatalf("round trip %s: %v %v", v, back.String(), err)
		}
	}
	// NewAmount copies: mutating the source does not change the amount.
	src := big.NewInt(7)
	a := NewAmount(src)
	src.SetInt64(8)
	if a.String() != "7" {
		t.Fatal("NewAmount aliases its argument")
	}
	// Big returns a copy too.
	a.Big().SetInt64(9)
	if a.String() != "7" {
		t.Fatal("Big aliases the amount")
	}
	var nilAmount *Amount
	if nilAmount.String() != "0" || nilAmount.Big().Sign() != 0 {
		t.Fatal("nil amount must read as zero")
	}
	var bad Amount
	for _, in := range []string{`"1.5"`, `"0x10"`, `""`, `"abc"`} {
		if err := json.Unmarshal([]byte(in), &bad); err == nil {
			t.Fatalf("accepted %s", in)
		}
	}
}

func TestComputePriceWad(t *testing.T) {
	cases := []struct {
		assets, supply int64
		want           string
	}{
		{0, 0, "<nil>"},
		{5, 0, "<nil>"},
		{1, 1, "1000000000000000000"},
		{2_000_000, 1_000_000_000, "2000000000000000"},
		{1, 3, "333333333333333333"}, // floor
		{0, 10, "0"},
	}
	for _, tc := range cases {
		got := ComputePriceWad(big.NewInt(tc.assets), big.NewInt(tc.supply))
		s := "<nil>"
		if got != nil {
			s = got.String()
		}
		if s != tc.want {
			t.Errorf("price(%d, %d) = %s, want %s", tc.assets, tc.supply, s, tc.want)
		}
	}
}

func TestTransferJSONShape(t *testing.T) {
	tr := Transfer{Value: NewAmount(big.NewInt(42)), LogIndex: 3, BlockTime: 9}
	b, err := json.Marshal(tr)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"block", "blockTime", "logIndex", "txHash", "token", "from", "to", "value"} {
		if _, ok := m[k]; !ok {
			t.Errorf("transfer JSON lacks %q: %s", k, b)
		}
	}
	if m["value"] != "42" {
		t.Fatalf("value %v", m["value"])
	}
}
