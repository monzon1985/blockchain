// SPDX-License-Identifier: MIT

package signer_test

import (
	"context"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/bindings"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/chain"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/clock"
	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/signer"
)

var (
	chainID = big.NewInt(31337)
	token   = common.HexToAddress("0x0000000000000000000000000000000000007070")
	factory = common.HexToAddress("0x000000000000000000000000000000000000fac7")
	dest    = common.HexToAddress("0x00000000000000000000000000000000000000d1")
	gwei    = big.NewInt(1_000_000_000)
)

type fakeAllowlist struct {
	active map[common.Address]bool
	err    error
}

func (f fakeAllowlist) IsActive(_ context.Context, _ string, a common.Address, _ time.Time) (bool, error) {
	return f.active[a], f.err
}

func newFirewall(t *testing.T, al signer.AllowlistChecker) (*signer.Firewall, common.Address) {
	t.Helper()
	key, _ := crypto.GenerateKey()
	s := signer.NewLocalKeystoreSigner(key)
	fw, err := signer.NewFirewall(s, signer.FirewallConfig{
		ChainID: chainID, Factory: factory, MaxFeeCap: new(big.Int).Mul(big.NewInt(500), gwei),
		Assets: map[string]signer.Asset{"USD": {Token: token, MaxPerTx: big.NewInt(1_000)}},
	}, al, clock.NewFake(time.Unix(0, 0)))
	if err != nil {
		t.Fatal(err)
	}
	return fw, s.Address()
}

type txOpts struct {
	chainID    *big.Int
	to         *common.Address
	value      *big.Int
	data       []byte
	gas        uint64
	fee, tip   *big.Int
	accessList types.AccessList
	legacy     bool
}

func mkTx(o txOpts) *types.Transaction {
	if o.chainID == nil {
		o.chainID = chainID
	}
	if o.value == nil {
		o.value = new(big.Int)
	}
	if o.gas == 0 {
		o.gas = 60_000
	}
	if o.fee == nil {
		o.fee = new(big.Int).Mul(big.NewInt(10), gwei)
	}
	if o.tip == nil {
		o.tip = gwei
	}
	if o.legacy {
		return types.NewTx(&types.LegacyTx{Nonce: 1, GasPrice: o.fee, Gas: o.gas, To: o.to, Value: o.value, Data: o.data})
	}
	return types.NewTx(&types.DynamicFeeTx{ChainID: o.chainID, Nonce: 1, GasFeeCap: o.fee, GasTipCap: o.tip, Gas: o.gas,
		To: o.to, Value: o.value, Data: o.data, AccessList: o.accessList})
}

func ptr(a common.Address) *common.Address { return &a }

