// SPDX-License-Identifier: MIT

package signer

import (
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/pricepath"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/report"
)

func newTestServer(t *testing.T, noise int64, now time.Time) (*Server, *httptest.Server) {
	t.Helper()
	key, _ := crypto.ToECDSA(common.LeftPadBytes([]byte{7}, 32))
	path, err := pricepath.Parse([]byte(`{"name":"t","dtSeconds":10,"prices":["3000000000000000000000","3300000000000000000000"]}`))
	if err != nil {
		t.Fatal(err)
	}
	s, err := New(Config{
		Key:      key,
		Domain:   report.Domain{ChainID: big.NewInt(31337), Verifier: common.HexToAddress("0x1234")},
		MarketID: report.MarketID("ETH-USD"),
		Path:     path,
		Start:    time.Unix(1_000, 0),
		NoiseBps: noise,
		Now:      func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	return s, srv
}

func getReport(t *testing.T, url string) report.Report {
	t.Helper()
	resp, err := http.Get(url + "/report")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	var r report.Report
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestReportEndpointSignsPathPrice(t *testing.T) {
	tests := []struct {
		name  string
		noise int64
		now   time.Time
		want  string
	}{
		{"first step", 0, time.Unix(1_005, 0), "3000000000000000000000"},
		{"second step", 0, time.Unix(1_010, 0), "3300000000000000000000"},
		{"after the end stays on the last price", 0, time.Unix(9_999, 0), "3300000000000000000000"},
		{"positive noise", 5, time.Unix(1_000, 0), "3001500000000000000000"},
		{"negative noise", -5, time.Unix(1_000, 0), "2998500000000000000000"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, srv := newTestServer(t, tc.noise, tc.now)
			r := getReport(t, srv.URL)
			if r.Price.String() != tc.want || r.Timestamp != uint64(tc.now.Unix()) || r.Signer != s.Address() {
				t.Fatalf("got price %s ts %d signer %s", r.Price, r.Timestamp, r.Signer)
			}
			if err := report.Verify(s.cfg.Domain, s.cfg.MarketID, r); err != nil {
				t.Fatalf("served report does not verify: %v", err)
			}
		})
	}
}

func TestHealthMetricsAndMethods(t *testing.T) {
	_, srv := newTestServer(t, 0, time.Unix(1_000, 0))
	getReport(t, srv.URL)

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz: %v %v", err, resp)
	}
	resp.Body.Close()

	resp, err = http.Get(srv.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(body), "signer_reports_served_total 1") {
		t.Fatalf("metrics missing counter:\n%s", body)
	}

	resp, err = http.Post(srv.URL+"/report", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST /report status %d", resp.StatusCode)
	}
}

func TestNewValidatesConfig(t *testing.T) {
	if _, err := New(Config{}); err == nil {
		t.Fatal("empty config accepted")
	}
}

func TestReportHonoursNotAfter(t *testing.T) {
	now := time.Unix(1_015, 0) // second step of the path (3,300) since t = 1,010
	tests := []struct {
		name   string
		query  string
		status int
		wantTs uint64
		price  string
	}{
		{"no parameter signs now", "", http.StatusOK, 1_015, "3300000000000000000000"},
		{"a later head signs now", "?notAfter=2000", http.StatusOK, 1_015, "3300000000000000000000"},
		{"a lagging head dates the report at the head", "?notAfter=1005", http.StatusOK, 1_005, "3000000000000000000000"},
		{"exactly the backdate limit", "?notAfter=955", http.StatusOK, 955, "3000000000000000000000"},
		{"further back is refused", "?notAfter=954", http.StatusUnprocessableEntity, 0, ""},
		{"not a timestamp", "?notAfter=abc", http.StatusBadRequest, 0, ""},
		{"negative", "?notAfter=-1", http.StatusBadRequest, 0, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, srv := newTestServer(t, 0, now)
			resp, err := http.Get(srv.URL + "/report" + tc.query)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != tc.status {
				t.Fatalf("status %d, want %d", resp.StatusCode, tc.status)
			}
			if tc.status != http.StatusOK {
				return
			}
			var r report.Report
			if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
				t.Fatal(err)
			}
			if r.Timestamp != tc.wantTs || r.Price.String() != tc.price {
				t.Fatalf("got ts %d price %s", r.Timestamp, r.Price)
			}
			if err := report.Verify(s.cfg.Domain, s.cfg.MarketID, r); err != nil {
				t.Fatalf("backdated report does not verify: %v", err)
			}
		})
	}
}

func TestAccountSignsForAContractWallet(t *testing.T) {
	key, _ := crypto.ToECDSA(common.LeftPadBytes([]byte{9}, 32))
	wallet := common.HexToAddress("0x00000000000000000000000000000000000c0de1")
	path, _ := pricepath.Parse([]byte(`{"name":"t","dtSeconds":10,"prices":["3000000000000000000000"]}`))
	s, err := New(Config{
		Key: key, Domain: report.Domain{ChainID: big.NewInt(1), Verifier: common.HexToAddress("0x1234")},
		MarketID: report.MarketID("ETH-USD"), Path: path, Start: time.Unix(0, 0), Account: wallet,
		Now: func() time.Time { return time.Unix(5, 0) },
	})
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.Report()
	if err != nil {
		t.Fatal(err)
	}
	if s.Address() != wallet || r.Signer != wallet {
		t.Fatalf("reports must name the wallet, got %s", r.Signer)
	}
	// The owner key signed it: an ECDSA check against the wallet address fails, so the keeper needs ERC-1271.
	if err := report.Verify(s.cfg.Domain, s.cfg.MarketID, r); err == nil {
		t.Fatal("a contract signer's report must not pass the EOA check")
	}
	digest := report.Digest(s.cfg.Domain, s.cfg.MarketID, r.Price, r.Timestamp)
	sig := append([]byte(nil), r.Signature...)
	sig[64] -= 27
	pub, err := crypto.SigToPub(digest.Bytes(), sig)
	if err != nil || crypto.PubkeyToAddress(*pub) != crypto.PubkeyToAddress(key.PublicKey) {
		t.Fatal("the owner key must have signed the digest")
	}
}
