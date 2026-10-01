// SPDX-License-Identifier: MIT

package stateproof

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"math/rand/v2"
	"os"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	gethrlp "github.com/ethereum/go-ethereum/rlp"
	gethtrie "github.com/ethereum/go-ethereum/trie"
	"github.com/holiman/uint256"
	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/rlp"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/trie"
)

func TestAccountVectorsFromEthereumTests(t *testing.T) {
	// The values of hex_encoded_securetrie_test.json are RLP-encoded accounts.
	raw, err := os.ReadFile("../trie/testdata/ethereum-tests/hex_encoded_securetrie_test.json")
	require.NoError(t, err)
	var vectors map[string]struct {
		In   map[string]string `json:"in"`
		Root string            `json:"root"`
	}
	require.NoError(t, json.Unmarshal(raw, &vectors))
	n := 0
	for name, tc := range vectors {
		state := trie.NewSecure()
		for addrHex, accHex := range tc.In {
			enc, err := hex.DecodeString(strings.TrimPrefix(accHex, "0x"))
			require.NoError(t, err)
			a, err := DecodeAccount(enc)
			require.NoError(t, err, "%s/%s", name, addrHex)
			back, err := a.Encode()
			require.NoError(t, err)
			require.Equal(t, enc, back, "re-encoding is byte-identical")

			addr, err := keccak.ParseAddress(addrHex)
			require.NoError(t, err)
			state.Put(addr[:], back)
			n++
		}
		require.Equal(t, tc.Root, state.Hash().Hex(), name)
		for addrHex, accHex := range tc.In {
			addr, _ := keccak.ParseAddress(addrHex)
			got, _, err := VerifyAccount(state.Hash(), addr, state.Prove(addr[:]))
			require.NoError(t, err)
			want, _ := hex.DecodeString(strings.TrimPrefix(accHex, "0x"))
			enc, _ := got.Encode()
			require.Equal(t, want, enc)
		}
	}
	require.Positive(t, n)
}

func TestDifferentialAccountEncoding(t *testing.T) {
	rng := rand.New(rand.NewPCG(41, 2026))
	for range 500 {
		var a Account
		a.Nonce = rng.Uint64() >> rng.IntN(64)
		a.Balance = new(big.Int).Rsh(new(big.Int).SetBytes(randBytes(rng, 32)), uint(rng.IntN(256)))
		copy(a.StorageRoot[:], randBytes(rng, 32))
		copy(a.CodeHash[:], randBytes(rng, 32))
		got, err := a.Encode()
		require.NoError(t, err)
		bal, _ := uint256.FromBig(a.Balance)
		want, err := gethrlp.EncodeToBytes(&types.StateAccount{Nonce: a.Nonce, Balance: bal, Root: common.Hash(a.StorageRoot), CodeHash: a.CodeHash[:]})
		require.NoError(t, err)
		require.Equal(t, want, got)
	}
}

func randBytes(rng *rand.Rand, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rng.Uint32())
	}
	return b
}

func TestDecodeAccountRejects(t *testing.T) {
	h := make([]byte, 32)
	cases := map[string][]byte{
		"not RLP":              {0x81, 0x01},
		"a string":             rlp.EncodeString([]byte("account")),
		"three items":          rlp.EncodeList(rlp.EncodeUint64(1), rlp.EncodeUint64(2), rlp.EncodeString(h)),
		"nonce leading zero":   rlp.EncodeList(rlp.EncodeString([]byte{0, 1}), rlp.EncodeUint64(2), rlp.EncodeString(h), rlp.EncodeString(h)),
		"nonce over 64 bits":   rlp.EncodeList(rlp.EncodeString(make([]byte, 9)), rlp.EncodeUint64(2), rlp.EncodeString(h), rlp.EncodeString(h)),
		"balance leading zero": rlp.EncodeList(rlp.EncodeUint64(1), rlp.EncodeString([]byte{0, 1}), rlp.EncodeString(h), rlp.EncodeString(h)),
		"short storage root":   rlp.EncodeList(rlp.EncodeUint64(1), rlp.EncodeUint64(2), rlp.EncodeString(h[:31]), rlp.EncodeString(h)),
		"code hash is a list":  rlp.EncodeList(rlp.EncodeUint64(1), rlp.EncodeUint64(2), rlp.EncodeString(h), rlp.EncodeList()),
	}
	for name, enc := range cases {
		_, err := DecodeAccount(enc)
		require.ErrorIs(t, err, ErrInvalidAccount, name)
	}
	_, err := Account{Balance: big.NewInt(-1)}.Encode()
	require.ErrorIs(t, err, ErrInvalidAccount)
}

func word(hexStr string) keccak.Hash {
	var w keccak.Hash
	b, err := hex.DecodeString(hexStr)
	if err != nil {
		panic(err)
	}
	copy(w[32-len(b):], b)
	return w
}