func TestFirewall(t *testing.T) {
	fw, self := newFirewall(t, fakeAllowlist{active: map[common.Address]bool{dest: true}})
	ff := bindings.NewForwarderFactory()
	flush := ff.PackFlushMany([][32]byte{{1}, {2}}, token)
	transfer := chain.EncodeTransfer(dest, big.NewInt(100))
	cases := []struct {
		name string
		req  signer.Request
		ok   bool
	}{
		{"withdrawal ok", signer.Request{Purpose: signer.PurposeWithdrawal, AccountID: "u", Asset: "USD", Tx: mkTx(txOpts{to: &token, data: transfer})}, true},
		{"withdrawal at max per tx", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(dest, big.NewInt(1_000))})}, true},
		{"above max per tx", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(dest, big.NewInt(1_001))})}, false},
		{"zero amount", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(dest, big.NewInt(0))})}, false},
		{"not allowlisted", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(common.HexToAddress("0xd2"), big.NewInt(1))})}, false},
		{"to self", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(self, big.NewInt(1))})}, false},
		{"to token", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(token, big.NewInt(1))})}, false},
		{"to factory", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(factory, big.NewInt(1))})}, false},
		{"to zero", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(common.Address{}, big.NewInt(1))})}, false},
		{"wrong token contract", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: ptr(dest), data: transfer})}, false},
		{"unknown asset", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "EUR", Tx: mkTx(txOpts{to: &token, data: transfer})}, false},
		{"approve instead of transfer", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: append([]byte{0x09, 0x5e, 0xa7, 0xb3}, transfer[4:]...)})}, false},
		{"wrong chain", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{chainID: big.NewInt(1), to: &token, data: transfer})}, false},
		{"legacy type", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{legacy: true, to: &token, data: transfer})}, false},
		{"fee above cap", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: transfer, fee: new(big.Int).Mul(big.NewInt(501), gwei)})}, false},
		{"tip above fee", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: transfer, fee: gwei, tip: big.NewInt(2e9)})}, false},
		{"contract creation", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{data: transfer})}, false},
		{"native value", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: transfer, value: big.NewInt(1)})}, false},
		{"access list", signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: transfer, accessList: types.AccessList{{Address: token}}})}, false},
		{"cancel ok", signer.Request{Purpose: signer.PurposeCancel, Tx: mkTx(txOpts{to: &self, gas: signer.SelfSendGas})}, true},
		{"filler ok", signer.Request{Purpose: signer.PurposeFiller, Tx: mkTx(txOpts{to: &self, gas: signer.SelfSendGas})}, true},
		{"cancel with data", signer.Request{Purpose: signer.PurposeCancel, Tx: mkTx(txOpts{to: &self, gas: signer.SelfSendGas, data: []byte{1}})}, false},
		{"cancel to other", signer.Request{Purpose: signer.PurposeCancel, Tx: mkTx(txOpts{to: ptr(dest), gas: signer.SelfSendGas})}, false},
		{"cancel wrong gas", signer.Request{Purpose: signer.PurposeCancel, Tx: mkTx(txOpts{to: &self, gas: 50_000})}, false},
		{"sweep ok", signer.Request{Purpose: signer.PurposeSweep, Asset: "USD", Tx: mkTx(txOpts{to: &factory, data: flush})}, true},
		{"sweep wrong target", signer.Request{Purpose: signer.PurposeSweep, Asset: "USD", Tx: mkTx(txOpts{to: &token, data: flush})}, false},
		{"sweep wrong token", signer.Request{Purpose: signer.PurposeSweep, Asset: "USD", Tx: mkTx(txOpts{to: &factory, data: ff.PackFlushMany([][32]byte{{1}}, dest)})}, false},
		{"sweep other method", signer.Request{Purpose: signer.PurposeSweep, Asset: "USD", Tx: mkTx(txOpts{to: &factory, data: ff.PackTransferOwnership(dest)})}, false},
		{"sweep native", signer.Request{Purpose: signer.PurposeSweep, Asset: "USD", Tx: mkTx(txOpts{to: &factory, data: ff.PackFlushNativeMany([][32]byte{{1}})})}, false},
		{"sweep empty batch", signer.Request{Purpose: signer.PurposeSweep, Asset: "USD", Tx: mkTx(txOpts{to: &factory, data: ff.PackFlushMany(nil, token)})}, false},
		{"sweep trailing bytes", signer.Request{Purpose: signer.PurposeSweep, Asset: "USD", Tx: mkTx(txOpts{to: &factory, data: append(flush, 0)})}, false},
		{"unknown purpose", signer.Request{Purpose: "other", Tx: mkTx(txOpts{to: &self, gas: signer.SelfSendGas})}, false},
		{"nil tx", signer.Request{Purpose: signer.PurposeCancel}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			signed, err := fw.Sign(context.Background(), tc.req)
			if tc.ok {
				if err != nil {
					t.Fatalf("refused: %v", err)
				}
				from, err := types.Sender(types.LatestSignerForChainID(chainID), signed)
				if err != nil || from != self {
					t.Fatalf("signature recovers to %s (%v), want %s", from, err, self)
				}
				return
			}
			if !errors.Is(err, signer.ErrPolicy) {
				t.Fatalf("expected a policy refusal, got %v", err)
			}
		})
	}
}

func TestFirewallAllowlistErrorIsNotAPolicyRefusal(t *testing.T) {
	fw, _ := newFirewall(t, fakeAllowlist{err: errors.New("db down")})
	_, err := fw.Sign(context.Background(), signer.Request{Purpose: signer.PurposeWithdrawal, Asset: "USD",
		Tx: mkTx(txOpts{to: &token, data: chain.EncodeTransfer(dest, big.NewInt(1))})})
	if err == nil || errors.Is(err, signer.ErrPolicy) {
		t.Fatalf("transient allowlist failure must be retryable, got %v", err)
	}
}

func TestNewFirewallValidates(t *testing.T) {
	key, _ := crypto.GenerateKey()
	s := signer.NewLocalKeystoreSigner(key)
	if _, err := signer.NewFirewall(s, signer.FirewallConfig{MaxFeeCap: gwei}, nil, clock.Real{}); err == nil {
		t.Fatal("missing chain id accepted")
	}
	if _, err := signer.NewFirewall(s, signer.FirewallConfig{ChainID: chainID}, nil, clock.Real{}); err == nil {
		t.Fatal("missing fee cap accepted")
	}
	if _, err := s.SignTx(context.Background(), mkTx(txOpts{to: &token}), nil); err == nil {
		t.Fatal("nil chain id accepted")
	}
}

func TestKeystoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	key, _ := crypto.GenerateKey()
	blob, err := signer.EncryptKeystore(key, "correct horse", true)
	if err != nil {
		t.Fatal(err)
	}
	ks, pw, bad := filepath.Join(dir, "k.json"), filepath.Join(dir, "p"), filepath.Join(dir, "bad")
	must(t, os.WriteFile(ks, blob, 0o600))
	must(t, os.WriteFile(pw, []byte("correct horse\r\n"), 0o600))
	must(t, os.WriteFile(bad, []byte("wrong"), 0o600))
	s, err := signer.LoadKeystore(ks, pw)
	if err != nil {
		t.Fatal(err)
	}
	if s.Address() != crypto.PubkeyToAddress(key.PublicKey) {
		t.Fatal("address mismatch")
	}
	if _, err := signer.LoadKeystore(ks, bad); err == nil {
		t.Fatal("wrong password accepted")
	}
	if _, err := signer.LoadKeystore(filepath.Join(dir, "missing"), pw); err == nil {
		t.Fatal("missing keystore accepted")
	}
	if _, err := signer.LoadKeystore(ks, filepath.Join(dir, "missing")); err == nil {
		t.Fatal("missing password file accepted")
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
