# Threat model: FROST threshold custody

This document covers the Rust signer stack (`frost-keccak`, `custody-protocol`,
`custody-net`) and the on-chain vault (`SchnorrVault.sol`, `SchnorrSecp256k1.sol`).
It is a technical demonstration: nothing here has been audited or deployed with real funds.

## 1. System in one paragraph

`n` participants hold Shamir shares of a secp256k1 key produced by a Pedersen DKG.
Any `t` of them can produce a Schnorr signature under the group key with two-round
FROST (RFC 9591 structure, custom challenge `keccak256(address(R) ‖ parity(P) ‖ P.x ‖ m)`).
A coordinator relays messages and aggregates, but is never trusted with secrets.
The vault holds ETH/ERC-20 and executes EIP-712 intents (withdrawals, key rotation,
limit changes, guardian replacement) that verify under the group key with one
`ecrecover`. Anyone may relay a signed intent.

## 2. Assets

| Asset | Where | Impact if lost / stolen |
|---|---|---|
| Vault funds | `SchnorrVault` | Direct loss. Bounded per UTC day by the token's limit. |
| Key shares `s_i` | Participant memory (`KeyMaterial`); never written to disk by this code | `t` shares = full signing power. Fewer than `t` reveal nothing about the key. |
| DKG polynomials and sent shares | Participant memory, one keygen session | `n-1` evaluations of every dealer's polynomial give the group secret when `t < n`. |
| Signing nonces `(d_i, e_i)` | Participant memory, one session | Reusing a nonce pair for two different messages leaks `s_i`. |
| Transport keys (ed25519 + X25519) | Key files (demo) | Impersonation of a party on the network; reading sealed DKG shares sent to it. |
| Operator approval key (optional) | Operator, outside the signers | Together with the coordinator: choosing what the group signs (within policy and on-chain limits). |
| Roster | Static file | Root of trust for all transport authentication. |
| Session journal | Participant (memory or append-only file) | Losing it only removes a defence-in-depth layer (see T5). |
| Group key `(P.x, parity)` | Vault storage | Replacing it = taking over the vault; requires current-group authorisation. |

## 3. Actors and trust assumptions

| Actor | Trusted for | Not trusted for |
|---|---|---|
| Participant (each) | Nothing individually | Anything: may be Byzantine |
| Threshold `t` | Safety holds while at most `t-1` participants are compromised | |
| Coordinator | Liveness (it can always stall a session). **Authorisation**: unless the signers' policies name an approver key, it chooses which in-policy actions the group signs | Key safety: it cannot read shares, make a dealer reveal one without the complainant's signed complaint, rotate the vault to a key the signers do not hold, lower the threshold through a rotation, forge messages, or frame an honest participant |
| Operator approver (optional) | Signing off each action (ed25519 over the EIP-712 digest) | Nothing else: it holds no share and never sees one |
| Relayer (any EOA) | Nothing | Can only submit intents the group signed |
| Guardian (`Ownable2Step` owner) | Pausing withdrawals, cancelling queued limit increases | Moving funds, rotating keys, changing limits, blocking its own (time-locked) replacement |
| Network | Nothing | May drop, delay, reorder, corrupt, replay or inject messages |

Cryptographic assumptions: discrete log on secp256k1; Keccak-256 and SHA-256 modelled
as random oracles; ed25519 (strict verification), X25519 and ChaCha20-Poly1305 secure;
participants have a working CSPRNG (FROST additionally hedges nonces with the share,
RFC 9591 §4.1). The roster (and the approver key, if used) is distributed authentically
out of band.

## 4. Threats, mitigations and the tests that enforce them

