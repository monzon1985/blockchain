// SPDX-License-Identifier: MIT

package service

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestListenPublishesBoundAddressAndServes(t *testing.T) {
	dir := t.TempDir()
	addrFile := filepath.Join(dir, "addr")
	ln, err := Listen("127.0.0.1:0", addrFile)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(addrFile)
	if err != nil || string(raw) != ln.Addr().String() {
		t.Fatalf("addr file %q, listener %s, err %v", raw, ln.Addr(), err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- Serve(ctx, ln, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte("hi"))
		}), slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	resp, err := http.Get("http://" + string(raw))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "hi" {
		t.Fatalf("body %q", body)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not stop")
	}
}

func TestListenErrors(t *testing.T) {
	if _, err := Listen("256.0.0.1:0", ""); err == nil {
		t.Fatal("invalid address accepted")
	}
	if _, err := Listen("127.0.0.1:0", filepath.Join(t.TempDir(), "missing", "addr")); err == nil {
		t.Fatal("unwritable addr file accepted")
	}
}

func TestLoggerLevels(t *testing.T) {
	if !Logger("debug", "x").Enabled(context.Background(), slog.LevelDebug) {
		t.Fatal("debug level not applied")
	}
	if Logger("nonsense", "x").Enabled(context.Background(), slog.LevelDebug) {
		t.Fatal("unknown level must default to info")
	}
}
