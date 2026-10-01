// SPDX-License-Identifier: MIT

// Package policy decides whether a withdrawal request may proceed: per-account rolling 24 h
// velocity limits, destination allowlists with a cool-down on new entries, per-transaction
// maxima and M-of-N approval thresholds.
//
// Evaluate is a pure function of the request and a State snapshot, which is what makes it
// property-testable; the withdrawal service gathers the State inside the same database
// transaction that records the decision, so concurrent requests cannot race past a limit.
package policy

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// Window is the length of the rolling velocity window.
const Window = 24 * time.Hour

// Reason codes returned in Decision.Reason and exposed by the API.
const (
	ReasonAssetUnsupported   = "asset_unsupported"
	ReasonAmountInvalid      = "amount_invalid"
	ReasonAboveMaxPerTx      = "above_max_per_tx"
	ReasonBadDestination     = "destination_invalid"
	ReasonNotAllowlisted     = "destination_not_allowlisted"
	ReasonInCooldown         = "destination_in_cooldown"
	ReasonVelocityExceeded   = "velocity_limit_exceeded"
	ReasonInsufficientFunds  = "insufficient_balance"
	ReasonApproved           = "approved"
	ReasonApprovalsRequired  = "approvals_required"
	ReasonRejectedByApprover = "rejected_by_approver"
)

// AssetRules are the limits of one asset, in base units.
type AssetRules struct {
	MaxPerTx          *big.Int // hard ceiling per withdrawal
	Velocity24h       *big.Int // ceiling on the sum of an account's withdrawals over Window
	ApprovalThreshold *big.Int // amounts >= this need ApprovalsRequired approvals
}

// Approver is an operator allowed to approve large withdrawals.
type Approver struct {
	ID          string
	TokenSHA256 string // hex SHA-256 of the bearer token; the token itself is never stored
}

// Rules is the complete policy.
type Rules struct {
	Assets            map[string]AssetRules
	AllowlistCooldown time.Duration
	ApprovalsRequired int // M
	Approvers         []Approver
}

// Validate checks internal consistency (M <= N, thresholds set).
func (r Rules) Validate() error {
	if r.AllowlistCooldown < 0 {
		return errors.New("policy: negative allowlist cool-down")
	}
	if r.ApprovalsRequired < 1 {
		return errors.New("policy: approvals_required must be at least 1")
	}
	if r.ApprovalsRequired > len(r.Approvers) {
		return fmt.Errorf("policy: approvals_required (%d) exceeds the number of approvers (%d)", r.ApprovalsRequired, len(r.Approvers))
	}
	seen := map[string]bool{}
	for _, a := range r.Approvers {
		if a.ID == "" {
			return fmt.Errorf("policy: approver %q needs an id", a.ID)
		}
		if _, ok := digest(a.TokenSHA256); !ok {
			return fmt.Errorf("policy: approver %q token_sha256 must be 64 hex digits", a.ID)
		}
		if seen[a.ID] {
			return fmt.Errorf("policy: duplicate approver %q", a.ID)
		}
		seen[a.ID] = true
	}
	if len(r.Assets) == 0 {
		return errors.New("policy: no assets configured")
	}
	for sym, a := range r.Assets {
		if a.MaxPerTx == nil || a.Velocity24h == nil || a.ApprovalThreshold == nil {
			return fmt.Errorf("policy: asset %s needs max_per_tx, velocity_24h and approval_threshold", sym)
		}
		if a.MaxPerTx.Sign() <= 0 || a.Velocity24h.Sign() <= 0 || a.ApprovalThreshold.Sign() <= 0 {
			return fmt.Errorf("policy: asset %s limits must be positive", sym)
		}
	}
	return nil
}

// Request is a withdrawal request as seen by the policy.
type Request struct {
	AccountID   string
	Asset       string
	Amount      *big.Int
	Destination common.Address
}

