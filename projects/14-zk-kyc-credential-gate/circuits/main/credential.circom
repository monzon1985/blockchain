// SPDX-License-Identifier: MIT
pragma circom 2.2.3;

include "../lib/credential_core.circom";

// Production instance:
//   - trusted-issuer Merkle tree depth 8 (up to 256 issuers),
//   - revocation sparse Merkle tree depth 20,
//   - 16-entry public sanctioned-country list.
//
// Public signal order (the on-chain ABI; circom orders public inputs by their
// declaration order in the template, after the outputs):
//   [0]      nullifier            (output)
//   [1]      currentDate
//   [2]      issuerRoot
//   [3]      revocationRoot
//   [4..19]  sanctioned[16]
//   [20]     appScope
//   [21]     recipient
component main {public [currentDate, issuerRoot, revocationRoot, sanctioned, appScope, recipient]} =
    CredentialGate(8, 20, 16);