### T1. Share compromise below the threshold
*Attack:* steal up to `t-1` shares (host compromise, memory dump).
*Mitigations:* Shamir secrecy: `t-1` shares interpolate to an unrelated key and cannot
sign. Proactive refresh (`refresh_dkg_*`) re-randomises every share while keeping the group
key, so shares stolen before a refresh are useless afterwards; refresh can also evict
a participant. Lost shares are recovered by `t` helpers (RTS) without re-keying.
*Tests:* `properties::fewer_than_t_signers_cannot_sign` (t-1 real shares with every
parameter check bypassed fail frost-core and the EVM model),
`properties::fewer_than_t_shares_cannot_recover_the_key`,
`signing::stolen_pre_refresh_share_is_useless_after_refresh`,
`properties::refresh_preserves_the_group_key`, `dkg::refresh_can_evict_a_participant`,
`properties::repair_restores_the_lost_share`.
*Limitation:* shares live only in process memory and are not persisted at all; sealed
storage (HSM, enclave, OS key store) is out of scope for this demo.

### T2. Below-threshold collusion and share harvesting
*Attack:* `t-1` participants pool their shares, or try to learn another participant's
share; a coordinator collects evaluations of the dealers' polynomials.
*Mitigations:* as T1. DKG shares travel inside sealed boxes to their recipient only, so
colluders learn nothing beyond their own shares; repair deltas and sigmas are sealed the
same way. A dealer reveals the plaintext share it sent to `j` only when the reveal request
carries `j`'s own signed `KeygenResult::Complaints` for this session naming the dealer as
undecryptable; such a reveal discloses nothing `j` was not already sent, and the session is
then poisoned: the dealer refuses any commit for it, so a revealed evaluation never ends up
in a live key.
*Tests:* `properties::sealed_boxes_are_bound_to_key_context_and_content`,
`adversarial::unsolicited_reveal_requests_are_refused` (a coordinator asking every dealer
for every share, with every kind of evidence it can forge, gets nothing),
`adversarial::a_session_with_a_reveal_never_commits`.
*Limitation:* Pedersen DKG lets a rushing adversary bias the distribution of the group key
(Gennaro et al., 1999). This does not help forge Schnorr signatures (Gennaro, Jarecki, Krawczyk and Rabin, CT-RSA 2003),
and it is the construction frost-core implements.

### T3. Rogue-key attempts
*Attack (DKG):* a dealer picks its commitment as a function of the others' so that it
controls the group key. *Mitigation:* every dealer proves knowledge of its constant term
(Schnorr proof bound to its identifier), verified by the coordinator before any relay and
again by every participant; the proof of knowledge prevents a dealer from cancelling the
other dealers' contributions. Round-one packages are origin-signed and echo-checked, which
proves every participant saw the same set but not that it was sent simultaneously: a rushing
dealer (possibly helped by the coordinator, which sees the other packages first) can still
bias the key distribution, see T2. For a refresh, the constant-term commitment is forced to
the identity, so no dealer can shift the group key.
*Attack (on-chain):* rotate the vault to a key nobody (or only the attacker) can use.
*Mitigation:* `rotateGroupKey` requires a signature by the current group **and** by the
new key over the same digest (proof of possession), rejects keys unusable with
`ecrecover`, and retires the old key forever. Off-chain, a signer only takes part in a
rotation towards a group key it holds a committed share of (a DKG it took part in), with a
threshold at least that of the signing group; a key the coordinator generated, a group some
signer is not in, or a lower-threshold group is refused.
*Tests:* `dkg::invalid_proof_of_knowledge_is_blamed_with_verifiable_evidence`,
`dkg::equivocating_dealer_is_blamed`, `dkg::refresh_share_check_uses_the_zero_constant_commitment`,
`adversarial::signers_only_rotate_to_groups_they_hold_at_the_same_threshold`,
`SchnorrVaultTest::test_rotationRequiresProofOfPossession`,
`SchnorrVaultTest::test_retiredKeysCannotBeReactivated`, invariant I4.

### T4. Malicious coordinator (equivocation, replay, framing, authorisation)
*Attack:* the coordinator sends different data to different participants (round-one sets,
signing packages, messages) to break consistency, extract an extra signature share, replay
start messages, blame an honest participant, or request actions the operators never wanted.
*Mitigations:*
- Participants accept only coordinator-signed envelopes; relayed messages keep their
  origin signature, so the coordinator cannot forge a participant's contribution.
