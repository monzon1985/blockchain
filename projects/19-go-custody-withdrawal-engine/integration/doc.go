// SPDX-License-Identifier: MIT

// Package integration runs the engine against a real node (anvil) and crash-tests the custodyd
// binary. Every test is behind the "integration" build tag because it needs Foundry's anvil on
// PATH:
//
//	CGO_ENABLED=0 go test -count=1 -tags integration -timeout 20m ./integration/...
package integration
