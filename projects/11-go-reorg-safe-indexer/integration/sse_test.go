// SPDX-License-Identifier: MIT

//go:build integration

package integration

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
)

// SSEConsumer follows /v1/stream like a real client: it applies `transfer` events, undoes them
// on `retract`, and after any disconnect (including the indexer being killed and restarted on
// a new port) reconnects with Last-Event-ID.
type SSEConsumer struct {
	url func() string

	mu         sync.Mutex
	last       uint64
	transfers  map[string]model.Transfer
	retracted  int
	reorgs     int
	reconnects int
	err        error

	cancel context.CancelFunc
	done   chan struct{}
}

func transferKey(t model.Transfer) string {
	return fmt.Sprintf("%s/%d", t.Block.Hash.Hex(), t.LogIndex)
}

// StartConsumer starts following the stream from the first retained event.
func StartConsumer(url func() string) *SSEConsumer {
	ctx, cancel := context.WithCancel(context.Background())
	c := &SSEConsumer{url: url, transfers: map[string]model.Transfer{}, cancel: cancel, done: make(chan struct{})}
	go c.loop(ctx)
	return c
}

func (c *SSEConsumer) loop(ctx context.Context) {
	defer close(c.done)
	first := true
	for ctx.Err() == nil {
		err := c.follow(ctx, first)
		first = false
		if ctx.Err() != nil {
			return
		}
		if err != nil && strings.HasPrefix(err.Error(), "protocol:") {
			c.mu.Lock()
			c.err = err
			c.mu.Unlock()
			return
		}
		c.mu.Lock()
		c.reconnects++
		c.mu.Unlock()
		time.Sleep(100 * time.Millisecond)
	}
}

func (c *SSEConsumer) follow(ctx context.Context, first bool) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url()+"/v1/stream", nil)
	if err != nil {
		return err
	}
	c.mu.Lock()
	last := c.last
	c.mu.Unlock()
	if first {
		req.URL.RawQuery = "after=0"
	} else {
		req.Header.Set("Last-Event-ID", strconv.FormatUint(last, 10))
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("protocol: stream answered %d", resp.StatusCode)
	}
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	var id uint64
	var kind, data string
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
			if kind != "" {
				if err := c.apply(id, kind, data); err != nil {
					return err
				}
			}
			id, kind, data = 0, "", ""
		case strings.HasPrefix(line, "id: "):
			id, _ = strconv.ParseUint(strings.TrimPrefix(line, "id: "), 10, 64)
		case strings.HasPrefix(line, "event: "):
			kind = strings.TrimPrefix(line, "event: ")
		case strings.HasPrefix(line, "data: "):
			data = strings.TrimPrefix(line, "data: ")
		}
	}
	return sc.Err()
}

func (c *SSEConsumer) apply(id uint64, kind, data string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if kind == "reset" {
		return fmt.Errorf("protocol: server reset the stream: %s", data)
	}
	if id != c.last+1 {
		return fmt.Errorf("protocol: event %d after %d (gap or duplicate)", id, c.last)
	}
	c.last = id
	switch kind {
	case model.EventTransfer:
		var tr model.Transfer
		if err := json.Unmarshal([]byte(data), &tr); err != nil {
			return fmt.Errorf("protocol: %w", err)
		}
		if _, dup := c.transfers[transferKey(tr)]; dup {
			return fmt.Errorf("protocol: transfer %s delivered twice", transferKey(tr))
		}
		c.transfers[transferKey(tr)] = tr
	case model.EventRetract:
		var r struct {
			Type string          `json:"type"`
			Item json.RawMessage `json:"item"`
		}
		if err := json.Unmarshal([]byte(data), &r); err != nil {
			return fmt.Errorf("protocol: %w", err)
		}
		if r.Type == model.EventTransfer {
			var tr model.Transfer
			if err := json.Unmarshal(r.Item, &tr); err != nil {
				return fmt.Errorf("protocol: %w", err)
			}
			if _, ok := c.transfers[transferKey(tr)]; !ok {
				return fmt.Errorf("protocol: retraction of unknown transfer %s", transferKey(tr))
			}
			delete(c.transfers, transferKey(tr))
			c.retracted++
		}
	case model.EventReorg:
		c.reorgs++
	}
	return nil
}

// WaitFor blocks until the consumer has applied event seq.
func (c *SSEConsumer) WaitFor(t testing.TB, seq uint64, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		last, err := c.last, c.err
		c.mu.Unlock()
		if err != nil {
			t.Fatalf("SSE consumer failed: %v", err)
		}
		if last >= seq {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("SSE consumer stuck at %d, want %d", c.last, seq)
}

// Counts returns how many transfer retractions and reorg events the consumer applied.
func (c *SSEConsumer) Counts() (retracted, reorgs int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.retracted, c.reorgs
}

// Stop ends the consumer (idempotent).
func (c *SSEConsumer) Stop() {
	c.cancel()
	<-c.done
}

// Transfers returns a copy of the consumer's view.
func (c *SSEConsumer) Transfers() map[string]model.Transfer {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]model.Transfer, len(c.transfers))
	for k, v := range c.transfers {
		out[k] = v
	}
	return out
}
