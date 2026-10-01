# Provenance of the vendored trie vectors

These files are copied unmodified from [ethereum/tests](https://github.com/ethereum/tests)
(MIT, see [LICENSE](LICENSE)).

- Upstream tag: [`v17.2`](https://github.com/ethereum/tests/tree/v17.2), commit
  `c67e485ff8b5be9abc8ad15345ec21aa22e290d9` (2025-06-04).
- Vendored on 2026-09-29. On 2026-10-01 every file's git blob hash was compared with the
  blob GitHub reports for the same path at `v17.2`, and all matched.

| Vendored file | Upstream path | Git blob SHA-1 |
|---|---|---|
| `LICENSE` | `LICENSE` | `8433e6f87c909d20b61eb8e3c3c217e12cb7d71b` |
| `trietest.json` | `TrieTests/trietest.json` | `91651405bb7f11aba529e455c344d2787efe97f5` |
| `trietest_secureTrie.json` | `TrieTests/trietest_secureTrie.json` | `ac4ecd2dd1c3cba1d868025423d6bccf6ffd6ef8` |
| `trieanyorder.json` | `TrieTests/trieanyorder.json` | `58fcc4f34a15f3e2854c45f366234199289601ae` |
| `trieanyorder_secureTrie.json` | `TrieTests/trieanyorder_secureTrie.json` | `a1d9a69611724c5cdd4e6f8a68848130cf1ad70c` |
| `hex_encoded_securetrie_test.json` | `TrieTests/hex_encoded_securetrie_test.json` | `473f96419a49ca6493a1460f93f46b254fb095a7` |

Check a file with `git hash-object <file>`, or run `go test ./internal/archtest`, which
recomputes every blob hash and fails if a file is modified, missing or not listed here.

To refresh: download the files listed above from a newer tag, update the tag, commit and
hashes in this table, and run `go test ./trie ./stateproof ./internal/archtest`.
