// SPDX-License-Identifier: MIT

// Command keeper runs the exchange: it polls the signer set for reports and settles LP requests, orders,
// liquidations and auto-deleveraging on the market. Prometheus metrics are served on -metrics-listen.
//
//	keeper -rpc http://127.0.0.1:8545 -market 0x... -signers http://127.0.0.1:1,http://127.0.0.1:2 \
//	       -keystore keeper.json -password-file pw -metrics-listen 127.0.0.1:0 -metrics-addr-file keeper.addr
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/keeper"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/keys"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/service"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "keeper:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		rpcURL        = flag.String("rpc", "", "JSON-RPC endpoint")
		market        = flag.String("market", "", "PerpsMarket address")
		signerList    = flag.String("signers", "", "comma-separated signer base URLs")
		keystoreFile  = flag.String("keystore", "", "encrypted keystore of the keeper account")
		passwordFile  = flag.String("password-file", "", "file holding the keystore password")
		poll          = flag.Duration("poll", time.Second, "interval between keeper ticks")
		fromBlock     = flag.Uint64("from-block", 0, "first block to scan for positions")
		margin        = flag.Duration("freshness-margin", 15*time.Second, "how long a report must stay fresh after the latest block")
		receiptWait   = flag.Duration("receipt-timeout", 30*time.Second, "wait for a transaction before replacing it with higher fees")
		replacements  = flag.Int("max-replacements", 3, "fee-bumped replacements of a stuck transaction per tick")
		metricsListen = flag.String("metrics-listen", "127.0.0.1:0", "metrics listen address (port 0 = free port)")
		metricsFile   = flag.String("metrics-addr-file", "", "write the metrics host:port here once listening")
		logLevel      = flag.String("log-level", "info", "debug, info, warn or error")
	)
	flag.Parse()
	if *rpcURL == "" || !common.IsHexAddress(*market) || *signerList == "" || *keystoreFile == "" || *passwordFile == "" {
		flag.Usage()
		return errors.New("-rpc, -market, -signers, -keystore and -password-file are required")
	}
	log := service.Logger(*logLevel, "keeper")
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	key, err := keys.Load(*keystoreFile, *passwordFile)
	if err != nil {
		return err
	}
	client, err := ethclient.DialContext(ctx, *rpcURL)
	if err != nil {
		return fmt.Errorf("dial %s: %w", *rpcURL, err)
	}
	defer client.Close()
	chainID, err := client.ChainID(ctx)
	if err != nil {
		return fmt.Errorf("chain id: %w", err)
	}

	metrics := keeper.NewMetrics()
	engine, err := keeper.New(ctx, keeper.Config{
		Backend:         client,
		ChainID:         chainID,
		Market:          common.HexToAddress(*market),
		SignerURLs:      strings.Split(*signerList, ","),
		Key:             key,
		Poll:            *poll,
		FromBlock:       *fromBlock,
		FreshnessMargin: *margin,
		ReceiptTimeout:  *receiptWait,
		MaxReplacements: *replacements,
		Logger:          log,
		Metrics:         metrics,
	})
	if err != nil {
		return err
	}

	ln, err := service.Listen(*metricsListen, *metricsFile)
	if err != nil {
		return err
	}
	serveErr := make(chan error, 1)
	go func() {
		serveErr <- service.Serve(ctx, ln, promhttp.HandlerFor(metrics.Registry, promhttp.HandlerOpts{}), log)
	}()
	log.Info("keeper started", "address", engine.Address(), "market", *market, "chainId", chainID,
		"metrics", ln.Addr().String())

	runErr := engine.Run(ctx)
	stop()
	return errors.Join(runErr, <-serveErr)
}
