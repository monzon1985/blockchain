// SPDX-License-Identifier: MIT

package rpcreplay

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// upstream is a tiny JSON-RPC node: eth_echo returns its params, anything else an error.
func upstream(t *testing.T) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		reqs, batch, err := readRequests(body)
		require.NoError(t, err)
		resps := make([]response, len(reqs))
		for i, q := range reqs {
			resps[i] = response{JSONRPC: "2.0", ID: q.ID}
			if q.Method == "eth_echo" {
				resps[i].Result = q.Params
			} else {
				resps[i].Error = json.RawMessage(`{"code":-32601,"message":"no such method"}`)
			}
		}
		writeResponses(w, resps, batch)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func post(t *testing.T, url, body string) string {
	t.Helper()
	resp, err := http.Post(url, "application/json", strings.NewReader(body))
	require.NoError(t, err)
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	return strings.TrimSpace(string(out))
}

func TestProxyRecordsAndRewrites(t *testing.T) {
	up := upstream(t)
	p := &Proxy{Upstream: up.URL, Record: true, Rewrite: func(method string, params, result json.RawMessage) json.RawMessage {
		if strings.Contains(string(params), "lie") {
			return json.RawMessage(`"rewritten"`)
		}
		return result
	}}
	srv := httptest.NewServer(p)
	defer srv.Close()

	require.JSONEq(t, `{"jsonrpc":"2.0","id":1,"result":[1]}`, post(t, srv.URL, `{"jsonrpc":"2.0","id":1,"method":"eth_echo","params":[1]}`))
	require.JSONEq(t, `[{"jsonrpc":"2.0","id":7,"result":"rewritten"},{"jsonrpc":"2.0","id":8,"error":{"code":-32601,"message":"no such method"}}]`,
		post(t, srv.URL, `[{"jsonrpc":"2.0","id":7,"method":"eth_echo","params":["lie"]},{"jsonrpc":"2.0","id":8,"method":"eth_nope","params":[]}]`))
	// A repeated call is recorded once.
	post(t, srv.URL, `{"jsonrpc":"2.0","id":2,"method":"eth_echo","params":[1]}`)

	c := p.Cassette()
	require.Len(t, c.Calls, 3)
	require.JSONEq(t, `"rewritten"`, string(c.Calls[1].Result), "the recording holds what the client saw")
	require.NotNil(t, c.Calls[2].Error)

	path := filepath.Join(t.TempDir(), "c.json")
	require.NoError(t, c.Save(path))
	back, err := Load(path)
	require.NoError(t, err)
	require.Equal(t, len(c.Calls), len(back.Calls))

	// The replayer answers the same calls, matching params regardless of key order.
	r := NewReplayer(back)
	rs := httptest.NewServer(r)
	defer rs.Close()
	require.JSONEq(t, `{"jsonrpc":"2.0","id":5,"result":[1]}`, post(t, rs.URL, `{"jsonrpc":"2.0","id":5,"method":"eth_echo","params":[1]}`))
	require.Contains(t, post(t, rs.URL, `{"jsonrpc":"2.0","id":6,"method":"eth_nope","params":[]}`), "no such method")
	require.Contains(t, post(t, rs.URL, `{"jsonrpc":"2.0","id":6,"method":"eth_unknown"}`), ErrNotRecorded.Error())
	r.Rewrite = func(_ string, _, _ json.RawMessage) json.RawMessage { return json.RawMessage(`"x"`) }
	require.JSONEq(t, `[{"jsonrpc":"2.0","id":9,"result":"x"}]`, post(t, rs.URL, `[{"jsonrpc":"2.0","id":9,"method":"eth_echo","params":[1]}]`))
}

func TestKeyNormalization(t *testing.T) {
	require.Equal(t, key("m", nil), key("m", json.RawMessage("null")), "absent params = null")
	require.Equal(t, key("m", json.RawMessage(`[{"b":1,"a":2}]`)), key("m", json.RawMessage(`[{"a":2, "b":1}]`)))
	require.NotEqual(t, key("m", json.RawMessage(`[1]`)), key("n", json.RawMessage(`[1]`)))
	require.Equal(t, "m{bad", key("m", json.RawMessage(`{bad`)))
}

func TestBadRequestsAndUpstreams(t *testing.T) {
	up := upstream(t)
	broken := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("not json")) }))
	defer broken.Close()
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()

	for _, tc := range []struct {
		name string
		h    http.Handler
		body string
		code int
	}{
		{"proxy: invalid request", &Proxy{Upstream: up.URL}, `{`, http.StatusBadRequest},
		{"proxy: upstream down", &Proxy{Upstream: deadURL}, `{"id":1,"method":"eth_echo"}`, http.StatusBadGateway},
		{"proxy: upstream not JSON-RPC", &Proxy{Upstream: broken.URL}, `{"id":1,"method":"eth_echo"}`, http.StatusBadGateway},
		{"proxy: upstream not JSON-RPC (batch)", &Proxy{Upstream: broken.URL}, `[{"id":1,"method":"eth_echo"}]`, http.StatusBadGateway},
		{"replayer: invalid request", NewReplayer(&Cassette{}), `[`, http.StatusBadRequest},
	} {
		srv := httptest.NewServer(tc.h)
		resp, err := http.Post(srv.URL, "application/json", strings.NewReader(tc.body))
		require.NoError(t, err, tc.name)
		require.Equal(t, tc.code, resp.StatusCode, tc.name)
		_ = resp.Body.Close()
		srv.Close()
	}

	_, err := Load(filepath.Join(t.TempDir(), "missing.json"))
	require.Error(t, err)
	bad := filepath.Join(t.TempDir(), "bad.json")
	require.NoError(t, (&Cassette{}).Save(bad))
	_, err = Load(bad)
	require.NoError(t, err)
	require.Error(t, (&Cassette{}).Save(filepath.Join(t.TempDir(), "no", "such", "dir", "c.json")))
}
