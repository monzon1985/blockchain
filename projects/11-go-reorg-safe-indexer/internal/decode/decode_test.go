// SPDX-License-Identifier: MIT

package decode

import (
	"bytes"
	"errors"
	"math/big"
	"slices"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

var (
	token    = common.HexToAddress("0x1000000000000000000000000000000000000001")
	vault    = common.HexToAddress("0x2000000000000000000000000000000000000002")
	asset    = common.HexToAddress("0x3000000000000000000000000000000000000003")
	stranger = common.HexToAddress("0x4000000000000000000000000000000000000004")
	alice    = common.HexToAddress("0x00000000000000000000000000000000000a11ce")
	bob      = common.HexToAddress("0x0000000000000000000000000000000000000b0b")

	topicApproval = crypto.Keccak256Hash([]byte("Approval(address,address,uint256)"))
)

func contracts() Contracts {
	return Contracts{Tokens: []common.Address{token, token}, Vaults: map[common.Address]common.Address{vault: asset}}
}

func word(v int64) []byte { return common.LeftPadBytes(big.NewInt(v).Bytes(), 32) }

func at(a common.Address) common.Hash { return common.BytesToHash(a.Bytes()) }

func TestSignatures(t *testing.T) {
	for name, got := range map[string]common.Hash{
		"Transfer(address,address,uint256)":                 TopicTransfer,
		"Deposit(address,address,uint256,uint256)":          TopicDeposit,
		"Withdraw(address,address,address,uint256,uint256)": TopicWithdraw,
	} {
		if want := crypto.Keccak256Hash([]byte(name)); got != want {
			t.Errorf("%s: binding topic %s, want %s", name, got, want)
		}
	}
}

func TestContractsAddresses(t *testing.T) {
	got := contracts().Addresses()
	want := []common.Address{token, vault, asset}
	slices.SortFunc(want, func(a, b common.Address) int { return a.Cmp(b) })
	if !slices.Equal(got, want) {
		t.Fatalf("Addresses() = %v, want %v (deduplicated, sorted)", got, want)
	}
}

func TestDecode(t *testing.T) {
	dirty := at(alice)
	dirty[0] = 1
	cases := []struct {
		name    string
		log     types.Log
		wantErr error
		check   func(t *testing.T, d Decoded)
	}{
		{
			name: "erc20 transfer",
			log:  types.Log{Address: token, Topics: []common.Hash{TopicTransfer, at(alice), at(bob)}, Data: word(42), BlockNumber: 7, Index: 3},
			check: func(t *testing.T, d Decoded) {
				tr := d.Transfer
				if tr == nil || tr.From != alice || tr.To != bob || tr.Value.String() != "42" || tr.Token != token || tr.Block.Number != 7 || tr.LogIndex != 3 {
					t.Fatalf("decoded %+v", tr)
				}
			},
		},
		{
			name: "transfer of vault shares",
			log:  types.Log{Address: vault, Topics: []common.Hash{TopicTransfer, at(common.Address{}), at(bob)}, Data: word(1)},
			check: func(t *testing.T, d Decoded) {
				if d.Transfer == nil || d.Transfer.Token != vault {
					t.Fatalf("decoded %+v", d)
				}
			},
		},
		{name: "erc721 transfer (tokenId indexed)", log: types.Log{Address: token, Topics: []common.Hash{TopicTransfer, at(alice), at(bob), common.BigToHash(big.NewInt(9))}}, wantErr: ErrMalformed},
		{name: "dirty address topic", log: types.Log{Address: token, Topics: []common.Hash{TopicTransfer, dirty, at(bob)}, Data: word(1)}, wantErr: ErrMalformed},
		{name: "short data", log: types.Log{Address: token, Topics: []common.Hash{TopicTransfer, at(alice), at(bob)}, Data: word(1)[:31]}, wantErr: ErrMalformed},
		{name: "trailing data", log: types.Log{Address: token, Topics: []common.Hash{TopicTransfer, at(alice), at(bob)}, Data: append(word(1), 0)}, wantErr: ErrMalformed},
		{name: "empty data", log: types.Log{Address: token, Topics: []common.Hash{TopicTransfer, at(alice), at(bob)}}, wantErr: ErrMalformed},
		{name: "anonymous log", log: types.Log{Address: token}, wantErr: ErrUnknownEvent},
		{name: "approval", log: types.Log{Address: token, Topics: []common.Hash{topicApproval, at(alice), at(bob)}, Data: word(1)}, wantErr: ErrUnknownEvent},
		{name: "unwatched emitter", log: types.Log{Address: stranger, Topics: []common.Hash{TopicTransfer, at(alice), at(bob)}, Data: word(1)}, wantErr: ErrUnknownEvent},
		{name: "deposit from a token", log: types.Log{Address: token, Topics: []common.Hash{TopicDeposit, at(alice), at(bob)}, Data: append(word(1), word(2)...)}, wantErr: ErrUnknownEvent},
		{
			name: "deposit",
			log:  types.Log{Address: vault, Topics: []common.Hash{TopicDeposit, at(alice), at(bob)}, Data: append(word(100), word(100000)...)},
			check: func(t *testing.T, d Decoded) {
				v := d.Vault
				if v == nil || v.Kind != "deposit" || v.Sender != alice || v.Owner != bob || v.Receiver != (common.Address{}) || v.Assets.String() != "100" || v.Shares.String() != "100000" {
					t.Fatalf("decoded %+v", v)
				}
			},
		},
		{
			name: "withdraw",
			log:  types.Log{Address: vault, Topics: []common.Hash{TopicWithdraw, at(alice), at(bob), at(alice)}, Data: append(word(5), word(5000)...)},
			check: func(t *testing.T, d Decoded) {
				v := d.Vault
				if v == nil || v.Kind != "withdraw" || v.Sender != alice || v.Receiver != bob || v.Owner != alice || v.Assets.String() != "5" || v.Shares.String() != "5000" {
					t.Fatalf("decoded %+v", v)
				}
			},
		},
		{name: "withdraw with 3 topics", log: types.Log{Address: vault, Topics: []common.Hash{TopicWithdraw, at(alice), at(bob)}, Data: append(word(5), word(5)...)}, wantErr: ErrMalformed},
		{name: "deposit with short data", log: types.Log{Address: vault, Topics: []common.Hash{TopicDeposit, at(alice), at(bob)}, Data: word(5)}, wantErr: ErrMalformed},
	}
	d := New(contracts())
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := d.Decode(&tc.log)
			if tc.wantErr != nil {
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("err = %v, want %v", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			tc.check(t, got)
		})
	}
}

