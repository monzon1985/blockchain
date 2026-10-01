// SPDX-License-Identifier: MIT

package chain

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

// Observer receives one call per RPC request (a batch counts once), for metrics.
type Observer func(method string, elapsed time.Duration, err error)

// RPCOptions configures an RPCSource.
type RPCOptions struct {
	// HTTPClient carries the transport (the tests put the fault injector here). Nil means
	// http.DefaultClient.
	HTTPClient *http.Client
	// CallTimeout bounds every individual request. Zero means 30s.
	CallTimeout time.Duration
	// HeaderBatch is the number of eth_getBlockByNumber calls per JSON-RPC batch. Zero means 100.
	HeaderBatch int
	// Observe, when set, is called after every request.
	Observe Observer
}

// RPCSource is the production Source: a go-ethereum rpc.Client with per-call timeouts,
// batched header fetches and header decoding that trusts the node-reported hash.
type RPCSource struct {
	rpc     *rpc.Client
	eth     *ethclient.Client
	timeout time.Duration
	batch   int
	observe Observer
}

var _ Source = (*RPCSource)(nil)

// Dial connects to an HTTP(S) or WS(S) JSON-RPC endpoint.
func Dial(ctx context.Context, url string, opts RPCOptions) (*RPCSource, error) {
	var clientOpts []rpc.ClientOption
	if opts.HTTPClient != nil {
		clientOpts = append(clientOpts, rpc.WithHTTPClient(opts.HTTPClient))
	}
	c, err := rpc.DialOptions(ctx, url, clientOpts...)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", url, err)
	}
	if opts.CallTimeout <= 0 {
		opts.CallTimeout = 30 * time.Second
	}
	if opts.HeaderBatch <= 0 {
		opts.HeaderBatch = 100
	}
	return &RPCSource{
		rpc:     c,
		eth:     ethclient.NewClient(c),
		timeout: opts.CallTimeout,
		batch:   opts.HeaderBatch,
		observe: opts.Observe,
	}, nil
}

// Close releases the underlying connection.
func (s *RPCSource) Close() { s.rpc.Close() }

// Eth exposes the ethclient view of the same connection (bindings need a ContractBackend).
func (s *RPCSource) Eth() *ethclient.Client { return s.eth }

func (s *RPCSource) call(ctx context.Context, method string, result any, args ...any) error {
	ctx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()
	start := time.Now()
	err := s.rpc.CallContext(ctx, result, method, args...)
	if s.observe != nil {
		s.observe(method, time.Since(start), err)
	}
	return err
}

// ChainID implements Source.
func (s *RPCSource) ChainID(ctx context.Context) (uint64, error) {
	var id hexutil.Big
	if err := s.call(ctx, "eth_chainId", &id); err != nil {
		return 0, err
	}
	b := (*big.Int)(&id)
	if !b.IsUint64() {
		return 0, fmt.Errorf("chain id %s does not fit in uint64", b)
	}
	return b.Uint64(), nil
}

func (s *RPCSource) header(ctx context.Context, method string, arg any) (Header, error) {
	var raw *rpcHeader
	if err := s.call(ctx, method, &raw, arg, false); err != nil {
		return Header{}, err
	}
	if raw == nil {
		return Header{}, ErrNotFound
	}
	return raw.header()
}

// LatestHeader implements Source.
func (s *RPCSource) LatestHeader(ctx context.Context) (Header, error) {
	return s.header(ctx, "eth_getBlockByNumber", "latest")
}

// HeaderByNumber implements Source.
func (s *RPCSource) HeaderByNumber(ctx context.Context, number uint64) (Header, error) {
	return s.header(ctx, "eth_getBlockByNumber", hexutil.Uint64(number))
}

// HeaderByHash implements Source.
func (s *RPCSource) HeaderByHash(ctx context.Context, hash common.Hash) (Header, error) {
	return s.header(ctx, "eth_getBlockByHash", hash)
}

// HeadersByRange implements Source with JSON-RPC batches of at most HeaderBatch requests.
func (s *RPCSource) HeadersByRange(ctx context.Context, from, to uint64) ([]Header, error) {
	if to < from {
		return nil, fmt.Errorf("chain: empty header range %d..%d", from, to)
	}
	out := make([]Header, 0, to-from+1)
	for start := from; start <= to; {
		end := min(to, start+uint64(s.batch)-1)
		raws := make([]*rpcHeader, end-start+1)
		elems := make([]rpc.BatchElem, len(raws))
		for i := range elems {
			elems[i] = rpc.BatchElem{
				Method: "eth_getBlockByNumber",
				Args:   []any{hexutil.Uint64(start + uint64(i)), false},
				Result: &raws[i],
			}
		}
		if err := s.batchCall(ctx, elems); err != nil {
			return nil, err
		}
		for i, elem := range elems {
			if elem.Error != nil {
				if errors.Is(elem.Error, rpc.ErrNoResult) {
					return nil, fmt.Errorf("header %d: %w", start+uint64(i), ErrNotFound)
				}
				return nil, fmt.Errorf("header %d: %w", start+uint64(i), elem.Error)
			}
			if raws[i] == nil {
				return nil, fmt.Errorf("header %d: %w", start+uint64(i), ErrNotFound)
			}
			h, err := raws[i].header()
			if err != nil {
				return nil, err
			}
			if h.Number != start+uint64(i) {
				return nil, fmt.Errorf("chain: asked for header %d, node returned %d", start+uint64(i), h.Number)
			}
			out = append(out, h)
		}
		if end == to {
			break
		}
		start = end + 1
	}
	return out, nil
}

func (s *RPCSource) batchCall(ctx context.Context, elems []rpc.BatchElem) error {
	ctx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()
	start := time.Now()
	err := s.rpc.BatchCallContext(ctx, elems)
	if s.observe != nil {
		s.observe("eth_getBlockByNumber[batch]", time.Since(start), err)
	}
	return err
}

// Logs implements Source.
func (s *RPCSource) Logs(ctx context.Context, q LogQuery) ([]types.Log, error) {
	arg := map[string]any{"address": q.Addresses}
	if q.BlockHash != nil {
		arg["blockHash"] = *q.BlockHash
	} else {
		arg["fromBlock"] = hexutil.Uint64(q.From)
		arg["toBlock"] = hexutil.Uint64(q.To)
	}
	var logs []types.Log
	if err := s.call(ctx, "eth_getLogs", &logs, arg); err != nil {
		return nil, err
	}
	return logs, nil
}

// BlockLogs implements Source with eth_getBlockReceipts. Only the receipts' logs are decoded,
// so chains whose receipts carry extra fields (L2s) work too.
func (s *RPCSource) BlockLogs(ctx context.Context, hash common.Hash) ([]types.Log, error) {
	var receipts []struct {
		Logs []types.Log `json:"logs"`
	}
	if err := s.call(ctx, "eth_getBlockReceipts", &receipts, hash); err != nil {
		return nil, err
	}
	if receipts == nil {
		return nil, fmt.Errorf("receipts of %s: %w", hash.TerminalString(), ErrNotFound)
	}
	var out []types.Log
	for _, r := range receipts {
		out = append(out, r.Logs...)
	}
	return out, nil
}