// AllowlistEntry is a destination registered by an account.
type AllowlistEntry struct {
	Address  common.Address
	AddedAt  time.Time
	ActiveAt time.Time
}

// State is everything Evaluate needs besides the request.
type State struct {
	Now       time.Time
	Available *big.Int        // customer balance available to withdraw
	UsedIn24h *big.Int        // sum of the account's non-failed withdrawals in the window
	Allowlist *AllowlistEntry // nil if the destination is not allowlisted
	Forbidden []common.Address
}

// Decision is the outcome of Evaluate.
type Decision struct {
	Allowed           bool
	Reason            string
	ApprovalsRequired int // 0 when the amount is below the approval threshold
}

// Evaluate applies the rules in a fixed order; the first failing check wins.
func (r Rules) Evaluate(req Request, st State) Decision {
	rules, ok := r.Assets[req.Asset]
	if !ok {
		return Decision{Reason: ReasonAssetUnsupported}
	}
	if req.Amount == nil || req.Amount.Sign() <= 0 {
		return Decision{Reason: ReasonAmountInvalid}
	}
	if req.Amount.Cmp(rules.MaxPerTx) > 0 {
		return Decision{Reason: ReasonAboveMaxPerTx}
	}
	if req.Destination == (common.Address{}) {
		return Decision{Reason: ReasonBadDestination}
	}
	for _, f := range st.Forbidden {
		if req.Destination == f {
			return Decision{Reason: ReasonBadDestination}
		}
	}
	if st.Allowlist == nil {
		return Decision{Reason: ReasonNotAllowlisted}
	}
	if st.Now.Before(st.Allowlist.ActiveAt) {
		return Decision{Reason: ReasonInCooldown}
	}
	used := new(big.Int)
	if st.UsedIn24h != nil {
		used.Set(st.UsedIn24h)
	}
	if used.Add(used, req.Amount).Cmp(rules.Velocity24h) > 0 {
		return Decision{Reason: ReasonVelocityExceeded}
	}
	if st.Available == nil || st.Available.Cmp(req.Amount) < 0 {
		return Decision{Reason: ReasonInsufficientFunds}
	}
	d := Decision{Allowed: true, Reason: ReasonApproved}
	if req.Amount.Cmp(rules.ApprovalThreshold) >= 0 {
		d.ApprovalsRequired = r.ApprovalsRequired
		d.Reason = ReasonApprovalsRequired
	}
	return d
}

// ActiveAt returns when an allowlist entry added at t becomes usable.
func (r Rules) ActiveAt(t time.Time) time.Time { return t.Add(r.AllowlistCooldown) }

// HashToken returns the hex SHA-256 of a bearer token, the form stored in configuration.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Principal is an authenticated caller.
type Principal struct {
	ID          string
	TokenSHA256 string
}

// digest decodes a hex SHA-256 (either case).
func digest(h string) ([]byte, bool) {
	b, err := hex.DecodeString(h)
	if err != nil || len(b) != sha256.Size {
		return nil, false
	}
	return b, true
}

// Authenticate finds the principal whose token hash matches token. Hashes are compared as
// decoded bytes, so the hex case does not matter, and every candidate is compared in constant
// time so the response time does not reveal which prefix matched. A principal whose hash is
// not 64 hex digits never matches (configuration loading rejects it anyway).
func Authenticate(token string, principals []Principal) (string, bool) {
	if token == "" {
		return "", false
	}
	sum := sha256.Sum256([]byte(token))
	found := ""
	for _, p := range principals {
		want, ok := digest(p.TokenSHA256)
		if ok && subtle.ConstantTimeCompare(sum[:], want) == 1 {
			found = p.ID
		}
	}
	return found, found != ""
}

// ApproverPrincipals converts approvers for Authenticate.
func (r Rules) ApproverPrincipals() []Principal {
	out := make([]Principal, len(r.Approvers))
	for i, a := range r.Approvers {
		out[i] = Principal{ID: a.ID, TokenSHA256: a.TokenSHA256}
	}
	return out
}
