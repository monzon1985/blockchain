// SPDX-License-Identifier: MIT

package api_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/api"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/withdrawal"
)

const (
	clientToken   = "gateway-token"
	approverToken = "approver-a-token"
)

type client struct {
	t   *testing.T
	srv *httptest.Server
}

func (c client) do(method, path, token string, body any, headers ...string) (int, http.Header, []byte) {
	c.t.Helper()
	var r io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		r = strings.NewReader(b)
	default:
		raw, _ := json.Marshal(b)
		r = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, c.srv.URL+path, r)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	resp, err := c.srv.Client().Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, out
}

func newServer(t *testing.T) (*testenv.Env, client) {
	e := testenv.Quiet(t, 101)
	srv := httptest.NewServer(api.NewRouter(e.App))
	t.Cleanup(srv.Close)
	return e, client{t: t, srv: srv}
}

func errCode(t *testing.T, body []byte) string {
	t.Helper()
	var b withdrawal.ErrorBody
	if err := json.Unmarshal(body, &b); err != nil {
		t.Fatalf("not an error body: %s", body)
	}
	return b.Error.Code
}

func TestAuthentication(t *testing.T) {
	_, c := newServer(t)
	cases := []struct {
		method, path, token string
		want                int
	}{
		{"POST", "/v1/withdrawals", "", http.StatusUnauthorized},
		{"POST", "/v1/withdrawals", "wrong", http.StatusForbidden},
		{"POST", "/v1/withdrawals", approverToken, http.StatusForbidden}, // approvers cannot submit
		{"POST", "/v1/withdrawals/wd_x/approvals", clientToken, http.StatusForbidden},
		{"POST", "/v1/withdrawals/wd_x/cancel", clientToken, http.StatusForbidden},
		{"GET", "/v1/withdrawals/wd_x", approverToken, http.StatusNotFound},
		{"GET", "/v1/withdrawals/wd_x", clientToken, http.StatusNotFound},
		{"GET", "/healthz", "", http.StatusOK},
		{"GET", "/readyz", "", http.StatusOK},
	}
	for _, tc := range cases {
		if code, _, body := c.do(tc.method, tc.path, tc.token, nil); code != tc.want {
			t.Errorf("%s %s with %q: %d %s", tc.method, tc.path, tc.token, code, body)
		}
	}
	if code, _, _ := c.do("GET", "/v1/withdrawals/wd_x", "", nil, "Authorization", "Basic abc"); code != http.StatusUnauthorized {
		t.Errorf("non-bearer scheme accepted: %d", code)
	}
}

