// SPDX-License-Identifier: MIT

// Package rpcfault injects JSON-RPC faults at the HTTP layer: latency, hung requests, HTTP 5xx,
// JSON-RPC error objects, bodies cut mid-stream, provider-style eth_getLogs limits, and
// silently dropped logs. It is an http.RoundTripper, so it wraps the indexer's real RPC client
// in unit tests, and, through NewProxy, sits between an unmodified indexer binary and anvil in
// the integration tests.
//
// Every random decision comes from one seeded generator, so a failing run replays with its seed
// (modulo goroutine scheduling).
package rpcfault

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ethereum/go-ethereum/common/hexutil"
)

// Config selects the faults. Rates are probabilities per HTTP request in [0, 1].
type Config struct {
	Seed uint64

	// HTTPErrorRate answers 503 Service Unavailable without forwarding.
	HTTPErrorRate float64
	// RPCErrorRate answers a well-formed JSON-RPC error (-32603) without forwarding.
	RPCErrorRate float64
	// TruncateRate forwards, then cuts the response body at a random byte.
	TruncateRate float64
	// TimeoutRate hangs until the request's context ends (the client's per-call timeout).
	TimeoutRate float64
	// MinLatency and MaxLatency add a uniform random delay before forwarding.
	MinLatency, MaxLatency time.Duration

	// MaxLogs turns eth_getLogs responses with more logs into the -32005 "query returned more
	// than N results" error real providers send. Zero disables the limit.
	MaxLogs int
	// MaxBlockRange rejects eth_getLogs ranges wider than N blocks with -32005. Zero disables.
	MaxBlockRange uint64
	// DropBlockRate silently removes every log of one block from a range eth_getLogs response
	// that contains logs (a provider returning an incomplete but well-formed answer). Block-hash
	// queries are never altered, which is how the indexer's bloom check can recover.
	DropBlockRate float64
	// DropLogRate silently removes one log of a block that has several in a range eth_getLogs
	// response: a partial omission. The block still has logs in the answer, so the bloom check
	// (which re-reads blocks that came back empty) cannot notice; only a reindex from an honest
	// endpoint (`indexer verify`) does. Range queries only.
	DropLogRate float64
}

// Stats counts injected faults.
type Stats struct {
	Requests, HTTPErrors, RPCErrors, Truncated, Timeouts, LimitErrors, DroppedBlocks, DroppedLogs atomic.Int64
}

// Snapshot returns the counters as a map (for logs and test assertions).
func (s *Stats) Snapshot() map[string]int64 {
	return map[string]int64{
		"requests":       s.Requests.Load(),
		"http_errors":    s.HTTPErrors.Load(),
		"rpc_errors":     s.RPCErrors.Load(),
		"truncated":      s.Truncated.Load(),
		"timeouts":       s.Timeouts.Load(),
		"limit_errors":   s.LimitErrors.Load(),
		"dropped_blocks": s.DroppedBlocks.Load(),
		"dropped_logs":   s.DroppedLogs.Load(),
	}
}

// Transport is the fault-injecting http.RoundTripper.
type Transport struct {
	base    http.RoundTripper
	mu      sync.Mutex
	cfg     Config
	rng     *rand.Rand
	enabled atomic.Bool

	Stats Stats
}

// New wraps base (http.DefaultTransport when nil). Faults start enabled.
func New(base http.RoundTripper, cfg Config) *Transport {
	if base == nil {
		base = http.DefaultTransport
	}
	t := &Transport{base: base, cfg: cfg, rng: rand.New(rand.NewPCG(cfg.Seed, cfg.Seed^0x9e3779b97f4a7c15))}
	t.enabled.Store(true)
	return t
}

// SetEnabled switches all faults, limits included, on or off.
func (t *Transport) SetEnabled(on bool) { t.enabled.Store(on) }

// SetConfig replaces the fault configuration (the seed is kept).
func (t *Transport) SetConfig(cfg Config) {
	t.mu.Lock()
	defer t.mu.Unlock()
	cfg.Seed = t.cfg.Seed
	t.cfg = cfg
}

