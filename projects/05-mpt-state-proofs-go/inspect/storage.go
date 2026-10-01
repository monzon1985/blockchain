// SPDX-License-Identifier: MIT

package inspect

import (
	"context"
	"fmt"
	"io"

	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/ethrpc"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/keccak"
	"github.com/monzon1985/blockchain/projects/05-mpt-state-proofs-go/stateproof"
)

// StorageReport is the result of RebuildStorage.
type StorageReport struct {
	Block       uint64      `json:"block"`
	BlockHash   keccak.Hash `json:"blockHash"`
	Address     string      `json:"address"`
	Slots       int         `json:"slots"`
	NonZero     int         `json:"nonZero"`
	StorageRoot keccak.Hash `json:"storageRoot"`
	Rebuilt     keccak.Hash `json:"rebuilt"`
	Checks      Checks      `json:"checks"`
}

// RebuildStorage reads the given slots with eth_getStorageAt, rebuilds the contract's storage
// trie from them, and compares its root with the storage root proven (via eth_getProof) under
// the verified block's stateRoot. Equal roots prove that the non-zero slots in the list are
// exactly the contract's storage, with exactly these values: a missing slot or a wrong value
// changes the root. The block must be the requested one and the proof must be for addr, or
// the report fails.
func RebuildStorage(ctx context.Context, src Source, addr keccak.Address, slots []keccak.Hash, ref ethrpc.BlockRef) (*StorageReport, error) {
	b, err := src.BlockByRef(ctx, ref)
	if err != nil {
		return nil, err
	}
	pinned := ethrpc.Number(b.Header.Number)
	rep := &StorageReport{Block: b.Header.Number, BlockHash: b.Hash, Address: addr.Hex(), Slots: len(slots)}
	c := &rep.Checks
	checkBlockNumber(c, ref, b.Header.Number)
	checkHeader(c, b)

	res, err := src.GetProof(ctx, addr, nil, pinned)
	if err != nil {
		return nil, err
	}
	checkAddress(c, addr, res.Address)
	out, err := stateproof.CheckGetProof(b.Header.StateRoot, res)
	switch {
	case err != nil:
		c.add("account proof", Fail, "INVALID: "+err.Error())
		return rep, nil
	case out.Account == nil:
		c.add("account proof", Fail, "no account at this address")
		return rep, nil
	case !out.OK():
		for _, m := range out.Mismatches {
			c.add("claims", Fail, "MISMATCH: "+m)
		}
	}
	rep.StorageRoot = out.Account.StorageRoot
	c.add("account proof", Pass, fmt.Sprintf("storageRoot %s proven under stateRoot %s", short(rep.StorageRoot), short(b.Header.StateRoot)))

	values := make(map[keccak.Hash]keccak.Hash, len(slots))
	for _, s := range slots {
		v, err := src.StorageAt(ctx, addr, s, pinned)
		if err != nil {
			return nil, err
		}
		values[s] = v
		if !v.IsZero() {
			rep.NonZero++
		}
	}
	rep.Rebuilt = stateproof.StorageRoot(values)
	c.compare("storage root", rep.StorageRoot, rep.Rebuilt,
		fmt.Sprintf("trie rebuilt from %s (%d non-zero) equals the proven storageRoot", plural(len(slots), "listed slot"), rep.NonZero))
	return rep, nil
}

// WriteText renders the report for a terminal.
func (r *StorageReport) WriteText(w io.Writer) {
	fmt.Fprintf(w, "storage of %s at block %d %s\n", r.Address, r.Block, r.BlockHash)
	fmt.Fprintf(w, "  %s listed, %d non-zero\n", plural(r.Slots, "slot"), r.NonZero)
	writeChecks(w, r.Checks)
}
