// SPDX-License-Identifier: MIT

// Package report implements the EIP-712 PriceReport used by the on-chain OracleVerifier: hashing, signing,
// verification, the JSON wire format served by signers, and the aggregation rules (one report per signer, quorum,
// median, spread) the keeper applies before submitting a batch.
package report

import (
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"slices"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
)

var (
	domainTypeHash = crypto.Keccak256Hash(
		[]byte("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"))
	// ReportTypeHash is keccak256("PriceReport(bytes32 marketId,uint256 price,uint64 timestamp)").
	ReportTypeHash = crypto.Keccak256Hash([]byte("PriceReport(bytes32 marketId,uint256 price,uint64 timestamp)"))
	nameHash       = crypto.Keccak256Hash([]byte("PerpsOracle"))
	versionHash    = crypto.Keccak256Hash([]byte("1"))
)

// Errors returned by Verify, CheckFields and Candidates.
var (
	ErrBadSignature  = errors.New("report: signature does not match signer")
	ErrWrongMarket   = errors.New("report: market id mismatch")
	ErrNotEnough     = errors.New("report: not enough valid reports")
	ErrSpreadTooWide = errors.New("report: no quorum within the spread limit")
	ErrInvalidReport = errors.New("report: malformed report")
)

// Domain is the EIP-712 domain of an OracleVerifier deployment.
type Domain struct {
	ChainID  *big.Int
	Verifier common.Address
}

// Separator returns the EIP-712 domain separator.
func (d Domain) Separator() common.Hash {
	return crypto.Keccak256Hash(
		domainTypeHash.Bytes(),
		nameHash.Bytes(),
		versionHash.Bytes(),
		common.LeftPadBytes(d.ChainID.Bytes(), 32),
		common.LeftPadBytes(d.Verifier.Bytes(), 32),
	)
}

// MarketID is keccak256 of a market name such as "ETH-USD".
func MarketID(name string) [32]byte {
	return crypto.Keccak256Hash([]byte(name))
}

// Digest is the typed-data hash a signer signs: keccak256("\x19\x01" || separator || structHash).
func Digest(d Domain, marketID [32]byte, price *big.Int, timestamp uint64) common.Hash {
	structHash := crypto.Keccak256Hash(
		ReportTypeHash.Bytes(),
		marketID[:],
		common.LeftPadBytes(price.Bytes(), 32),
		common.LeftPadBytes(new(big.Int).SetUint64(timestamp).Bytes(), 32),
	)
	return crypto.Keccak256Hash([]byte{0x19, 0x01}, d.Separator().Bytes(), structHash.Bytes())
}

// Report is one signer's signed observation.
type Report struct {
	Signer    common.Address
	MarketID  [32]byte
	Price     *big.Int
	Timestamp uint64
	Signature []byte // 65 bytes, v in {27, 28}
}

// Sign produces a report for (marketID, price, timestamp) signed by key.
func Sign(key *ecdsa.PrivateKey, d Domain, marketID [32]byte, price *big.Int, timestamp uint64) (Report, error) {
	if price == nil || price.Sign() <= 0 {
		return Report{}, fmt.Errorf("%w: price must be positive", ErrInvalidReport)
	}
	sig, err := crypto.Sign(Digest(d, marketID, price, timestamp).Bytes(), key)
	if err != nil {
		return Report{}, err
	}
	sig[64] += 27 // Ethereum-style recovery id, as expected by OpenZeppelin ECDSA
	return Report{
		Signer:    crypto.PubkeyToAddress(key.PublicKey),
		MarketID:  marketID,
		Price:     new(big.Int).Set(price),
		Timestamp: timestamp,
		Signature: sig,
	}, nil
}

// CheckFields validates what every report must satisfy whatever the signer type: the market and a positive price.
func CheckFields(marketID [32]byte, r Report) error {
	if r.MarketID != marketID {
		return ErrWrongMarket
	}
	if r.Price == nil || r.Price.Sign() <= 0 {
		return ErrInvalidReport
	}
	return nil
}