func TestDirectDecodersRejectOtherEvents(t *testing.T) {
	if _, err := DecodeTransfer(&types.Log{Topics: []common.Hash{TopicDeposit}}); !errors.Is(err, ErrUnknownEvent) {
		t.Fatalf("DecodeTransfer on a Deposit: %v", err)
	}
	if _, err := DecodeVaultEvent(&types.Log{Topics: []common.Hash{TopicTransfer}}); !errors.Is(err, ErrUnknownEvent) {
		t.Fatalf("DecodeVaultEvent on a Transfer: %v", err)
	}
	if _, err := DecodeVaultEvent(&types.Log{}); !errors.Is(err, ErrUnknownEvent) {
		t.Fatalf("DecodeVaultEvent on an anonymous log: %v", err)
	}
}

// FuzzDecodeLog feeds arbitrary topics and data (optionally forced into the canonical shape of a
// tracked event) to the decoder. It must never panic, and whatever it accepts must re-encode to
// the identical log: the decoder accepts exactly the encodings Solidity's `emit` produces.
func FuzzDecodeLog(f *testing.F) {
	f.Add(byte(0), byte(3), true, bytes.Repeat([]byte{0xab}, 64), word(42))
	f.Add(byte(1), byte(3), true, bytes.Repeat([]byte{0x01}, 64), append(word(1), word(2)...))
	f.Add(byte(2), byte(4), true, bytes.Repeat([]byte{0x02}, 96), append(word(1), word(2)...))
	f.Add(byte(0), byte(4), false, bytes.Repeat([]byte{0xff}, 96), []byte{})
	f.Add(byte(3), byte(2), false, []byte{1, 2, 3}, []byte{4})
	d := New(contracts())
	f.Fuzz(func(t *testing.T, sel, ntopics byte, canonicalize bool, topicBytes, data []byte) {
		sigs := []common.Hash{TopicTransfer, TopicDeposit, TopicWithdraw, topicApproval}
		emitters := []common.Address{token, vault, asset, stranger}
		l := types.Log{Address: emitters[int(sel>>2)%len(emitters)], Data: data}
		n := int(ntopics % 6)
		if n > 0 {
			l.Topics = append(l.Topics, sigs[int(sel)%len(sigs)])
		}
		for i := 1; i < n; i++ {
			var h common.Hash
			if off := (i - 1) * 32; off < len(topicBytes) {
				copy(h[:], topicBytes[off:])
			}
			if canonicalize {
				clear(h[:12])
			}
			l.Topics = append(l.Topics, h)
		}
		if canonicalize && n > 0 {
			words := 1
			if l.Topics[0] != TopicTransfer {
				words = 2
			}
			l.Data = append(append([]byte{}, data...), make([]byte, words*32)...)[:words*32]
		}

		got, err := d.Decode(&l)
		if err != nil {
			if !errors.Is(err, ErrMalformed) && !errors.Is(err, ErrUnknownEvent) {
				t.Fatalf("unexpected error class: %v", err)
			}
			return
		}
		var topics []common.Hash
		var enc []byte
		switch {
		case got.Transfer != nil:
			tr := got.Transfer
			topics = []common.Hash{TopicTransfer, at(tr.From), at(tr.To)}
			enc = common.LeftPadBytes(tr.Value.Big().Bytes(), 32)
		case got.Vault != nil && got.Vault.Kind == "deposit":
			v := got.Vault
			topics = []common.Hash{TopicDeposit, at(v.Sender), at(v.Owner)}
			enc = append(common.LeftPadBytes(v.Assets.Big().Bytes(), 32), common.LeftPadBytes(v.Shares.Big().Bytes(), 32)...)
		case got.Vault != nil && got.Vault.Kind == "withdraw":
			v := got.Vault
			topics = []common.Hash{TopicWithdraw, at(v.Sender), at(v.Receiver), at(v.Owner)}
			enc = append(common.LeftPadBytes(v.Assets.Big().Bytes(), 32), common.LeftPadBytes(v.Shares.Big().Bytes(), 32)...)
		default:
			t.Fatalf("Decode succeeded without a result: %+v", got)
		}
		if !slices.Equal(topics, l.Topics) || !bytes.Equal(enc, l.Data) {
			t.Fatalf("round trip mismatch:\n topics %x\n   want %x\n data %x\n want %x", topics, l.Topics, enc, l.Data)
		}
	})
}