- Each participant signs the digest of the round-one set it received; mismatches abort.
- A DKG is committed only against a certificate of `n` signed, identical results.
- Every session id (keygen, signing, repair) is burned in the node's journal before the
  node's first message for it leaves, so a replayed `KeygenStart`, `RepairStart` or
  `SignRequest` never makes an honest node answer a step twice.
- Signers receive the structured action, compute the EIP-712 digest themselves and check
  it against a local policy (pinned vault and chain id; optional amount cap, recipient and
  guardian allowlists, daily-limit cap; the rotation rule of T3). With an approver key in
  the policy, a request must also carry the operator's ed25519 approval of exactly that
  digest, so the coordinator alone cannot get anything signed.
- A signer refuses a package whose message, signer set or own commitment differs from
  what it committed to, and its nonces are consumed either way.
- Every provable blame carries the culprit's own signed messages. For the six cryptographic
  faults (invalid proof of knowledge, invalid or missing share, inconsistent broadcast,
  equivocation, invalid signature share) `Blame::verify` returns `Evidence::Conclusive` from the
  evidence alone, and is built so that it cannot be used to frame:
  an inconsistent-broadcast claim ships the `n` origin-signed round-one envelopes and the
  verifier recomputes the digest; a missing-share claim ships the same set and is accepted only
  if its digest is the one the dealer signed and the recipient is another member of that set;
  equivocation is accepted only for two different answers to a once-per-session step (round-one
  or round-two package, keygen result, nonce commitment, signature share, repair message, or a
  reveal for the same recipient), never for refusals; an invalid-share claim is only accepted
  against the signing package whose digest the signer itself signed. For transcript-dependent
  faults (malformed message, false complaint, inconsistent result, failed reveal) it returns
  `Evidence::SignedOnly`: the party signed the message, and judging it requires replaying the
  session transcript.
*Residual risk:* the coordinator can always abort sessions (liveness). Without an approver,
it decides which in-policy actions are signed, bounded by the vault's daily limits, time locks
and guardian (see §5).
*Tests:* `adversarial::*` (reveal harvesting, poisoned sessions, rotation to a coordinator key,
approvals), `blame::honest_repeated_answers_are_not_equivocation`,
`blame::replayed_keygen_start_is_refused_after_the_session`,
`blame::missing_share_blame_cannot_frame_an_honest_dealer`,
`dkg::participants_refuse_an_incomplete_commit_certificate`,
`dkg::participants_ignore_envelopes_not_signed_by_the_coordinator`,
`validation::incomplete_bundles_are_refused`,
`signing::signer_never_reuses_nonces`,
`signing::signer_rejects_packages_with_altered_commitments_or_signer_sets`,
`signing::signer_policy_violations_are_declined`,
`blame::keygen_evidence_is_bound_to_session_mode_and_party`,
`blame::signing_evidence_needs_the_signing_context`.

### T5. Nonce reuse
*Attack:* obtain two signature shares under the same nonce pair (replayed session, restart,
coordinator substituting the message).
*Mitigations:* nonces exist only in memory for one session and are consumed by the first
round-two request; a session identifier is burned (optionally in an fsynced append-only
journal) before commitments leave the signer; replays are refused. A restarted signer has
no nonces at all, so it cannot be tricked into reusing old ones.
*Tests:* `signing::signer_never_reuses_nonces`, `signing::replayed_sign_request_is_refused_by_the_node`,
`signing::session_journal_survives_restarts`.

### T6. Malicious participant during signing (identifiable abort)
*Attack:* submit an invalid signature share to stall the group.
*Mitigation:* aggregation uses `CheaterDetection::AllCheaters`; every invalid share is
reported with the signer's signed share envelope; retries exclude culprits.
*Tests:* `signing::corrupted_share_is_identified_with_verifiable_evidence`,
`signing::all_cheaters_are_named_not_just_the_first`,
`signing::retry_excludes_cheaters_and_unresponsive_signers`,
`signing::share_bound_to_another_package_is_malformed`,
`network::byzantine_share_is_identified_with_evidence` (over TCP).

