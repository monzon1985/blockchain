// SPDX-License-Identifier: MIT

package api

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/model"
	"github.com/monzon1985/blockchain/projects/11-go-reorg-safe-indexer/internal/store"
)

// streamBatch is the number of outbox events read per query.
const streamBatch = 256

// stream serves GET /v1/stream as Server-Sent Events.
//
// Each outbox event becomes one SSE message whose `id` is its sequence number and whose
// `event` is its kind (transfer, vault_event, share_price, retract, reorg). A client resumes
// with the Last-Event-ID header (browsers send it automatically on reconnect) or `?after=N`;
// without either it starts at the current end of the outbox. `?after=0` replays all retained
// events. If the requested position was already pruned the server answers 410 Gone before
// streaming (and sends a `reset` event if it happens mid-stream): the client must resync from
// the REST endpoints instead of silently missing retractions.
func (s *Server) stream(w http.ResponseWriter, r *http.Request) {
	rc := http.NewResponseController(w)
	var oldest, newest uint64
	if err := s.st.View(r.Context(), func(rd store.Reader) error {
		var err error
		oldest, newest, err = rd.EventBounds()
		return err
	}); err != nil {
		s.fail(w, r, err)
		return
	}
	last := newest
	raw := r.Header.Get("Last-Event-ID")
	if q := r.URL.Query().Get("after"); q != "" {
		raw = q
	}
	if raw != "" {
		n, err := strconv.ParseUint(raw, 10, 63)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_after", fmt.Sprintf("after / Last-Event-ID must be a sequence number, got %q", raw))
			return
		}
		if n > newest {
			writeError(w, http.StatusBadRequest, "invalid_after", fmt.Sprintf("sequence %d is in the future (newest is %d)", n, newest))
			return
		}
		if n+1 < oldest {
			writeJSON(w, http.StatusGone, map[string]any{"error": apiError{Code: "events_pruned",
				Message: fmt.Sprintf("events after %d were pruned (oldest retained is %d); resync from the REST API and resume from %d", n, oldest, newest)},
				"oldest": oldest, "newest": newest})
			return
		}
		last = n
	}

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	if _, err := fmt.Fprintf(w, "retry: 2000\n: stream starts after event %d\n\n", last); err != nil {
		return
	}
	_ = rc.Flush()
	if s.m != nil {
		s.m.SSEClients.Inc()
		defer s.m.SSEClients.Dec()
	}

	poll := time.NewTicker(s.cfg.PollInterval)
	defer poll.Stop()
	heartbeat := time.NewTicker(s.cfg.Heartbeat)
	defer heartbeat.Stop()
	for {
		wake := s.hub.Wait() // taken before reading, so no commit can slip between read and wait
		var events []model.Event
		if err := s.st.View(r.Context(), func(rd store.Reader) error {
			var err error
			events, err = rd.EventsAfter(last, streamBatch)
			return err
		}); err != nil {
			if r.Context().Err() == nil {
				s.log.Warn("stream read failed", "err", err)
			}
			return
		}
		for _, ev := range events {
			if ev.Seq != last+1 {
				// The events after `last` were pruned while this client lagged behind.
				_, _ = fmt.Fprintf(w, "event: reset\ndata: {\"reason\":\"events_pruned\",\"resumeFrom\":%d}\n\n", ev.Seq-1)
				_ = rc.Flush()
				return
			}
			if _, err := fmt.Fprintf(w, "id: %d\nevent: %s\ndata: %s\n\n", ev.Seq, ev.Kind, ev.Payload); err != nil {
				return
			}
			last = ev.Seq
		}
		if len(events) > 0 {
			if err := rc.Flush(); err != nil {
				return
			}
		}
		if len(events) == streamBatch {
			continue
		}
		select {
		case <-r.Context().Done():
			return
		case <-s.streams.Done():
			return
		case <-wake:
		case <-poll.C:
		case <-heartbeat.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			if err := rc.Flush(); err != nil {
				return
			}
		}
	}
}
