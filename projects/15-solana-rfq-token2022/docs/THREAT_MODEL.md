# Threat model — Solana RFQ settlement

**This is a technical demonstration. Nothing here has been audited and no code
is deployed with real funds.** Program keypairs in `target/deploy` are throwaway
build artefacts.

## Assets

| Asset | Where |
|---|---|
| Maker inventory | per-maker vault token accounts owned by the vault-authority PDA `["vault_authority", maker]` |
| Accrued protocol fees | per-mint fee vault owned by the config PDA |
| Quote authenticity | the maker's registered ed25519 quote-signer key |
| Replay state | per-maker nonce-bitmap pages + per-quote fill trackers (`QuoteFill`) |
| Tracker rent | lamports of an open `QuoteFill`, owed to the taker that paid them |
| Program code | the upgradeable `rfq` program (and its upgrade authority) |

## Actors and trust assumptions

| Actor | Trust | Can | Cannot |
|---|---|---|---|
| **Program upgrade authority** | **fully trusted** | replace the program: new code can sign as every vault-authority PDA and the config PDA, i.e. move all maker inventory and fees | — Use a multisig with a timelock in production, or freeze the program with `solana program set-upgrade-authority --final`. Initially the same key as the admin (it must sign `initialize_config`); after `propose_admin`/`accept_admin` the two are distinct. |
| **Admin** (`config.admin`) | trusted for parameters, **not** for custody | set the fee (≤ 10%, applied to future fills; takers are bounded by `min_out`), pause settlement, withdraw *only* accrued fees, hand over admin (two-step) | move maker inventory: `withdraw_fees` only accepts token accounts whose authority is the config PDA, and maker vaults belong to a different PDA (`custody.rs` `nobody_else_can_move_maker_inventory`) |
| **Maker owner** | trusted for its own inventory | register, create/fund/withdraw its vaults (withdrawals stay open while paused), rotate the quote signer, cancel quotes, deactivate | touch another maker's vaults or the fee vaults |
| **Quote signer** | may be a hot key; **as powerful as the maker over its inventory until revoked** | sign any quote — any unused nonce, any expiry, any price, e.g. the whole vault for 1 unit of the taker mint | survive the maker's reaction: `set_quote_signer`, `bump_min_nonce`, `cancel_nonces` and `set_maker_active(false)` apply to every unsettled quote they cover. Nothing *proactively* bounds a compromised key (no per-quote or per-period cap) — see Known limitations. |
| **Taker** | untrusted | settle any valid, unexpired, uncancelled quote it is entitled to; choose `fill_amount`, `min_out`, `max_in` and the remaining accounts | forge or replay a quote, substitute programs or accounts |
| **Anyone** | untrusted | close a *dead* quote's tracker (`close_quote_fill`; the refund can only go to the recorded payer); send lamports to any PDA | block a quote by pre-funding its tracker address |
| **Transfer-hook program** | untrusted third party | run arbitrary logic during a hooked transfer, with the accounts the mint's `ExtraAccountMetaList` declares | receive a signer privilege: Token-2022 invokes hooks with de-escalated accounts |

## Attack surface and mitigations

Vulnerability classes follow the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/).

