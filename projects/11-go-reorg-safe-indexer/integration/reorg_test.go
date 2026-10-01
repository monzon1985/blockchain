// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"io"
	"math/big"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
)

type transfersPage struct {
	Data []model.Transfer `json:"data"`
	Meta struct {
		SafeHead *uint64 `json:"safeHead"`
	} `json:"meta"`
}

// TestAnvilReorgRetractsData drives one deterministic reorg on anvil, deeper than the
// confirmation depth, and checks every consumer-facing surface: the REST latest and safe views,
// the SSE stream (a `retract` carrying the orphaned transfer, then a `reorg` event) and the
// deep-reorg metric.
func TestAnvilReorgRetractsData(t *testing.T) {
	a := StartAnvil(t)
	f := a.Deploy()
	alice, bob, carol := a.Accounts[1], a.Accounts[2], a.Accounts[3]
	a.Send(f.Owner, &f.TokenA, tokenABI.PackMint(alice, big.NewInt(1_000_000)))
	a.Mine(1)
	a.Send(alice, &f.TokenA, tokenABI.PackTransfer(bob, big.NewInt(100)))
	a.Mine(1)
	a.Mine(3)

	ix := StartIndexer(t, "serve", "--rpc-url", a.URL, "--db", t.TempDir()+"/idx.db",
		"--token", f.TokenA.Hex(), "--token", f.TokenB.Hex(), "--vault", f.Vault.Hex(),
		"--confirmations", "2", "--poll-interval", "50ms")
	n, h := a.HeadRef()
	WaitForTip(t, func() string { return ix.URL }, n, h, 30*time.Second, ix.Logs)

	var latest, safe transfersPage
	if code, err := GetJSON(ix.URL+"/v1/transfers?token="+f.TokenA.Hex(), &latest); err != nil || code != http.StatusOK {
		t.Fatalf("transfers: %d %v", code, err)
	}
	if len(latest.Data) != 2 || latest.Data[1].To != bob {
		t.Fatalf("want mint + alice->bob, got %+v", latest.Data)
	}
	// alice->bob is 3 blocks deep: already in the safe view with 2 confirmations.
	if _, err := GetJSON(ix.URL+"/v1/transfers?view=safe&token="+f.TokenA.Hex(), &safe); err != nil || len(safe.Data) != 2 {
		t.Fatalf("safe view before the reorg: %+v %v", safe, err)
	}
	orphaned := latest.Data[1]

	// An SSE consumer replays the stream from its first event and follows it.
	stream := StartConsumer(func() string { return ix.URL })
	defer stream.Stop()
	var st struct {
		Events struct {
			Newest uint64 `json:"newest"`
		} `json:"events"`
	}
	GetJSON(ix.URL+"/v1/status", &st)
	stream.WaitFor(t, st.Events.Newest, 30*time.Second)

	// Reorg the last 4 blocks (alice->bob included): alice pays carol instead.
	a.Reorg(4, []ReorgTx{{Req: txRequest{From: alice, To: &f.TokenA, Data: tokenABI.PackTransfer(carol, big.NewInt(7)), Gas: 200_000}, Offset: 1}})
	n, h = a.HeadRef()
	WaitForTip(t, func() string { return ix.URL }, n, h, 30*time.Second, ix.Logs)
	if code, err := GetJSON(ix.URL+"/v1/transfers?token="+f.TokenA.Hex(), &latest); err != nil || code != http.StatusOK {
		t.Fatalf("transfers: %d %v", code, err)
	}
	if len(latest.Data) != 2 || latest.Data[1].To != carol || latest.Data[1].Value.String() != "7" {
		t.Fatalf("after reorg want mint + alice->carol 7, got %+v", latest.Data)
	}
	var status Status
	GetJSON(ix.URL+"/v1/status", &status)
	if status.Reorgs != 1 {
		t.Fatalf("want 1 reorg, got %d", status.Reorgs)
	}
	GetJSON(ix.URL+"/v1/status", &st)
	stream.WaitFor(t, st.Events.Newest, 30*time.Second)
	if retracted, reorgs := stream.Counts(); retracted != 1 || reorgs != 1 {
		t.Fatalf("stream saw %d transfer retractions and %d reorg events, want 1 and 1", retracted, reorgs)
	}
	if _, still := stream.Transfers()[transferKey(orphaned)]; still {
		t.Fatal("the consumer still holds the orphaned transfer")
	}

	// A 4-block reorg with 2 confirmations retracted safe data: an incident, counted apart.
	resp, err := http.Get(ix.URL + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	for _, want := range []string{"indexer_reorgs_total 1", "indexer_deep_reorgs_total 1", `indexer_reorg_depth_blocks_bucket{le="4"} 1`} {
		if !strings.Contains(string(body), want) {
			t.Errorf("/metrics lacks %q", want)
		}
	}
	if !strings.Contains(ix.Logs(), "reorg deeper than the confirmation depth") {
		t.Error("deep reorg not logged as an error")
	}
}
