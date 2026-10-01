// SPDX-License-Identifier: MIT

package store

import (
	"fmt"
	"slices"
	"strings"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/chain"
)

// SnapshotTables lists the tables that make up the indexed state, in diff order. Headers, the
// checkpoint, the outbox and the reorg log are bookkeeping and are deliberately excluded: the
// correctness property is about the data, and those tables legitimately differ between an
// incremental run and a reindex (a reorg log, pruned headers, event sequence numbers).
var SnapshotTables = []string{"logs", "transfers", "vault_events", "share_prices", "balances", "supplies"}

// Row is one table row rendered canonically: Key is the primary key, Value every column.
type Row struct {
	Key   string
	Value string
}

// Snapshot is a backend-independent dump of the indexed state. Two stores hold the same data
// if and only if their snapshots are equal, whatever their backends.
type Snapshot struct {
	Tip    *chain.BlockRef
	Tables map[string][]Row
}

// Difference is one row that differs between two snapshots. An empty side means the row is
// missing from that snapshot.
type Difference struct {
	Table string
	Key   string
	Left  string
	Right string
}

func (d Difference) String() string {
	switch {
	case d.Left == "":
		return fmt.Sprintf("%s[%s]: only on the right: %s", d.Table, d.Key, d.Right)
	case d.Right == "":
		return fmt.Sprintf("%s[%s]: only on the left: %s", d.Table, d.Key, d.Left)
	default:
		return fmt.Sprintf("%s[%s]: left %s, right %s", d.Table, d.Key, d.Left, d.Right)
	}
}

// Rows returns the total number of rows.
func (s *Snapshot) Rows() int {
	n := 0
	for _, rows := range s.Tables {
		n += len(rows)
	}
	return n
}

// Counts returns the number of rows per table.
func (s *Snapshot) Counts() map[string]int {
	out := make(map[string]int, len(s.Tables))
	for _, t := range SnapshotTables {
		out[t] = len(s.Tables[t])
	}
	return out
}

// Diff compares two snapshots row by row. It returns nil when they are identical. The tip is
// compared too: two stores at different tips are reported as a "tip" difference.
func Diff(left, right *Snapshot) []Difference {
	var out []Difference
	lt, rt := tipString(left.Tip), tipString(right.Tip)
	if lt != rt {
		out = append(out, Difference{Table: "checkpoint", Key: "tip", Left: lt, Right: rt})
	}
	for _, table := range SnapshotTables {
		l, r := left.Tables[table], right.Tables[table]
		i, j := 0, 0
		for i < len(l) || j < len(r) {
			switch {
			case j == len(r) || (i < len(l) && l[i].Key < r[j].Key):
				out = append(out, Difference{Table: table, Key: l[i].Key, Left: l[i].Value})
				i++
			case i == len(l) || r[j].Key < l[i].Key:
				out = append(out, Difference{Table: table, Key: r[j].Key, Right: r[j].Value})
				j++
			default:
				if l[i].Value != r[j].Value {
					out = append(out, Difference{Table: table, Key: l[i].Key, Left: l[i].Value, Right: r[j].Value})
				}
				i++
				j++
			}
		}
	}
	return out
}

func tipString(t *chain.BlockRef) string {
	if t == nil {
		return "none"
	}
	return fmt.Sprintf("%d:%s", t.Number, t.Hash.Hex())
}

// SortRows orders rows by key (backends call it so collation never matters).
func SortRows(rows []Row) {
	slices.SortFunc(rows, func(a, b Row) int { return strings.Compare(a.Key, b.Key) })
}
