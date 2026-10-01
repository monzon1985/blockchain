// SPDX-License-Identifier: MIT

package app

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"time"
)

// ShutdownTimeout bounds how long in-flight HTTP requests may take to finish on shutdown.
const ShutdownTimeout = 15 * time.Second

// Serve runs the HTTP API and every engine loop until ctx is cancelled (SIGINT/SIGTERM in the
// binary), then shuts down gracefully: the listener stops accepting, in-flight requests finish,
// every loop returns after its current iteration, and the audit log is flushed one last time.
// When addrFile is set, the bound address is written to it (useful with a ":0" listen address).
func (a *App) Serve(ctx context.Context, handler http.Handler, listen, addrFile string) error {
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	addr := ln.Addr().String()
	if addrFile != "" {
		tmp := addrFile + ".tmp"
		if err := os.WriteFile(tmp, []byte(addr), 0o600); err != nil {
			ln.Close()
			return err
		}
		if err := os.Rename(tmp, addrFile); err != nil {
			ln.Close()
			return err
		}
	}
	a.Log.Info("custodyd listening", "addr", addr, "hot_wallet", a.HotWallet.Hex(), "chain_id", a.Cfg.Chain.ChainID,
		"confirmations", a.Cfg.Chain.Confirmations)

	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second}
	srvErr := make(chan error, 1)
	go func() { srvErr <- srv.Serve(ln) }()
	loopsCtx, stopLoops := context.WithCancel(ctx)
	defer stopLoops()
	loopsDone := make(chan struct{})
	go func() {
		a.Run(loopsCtx)
		close(loopsDone)
	}()

	var serveErr error
	select {
	case <-ctx.Done():
		a.Log.Info("shutdown requested")
	case err := <-srvErr:
		if !errors.Is(err, http.ErrServerClosed) {
			serveErr = err
			a.Log.Error("http server failed", "err", err)
		}
	}
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		a.Log.Error("http shutdown", "err", err)
	}
	stopLoops()
	<-loopsDone
	a.Log.Info("custodyd stopped")
	return serveErr
}
