// SPDX-License-Identifier: MIT

package chain

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strings"

	"github.com/ethereum/go-ethereum/rpc"
)

// limitExceededCode is the EIP-1474 JSON-RPC code for "limit exceeded".
const limitExceededCode = -32005

// rangeTooLargeHints are lower-cased fragments of the errors real providers return when an
// eth_getLogs query covers too many blocks or matches too many logs. There is no standard
// error, so the list is empirical: geth/Erigon/Infura ("query returned more than 10000
// results"), Alchemy ("Log response size exceeded"), and the block-range variants of
// QuickNode, Ankr, Nethermind and Besu.
var rangeTooLargeHints = []string{
	"query returned more than",
	"response size exceeded",
	"response size should not greater than",
	"too many results",
	"too many logs",
	"logs matched by query exceeds limit",
	"exceeds max results",
	"limit exceeded",
	"block range",
	"range too large",
	"range is too large",
	"query timeout exceeded",
}

// rateLimitHints are lower-cased fragments of the errors providers return when they throttle
// the caller rather than the query. Several of them reuse -32005 ("limit exceeded") for it
// (Infura: "daily request count exceeded, request rate limited"; Alchemy: "exceeded its compute
// units per second capacity"), so these are checked before the code: splitting a range in
// answer to a rate limit would multiply the requests instead of slowing down.
var rateLimitHints = []string{
	"rate limit",
	"rate-limit",
	"ratelimit",
	"request rate",
	"rate exceeded",
	"request count",
	"too many requests",
	"capacity",
	"throughput",
}

// IsRateLimited reports whether err is the provider throttling the caller (HTTP 429, or one of
// the messages above). Such errors are retried with backoff and never cause a range split.
func IsRateLimited(err error) bool {
	if err == nil {
		return false
	}
	var httpErr rpc.HTTPError
	if errors.As(err, &httpErr) && httpErr.StatusCode == http.StatusTooManyRequests {
		return true
	}
	msg := strings.ToLower(err.Error())
	for _, hint := range rateLimitHints {
		if strings.Contains(msg, hint) {
			return true
		}
	}
	return false
}

// IsRangeTooLarge reports whether err is a provider telling the caller to query fewer blocks
// or fewer logs. A rate limit is never one, even when it carries -32005.
func IsRangeTooLarge(err error) bool {
	if err == nil || IsRateLimited(err) {
		return false
	}
	var rpcErr rpc.Error
	if errors.As(err, &rpcErr) && rpcErr.ErrorCode() == limitExceededCode {
		return true
	}
	msg := strings.ToLower(err.Error())
	for _, hint := range rangeTooLargeHints {
		if strings.Contains(msg, hint) {
			return true
		}
	}
	return false
}

// IsTimeout reports whether err is a request timing out (as opposed to the caller cancelling):
// a context deadline or a network timeout.
func IsTimeout(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

// Kind classifies an RPC error for metrics and retry decisions.
func Kind(err error) string {
	var httpErr rpc.HTTPError
	var rpcErr rpc.Error
	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, ErrNotFound):
		return "not_found"
	case IsTimeout(err):
		return "timeout"
	case IsRateLimited(err):
		return "rate_limited"
	case IsRangeTooLarge(err):
		return "range_too_large"
	case errors.As(err, &httpErr):
		return "http"
	case errors.As(err, &rpcErr):
		return "rpc"
	default:
		// Malformed or truncated JSON, connection resets, and similar transport failures.
		return "transport"
	}
}
