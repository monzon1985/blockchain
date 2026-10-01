// SPDX-License-Identifier: MIT

// Package bindings holds abigen v2 bindings for the Solidity fixtures in ../../contracts.
//
// The indexer uses them in two places: internal/decode unpacks logs with the generated
// Unpack*Event methods (no hand-written ABI parsing), and the integration tests deploy the
// fixtures and drive traffic through them.
//
// Regenerate with `forge build` (in contracts/) and then `go generate ./...`. CI does exactly
// that and fails on `git diff --exit-code -- internal/bindings`, so the committed bindings
// always match the contracts. The last step adds the SPDX header to the abigen output (after
// its "Code generated ... DO NOT EDIT." line), so the regenerated files are byte-identical.
// Bytecode is compiled without CBOR metadata (see contracts/foundry.toml), which keeps it
// identical across machines.
package bindings

//go:generate go run ../tools/forgeartifact -artifact ../../contracts/out/FixtureToken.sol/FixtureToken.json -out artifacts
//go:generate go run ../tools/forgeartifact -artifact ../../contracts/out/FixtureVault.sol/FixtureVault.json -out artifacts
//go:generate go tool abigen --v2 --abi artifacts/FixtureToken.abi --bin artifacts/FixtureToken.bin --pkg bindings --type FixtureToken --out fixture_token.go
//go:generate go tool abigen --v2 --abi artifacts/FixtureVault.abi --bin artifacts/FixtureVault.bin --pkg bindings --type FixtureVault --out fixture_vault.go
//go:generate go run ../tools/forgeartifact -spdx MIT fixture_token.go fixture_vault.go
