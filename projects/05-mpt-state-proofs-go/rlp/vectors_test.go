// SPDX-License-Identifier: MIT

package rlp

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// Vectors vendored from ethereum/tests (RLPTests), MIT-licensed; see testdata/ethereum-tests.

func loadVectors(t *testing.T, name string) map[string]struct {
	In  json.RawMessage `json:"in"`
	Out string          `json:"out"`
} {
	t.Helper()
	raw, err := os.ReadFile("testdata/ethereum-tests/" + name)
	require.NoError(t, err)
	var v map[string]struct {
		In  json.RawMessage `json:"in"`
		Out string          `json:"out"`
	}
	require.NoError(t, json.Unmarshal(raw, &v))
	require.NotEmpty(t, v)
	return v
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func unhex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(strings.TrimPrefix(strings.TrimPrefix(s, "0x"), "0X"))
	require.NoError(t, err)
	return b
}

// jsonToValue converts the ethereum/tests input notation: strings are byte strings, except
// "#<decimal>" which is a big integer; numbers are unsigned integers; arrays are lists.
func jsonToValue(t *testing.T, raw json.RawMessage) Value {
	t.Helper()
	var x any
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	require.NoError(t, dec.Decode(&x))
	var conv func(any) Value
	conv = func(x any) Value {
		switch v := x.(type) {
		case string:
			if strings.HasPrefix(v, "#") {
				n, ok := new(big.Int).SetString(v[1:], 10)
				require.True(t, ok, v)
				return Str(n.Bytes())
			}
			return Str([]byte(v))
		case json.Number:
			n, ok := new(big.Int).SetString(v.String(), 10)
			require.True(t, ok, v)
			return Str(n.Bytes())
		case []any:
			items := make([]Value, len(v))
			for i, it := range v {
				items[i] = conv(it)
			}
			return ListOf(items...)
		default:
			t.Fatalf("unexpected JSON value %T", x)
			return Value{}
		}
	}
	return conv(x)
}

func TestEthereumValidVectors(t *testing.T) {
	vectors := loadVectors(t, "rlptest.json")
	for _, name := range sortedKeys(vectors) {
		tc := vectors[name]
		t.Run(name, func(t *testing.T) {
			want := unhex(t, tc.Out)
			v := jsonToValue(t, tc.In)
			require.Equal(t, hex.EncodeToString(want), hex.EncodeToString(v.Encode()), "encode")

			got, err := Decode(want)
			require.NoError(t, err, "decode")
			require.True(t, got.Equal(v), "decode(encode(x)) != x")
			require.Equal(t, want, got.Encode(), "re-encode")
		})
	}
}

func TestEthereumInvalidVectors(t *testing.T) {
	vectors := loadVectors(t, "invalidRLPTest.json")
	for _, name := range sortedKeys(vectors) {
		tc := vectors[name]
		t.Run(name, func(t *testing.T) {
			require.JSONEq(t, `"INVALID"`, string(tc.In))
			_, err := Decode(unhex(t, tc.Out))
			require.Error(t, err)
		})
	}
}
