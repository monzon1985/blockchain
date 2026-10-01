// SPDX-License-Identifier: MIT

package ethrpc

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// FuzzDecodeRPC feeds arbitrary bytes to the JSON-RPC decoders: whatever a node sends, they
// must return a value or an error, never panic. Real anvil responses seed the corpus.
func FuzzDecodeRPC(f *testing.F) {
	for _, name := range []string{"verify-block-1", "verify-block-3", "verify-proof-contract"} {
		raw, err := os.ReadFile(filepath.Join("..", "internal", "cli", "testdata", name+".cassette.json"))
		if err != nil {
			f.Fatal(err)
		}
		var c struct {
			Calls []struct {
				Result json.RawMessage `json:"result"`
			} `json:"calls"`
		}
		if err := json.Unmarshal(raw, &c); err != nil {
			f.Fatal(err)
		}
		for _, call := range c.Calls {
			f.Add([]byte(call.Result))
		}
	}
	f.Add([]byte(`{"logsBloom":"0x00","transactions":[{}],"withdrawals":[1]}`))
	f.Add([]byte(`[{"type":"0x2","logs":[{"removed":true}]}]`))
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = DecodeBlock(data)
		_, _ = DecodeReceipts(data)
		_, _ = DecodeProof(data)
	})
}
