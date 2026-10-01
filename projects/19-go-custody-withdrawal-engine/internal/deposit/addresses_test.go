// SPDX-License-Identifier: MIT

package deposit_test

import (
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/monzon1985/blockchain/projects/19-go-custody-withdrawal-engine/internal/deposit"
)

// Reference vectors computed independently with Foundry's `cast create2` over the ERC-1167
// init-code hash (`cast keccak 0x3d602d...73<impl>5af43d...f3`). The integration suite also
// compares every derived address with ForwarderFactory.forwarderAddress on anvil.
func TestForwarderAddressMatchesCastVectors(t *testing.T) {
	factory := common.HexToAddress("0x5FbDB2315678afecb367f032d93F642f64180aa3")
	impl := common.HexToAddress("0xa16E02E87b7454126E5E10d957A927A7F5B5d2be")
	if got := common.BytesToHash(deposit.CloneInitCodeHash(impl)); got != common.HexToHash("0xa84f59ff415cd4ee28ad880ae68a3f84d45f5f088c8b28d956e63c5d0ed38b27") {
		t.Fatalf("init code hash %s", got)
	}
	vectors := []struct{ user, salt, addr string }{
		{"alice", "0x9c0257114eb9399a2985f8e75dad7600c5d89fe3824ffa99ec1c3eb8bf3b0501", "0xE0Be40268473f409A2111BD63caEE5B6ab35b815"},
		{"bob", "0x38e47a7b719dce63662aeaf43440326f551b8a7ee198cee35cb5d517f2d296a2", "0x9fEAb4CFB2F96cD69cD8C2A56e91F90d4EAc7A34"},
		{"user:42", "0x7a662eef64d391773f5f7ef5e3cb2306ec5485455723e692e724f875897c82f7", "0x0374aDBe213be47420AC236052064C4Ad171a9d7"},
		{"", "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "0x95B2aD62a2828FB31Fa4B4AA08F3d790Cf1348a1"},
	}
	d := deposit.NewDeriver(factory, impl)
	for _, v := range vectors {
		if s := deposit.Salt(v.user); s != common.HexToHash(v.salt) {
			t.Fatalf("salt(%q) = %s", v.user, s)
		}
		a, s := d.Address(v.user)
		if a != common.HexToAddress(v.addr) || s != common.HexToHash(v.salt) {
			t.Fatalf("address(%q) = %s, want %s", v.user, a, v.addr)
		}
		if a2 := deposit.ForwarderAddress(factory, impl, s); a2 != a {
			t.Fatalf("ForwarderAddress and Deriver disagree for %q", v.user)
		}
	}
}

// FuzzForwarderAddress cross-checks the optimised derivation against a byte-by-byte
// implementation of keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:].
func FuzzForwarderAddress(f *testing.F) {
	f.Add([]byte("alice"), []byte{1}, []byte{2})
	f.Fuzz(func(t *testing.T, user, factoryB, implB []byte) {
		factory, impl := common.BytesToAddress(factoryB), common.BytesToAddress(implB)
		salt := crypto.Keccak256(user)
		init := append(append(common.FromHex("3d602d80600a3d3981f3363d3d373d3d3d363d73"), impl.Bytes()...),
			common.FromHex("5af43d82803e903d91602b57fd5bf3")...)
		pre := append(append(append([]byte{0xff}, factory.Bytes()...), salt...), crypto.Keccak256(init)...)
		want := common.BytesToAddress(crypto.Keccak256(pre)[12:])
		got, _ := deposit.NewDeriver(factory, impl).Address(string(user))
		if got != want {
			t.Fatalf("got %s want %s", got, want)
		}
	})
}
