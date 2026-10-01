// SPDX-License-Identifier: MIT

// Command signer runs one member of the oracle signer set. It serves EIP-712 signed reports of a deterministic
// price path (a fixture written by the Python generator) on GET /report, plus /healthz and /metrics. Keepers ask for
// GET /report?notAfter=<latest block timestamp>; the signer then dates the report at min(now, notAfter), within
// -max-backdate. Every signer of a set must use the same -start, or they quote different steps of the path.
//
//	signer -keystore s1.json -password-file pw -path gbm_calm.json -chain-id 31337 -verifier 0x... \
//	       -start 1767225600 -listen 127.0.0.1:0 -addr-file s1.addr
package main

import (
	"context"
	"flag"
	"fmt"
	"math/big"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/keys"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/pricepath"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/report"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/service"
	"github.com/monzon1985/blockchain/projects/20-oracle-perps-engine/keeper/internal/signer"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "signer:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		keystoreFile = flag.String("keystore", "", "encrypted keystore (Web3 Secret Storage) of the signing key")
		passwordFile = flag.String("password-file", "", "file holding the keystore password")
		pathFile     = flag.String("path", "", "price-path fixture (JSON)")
		market       = flag.String("market", "ETH-USD", "market name; its keccak256 is the signed marketId")
		chainID      = flag.Int64("chain-id", 31337, "chain id of the EIP-712 domain")
		verifier     = flag.String("verifier", "", "OracleVerifier address (EIP-712 verifyingContract)")
		listen       = flag.String("listen", "127.0.0.1:0", "listen address (port 0 picks a free port)")
		addrFile     = flag.String("addr-file", "", "write the bound host:port here once listening")
		startUnix    = flag.Int64("start", 0, "unix time of the path's first step (0 = now; give every signer the same value)")
		step         = flag.Duration("step", 0, "override the path step (e.g. 1s to replay fast)")
		noiseBps     = flag.Int64("noise-bps", 0, "fixed quote offset in basis points")
		account      = flag.String("account", "", "ERC-1271 wallet to sign for (default: the key's own address)")
		maxBackdate  = flag.Duration("max-backdate", signer.DefaultMaxBackdate, "furthest notAfter in the past honoured")
		logLevel     = flag.String("log-level", "info", "debug, info, warn or error")
	)
	flag.Parse()
	if *keystoreFile == "" || *passwordFile == "" || *pathFile == "" || !common.IsHexAddress(*verifier) {
		flag.Usage()
		return fmt.Errorf("-keystore, -password-file, -path and a valid -verifier are required")
	}
	if *account != "" && !common.IsHexAddress(*account) {
		return fmt.Errorf("-account %q is not an address", *account)
	}
	log := service.Logger(*logLevel, "signer")

	key, err := keys.Load(*keystoreFile, *passwordFile)
	if err != nil {
		return err
	}
	path, err := pricepath.Load(*pathFile)
	if err != nil {
		return err
	}
	if *step > 0 {
		path = path.WithStep(*step)
	}
	start := time.Now()
	if *startUnix != 0 {
		start = time.Unix(*startUnix, 0)
	}
	srv, err := signer.New(signer.Config{
		Key:         key,
		Domain:      report.Domain{ChainID: big.NewInt(*chainID), Verifier: common.HexToAddress(*verifier)},
		MarketID:    report.MarketID(*market),
		Path:        path,
		Start:       start,
		NoiseBps:    *noiseBps,
		Account:     common.HexToAddress(*account),
		MaxBackdate: *maxBackdate,
		Logger:      log,
	})
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ln, err := service.Listen(*listen, *addrFile)
	if err != nil {
		return err
	}
	log.Info("signer listening", "addr", ln.Addr().String(), "signer", srv.Address(), "path", path.Name,
		"steps", len(path.Prices), "step", path.Step.String())
	return service.Serve(ctx, ln, srv.Handler(), log)
}