// Verify checks that the report is for marketID and carries an ECDSA signature by Report.Signer that
// OpenZeppelin's ECDSA library (and hence OracleVerifier) accepts: 65 bytes, v in {27, 28}, 0 < r < n and
// 0 < s <= n/2 (no malleable high-s twin). Contract signers (ERC-1271) are checked by the keeper with an eth_call.
func Verify(d Domain, marketID [32]byte, r Report) error {
	if err := CheckFields(marketID, r); err != nil {
		return err
	}
	if len(r.Signature) != 65 {
		return ErrInvalidReport
	}
	v := r.Signature[64]
	if v != 27 && v != 28 {
		return fmt.Errorf("%w: recovery id %d (want 27 or 28)", ErrBadSignature, v)
	}
	rr := new(big.Int).SetBytes(r.Signature[:32])
	ss := new(big.Int).SetBytes(r.Signature[32:64])
	if !crypto.ValidateSignatureValues(v-27, rr, ss, true) {
		return fmt.Errorf("%w: r or s out of range (high-s signatures are malleable)", ErrBadSignature)
	}
	sig := slices.Clone(r.Signature)
	sig[64] -= 27
	pub, err := crypto.SigToPub(Digest(d, marketID, r.Price, r.Timestamp).Bytes(), sig)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrBadSignature, err)
	}
	if crypto.PubkeyToAddress(*pub) != r.Signer {
		return ErrBadSignature
	}
	return nil
}

type wire struct {
	Signer    common.Address `json:"signer"`
	MarketID  common.Hash    `json:"marketId"`
	Price     string         `json:"price"`
	Timestamp uint64         `json:"timestamp"`
	Signature hexutil.Bytes  `json:"signature"`
}

// MarshalJSON encodes the price as a decimal string (it does not fit in a JSON number).
func (r Report) MarshalJSON() ([]byte, error) {
	if r.Price == nil {
		return nil, ErrInvalidReport
	}
	return json.Marshal(wire{r.Signer, r.MarketID, r.Price.String(), r.Timestamp, r.Signature})
}

// UnmarshalJSON decodes the wire format.
func (r *Report) UnmarshalJSON(data []byte) error {
	var w wire
	if err := json.Unmarshal(data, &w); err != nil {
		return err
	}
	price, ok := new(big.Int).SetString(strings.TrimSpace(w.Price), 10)
	if !ok {
		return fmt.Errorf("%w: price %q", ErrInvalidReport, w.Price)
	}
	*r = Report{Signer: w.Signer, MarketID: w.MarketID, Price: price, Timestamp: w.Timestamp, Signature: w.Signature}
	return nil
}

// Median mirrors OracleVerifier: the middle value, or the floor of the mean of the two middle values.
func Median(prices []*big.Int) *big.Int {
	if len(prices) == 0 {
		return nil
	}
	sorted := slices.Clone(prices)
	slices.SortFunc(sorted, func(a, b *big.Int) int { return a.Cmp(b) })
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return new(big.Int).Set(sorted[mid])
	}
	sum := new(big.Int).Add(sorted[mid-1], sorted[mid])
	return sum.Rsh(sum, 1)
}

// WithinSpread reports whether (max - min) * 10_000 <= maxSpreadBps * median, the on-chain dispersion rule.
func WithinSpread(prices []*big.Int, maxSpreadBps uint16) bool {
	if len(prices) == 0 {
		return false
	}
	lo, hi := prices[0], prices[0]
	for _, p := range prices[1:] {
		if p.Cmp(lo) < 0 {
			lo = p
		}
		if p.Cmp(hi) > 0 {
			hi = p
		}
	}
	lhs := new(big.Int).Mul(new(big.Int).Sub(hi, lo), big.NewInt(10_000))
	rhs := new(big.Int).Mul(big.NewInt(int64(maxSpreadBps)), Median(prices))
	return lhs.Cmp(rhs) <= 0
}

// maxBatch mirrors OracleVerifier.MAX_SIGNERS: no batch can hold more distinct signers.
const maxBatch = 16

