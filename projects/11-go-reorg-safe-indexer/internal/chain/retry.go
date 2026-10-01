// SPDX-License-Identifier: MIT

package chain

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/rpc"
)

// RetryPolicy bounds retries of transient RPC failures.
type RetryPolicy struct {
	// Attempts is the total number of calls, first one included (default 5).
	Attempts int
	// Backoff is the first delay; it doubles up to MaxBackoff (defaults 50ms and 2s).
	Backoff, MaxBackoff time.Duration
	// Stop, when it returns true for an error, ends retrying immediately (the fetcher stops on
	// "too large" errors it handles by splitting).
	Stop func(error) bool
	// OnRetry is called before each retry.
	OnRetry func(err error)
}

// permanentRPCCodes are JSON-RPC error codes that the same request will always get again:
// malformed JSON, an invalid request, an unknown method, invalid parameters (JSON-RPC 2.0) and
// a reverted eth_call (3, as geth and anvil report it).
var permanentRPCCodes = map[int]bool{-32700: true, -32600: true, -32601: true, -32602: true, 3: true}

// Retryable reports whether an error is worth retrying as is: timeouts, rate limits, HTTP
// failures, broken or truncated responses, and JSON-RPC errors other than "unknown block" and
// the permanent codes above.
func Retryable(err error) bool {
	switch Kind(err) {
	case "timeout", "rate_limited", "http", "transport":
		return true
	case "rpc":
		var rpcErr rpc.Error
		if errors.As(err, &rpcErr) && permanentRPCCodes[rpcErr.ErrorCode()] {
			return false
		}
		return !IsUnknownBlock(err)
	default:
		return false
	}
}

// unknownBlockHints are lower-cased fragments of the errors nodes return for a block they do
// not know: geth's "unknown block" (eth_getLogs by blockHash), and the "header not found" /
// "block not found" of other clients and providers. A bare "not found" is deliberately not
// one: JSON-RPC -32601 "Method not found" would otherwise turn a missing method into an
// orphaned block, and the engine would re-fetch the same range forever.
var unknownBlockHints = []string{"unknown block", "header not found", "block not found"}

// IsUnknownBlock reports whether err says the node does not know a block (never transient for
// a specific hash: the block was orphaned and forgotten). Permanent JSON-RPC errors (an unknown
// method, invalid parameters) never are, whatever their message.
func IsUnknownBlock(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, ErrNotFound) {
		return true
	}
	var rpcErr rpc.Error
	if errors.As(err, &rpcErr) && permanentRPCCodes[rpcErr.ErrorCode()] {
		return false
	}
	msg := strings.ToLower(err.Error())
	for _, hint := range unknownBlockHints {
		if strings.Contains(msg, hint) {
			return true
		}
	}
	return false
}

// Retry calls fn until it succeeds, returns a non-retryable error, or exhausts the policy.
func Retry(ctx context.Context, p RetryPolicy, fn func() error) error {
	if p.Attempts <= 0 {
		p.Attempts = 5
	}
	if p.Backoff <= 0 {
		p.Backoff = 50 * time.Millisecond
	}
	if p.MaxBackoff <= 0 {
		p.MaxBackoff = 2 * time.Second
	}
	delay := p.Backoff
	for attempt := 1; ; attempt++ {
		err := fn()
		if err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if (p.Stop != nil && p.Stop(err)) || !Retryable(err) || attempt >= p.Attempts {
			return err
		}
		if p.OnRetry != nil {
			p.OnRetry(err)
		}
		t := time.NewTimer(delay)
		select {
		case <-t.C:
		case <-ctx.Done():
			t.Stop()
			return ctx.Err()
		}
		delay = min(delay*2, p.MaxBackoff)
	}
}