func TestStorageValueEncoding(t *testing.T) {
	require.Nil(t, EncodeStorageValue(keccak.Hash{}), "zero is not stored")
	cases := []struct {
		value keccak.Hash
		enc   []byte
	}{
		{word("01"), []byte{0x01}},
		{word("7f"), []byte{0x7f}},
		{word("80"), []byte{0x81, 0x80}},
		{word("0100"), []byte{0x82, 0x01, 0x00}},
		{word("ff" + strings.Repeat("00", 31)), append([]byte{0xa0, 0xff}, make([]byte, 31)...)},
	}
	for _, tc := range cases {
		require.Equal(t, tc.enc, EncodeStorageValue(tc.value))
		got, err := DecodeStorageValue(tc.enc)
		require.NoError(t, err)
		require.Equal(t, tc.value, got)
	}
	for name, enc := range map[string][]byte{
		"empty string":  {0x80},
		"leading zero":  {0x82, 0x00, 0x01},
		"33 bytes":      append([]byte{0xa1}, make([]byte, 33)...),
		"a list":        {0xc0},
		"trailing data": {0x01, 0x02},
		"not RLP":       {0x81, 0x01},
	} {
		_, err := DecodeStorageValue(enc)
		require.ErrorIs(t, err, ErrInvalidStorageValue, name)
	}
}

func TestDifferentialStorageRoot(t *testing.T) {
	rng := rand.New(rand.NewPCG(42, 2026))
	for range 30 {
		slots := map[keccak.Hash]keccak.Hash{}
		g := gethtrie.NewEmpty(nil)
		for range rng.IntN(300) {
			var slot, value keccak.Hash
			copy(slot[:], randBytes(rng, 32))
			n := rng.IntN(33) // 0 = zero value, which is not stored
			copy(value[32-n:], randBytes(rng, n))
			if n > 0 && value[32-n] == 0 {
				value[32-n] = 1
			}
			slots[slot] = value
			if n > 0 {
				enc, _ := gethrlp.EncodeToBytes(common.TrimLeftZeroes(value[:]))
				require.NoError(t, g.Update(hashKey(slot[:]), enc))
			}
		}
		require.Equal(t, g.Hash(), common.Hash(StorageRoot(slots)))
	}
	require.Equal(t, keccak.EmptyRoot, StorageRoot(nil))
}

func hashKey(b []byte) []byte {
	h := keccak.Sum256(b)
	return h[:]
}

// world is a small state built with this module's tries: a funded EOA and a contract with
// storage. It plays the node in the eth_getProof tests below.
type world struct {
	state    *trie.SecureTrie
	accounts map[keccak.Address]Account
	storage  map[keccak.Address]*trie.SecureTrie
	values   map[keccak.Address]map[keccak.Hash]keccak.Hash
}

var (
	eoa      = keccak.Address{0xee}
	contract = keccak.Address{0xcc}
	nobody   = keccak.Address{0x00, 0x01}
)

func newWorld(t *testing.T) *world {
	w := &world{state: trie.NewSecure(), accounts: map[keccak.Address]Account{}, storage: map[keccak.Address]*trie.SecureTrie{}, values: map[keccak.Address]map[keccak.Hash]keccak.Hash{}}
	slots := map[keccak.Hash]keccak.Hash{word("00"): word("2a"), word("01"): word("deadbeef"), word("ff"): word("01" + strings.Repeat("00", 31))}
	w.values[contract] = slots
	w.storage[contract] = StorageTrie(slots)
	w.accounts[eoa] = Account{Nonce: 7, Balance: big.NewInt(1e18), StorageRoot: keccak.EmptyRoot, CodeHash: keccak.EmptyCode}
	w.accounts[contract] = Account{Nonce: 1, Balance: big.NewInt(0), StorageRoot: w.storage[contract].Hash(), CodeHash: keccak.Sum256([]byte("code"))}
	for addr, a := range w.accounts {
		enc, err := a.Encode()
		require.NoError(t, err)
		w.state.Put(addr[:], enc)
	}
	return w
}

// getProof answers like an honest node.
func (w *world) getProof(addr keccak.Address, slots ...keccak.Hash) *GetProofResult {
	r := &GetProofResult{Address: addr, AccountProof: w.state.Prove(addr[:]), Balance: new(big.Int)}
	if a, ok := w.accounts[addr]; ok {
		r.Balance, r.Nonce, r.CodeHash, r.StorageHash = a.Balance, a.Nonce, a.CodeHash, a.StorageRoot
	}
	for _, s := range slots {
		sr := StorageResult{Key: s, Value: new(big.Int)}
		if st := w.storage[addr]; st != nil {
			sr.Proof = st.Prove(s[:])
			v := w.values[addr][s]
			sr.Value = new(big.Int).SetBytes(v[:])
		}
		r.StorageProof = append(r.StorageProof, sr)
	}
	return r
}

