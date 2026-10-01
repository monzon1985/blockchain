// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/crypto/kzg4844"
	"github.com/holiman/uint256"
	"github.com/stretchr/testify/require"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/block"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/inspect"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/internal/devnet"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
)

// go-ethereum builds and signs these transactions (eth_sendTransaction cannot express blobs or
// authorizations); the inspector then verifies the blocks they land in with its own code.

func newFundedKey(t *testing.T, n *devnet.Node) (*ecdsa.PrivateKey, common.Address) {
	t.Helper()
	key, err := crypto.GenerateKey()
	require.NoError(t, err)
	addr := crypto.PubkeyToAddress(key.PublicKey)
	require.NoError(t, n.Call(testContext(t), nil, "anvil_setBalance", addr, "0x56bc75e2d63100000")) // 100 ether
	return key, addr
}

// blobSidecar builds a sidecar of n blobs in the given version (0: one proof per blob,
// Cancun/Prague; 1: cell proofs, Osaka's PeerDAS format).
func blobSidecar(t *testing.T, n int, version byte) *types.BlobTxSidecar {
	var (
		blobs   []kzg4844.Blob
		commits []kzg4844.Commitment
		proofs  []kzg4844.Proof
	)
	for i := range n {
		var b kzg4844.Blob
		for j := range 64 { // canonical field elements: the first byte of each stays zero
			b[j*32+31] = byte(i*64 + j)
		}
		c, err := kzg4844.BlobToCommitment(&b)
		require.NoError(t, err)
		blobs, commits = append(blobs, b), append(commits, c)
		if version == types.BlobSidecarVersion0 {
			p, err := kzg4844.ComputeBlobProof(&b, c)
			require.NoError(t, err)
			proofs = append(proofs, p)
		} else {
			ps, err := kzg4844.ComputeCellProofs(&b)
			require.NoError(t, err)
			proofs = append(proofs, ps...)
		}
	}
	return types.NewBlobTxSidecar(version, blobs, commits, proofs)
}

func TestBlobAndSetCodeTransactions(t *testing.T) {
	for _, tc := range []struct {
		hardfork string
		setCode  bool
		version  byte
	}{
		{"cancun", false, types.BlobSidecarVersion0},
		{"prague", true, types.BlobSidecarVersion0},
		{"osaka", true, types.BlobSidecarVersion1},
	} {
		t.Run(tc.hardfork, func(t *testing.T) {
			n := startNode(t, tc.hardfork)
			ctx := testContext(t)
			key, _ := newFundedKey(t, n)
			signer := types.LatestSignerForChainID(big.NewInt(devnet.ChainID))
			to := common.Address{0x42}
			fee := uint256.NewInt(20_000_000_000)
			tip := uint256.NewInt(1_000_000_000)

			sidecar := blobSidecar(t, 2, tc.version)
			blobTx, err := types.SignNewTx(key, signer, &types.BlobTx{
				ChainID: uint256.NewInt(devnet.ChainID), Nonce: 0, GasTipCap: tip, GasFeeCap: fee, Gas: 21_000,
				To: to, Value: uint256.NewInt(0), BlobFeeCap: fee, BlobHashes: sidecar.BlobHashes(), Sidecar: sidecar,
			})
			require.NoError(t, err)
			network, err := blobTx.MarshalBinary() // with the sidecar: the pool needs the blobs
			require.NoError(t, err)
			h, err := n.SendRaw(ctx, network)
			require.NoError(t, err, "anvil log:\n%s", n.Log())
			require.Equal(t, keccak.Hash(blobTx.Hash()), h)
			txs := []*types.Transaction{blobTx}

			var authority common.Address
			if tc.setCode {
				authKey, err := crypto.GenerateKey()
				require.NoError(t, err)
				authority = crypto.PubkeyToAddress(authKey.PublicKey)
				auth, err := types.SignSetCode(authKey, types.SetCodeAuthorization{ChainID: *uint256.NewInt(devnet.ChainID), Address: to, Nonce: 0})
				require.NoError(t, err)
				setCodeTx, err := types.SignNewTx(key, signer, &types.SetCodeTx{
					ChainID: uint256.NewInt(devnet.ChainID), Nonce: 1, GasTipCap: tip, GasFeeCap: fee, Gas: 100_000,
					To: authority, Value: uint256.NewInt(0), AuthList: []types.SetCodeAuthorization{auth},
				})
				require.NoError(t, err)
				raw, err := setCodeTx.MarshalBinary()
				require.NoError(t, err)
				_, err = n.SendRaw(ctx, raw)
				require.NoError(t, err)
				txs = append(txs, setCodeTx)
			}
			num, err := n.Mine(ctx, 0)
			require.NoError(t, err)

			c := dial(t, n.URL)
			rep, err := inspect.VerifyBlock(ctx, c, ethrpc.Number(num))
			require.NoError(t, err)
			requireAllPass(t, rep.Checks)
			require.Equal(t, len(txs), rep.Transactions, "both transactions were included")
			require.Equal(t, 1, rep.TxTypes["blob"])
			blobGas := statuses(rep.Checks)["blobGasUsed"]
			require.Equal(t, inspect.Pass, blobGas)
			b, err := c.BlockByRef(ctx, ethrpc.Number(num))
			require.NoError(t, err)
			require.Equal(t, uint64(2*block.GasPerBlob), *b.Header.BlobGasUsed)

			// The node's canonical envelope is the transaction without its sidecar.
			raws, err := c.RawTransactions(ctx, []keccak.Hash{keccak.Hash(blobTx.Hash())})
			require.NoError(t, err)
			canonical, err := blobTx.WithoutBlobTxSidecar().MarshalBinary()
			require.NoError(t, err)
			require.Equal(t, canonical, raws[0])
			count, err := block.BlobCount(raws[0])
			require.NoError(t, err)
			require.Equal(t, 2, count)

			if tc.setCode {
				require.Equal(t, 1, rep.TxTypes["set-code"])
				// EIP-7702: the authority's code is now the delegation designator 0xef0100 || to,
				// and the account proof shows it.
				proof, err := inspect.VerifyProof(ctx, c, keccak.Address(authority), nil, ethrpc.Number(num))
				require.NoError(t, err)
				requireAllPass(t, proof.Checks)
				designator := append([]byte{0xef, 0x01, 0x00}, to[:]...)
				require.Equal(t, keccak.Sum256(designator), proof.Account.CodeHash, fmt.Sprintf("delegation to %s", to))
			}
		})
	}
}