### T7. Malicious participant during DKG (complaints)
| Misbehaviour | Detection | Blame |
|---|---|---|
| Invalid proof of knowledge | coordinator, before relay | dealer (provable) |
| Wrong number of coefficients | coordinator, before relay | dealer (provable) |
| Two different round-one packages | coordinator | dealer (`Equivocation`, provable) |
| Wrong round-one digest | coordinator | participant (provable) |
| Missing share for a recipient | coordinator | dealer (provable) |
| Share failing the Feldman check | recipient reveals the dealer-signed statement | dealer (provable) |
| Forged or unfounded complaint | coordinator checks the evidence | complainant (`FalseComplaint`) |
| Box that cannot be opened | reveal request to the dealer, carrying the complaint | dealer if it does not reveal a valid share; otherwise an unattributable **dispute** (both listed, nobody blamed) |
| Different public key package reported | coordinator recomputes it from the commitments | participant (`InconsistentResult`) |
| Silence | phase deadline | `Unresponsive` (liveness, not provable) |

Nothing from an aborted session is ever committed, and a session with a reveal always aborts.
*Tests:* `dkg::*`, `validation::silent_participants_are_named_in_every_keygen_phase`, `network::dkg_blames_*`.

### T8. Network attacker and resource exhaustion
*Attack:* drop, delay, corrupt, replay or inject frames; open many connections; stop
reading to stall the coordinator; make a node accumulate session state.
*Mitigations:* mutually authenticated handshake (challenge, signed hello, signed welcome);
ed25519 origin signatures on every envelope; session identifiers burned in the journal;
sealed boxes bind session, sender, recipient and purpose. Frames are capped at 4 KiB before
authentication and 4 MiB after, checked before allocation; at most twice the roster size
(plus two) connections may be in the handshake at once, and finished connection tasks are
reaped. The coordinator never waits on a participant's queue: one that stops reading is
disconnected and named unresponsive by the phase deadline. Nodes keep at most 64 in-flight
sessions of each kind (keygen, signing, repair helper, repair recipient), evict the oldest
and expire all of them after 10 minutes; dropped state zeroises its secrets. A corrupted
message never authenticates, so it can only be reported as a liveness fault; it can never
frame the sender.
*Tests:* `network::dropped_share_is_named_unresponsive_and_retry_succeeds`,
`network::delay_within_the_deadline_is_tolerated`,
`network::delay_beyond_the_deadline_is_named_unresponsive`,
`network::corrupted_messages_are_rejected_and_cannot_frame_the_sender`,
`handshake::*` (including `unauthenticated_peers_cannot_announce_large_frames` and
`pending_handshakes_are_capped_and_finished_tasks_reaped`),
`coordinator::tests::dispatch_never_waits_for_a_participant_that_stopped_reading`,
`validation::abandoned_keygen_and_repair_sessions_are_bounded_and_expire`,
`signing::abandoned_sessions_cannot_accumulate_nonces`, `properties::envelopes_are_authenticated`.