func TestWithdrawalLifecycleOverHTTP(t *testing.T) {
	e, c := newServer(t)
	e.FundUser("alice", 1_000_000_000)
	dest := testenv.Addr(1)

	code, _, body := c.do("POST", "/v1/accounts/alice/allowlist", clientToken, map[string]string{"address": dest.Hex(), "label": "cold"})
	if code != http.StatusCreated {
		t.Fatalf("allowlist add: %d %s", code, body)
	}
	code, _, body = c.do("GET", "/v1/accounts/alice/allowlist", clientToken, nil)
	if code != http.StatusOK || !strings.Contains(string(body), dest.Hex()) {
		t.Fatalf("allowlist list: %d %s", code, body)
	}
	req := map[string]string{"account_id": "alice", "asset": testenv.Asset, "amount": "1000000", "destination": dest.Hex()}
	code, _, body = c.do("POST", "/v1/withdrawals", clientToken, req, "Idempotency-Key", "k-1")
	if code != http.StatusUnprocessableEntity || errCode(t, body) != "destination_in_cooldown" {
		t.Fatalf("cool-down not enforced: %d %s", code, body)
	}
	e.Clock.Advance(25 * time.Hour)

	code, _, body = c.do("POST", "/v1/withdrawals", clientToken, req)
	if code != http.StatusBadRequest || errCode(t, body) != "idempotency_key_required" {
		t.Fatalf("missing key: %d %s", code, body)
	}
	code, hdr, body := c.do("POST", "/v1/withdrawals", clientToken, req, "Idempotency-Key", "k-2")
	if code != http.StatusCreated || hdr.Get("Idempotent-Replayed") != "" {
		t.Fatalf("create: %d %s", code, body)
	}
	var v withdrawal.View
	_ = json.Unmarshal(body, &v)
	code, hdr, body2 := c.do("POST", "/v1/withdrawals", clientToken, req, "Idempotency-Key", "k-2")
	if code != http.StatusCreated || hdr.Get("Idempotent-Replayed") != "true" || !bytes.Equal(body, body2) {
		t.Fatalf("replay: %d %s %s", code, hdr, body2)
	}
	req["amount"] = "2000000"
	if code, _, body := c.do("POST", "/v1/withdrawals", clientToken, req, "Idempotency-Key", "k-2"); code != http.StatusUnprocessableEntity || errCode(t, body) != "idempotency_key_reused" {
		t.Fatalf("key reuse: %d %s", code, body)
	}
	if code, _, body := c.do("POST", "/v1/withdrawals", clientToken, `{"account_id":"alice","extra":1}`, "Idempotency-Key", "k-3"); code != http.StatusBadRequest {
		t.Fatalf("unknown field: %d %s", code, body)
	}
	if code, _, _ := c.do("POST", "/v1/withdrawals", clientToken, strings.Repeat("x", 70<<10), "Idempotency-Key", "k-4"); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized body: %d", code)
	}

	e.RunUntil(20, func() bool { return e.Status(v.ID) == withdrawal.Confirmed })
	code, _, body = c.do("GET", "/v1/withdrawals/"+v.ID, clientToken, nil)
	if code != http.StatusOK || !strings.Contains(string(body), `"status":"confirmed"`) || !strings.Contains(string(body), `"tx_hash":"0x`) {
		t.Fatalf("get: %d %s", code, body)
	}
	code, _, body = c.do("GET", "/v1/accounts/alice/withdrawals?limit=5", clientToken, nil)
	if code != http.StatusOK || !strings.Contains(string(body), v.ID) {
		t.Fatalf("list: %d %s", code, body)
	}
	code, _, body = c.do("GET", "/v1/accounts/alice/balances", clientToken, nil)
	if code != http.StatusOK || !strings.Contains(string(body), `"tUSD":"999000000"`) {
		t.Fatalf("balances: %d %s", code, body)
	}
	code, _, body = c.do("GET", "/v1/accounts/alice/deposits", clientToken, nil)
	if code != http.StatusOK || !strings.Contains(string(body), `"status":"credited"`) {
		t.Fatalf("deposits: %d %s", code, body)
	}
	if code, _, body := c.do("POST", "/v1/withdrawals/"+v.ID+"/cancel", approverToken, nil); code != http.StatusConflict {
		t.Fatalf("cancel confirmed: %d %s", code, body)
	}
	code, _, body = c.do("GET", "/v1/reconciliation", approverToken, nil)
	if code != http.StatusOK || !strings.Contains(string(body), `"ok":true`) {
		t.Fatalf("reconciliation: %d %s", code, body)
	}
	code, _, body = c.do("GET", "/metrics", "", nil)
	if code != http.StatusOK || !strings.Contains(string(body), "custody_withdrawal_transitions_total") ||
		!strings.Contains(string(body), `custody_http_requests_total{code="201",route="/v1/withdrawals"}`) {
		t.Fatalf("metrics: %d", code)
	}
	if code, _, _ := c.do("DELETE", "/v1/accounts/alice/allowlist/"+dest.Hex(), clientToken, nil); code != http.StatusNoContent {
		t.Fatalf("allowlist delete: %d", code)
	}
	if code, _, _ := c.do("DELETE", "/v1/accounts/alice/allowlist/"+dest.Hex(), clientToken, nil); code != http.StatusNotFound {
		t.Fatalf("allowlist double delete: %d", code)
	}
}

func TestApprovalAndCancelOverHTTP(t *testing.T) {
	e, c := newServer(t)
	e.FundUser("bob", 2_000_000_000)
	e.Allowlist("bob", testenv.Addr(1), testenv.Addr(2))
	id := testenv.CreatedID(t, e.Create("big", "bob", 600_000_000, testenv.Addr(1)))
	e.Dispatch()
	if code, _, body := c.do("POST", "/v1/withdrawals/"+id+"/approvals", approverToken, map[string]string{"decision": "maybe"}); code != http.StatusBadRequest {
		t.Fatalf("bad decision: %d %s", code, body)
	}
	if code, _, body := c.do("POST", "/v1/withdrawals/"+id+"/approvals", approverToken, map[string]string{"decision": "approve"}); code != http.StatusOK {
		t.Fatalf("approve: %d %s", code, body)
	}
	if code, _, _ := c.do("POST", "/v1/withdrawals/"+id+"/approvals", approverToken, map[string]string{"decision": "approve"}); code != http.StatusConflict {
		t.Fatalf("duplicate approval: %d", code)
	}
	if code, _, _ := c.do("POST", "/v1/withdrawals/wd_missing/approvals", approverToken, map[string]string{"decision": "approve"}); code != http.StatusNotFound {
		t.Fatalf("unknown withdrawal: %d", code)
	}
	code, _, body := c.do("POST", "/v1/withdrawals/"+id+"/cancel", approverToken, nil)
	if code != http.StatusAccepted || !strings.Contains(string(body), `"status":"failed"`) {
		t.Fatalf("cancel: %d %s", code, body)
	}
	if code, _, _ := c.do("POST", "/v1/withdrawals/wd_missing/cancel", approverToken, nil); code != http.StatusNotFound {
		t.Fatalf("cancel unknown: %d", code)
	}
}