// Dedupe keeps one report per signer, the newest (ties: the first seen). A signer that echoes another signer's
// report, or two URLs that serve the same signer, cannot block a batch: the copy only competes with the original.
func Dedupe(reports []Report) []Report {
	index := make(map[common.Address]int, len(reports))
	out := make([]Report, 0, len(reports))
	for _, r := range reports {
		if i, ok := index[r.Signer]; ok {
			if r.Timestamp > out[i].Timestamp {
				out[i] = r
			}
			continue
		}
		index[r.Signer] = len(out)
		out = append(out, r)
	}
	return out
}

// Batch is a set of reports the on-chain verifier should accept, with its median.
type Batch struct {
	Reports []Report
	Median  *big.Int
}

// Candidates lists, best first, every subset of at least quorum distinct-signer reports whose spread is within
// the limit: larger subsets first, then the tightest spread, then a deterministic order. The keeper submits the
// first one the chain accepts, so an outlier, or a report that verifies off-chain but not on-chain, is dropped
// instead of blocking execution. Each batch is sorted by signer, which keeps calldata stable.
func Candidates(reports []Report, quorum int, maxSpreadBps uint16) ([]Batch, error) {
	distinct := Dedupe(reports)
	slices.SortFunc(distinct, func(a, b Report) int { return a.Signer.Cmp(b.Signer) })
	if quorum < 1 || len(distinct) < quorum {
		return nil, fmt.Errorf("%w: have %d, need %d", ErrNotEnough, len(distinct), quorum)
	}
	if len(distinct) > maxBatch {
		return nil, fmt.Errorf("%w: %d signers, at most %d", ErrInvalidReport, len(distinct), maxBatch)
	}
	type scored struct {
		batch  Batch
		spread *big.Int
		mask   int
	}
	var all []scored
	n := len(distinct)
	for mask := 1; mask < 1<<n; mask++ {
		var subset []Report
		for i := range n {
			if mask&(1<<i) != 0 {
				subset = append(subset, distinct[i])
			}
		}
		if len(subset) < quorum {
			continue
		}
		prices := pricesOf(subset)
		if !WithinSpread(prices, maxSpreadBps) {
			continue
		}
		all = append(all, scored{Batch{subset, Median(prices)}, spreadOf(prices), mask})
	}
	if len(all) == 0 {
		return nil, ErrSpreadTooWide
	}
	slices.SortFunc(all, func(a, b scored) int {
		if c := len(b.batch.Reports) - len(a.batch.Reports); c != 0 {
			return c
		}
		if c := a.spread.Cmp(b.spread); c != 0 {
			return c
		}
		return a.mask - b.mask
	})
	out := make([]Batch, len(all))
	for i, sc := range all {
		out[i] = sc.batch
	}
	return out, nil
}

// Aggregate returns the best candidate batch (see Candidates) and its median.
func Aggregate(reports []Report, quorum int, maxSpreadBps uint16) ([]Report, *big.Int, error) {
	batches, err := Candidates(reports, quorum, maxSpreadBps)
	if err != nil {
		return nil, nil, err
	}
	return batches[0].Reports, batches[0].Median, nil
}

// OldestTimestamp returns the minimum timestamp of a batch (what the contract compares with order creation).
func OldestTimestamp(reports []Report) uint64 {
	var oldest uint64
	for i, r := range reports {
		if i == 0 || r.Timestamp < oldest {
			oldest = r.Timestamp
		}
	}
	return oldest
}

func pricesOf(reports []Report) []*big.Int {
	out := make([]*big.Int, len(reports))
	for i, r := range reports {
		out[i] = r.Price
	}
	return out
}

func spreadOf(prices []*big.Int) *big.Int {
	lo, hi := prices[0], prices[0]
	for _, p := range prices[1:] {
		if p.Cmp(lo) < 0 {
			lo = p
		}
		if p.Cmp(hi) > 0 {
			hi = p
		}
	}
	return new(big.Int).Sub(hi, lo)
}