### T9. On-chain attacks
| Threat (OWASP SC Top 10) | Mitigation | Test |
|---|---|---|
| Replay (SC: signature replay) | Unordered nonce bitmap shared by all intent types; every group-signed path emits the nonce it consumed | `test_withdrawRevertsOnReplay`, invariant I3 |
| Cross-chain / cross-vault replay | EIP-712 domain with chain id and verifying contract | `test_signatureIsBoundToVaultAndChain` |
| Stale intents | Inclusive deadline on every intent | `test_withdrawRevertsWhenExpired` |
| Signature malleability | `z < n`, `z != 0`, `address(R) != 0`, `0 < P.x < n` | `test_rejectsMalformedFields`, `response_words_at_or_above_order_are_rejected` |
| Access control (SC01) | All privileged paths require a group signature; guardian limited to pause/cancel; group replaces the guardian only after 2 days | `test_onlyGuardianCanPauseUnpauseAndCancel`, `test_groupCanReplaceGuardianAfterTheTimeLock` |
| Reentrancy (SC05) | `ReentrancyGuardTransient` + checks-effects-interactions | `test_reentrancyIsBlocked` |
| Unchecked external calls | `Address.sendValue` / `SafeERC20` revert bubbles; nonce and usage roll back | `test_failedEthTransferBubblesAndKeepsNonce` |
| Drain after key theft | Per-token cap per UTC day; limit increases and guardian replacement time-locked 2 days; guardian can pause and cancel increases meanwhile; a rotation voids everything queued under the retired key | `RateLimitFuzzTest`, `test_rotationVoidsQueuedChanges`, invariants I1, I5, I6, I7 |
| Rogue rotation | Current-group signature + proof of possession; retired keys stay retired; signers only rotate to groups they hold (T3) | T3 tests, invariant I4 |
| Silent breakage | Every valid in-limit intent from the model succeeds, and every run ends with a liveness proof (unpause, withdraw, rotate, stale key rejected) | invariant I8, `afterInvariant` |

### T10. The `address(R)` challenge
The challenge binds `R` through its 160-bit Ethereum address instead of the full point.
Accepting a forgery requires `address(z·G − e·P) = A` where `e` itself depends on `A`,
a 160-bit preimage-style search; no generic birthday shortcut is known because the target
moves with every candidate `A`. This is the same trade-off as the Chainlink verifier this
design follows. The key's parity and x-coordinate are both hashed, so the negated key is a
different key (`wrong_key_parity` fixtures).

## 5. Known limitations

- **Not audited; demo only.** No real funds, no production deployment, not a qualified or
  compliant custody product.
- **Shares are not persisted**: they live in process memory only (no HSM, enclave or OS
  key-store integration, and no encrypted share files). The CLI's groups disappear when its
  processes exit; `DeploySchnorrVault.s.sol` is a template for a group whose key packages are
  persisted elsewhere.
- **Authorisation without an approver:** with the permissive policy the demos use, whoever
  runs the coordinator chooses which in-policy actions the group signs. The vault bounds the
  damage (daily caps, 2-day locks on raises and guardian replacement, guardian pause), but a
  production deployment should configure an approver key and allowlists.
- **Equivocation evidence across restarts** assumes participants persist their session
  journal (`--journal`); a node restarted with an in-memory journal could be replayed into
  answering a step twice.
- **DKG liveness:** every participant must be online; any fault aborts and the session is
  restarted without the named parties (no robust DKG).
- **Coordinator** is a single point of failure for liveness.
- **Unattributable disputes:** when a recipient cannot open a box and the dealer then reveals a
  valid share, neither party can be proven at fault (the session aborts either way).
- **Repair:** a helper sending a bad sigma makes the repair fail closed, but the helper
  cannot be identified from the (uniformly random) sigmas.
- **Daily windows** are fixed UTC days: up to twice the limit can leave around midnight.
  A rolling window (e.g. OpenZeppelin 5.7 `RateLimiter.SlidingWindow`) removes this at a
  higher gas cost.
- **Rotations take effect immediately.** They are the incident response to a leaked key, so
  they are not time-locked; the signer-side rotation rule (T3) is what stops a coordinator from
  redirecting one.
- **Fee-on-transfer / rebasing tokens** are accounted by the amount requested, not received.
- **Threshold compromise** (an attacker with `t` shares) is outside the safety model. The vault
  bounds the damage (daily caps, 2-day locks on raises and guardian replacement, pausing) and
  gives the honest group a window to rotate first, but an attacker who rotates first keeps control.
- **Transport:** protocol messages other than DKG shares and repair values are signed but
  not encrypted; they contain only public data.