type rpcRequest struct {
	ID     json.RawMessage   `json:"id"`
	Method string            `json:"method"`
	Params []json.RawMessage `json:"params"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// decision is what the random draw chose for one request.
type decision struct {
	latency                                           time.Duration
	timeout, httpErr, rpcErr, truncate, drop, dropLog bool
	truncateAt                                        float64
	dropPick, dropLogPick                             uint64
	maxLogs                                           int
	maxRange                                          uint64
}

func (t *Transport) decide() decision {
	t.mu.Lock()
	defer t.mu.Unlock()
	c := t.cfg
	d := decision{maxLogs: c.MaxLogs, maxRange: c.MaxBlockRange}
	if c.MaxLatency > 0 {
		span := c.MaxLatency - c.MinLatency
		d.latency = c.MinLatency
		if span > 0 {
			d.latency += time.Duration(t.rng.Int64N(int64(span)))
		}
	}
	d.timeout = t.rng.Float64() < c.TimeoutRate
	d.httpErr = t.rng.Float64() < c.HTTPErrorRate
	d.rpcErr = t.rng.Float64() < c.RPCErrorRate
	d.truncate = t.rng.Float64() < c.TruncateRate
	d.truncateAt = t.rng.Float64()
	d.drop = t.rng.Float64() < c.DropBlockRate
	d.dropPick = t.rng.Uint64()
	if c.DropLogRate > 0 { // drawn only when enabled, so existing seeds keep their fault sequences
		d.dropLog = t.rng.Float64() < c.DropLogRate
		d.dropLogPick = t.rng.Uint64()
	}
	return d
}

// RoundTrip implements http.RoundTripper.
func (t *Transport) RoundTrip(req *http.Request) (*http.Response, error) {
	if !t.enabled.Load() {
		return t.base.RoundTrip(req)
	}
	t.Stats.Requests.Add(1)
	body, err := readBody(req)
	if err != nil {
		return nil, err
	}
	var single *rpcRequest
	if trimmed := bytes.TrimSpace(body); len(trimmed) > 0 && trimmed[0] == '{' {
		single = new(rpcRequest)
		if err := json.Unmarshal(trimmed, single); err != nil {
			single = nil
		}
	}
	d := t.decide()

	if d.latency > 0 {
		select {
		case <-time.After(d.latency):
		case <-req.Context().Done():
			return nil, req.Context().Err()
		}
	}
	switch {
	case d.timeout:
		t.Stats.Timeouts.Add(1)
		<-req.Context().Done()
		return nil, req.Context().Err()
	case d.httpErr:
		t.Stats.HTTPErrors.Add(1)
		return textResponse(req, http.StatusServiceUnavailable, "injected: upstream unavailable"), nil
	case d.rpcErr && single != nil:
		t.Stats.RPCErrors.Add(1)
		return jsonResponse(req, rpcResponse{JSONRPC: "2.0", ID: single.ID, Error: &rpcError{Code: -32603, Message: "injected: internal error"}}), nil
	}

	if single != nil && single.Method == "eth_getLogs" && d.maxRange > 0 {
		if from, to, ok := logRange(single); ok && to >= from && to-from+1 > d.maxRange {
			t.Stats.LimitErrors.Add(1)
			return jsonResponse(req, rpcResponse{JSONRPC: "2.0", ID: single.ID, Error: &rpcError{
				Code: -32005, Message: fmt.Sprintf("block range too large: %d > %d", to-from+1, d.maxRange)}}), nil
		}
	}

	req.Body = io.NopCloser(bytes.NewReader(body))
	req.ContentLength = int64(len(body))
	resp, err := t.base.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	respBody, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		return nil, err
	}

	if single != nil && single.Method == "eth_getLogs" && resp.StatusCode == http.StatusOK {
		respBody = t.limitLogs(single, respBody, d)
	}
	if d.truncate && len(respBody) > 1 {
		t.Stats.Truncated.Add(1)
		respBody = respBody[:int(d.truncateAt*float64(len(respBody)-1))]
	}
	resp.Body = io.NopCloser(bytes.NewReader(respBody))
	resp.ContentLength = int64(len(respBody))
	resp.Header.Set("Content-Length", strconv.Itoa(len(respBody)))
	return resp, nil
}

// limitLogs applies MaxLogs, DropBlockRate and DropLogRate to an eth_getLogs response body.
func (t *Transport) limitLogs(req *rpcRequest, body []byte, d decision) []byte {
	var resp rpcResponse
	if err := json.Unmarshal(body, &resp); err != nil || resp.Error != nil {
		return body
	}
	var logs []map[string]json.RawMessage
	if err := json.Unmarshal(resp.Result, &logs); err != nil {
		return body
	}
	if d.maxLogs > 0 && len(logs) > d.maxLogs {
		t.Stats.LimitErrors.Add(1)
		out, _ := json.Marshal(rpcResponse{JSONRPC: "2.0", ID: resp.ID, Error: &rpcError{
			Code: -32005, Message: fmt.Sprintf("query returned more than %d results", d.maxLogs)}})
		return out
	}
	if _, _, isRange := logRange(req); !isRange || (!d.drop && !d.dropLog) || len(logs) == 0 {
		return body
	}
	changed := false
	if d.drop {
		victim := logs[d.dropPick%uint64(len(logs))]["blockHash"]
		kept := logs[:0]
		for _, l := range logs {
			if !bytes.Equal(l["blockHash"], victim) {
				kept = append(kept, l)
			}
		}
		logs = kept
		t.Stats.DroppedBlocks.Add(1)
		changed = true
	}
	if d.dropLog {
		perBlock := map[string]int{}
		for _, l := range logs {
			perBlock[string(l["blockHash"])]++
		}
		var candidates []int // logs whose block keeps at least one other log
		for i, l := range logs {
			if perBlock[string(l["blockHash"])] >= 2 {
				candidates = append(candidates, i)
			}
		}
		if len(candidates) > 0 {
			i := candidates[d.dropLogPick%uint64(len(candidates))]
			logs = append(logs[:i:i], logs[i+1:]...)
			t.Stats.DroppedLogs.Add(1)
			changed = true
		}
	}
	if !changed {
		return body
	}
	resp.Result, _ = json.Marshal(logs)
	out, _ := json.Marshal(resp)
	return out
}

// logRange extracts fromBlock/toBlock from an eth_getLogs request; ok is false for block-hash
// queries and for tags such as "latest".
func logRange(req *rpcRequest) (from, to uint64, ok bool) {
	if len(req.Params) == 0 {
		return 0, 0, false
	}
	var filter struct {
		FromBlock *hexutil.Uint64 `json:"fromBlock"`
		ToBlock   *hexutil.Uint64 `json:"toBlock"`
	}
	if err := json.Unmarshal(req.Params[0], &filter); err != nil || filter.FromBlock == nil || filter.ToBlock == nil {
		return 0, 0, false
	}
	return uint64(*filter.FromBlock), uint64(*filter.ToBlock), true
}

func readBody(req *http.Request) ([]byte, error) {
	if req.Body == nil {
		return nil, nil
	}
	defer req.Body.Close()
	return io.ReadAll(req.Body)
}

func textResponse(req *http.Request, status int, msg string) *http.Response {
	return &http.Response{
		Status:        fmt.Sprintf("%d %s", status, http.StatusText(status)),
		StatusCode:    status,
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        http.Header{"Content-Type": {"text/plain"}},
		Body:          io.NopCloser(bytes.NewReader([]byte(msg))),
		ContentLength: int64(len(msg)),
		Request:       req,
	}
}

func jsonResponse(req *http.Request, v any) *http.Response {
	body, _ := json.Marshal(v)
	resp := textResponse(req, http.StatusOK, "")
	resp.Header.Set("Content-Type", "application/json")
	resp.Body = io.NopCloser(bytes.NewReader(body))
	resp.ContentLength = int64(len(body))
	return resp
}

// NewProxy returns an HTTP handler that forwards JSON-RPC requests to target through t, so a
// process that knows nothing about fault injection (the indexer binary) can be tested against
// a faulty node.
func NewProxy(target *url.URL, t *Transport) http.Handler {
	p := httputil.NewSingleHostReverseProxy(target)
	p.Transport = t
	p.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		// A hung or failed upstream call becomes a 502 for the client.
		http.Error(w, "proxy: "+err.Error(), http.StatusBadGateway)
	}
	return p
}
