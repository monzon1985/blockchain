// SPDX-License-Identifier: MIT

package app_test

import (
	"context"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/app"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chainsim"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/config"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/testenv"
)

// TestStartupRefusesMisconfiguration: the engine verifies the node and the factory before it
// does anything, because a wrong factory would hand customers deposit addresses nobody can sweep.
func TestStartupRefusesMisconfiguration(t *testing.T) {
	key, _ := crypto.GenerateKey()
	hot := crypto.PubkeyToAddress(key.PublicKey)
	other := common.HexToAddress("0x00000000000000000000000000000000000000aa")
	cases := []struct {
		name    string
		factory chainsim.Factory
		tweak   func(*config.Config)
		want    string
	}{
		{"wrong chain", chainsim.Factory{Destination: hot, Owner: hot}, func(c *config.Config) { c.Chain.ChainID = 1 }, "configuration says"},
		{"factory pays someone else", chainsim.Factory{Destination: other, Owner: hot}, nil, "not the hot wallet"},
		{"factory owned by someone else", chainsim.Factory{Destination: hot, Owner: other}, nil, "must own it"},
		{"not a factory", chainsim.Factory{Destination: hot, Owner: hot}, func(c *config.Config) { c.Deposits.Factory = testenv.TokenAddr.Hex() }, "is it a ForwarderFactory"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := tc.factory
			f.Address, f.Implementation, f.Token = testenv.FactoryAddr, testenv.ImplAddr, testenv.TokenAddr
			c := chainsim.New(chainsim.Config{ChainID: big.NewInt(31337), Tokens: []common.Address{testenv.TokenAddr}, Factory: &f})
			cfg := testenv.Config(t.TempDir(), hot)
			if tc.tweak != nil {
				tc.tweak(cfg)
			}
			a, err := app.New(context.Background(), cfg, app.Deps{Chain: c, Signer: signer.NewLocalKeystoreSigner(key), Log: testenv.Logger()})
			if err == nil {
				a.Close()
				t.Fatal("misconfiguration accepted")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}
