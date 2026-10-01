// SPDX-License-Identifier: MIT

// Package rpcreplay sits between a JSON-RPC client and a node. A Proxy forwards calls to a
// live node and can record them or rewrite results on the way back (to simulate a lying or
// corrupted node); a Replayer answers from a recorded Cassette without any node. Both speak
// single and batched JSON-RPC over HTTP.
package rpcreplay

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
)

// Call is one recorded JSON-RPC exchange.
type Call struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  json.RawMessage `json:"error,omitempty"`
}

// Cassette is a recorded session.
type Cassette struct {
	Calls []Call `json:"calls"`
}

// Load reads a cassette file.
func Load(path string) (*Cassette, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Cassette
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("rpcreplay: %s: %w", path, err)
	}
	return &c, nil
}

// Save writes the cassette as indented JSON with a trailing newline.
func (c *Cassette) Save(path string) error {
	raw, err := json.MarshalIndent(c, "", " ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(raw, '\n'), 0o644)
}

// Rewrite may replace the result of a call. It returns the result unchanged to pass it on.
type Rewrite func(method string, params, result json.RawMessage) json.RawMessage

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   json.RawMessage `json:"error,omitempty"`
}

// key identifies a call by method and canonical parameters (re-marshalling sorts object keys).
// An absent params member and "params": null are the same call.
func key(method string, params json.RawMessage) string {
	if len(params) == 0 {
		params = json.RawMessage("null")
	}
	var v any
	if json.Unmarshal(params, &v) != nil {
		return method + string(params)
	}
	canon, _ := json.Marshal(v)
	return method + string(canon)
}

// readRequests parses a single or batched request body.
func readRequests(body []byte) ([]request, bool, error) {
	body = bytes.TrimSpace(body)
	if len(body) > 0 && body[0] == '[' {
		var reqs []request
		err := json.Unmarshal(body, &reqs)
		return reqs, true, err
	}
	var r request
	err := json.Unmarshal(body, &r)
	return []request{r}, false, err
}

func writeResponses(w http.ResponseWriter, resps []response, batch bool) {
	w.Header().Set("Content-Type", "application/json")
	var v any = resps
	if !batch {
		v = resps[0]
	}
	_ = json.NewEncoder(w).Encode(v)
}

// Proxy forwards calls to Upstream. It is safe for concurrent use.
type Proxy struct {
	Upstream string
	// Rewrite, if set, may change results before they reach the client (and the recording).
	Rewrite Rewrite
	// Record keeps every exchange for Cassette.
	Record bool

	mu    sync.Mutex
	calls []Call
	seen  map[string]bool
}

// ServeHTTP implements http.Handler.
func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	reqs, batch, err := readRequests(body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	upstream, err := http.Post(p.Upstream, "application/json", bytes.NewReader(body))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer upstream.Body.Close()
	respBody, err := io.ReadAll(upstream.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	var resps []response
	if batch {
		err = json.Unmarshal(respBody, &resps)
	} else {
		var one response
		err = json.Unmarshal(respBody, &one)
		resps = []response{one}
	}
	if err != nil {
		http.Error(w, "rpcreplay: upstream answered with invalid JSON-RPC: "+err.Error(), http.StatusBadGateway)
		return
	}
	byID := make(map[string]request, len(reqs))
	for _, q := range reqs {
		byID[string(q.ID)] = q
	}
	for i := range resps {
		q, ok := byID[string(resps[i].ID)]
		if !ok {
			continue
		}
		if p.Rewrite != nil && resps[i].Result != nil {
			resps[i].Result = p.Rewrite(q.Method, q.Params, resps[i].Result)
		}
		p.record(q, resps[i])
	}
	writeResponses(w, resps, batch)
}

func (p *Proxy) record(q request, r response) {
	if !p.Record {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	k := key(q.Method, q.Params)
	if p.seen == nil {
		p.seen = map[string]bool{}
	}
	if p.seen[k] {
		return
	}
	p.seen[k] = true
	p.calls = append(p.calls, Call{Method: q.Method, Params: q.Params, Result: r.Result, Error: r.Error})
}

// Cassette returns the recorded calls, in the order they were first made.
func (p *Proxy) Cassette() *Cassette {
	p.mu.Lock()
	defer p.mu.Unlock()
	return &Cassette{Calls: append([]Call(nil), p.calls...)}
}

// ErrNotRecorded is the error message a Replayer returns for an unknown call.
var ErrNotRecorded = errors.New("rpcreplay: call not recorded")

// Replayer answers calls from a cassette. It is safe for concurrent use.
type Replayer struct {
	calls   map[string]Call
	Rewrite Rewrite
}

// NewReplayer indexes a cassette.
func NewReplayer(c *Cassette) *Replayer {
	r := &Replayer{calls: make(map[string]Call, len(c.Calls))}
	for _, call := range c.Calls {
		k := key(call.Method, call.Params)
		if _, dup := r.calls[k]; !dup {
			r.calls[k] = call
		}
	}
	return r
}

// ServeHTTP implements http.Handler.
func (r *Replayer) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(req.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	reqs, batch, err := readRequests(body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	resps := make([]response, len(reqs))
	for i, q := range reqs {
		resps[i] = response{JSONRPC: "2.0", ID: q.ID}
		call, ok := r.calls[key(q.Method, q.Params)]
		switch {
		case !ok:
			msg, _ := json.Marshal(map[string]any{"code": -32000, "message": fmt.Sprintf("%v: %s %s", ErrNotRecorded, q.Method, q.Params)})
			resps[i].Error = msg
		case call.Error != nil:
			resps[i].Error = call.Error
		default:
			resps[i].Result = call.Result
			if r.Rewrite != nil {
				resps[i].Result = r.Rewrite(q.Method, q.Params, call.Result)
			}
		}
	}
	writeResponses(w, resps, batch)
}
