// SPDX-License-Identifier: MIT

package deploy

import (
	"context"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/eth/ethconfig"
	"github.com/ethereum/go-ethereum/ethclient/simulated"
	"github.com/ethereum/go-ethereum/node"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/bindings"
)

// fixture is contracts/test/fixtures/deployment.json, which PerpsDeployment.sol is checked against too.
type fixture struct {
	GovernanceDelay uint32 `json:"governanceDelay"`
	Roles           []struct {
		ExecutionDelay uint32 `json:"executionDelay"`
		ID             uint64 `json:"id"`
		Name           string `json:"name"`
	} `json:"roles"`
	FunctionRoles []struct {
		Role      uint64 `json:"role"`
		Signature string `json:"signature"`
		Target    string `json:"target"`
	} `json:"functionRoles"`
	RiskParams map[string]*big.Int `json:"riskParams"`
}

func loadFixture(t *testing.T) fixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "contracts", "test", "fixtures", "deployment.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx fixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	return fx
}

func lowerFirst(s string) string {
	r := []rune(s)
	r[0] = unicode.ToLower(r[0])
	return string(r)
}

func asBig(v reflect.Value) *big.Int {
	switch v.Kind() {
	case reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return new(big.Int).SetUint64(v.Uint())
	case reflect.Pointer:
		return v.Interface().(*big.Int)
	}
	panic("unexpected field kind " + v.Kind().String())
}

// TestDeploymentMatchesFixture checks the hand-written Go mirror against the configuration PerpsDeployment.sol is
// verified against: the risk parameters, the role identifiers and delays, the function-to-role table, and the state
// a Go deployment actually leaves on chain.
func TestDeploymentMatchesFixture(t *testing.T) {
	fx := loadFixture(t)
	if fx.GovernanceDelay != GovernanceDelay {
		t.Fatalf("governance delay %d, fixture %d", GovernanceDelay, fx.GovernanceDelay)
	}

	// Risk parameters, field by field (and no field missing on either side).
	p := reflect.ValueOf(DefaultRiskParams())
	if p.NumField() != len(fx.RiskParams) {
		t.Fatalf("%d RiskParams fields, fixture has %d", p.NumField(), len(fx.RiskParams))
	}
	for i := range p.NumField() {
		key := lowerFirst(p.Type().Field(i).Name)
		want, ok := fx.RiskParams[key]
		if !ok {
			t.Fatalf("fixture has no %s", key)
		}
		if got := asBig(p.Field(i)); got.Cmp(want) != 0 {
			t.Fatalf("%s: Go mirror %s, fixture %s", key, got, want)
		}
	}

	// Function-to-role table, by full ABI signature.
	type entry struct {
		target, sig string
		role        uint64
	}
	var mine, theirs []entry
	for _, fr := range FunctionRoles() {
		meta, err := ContractMeta(fr.Target)
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := meta.GetAbi()
		if err != nil {
			t.Fatal(err)
		}
		mine = append(mine, entry{fr.Target, parsed.Methods[fr.Method].Sig, fr.Role})
	}
	for _, fr := range fx.FunctionRoles {
		theirs = append(theirs, entry{fr.Target, fr.Signature, fr.Role})
	}
	byKey := func(a, b entry) int { return strings.Compare(a.target+a.sig, b.target+b.sig) }
	slices.SortFunc(mine, byKey)
	slices.SortFunc(theirs, byKey)
	if !slices.Equal(mine, theirs) {
		t.Fatalf("role table differs:\n go      %v\n fixture %v", mine, theirs)
	}

	// Deploy on an in-process chain and read the configuration back.
	alloc := types.GenesisAlloc{}
	adminKey, _ := crypto.GenerateKey()
	admin := crypto.PubkeyToAddress(adminKey.PublicKey)
	alloc[admin] = types.Account{Balance: new(big.Int).Mul(big.NewInt(100), big.NewInt(1e18))}
	sim := simulated.NewBackend(alloc, func(_ *node.Config, eth *ethconfig.Config) {
		cfg := *eth.Genesis.Config
		cfg.BogotaTime, cfg.AmsterdamTime = nil, nil
		eth.Genesis.Config = &cfg
	})
	t.Cleanup(func() { _ = sim.Close() })
	b := mineEachTx{Client: sim.Client(), sim: sim}
	opts, _ := bind.NewKeyedTransactorWithChainID(adminKey, big.NewInt(1337))
	holders := map[string]common.Address{
		"ADMIN": admin, "KEEPER": common.HexToAddress("0xAa"), "RISK_ADMIN": common.HexToAddress("0xBb"),
		"ORACLE_ADMIN": common.HexToAddress("0xCc"), "GUARDIAN": common.HexToAddress("0xDd"),
	}
	sys, err := Deploy(context.Background(), b, opts, Config{
		Signers: []common.Address{common.HexToAddress("0x11"), common.HexToAddress("0x12")}, MinSigners: 2,
		MaxReportAge: 60, MaxSpreadBps: 50, Keepers: []common.Address{holders["KEEPER"]},
		RiskAdmin: holders["RISK_ADMIN"], OracleAdmin: holders["ORACLE_ADMIN"], Guardian: holders["GUARDIAN"],
		MarketName: "ETH-USD", Params: DefaultRiskParams(), ReceiptPoll: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	manager, _ := bindings.NewAccessManager(sys.Manager, b)
	call := &bind.CallOpts{}
	for _, fr := range fx.FunctionRoles {
		target, err := sys.Address(fr.Target)
		if err != nil {
			t.Fatal(err)
		}
		sel := [4]byte(crypto.Keccak256([]byte(fr.Signature))[:4])
		role, err := manager.GetTargetFunctionRole(call, target, sel)
		if err != nil || role != fr.Role {
			t.Fatalf("%s %s: on-chain role %d (err %v), fixture %d", fr.Target, fr.Signature, role, err, fr.Role)
		}
	}
	ids := map[string]uint64{
		"ADMIN": AdminRole, "KEEPER": KeeperRole, "RISK_ADMIN": RiskAdminRole, "ORACLE_ADMIN": OracleAdminRole,
		"GUARDIAN": GuardianRole,
	}
	for _, r := range fx.Roles {
		if ids[r.Name] != r.ID {
			t.Fatalf("role %s: Go id %d, fixture %d", r.Name, ids[r.Name], r.ID)
		}
		got, err := manager.HasRole(call, r.ID, holders[r.Name])
		if err != nil || !got.IsMember || got.ExecutionDelay != r.ExecutionDelay {
			t.Fatalf("role %s: member %v delay %d (err %v), fixture delay %d", r.Name, got.IsMember,
				got.ExecutionDelay, err, r.ExecutionDelay)
		}
	}
}

// mineEachTx commits a block after every transaction, like anvil's automine mode.
type mineEachTx struct {
	simulated.Client
	sim *simulated.Backend
}

func (m mineEachTx) SendTransaction(ctx context.Context, tx *types.Transaction) error {
	if err := m.Client.SendTransaction(ctx, tx); err != nil {
		return err
	}
	m.sim.Commit()
	return nil
}
