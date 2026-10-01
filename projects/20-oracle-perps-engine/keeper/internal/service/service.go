// SPDX-License-Identifier: MIT

// Package service holds the process plumbing shared by the signer and keeper binaries: listeners that can bind to
// port 0 and publish the chosen address, graceful HTTP shutdown and JSON logging.
package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Listen binds addr (use port 0 for a free port) and, if addrFile is set, atomically writes the bound host:port to
// it so that supervisors and tests can discover the port without races.
func Listen(addr, addrFile string) (net.Listener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	if addrFile != "" {
		if err := WriteFileAtomic(addrFile, []byte(ln.Addr().String())); err != nil {
			_ = ln.Close()
			return nil, err
		}
	}
	return ln, nil
}

// WriteFileAtomic writes data to a temporary file next to path and renames it into place.
func WriteFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// Serve runs an HTTP server on ln until ctx is cancelled, then shuts it down gracefully.
func Serve(ctx context.Context, ln net.Listener, h http.Handler, log *slog.Logger) error {
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Serve(ln) }()
	select {
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	log.Info("http server stopped", "addr", ln.Addr().String())
	return nil
}

// Logger returns a JSON slog logger at the given level ("debug", "info", "warn", "error").
func Logger(level string, component string) *slog.Logger {
	var lvl slog.Level
	if err := lvl.UnmarshalText([]byte(level)); err != nil {
		lvl = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: lvl})).With("component", component)
}
