// SPDX-License-Identifier: MIT

package api

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

// View selects which data a query may see.
type View string

// Views.
const (
	// ViewLatest includes every indexed block, which a reorg may still retract.
	ViewLatest View = "latest"
	// ViewSafe only includes blocks with at least --confirmations confirmations.
	ViewSafe View = "safe"
)

func parseView(q url.Values) (View, error) {
	switch v := q.Get("view"); v {
	case "", string(ViewLatest):
		return ViewLatest, nil
	case string(ViewSafe):
		return ViewSafe, nil
	default:
		return "", badRequest("invalid_view", fmt.Sprintf("view must be %q or %q, got %q", ViewLatest, ViewSafe, v))
	}
}

func parseLimit(q url.Values) (int, error) {
	raw := q.Get("limit")
	if raw == "" {
		return DefaultLimit, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > MaxLimit {
		// Out-of-range limits are rejected, never clamped: a client asking for 5000 rows must
		// not believe it received all of them.
		return 0, badRequest("invalid_limit", fmt.Sprintf("limit must be an integer between 1 and %d, got %q", MaxLimit, raw))
	}
	return n, nil
}

func parseAddress(name, raw string) (common.Address, error) {
	if !common.IsHexAddress(raw) || !strings.HasPrefix(raw, "0x") && !strings.HasPrefix(raw, "0X") {
		return common.Address{}, badRequest("invalid_address", fmt.Sprintf("%s must be a 0x-prefixed 20-byte hex address, got %q", name, raw))
	}
	return common.HexToAddress(raw), nil
}

func optAddress(q url.Values, name string) (*common.Address, error) {
	raw := q.Get(name)
	if raw == "" {
		return nil, nil
	}
	a, err := parseAddress(name, raw)
	if err != nil {
		return nil, err
	}
	return &a, nil
}

func optBlock(q url.Values, name string) (*uint64, error) {
	raw := q.Get(name)
	if raw == "" {
		return nil, nil
	}
	n, err := strconv.ParseUint(raw, 10, 63)
	if err != nil {
		return nil, badRequest("invalid_block", fmt.Sprintf("%s must be a non-negative decimal block number, got %q", name, raw))
	}
	return &n, nil
}

func blockRange(q url.Values) (from, to *uint64, err error) {
	if from, err = optBlock(q, "fromBlock"); err != nil {
		return nil, nil, err
	}
	if to, err = optBlock(q, "toBlock"); err != nil {
		return nil, nil, err
	}
	if from != nil && to != nil && *from > *to {
		return nil, nil, badRequest("invalid_block_range", fmt.Sprintf("fromBlock %d is above toBlock %d", *from, *to))
	}
	return from, to, nil
}

// cursor is the decoded form of an opaque pagination cursor. It is bound to the endpoint and
// to the exact filters of the query that produced it, so it cannot be replayed against a
// different query by mistake.
type cursor struct {
	Version  int    `json:"v"`
	Endpoint string `json:"e"`
	Query    string `json:"q"`
	Block    uint64 `json:"b,omitempty"`
	LogIndex uint64 `json:"i,omitempty"`
	Holder   string `json:"h,omitempty"`
}

// queryFingerprint hashes the filter parameters of a request (everything except cursor and
// limit, which may change between pages).
func queryFingerprint(endpoint string, q url.Values, pathParams ...string) string {
	h := sha256.New()
	h.Write([]byte(endpoint))
	for _, p := range pathParams {
		h.Write([]byte{0})
		h.Write([]byte(strings.ToLower(p)))
	}
	keys := []string{"token", "address", "from", "to", "holder", "fromBlock", "toBlock", "atBlock", "view"}
	for _, k := range keys {
		h.Write([]byte{0})
		h.Write([]byte(k + "=" + strings.ToLower(q.Get(k))))
	}
	return hex.EncodeToString(h.Sum(nil)[:8])
}

func encodeCursor(c cursor) string {
	c.Version = 1
	b, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(b)
}

func decodeCursor(q url.Values, endpoint, fingerprint string) (*cursor, error) {
	raw := q.Get("cursor")
	if raw == "" {
		return nil, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, badRequest("invalid_cursor", "cursor is not valid base64url")
	}
	var c cursor
	if err := json.Unmarshal(b, &c); err != nil || c.Version != 1 {
		return nil, badRequest("invalid_cursor", "cursor is malformed")
	}
	if c.Endpoint != endpoint || c.Query != fingerprint {
		return nil, badRequest("cursor_mismatch", "cursor was issued for a different query; restart pagination without it")
	}
	return &c, nil
}