func TestDepositAddressAndValidation(t *testing.T) {
	e, c := newServer(t)
	code, _, body := c.do("POST", "/v1/accounts/carol/deposit-address", clientToken, nil)
	want, _ := e.App.Deriver.Address("carol")
	if code != http.StatusOK || !strings.Contains(string(body), want.Hex()) {
		t.Fatalf("deposit address: %d %s", code, body)
	}
	if code, _, body2 := c.do("GET", "/v1/accounts/carol/deposit-address", clientToken, nil); code != http.StatusOK || !bytes.Equal(body, body2) {
		t.Fatalf("second call must return the same address: %s vs %s", body, body2)
	}
	for _, p := range []string{"/v1/accounts/bad%20id/balances", "/v1/accounts/" + strings.Repeat("a", 65) + "/withdrawals"} {
		if code, _, _ := c.do("GET", p, clientToken, nil); code != http.StatusBadRequest {
			t.Errorf("%s: %d", p, code)
		}
	}
	if code, _, _ := c.do("POST", "/v1/accounts/carol/allowlist", clientToken, map[string]string{"address": "0x1234"}); code != http.StatusUnprocessableEntity {
		t.Errorf("bad address accepted: %d", code)
	}
	if code, _, _ := c.do("POST", "/v1/accounts/carol/allowlist", clientToken, map[string]string{"address": e.Hot.Hex()}); code != http.StatusUnprocessableEntity {
		t.Errorf("hot wallet allowlisted: %d", code)
	}
	if code, _, _ := c.do("POST", "/v1/accounts/carol/allowlist", clientToken, "{"); code != http.StatusBadRequest {
		t.Errorf("malformed JSON accepted: %d", code)
	}
	if code, _, _ := c.do("DELETE", "/v1/accounts/carol/allowlist/nope", clientToken, nil); code != http.StatusBadRequest {
		t.Errorf("bad address in path: %d", code)
	}
	if code, _, _ := c.do("GET", "/v1/reconciliation", clientToken, nil); code != http.StatusNotFound {
		t.Errorf("reconciliation before the first run: %d", code)
	}
	if code, _, _ := c.do("GET", "/nope", "", nil); code != http.StatusNotFound {
		t.Errorf("unknown route: %d", code)
	}
}

// TestReadinessAndInternalErrorsDoNotLeakDetails: /readyz names the dependency that is down and
// a 500 says "internal", but neither echoes the underlying error, which can carry SQL text, file
// paths or an RPC URL with a provider key in it.
func TestReadinessAndInternalErrorsDoNotLeakDetails(t *testing.T) {
	e, c := newServer(t)
	if code, _, _ := c.do("GET", "/readyz", "", nil); code != http.StatusOK {
		t.Fatalf("ready: %d", code)
	}
	const secret = "https://rpc.example/v3/SECRET-PROVIDER-KEY"
	e.Chain.SetReadFault(func(method string) error {
		if method == "Head" {
			return errors.New(`Post "` + secret + `": dial tcp: connection refused`)
		}
		return nil
	})
	code, _, body := c.do("GET", "/readyz", "", nil)
	if code != http.StatusServiceUnavailable || errCode(t, body) != "node_unreachable" || strings.Contains(string(body), "SECRET") {
		t.Fatalf("readyz with the node down: %d %s", code, body)
	}
	e.Chain.SetReadFault(nil)

	e.App.DB.Close()
	code, _, body = c.do("GET", "/readyz", "", nil)
	if code != http.StatusServiceUnavailable || errCode(t, body) != "database_unavailable" || strings.Contains(string(body), "sql:") {
		t.Fatalf("readyz with a closed database: %d %s", code, body)
	}
	for _, path := range []string{"/v1/withdrawals/wd_x", "/v1/accounts/alice/balances", "/v1/accounts/alice/deposits", "/v1/accounts/alice/withdrawals", "/v1/accounts/alice/allowlist"} {
		code, _, body := c.do("GET", path, clientToken, nil)
		if code != http.StatusInternalServerError || errCode(t, body) != "internal" || strings.Contains(string(body), "sql:") {
			t.Fatalf("GET %s with the database gone: %d %s", path, code, body)
		}
	}
}

