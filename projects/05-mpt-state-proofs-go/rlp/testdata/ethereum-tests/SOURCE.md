# Provenance of the vendored RLP vectors

These files are copied unmodified from [ethereum/tests](https://github.com/ethereum/tests)
(MIT, see [LICENSE](LICENSE)).

- Upstream tag: [`v17.2`](https://github.com/ethereum/tests/tree/v17.2), commit
  `c67e485ff8b5be9abc8ad15345ec21aa22e290d9` (2025-06-04).
- Vendored on 2026-09-29. On 2026-10-01 every file's git blob hash was compared with the
  blob GitHub reports for the same path at `v17.2`, and all matched.

| Vendored file | Upstream path | Git blob SHA-1 |
|---|---|---|
| `LICENSE` | `LICENSE` | `8433e6f87c909d20b61eb8e3c3c217e12cb7d71b` |
| `rlptest.json` | `RLPTests/rlptest.json` | `cb0d9fd399f140d6bab9d411033f8be131df8df0` |
| `invalidRLPTest.json` | `RLPTests/invalidRLPTest.json` | `21d0b2d14332292c9a9bd5becb73ad6a5bacba62` |

Check a file with `git hash-object <file>`, or run `go test ./internal/archtest`, which
recomputes every blob hash and fails if a file is modified, missing or not listed here.

To refresh: download the files listed above from a newer tag, update the tag, commit and
hashes in this table, and run `go test ./rlp ./internal/archtest`.