func TestCheckGetProofHonest(t *testing.T) {
	w := newWorld(t)
	root := w.state.Hash()

	out, err := CheckGetProof(root, w.getProof(contract, word("00"), word("01"), word("ff"), word("05")))
	require.NoError(t, err)
	require.True(t, out.OK(), out.Mismatches)
	require.Equal(t, w.accounts[contract].StorageRoot, out.Account.StorageRoot)
	require.Len(t, out.Slots, 4)
	require.Equal(t, word("2a"), out.Slots[0].Value)
	require.True(t, out.Slots[2].Exists)
	require.False(t, out.Slots[3].Exists, "slot 5 was never written")
	require.NotEmpty(t, out.AccountSteps)

	out, err = CheckGetProof(root, w.getProof(eoa, word("00")))
	require.NoError(t, err)
	require.True(t, out.OK(), out.Mismatches)
	require.Equal(t, uint64(7), out.Account.Nonce)
	require.False(t, out.Slots[0].Exists, "an EOA has an empty storage trie")

	// An address without an account, in both conventions for the empty hashes.
	absent := w.getProof(nobody, word("00"))
	out, err = CheckGetProof(root, absent)
	require.NoError(t, err)
	require.True(t, out.OK(), out.Mismatches)
	require.Nil(t, out.Account)
	absent.CodeHash, absent.StorageHash, absent.Balance = keccak.EmptyCode, keccak.EmptyRoot, nil
	out, err = CheckGetProof(root, absent)
	require.NoError(t, err)
	require.True(t, out.OK(), out.Mismatches)
}

func TestCheckGetProofMismatches(t *testing.T) {
	w := newWorld(t)
	root := w.state.Hash()
	cases := []struct {
		name   string
		addr   keccak.Address
		mutate func(r *GetProofResult)
		want   string
	}{
		{"balance", eoa, func(r *GetProofResult) { r.Balance = big.NewInt(1) }, "balance"},
		{"nonce", eoa, func(r *GetProofResult) { r.Nonce++ }, "nonce"},
		{"code hash", contract, func(r *GetProofResult) { r.CodeHash = keccak.EmptyCode }, "codeHash"},
		{"storage hash", contract, func(r *GetProofResult) { r.StorageHash = keccak.EmptyRoot }, "storageHash"},
		{"slot value", contract, func(r *GetProofResult) { r.StorageProof[0].Value = big.NewInt(43) }, "slot"},
		{"slot claimed nil for a set slot", contract, func(r *GetProofResult) { r.StorageProof[0].Value = nil }, "slot"},
		{"absent account with a balance", nobody, func(r *GetProofResult) { r.Balance = big.NewInt(5) }, "absent account claimed nonce"},
		{"absent account with code", nobody, func(r *GetProofResult) { r.CodeHash = keccak.Sum256([]byte("x")) }, "codeHash"},
		{"absent account with storage", nobody, func(r *GetProofResult) { r.StorageHash = keccak.Sum256([]byte("x")) }, "storageHash"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := w.getProof(tc.addr, word("00"))
			tc.mutate(r)
			out, err := CheckGetProof(root, r)
			require.NoError(t, err, "the proofs are still valid")
			require.False(t, out.OK())
			require.Contains(t, strings.Join(out.Mismatches, "\n"), tc.want)
		})
	}
}

func TestCheckGetProofInvalidProofs(t *testing.T) {
	w := newWorld(t)
	root := w.state.Hash()

	r := w.getProof(contract, word("00"))
	_, err := CheckGetProof(keccak.Sum256([]byte("other root")), r)
	require.ErrorIs(t, err, trie.ErrMissingProofNode)

	r = w.getProof(contract, word("00"))
	r.StorageProof[0].Proof[0][5] ^= 1
	_, err = CheckGetProof(root, r)
	require.Error(t, err)

	r = w.getProof(contract, word("00"))
	r.AccountProof = r.AccountProof[:len(r.AccountProof)-1]
	_, err = CheckGetProof(root, r)
	require.ErrorIs(t, err, trie.ErrMissingProofNode)

	// A lying node builds its own storage trie with a fake value and claims its root as
	// storageHash. The slot proof is internally consistent, but it is checked against the
	// storage root inside the proven account, so it fails.
	fake := StorageTrie(map[keccak.Hash]keccak.Hash{word("00"): word("0bad")})
	r = w.getProof(contract, word("00"))
	r.StorageHash = fake.Hash()
	slot0 := word("00")
	r.StorageProof[0].Proof = fake.Prove(slot0[:])
	r.StorageProof[0].Value = big.NewInt(0xbad)
	_, err = CheckGetProof(root, r)
	require.ErrorIs(t, err, trie.ErrMissingProofNode)

	// An account leaf that is not an account.
	bad := trie.NewSecure()
	bad.Put(eoa[:], []byte{0x01})
	_, _, err = VerifyAccount(bad.Hash(), eoa, bad.Prove(eoa[:]))
	require.ErrorIs(t, err, ErrInvalidAccount)

	// A storage leaf that is not a canonical value.
	badStorage := trie.NewSecure()
	slot := word("00")
	badStorage.Put(slot[:], []byte{0x82, 0x00, 0x01})
	_, _, err = VerifyStorage(badStorage.Hash(), slot, badStorage.Prove(slot[:]))
	require.ErrorIs(t, err, ErrInvalidStorageValue)
}
