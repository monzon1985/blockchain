// SPDX-License-Identifier: MIT

// Package bindings holds abigen-generated Go bindings for the contracts. Regenerate after `forge build`:
//
//	cd contracts && forge build && cd ../keeper && go generate ./...
//
// CI regenerates them and fails if the committed files differ (the bytecode is metadata-free, so the output is
// reproducible across platforms).
package bindings

//go:generate go run ../tools/abiextract -artifacts ../../../contracts/out -out combined.json PerpsMarket:bin OrderBook LPVault OracleVerifier:bin AccessManager:bin MockUSD:bin MockERC1271Signer:bin
//go:generate go tool abigen --combined-json combined.json --pkg bindings --out bindings.go