// TestCreateRejectsMalformedInput maps every malformed field of POST /v1/withdrawals to its
// error code, and checks that a rejection is stored under its Idempotency-Key like a success:
// the same retry gets the same answer (marked as a replay), and no withdrawal is created.
func TestCreateRejectsMalformedInput(t *testing.T) {
	e, c := newServer(t)
	e.FundUser("alice", 1_000_000_000)
	e.Allowlist("alice", testenv.Addr(1))
	good := testenv.Addr(1).Hex()
	// An EIP-55 test vector from the EIP with the case of one letter flipped: mixed case and a
	// wrong checksum, the typical result of a mangled copy-paste.
	const eip55 = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
	mixed := strings.Replace(eip55, "aA", "aa", 1)
	if _, ok := withdrawal.ParseAddress(eip55); !ok {
		t.Fatalf("EIP-55 vector %s rejected", eip55)
	}
	if _, ok := withdrawal.ParseAddress(mixed); ok {
		t.Fatalf("test vector %s unexpectedly has a valid checksum", mixed)
	}
	cases := []struct {
		name, body string
		code       int
		errCode    string
	}{
		{"account with a space", `{"account_id":"al ice","asset":"tUSD","amount":"1","destination":"` + good + `"}`, 422, "account_invalid"},
		{"empty account", `{"account_id":"","asset":"tUSD","amount":"1","destination":"` + good + `"}`, 422, "account_invalid"},
		{"zero amount", `{"account_id":"alice","asset":"tUSD","amount":"0","destination":"` + good + `"}`, 422, "amount_invalid"},
		{"negative amount", `{"account_id":"alice","asset":"tUSD","amount":"-5","destination":"` + good + `"}`, 422, "amount_invalid"},
		{"leading zero", `{"account_id":"alice","asset":"tUSD","amount":"01","destination":"` + good + `"}`, 422, "amount_invalid"},
		{"exponent", `{"account_id":"alice","asset":"tUSD","amount":"1e6","destination":"` + good + `"}`, 422, "amount_invalid"},
		{"79 digits", `{"account_id":"alice","asset":"tUSD","amount":"1` + strings.Repeat("0", 78) + `","destination":"` + good + `"}`, 422, "amount_invalid"},
		{"78 digits above 2^256", `{"account_id":"alice","asset":"tUSD","amount":"` + strings.Repeat("9", 78) + `","destination":"` + good + `"}`, 422, "amount_invalid"},
		{"no 0x prefix", `{"account_id":"alice","asset":"tUSD","amount":"1","destination":"` + good[2:] + `"}`, 422, "destination_invalid"},
		{"bad checksum", `{"account_id":"alice","asset":"tUSD","amount":"1","destination":"` + mixed + `"}`, 422, "destination_invalid"},
		{"short address", `{"account_id":"alice","asset":"tUSD","amount":"1","destination":"0x1234"}`, 422, "destination_invalid"},
		{"unknown asset", `{"account_id":"alice","asset":"DOGE","amount":"1","destination":"` + good + `"}`, 422, "asset_unsupported"},
		{"trailing data", `{"account_id":"alice","asset":"tUSD","amount":"1","destination":"` + good + `"} {}`, 400, "malformed_body"},
		{"not JSON", `amount=1`, 400, "malformed_body"},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			key := fmt.Sprintf("bad-%d", i)
			code, hdr, body := c.do("POST", "/v1/withdrawals", clientToken, tc.body, "Idempotency-Key", key)
			if code != tc.code || errCode(t, body) != tc.errCode || hdr.Get("Idempotent-Replayed") != "" {
				t.Fatalf("got %d %s, want %d %s", code, body, tc.code, tc.errCode)
			}
			if tc.code != http.StatusUnprocessableEntity {
				return // a request that does not parse is never stored
			}
			code2, hdr2, body2 := c.do("POST", "/v1/withdrawals", clientToken, tc.body, "Idempotency-Key", key)
			if code2 != code || !bytes.Equal(body, body2) || hdr2.Get("Idempotent-Replayed") != "true" {
				t.Fatalf("retry of a rejected request: %d %s (replayed=%q)", code2, body2, hdr2.Get("Idempotent-Replayed"))
			}
		})
	}
	all, err := withdrawal.All(e.Ctx, e.App.DB)
	if err != nil || len(all) != 0 {
		t.Fatalf("%d withdrawals created by rejected requests (%v)", len(all), err)
	}
}
