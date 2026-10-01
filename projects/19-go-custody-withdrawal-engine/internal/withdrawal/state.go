// SPDX-License-Identifier: MIT

// Package withdrawal implements the withdrawal API service, its persisted state machine, the
// outbox dispatcher that advances it, and the transaction-manager owner that maps chain events
// back onto it.
package withdrawal

// Status is a withdrawal state.
type Status string

// Withdrawal states. The happy path is requested -> approved -> signed -> broadcast -> mined ->
// confirmed. mined -> broadcast happens when the inclusion is reorged out.
const (
	Requested Status = "requested" // accepted by policy, funds reserved, waiting for approvals
	Approved  Status = "approved"  // approvals satisfied, signing intent queued
	Signed    Status = "signed"    // nonce assigned, signed transaction persisted (write-ahead)
	Broadcast Status = "broadcast" // a node accepted a transaction for the nonce
	Mined     Status = "mined"     // a transaction for the nonce is in a canonical block
	Confirmed Status = "confirmed" // the transfer reached the confirmation depth
	Failed    Status = "failed"    // rejected before signing, or reverted on chain; funds returned
	Replaced  Status = "replaced"  // a cancellation took the nonce instead; funds returned
)

// Created is the pseudo-state before a withdrawal exists, used in the transition log.
const Created Status = ""

// edges is the complete transition relation. Once a transaction is signed the only exits go
// through mined: a withdrawal whose transaction might be on the network can never be failed
// or refunded by the engine without the chain having decided.
var edges = map[Status][]Status{
	Created:   {Requested},
	Requested: {Approved, Failed},
	Approved:  {Signed, Failed},
	Signed:    {Broadcast},
	Broadcast: {Mined},
	Mined:     {Broadcast, Confirmed, Failed, Replaced},
}

// CanTransition reports whether from -> to is a legal edge.
func CanTransition(from, to Status) bool {
	for _, t := range edges[from] {
		if t == to {
			return true
		}
	}
	return false
}

// Terminal reports whether s is final.
func (s Status) Terminal() bool { return s == Confirmed || s == Failed || s == Replaced }

// Refundable reports whether a withdrawal ending in s returns its reserved funds.
func (s Status) Refundable() bool { return s == Failed || s == Replaced }

// AllStatuses lists every real state.
var AllStatuses = []Status{Requested, Approved, Signed, Broadcast, Mined, Confirmed, Failed, Replaced}