| Vector | Class | Mitigation | Tests |
|---|---|---|---|
| ed25519-introspection forgery ("some ed25519 instruction exists") | SC01:2026 Access Control | `settle` reads the instruction *immediately preceding* it from the address-checked instructions sysvar and requires the ed25519 program id. The vulnerable `settle_naive_v1` exists only in opt-in `naive-v1` builds at separate program ids, and every build rejects execution at any other address. | `exploit.rs` |
| Incomplete signature validation (multiple signatures, offsets into other instructions, wrong key or message) | SC05:2026 Lack of Input Validation | exactly one signature; all three offset instruction-indices `== u16::MAX`; the verified public key must equal the maker's registered signer and the message must equal the domain-separated quote encoding. | `exploit.rs` `v2_rejects_*`; `ed25519.rs` properties |
| Cross-deployment / cross-quote replay of a signature | SC02:2026 Business Logic | the signed message embeds a 16-byte domain tag **and the program id**; an open tracker stores `sha256(message)` and later fills must match it. | `v2_rejects_wrong_message_and_wrong_signer`, `a_tracker_is_bound_to_its_quote_hash` |
| Replay / double spend / cancellation | SC02:2026 Business Logic | 256-nonce bitmap per page (bit set on completion), monotonic `min_nonce` bulk cancel, per-page mask cancel, `Clock` expiry, per-quote partial-fill accounting. | `full_fill_moves_exact_amounts_and_cannot_be_replayed` (fresh blockhash, so only the program can stop it), `bumped_min_nonce_and_cancel_mask_kill_quotes` |
| Unprotected initializer front-run | SC01:2026 Access Control | `initialize_config` is gated on the program's `ProgramData` upgrade authority. | `initialize_config_is_gated_on_the_upgrade_authority` |
| Privileged custody | SC01:2026 Access Control | admin withdrawals: `token::authority = config`; maker withdrawals: `token::authority = vault_authority` of the signing owner; the PDAs are distinct. | `custody.rs` |
| Substituted token / system program — a CPI signed by the vault-authority PDA would let the substitute act with the maker's authority over every vault | SC06:2026 Unchecked External Calls / SC01:2026 | both programs require the token-program slots to be exactly SPL Token or Token-2022 (`Interface<TokenInterface>` / `InvalidProgramId`) and the system slot to be the System program, checked during account deserialisation, before any CPI. | `substituted_token_and_system_programs_are_rejected_before_any_cpi` |
| Fake PDAs, wrong owner, wrong account type, uninitialised accounts | SC05:2026 Lack of Input Validation | every program account is owner-, discriminator- and seed-checked (stored-bump `create_program_address`, exactly as Anchor); byte-valid look-alikes at random or non-canonical addresses fail the seeds check, the same bytes under another owner fail the owner check. | `fake_pdas_and_wrong_owners_are_rejected`, `uninitialised_account_in_the_config_slot_is_rejected` |
| Duplicate mutable accounts / missing `mut` (e.g. `taker_dst = maker_vault_out`: the taker pays and receives nothing) | SC05:2026 Lack of Input Validation | Anchor's duplicate-mutable-account check, reproduced by the Pinocchio program over the same seven accounts; `ConstraintMut` on every mutable account. | `duplicate_mutable_accounts_are_rejected`, `mutable_accounts_must_be_writable` |
| Pre-funded tracker address (anyone can send lamports to the predictable `QuoteFill` PDA; a plain `create_account` would then fail forever) | SC02:2026 Business Logic (denial of service) | both programs follow Anchor's `init_if_needed`: top up to rent-exempt, `allocate`, `assign`. | `a_pre_funded_tracker_address_cannot_block_a_quote` |
| Stranded tracker rent (partial fill, then cancellation, expiry or completion by another taker) | SC02:2026 Business Logic | the tracker records its payer; `settle` closes it only when the payer completes the quote; otherwise the permissionless `close_quote_fill` refunds the payer once the quote is dead. | `completion_by_another_taker_leaves_the_rent_to_its_payer`, `dead_quote_trackers_are_closed_to_their_payer` |
| Arithmetic | SC07:2026 Arithmetic Errors / SC09:2026 Integer Overflow and Underflow | all settlement math is checked `u128`; `overflow-checks = true` in release; pricing rounds **up** for the maker, the protocol fee rounds up, and Token-2022 transfer fees are grossed up so a fee-bearing `taker_mint` never short-changes the maker. | `math.rs`, `transfer_fee.rs` properties |
| Reentrancy through token CPIs / transfer hooks | SC08:2026 Reentrancy | the Solana runtime rejects indirect reentrancy (A → B → A fails with `ReentrancyNotAllowed`; only direct self-recursion is allowed, which neither program performs), so a hook cannot call back into `settle`. In addition, the replay state is persisted before any CPI: the Pinocchio program writes the nonce bit and fill into account data directly, and the Anchor program calls `exit()` on `nonce_page` and `quote_fill` before its CPIs (Anchor would otherwise serialise `Account<T>` only after the handler, leaving on-chain data stale while the CPIs run). | — (runtime property; ordering visible in both handlers) |
| Malicious transfer hook / hook account spoofing | SC06:2026 Unchecked External Calls | extra accounts are resolved from the mint's on-chain `ExtraAccountMetaList` via the canonical helper (Anchor) or a differentially-tested port (Pinocchio); a missing or wrong account fails resolution or Token-2022's own `check_account_infos`; hooks run with de-escalated privileges; lists with more than 12 extra metas are rejected identically by both programs. | `missing_hook_extra_metas_are_rejected`, `transfer_hook_blocks_a_non_allowlisted_taker`, `hooks_with_too_many_extra_metas_are_rejected_by_both`, `hook/tests.rs` |
| Token-2022 confusion (mint/account of the wrong program, malformed state) | SC05:2026 Lack of Input Validation | mints and token accounts are validated by owning token program, mint and authority; account data is parsed exactly like `StateWithExtensions::unpack` (errors included); `transfer_checked` uses the mint's decimals. | `wrong_and_malformed_mints_are_rejected`, `token.rs` `parse_errors_match_token_2022` |
| Slippage / MEV | SC02:2026 Business Logic | the taker supplies `min_out` (maker-mint received) and `max_in` (taker-mint sent); both are enforced against the exact computed amounts. | `slippage_thresholds_are_tight`, `transfer_fee_mint_is_grossed_up_for_the_maker` |
| Program upgrade | SC10:2026 Proxy and Upgradeability | the upgrade authority is a fully trusted role (above); the exploit build cannot share the production address. | `a_build_refuses_to_run_at_any_address_but_its_own` |

## Known limitations

- **Not audited.** Production-grade code, demonstration only.
- **The upgrade authority can do anything.** Production deployments need a
  multisig/timelock or an immutable program.
- **A compromised quote signer is only reactively bounded.** Until the maker
  rotates the key, bumps `min_nonce` or deactivates, the attacker can sign the
  full inventory away at any price. Optional on-chain bounds (per-quote maximum
  size, per-slot notional cap) are future work.
- The in-repo `test-hook` is a **testing** program, not part of the protocol.
- The Pinocchio program is a settle-only re-implementation and is **not
  deployable on its own**: it owner-checks and derives PDAs against its own
  program id and has no instructions to create its config, maker registry or
  nonce pages (the test harnesses seed them). It shares the Anchor program's
  byte-identical account layouts and instruction ABI, not its accounts.
- **Other Token-2022 extensions are enforced by the token program, and the
  quote does not price them.** Pausable or NonTransferable mints, CpiGuard or
  MemoTransfer on the accounts involved, or a frozen DefaultAccountState make
  settlement fail; a PermanentDelegate on `taker_mint` lets its delegate claw
  back what the maker received (and on `maker_mint`, what the taker received).
  Makers should allowlist the mints they quote. Confidential transfers are not
  supported.
- Hooks declaring more than 12 extra accounts are rejected (by both programs).
- PDA checks follow Anchor's stored-bump semantics (`create_program_address`
  with the bump saved in the account). Only the program can create accounts it
  owns, and it always uses canonical bumps, so no non-canonical account can
  exist on chain.
- No oracle: quote prices are whatever the maker signs. Stale-quote risk is
  bounded by `expiry` and the maker's own cancellations.
