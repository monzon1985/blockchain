// SPDX-License-Identifier: MIT

// Package bindings contains abigen v2 bindings for the Solidity contracts in ../../contracts.
//
// Regenerate with `forge build` (in contracts/) followed by `go generate ./...`. CI runs both
// and fails on `git diff --exit-code -- internal/bindings`, so committed bindings always match
// the contracts. Contract bytecode is compiled without CBOR metadata (see foundry.toml), which
// keeps it identical across machines.
package bindings

//go:generate go run ../tools/forgeartifact -artifact ../../contracts/out/ForwarderFactory.sol/ForwarderFactory.json -out artifacts
//go:generate go run ../tools/forgeartifact -artifact ../../contracts/out/DepositForwarder.sol/DepositForwarder.json -out artifacts
//go:generate go run ../tools/forgeartifact -artifact ../../contracts/out/TestToken.sol/TestToken.json -out artifacts
//go:generate go tool abigen --v2 --abi artifacts/ForwarderFactory.abi --bin artifacts/ForwarderFactory.bin --pkg bindings --type ForwarderFactory --out forwarder_factory.go
//go:generate go tool abigen --v2 --abi artifacts/DepositForwarder.abi --bin artifacts/DepositForwarder.bin --pkg bindings --type DepositForwarder --out deposit_forwarder.go
//go:generate go tool abigen --v2 --abi artifacts/TestToken.abi --bin artifacts/TestToken.bin --pkg bindings --type TestToken --out test_token.go
//go:generate go run ../tools/forgeartifact -spdx forwarder_factory.go,deposit_forwarder.go,test_token.go
