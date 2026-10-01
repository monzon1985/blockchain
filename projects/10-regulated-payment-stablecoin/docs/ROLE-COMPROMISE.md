# Role compromise analysis

What an attacker can do with each key of the Test Payment Dollar (tPD), how fast, and what caps the damage. The design rule behind every row: **containment acts instantly, every change of the configuration waits 2 days.** The instant tools are the pause (global), `removeMinter` (one minter), and blocklist / freeze (one address, bridge contracts included). Everything that goes through ADMIN or UPGRADER waits 2 days in both directions: granting and revoking roles, raising and lowering limits and ceilings, replacing the attestor, upgrading. Revoking a compromised key is therefore never instant, and for BLOCKLISTER, COMPLIANCE_OFFICER and PAUSER the only instant brake is the global pause (or, for PAUSER, nothing). Supply increases are capped three times for minters (per-minter allowance, per-minter rolling 24 h limit, attested reserves) and twice for bridges (per-bridge rolling 24 h limit, attested reserves).

> Technical demonstration. tPD is a test token on local chains; nothing here describes a real issuer's key management.

All role ids live in [`src/access/Roles.sol`](../src/access/Roles.sol); the wiring is [`script/StablecoinDeployment.sol`](../script/StablecoinDeployment.sol) and is re-checked after every deployment by [`script/VerifyRoles.s.sol`](../script/VerifyRoles.s.sol), which also lists every operation still scheduled on the AccessManager, so a malicious schedule is visible during its whole 2-day window.

## Summary

| Key | Instant powers | Delayed powers (2 days) | Worst case if compromised | Who stops it, and how fast |
|---|---|---|---|---|
| **ADMIN** (governance) | cancel scheduled operations | grant / revoke every role, rewire selectors, change the reserve attestor, the minter-limit ceiling and the bridge limits, close the target, move the token to another authority | full control, **after** a public 2-day `OperationScheduled` window | another ADMIN member (none in the default wiring, see below); PAUSER can pause the token while the operation is pending |
| **UPGRADER** | none | `upgradeToAndCall` | arbitrary implementation = arbitrary balances, **after** 2 days | PAUSER (guardian of UPGRADER) or ADMIN cancels the scheduled upgrade, instantly |
| **MASTER_MINTER** | `configureMinter` (allowance + daily limit up to the ceiling), `removeMinter` | none | raise existing minters to the ceiling; remove all minters (issuance DoS) | PAUSER pauses instantly (global); ADMIN revokes in 2 days |
| **MINTER** | `mint` within allowance, rolling 24 h limit and reserve headroom; `burn` own balance | none | `min(allowance, daily limit, reserve headroom)` new tokens per 24 h | MASTER_MINTER `removeMinter` (instant), PAUSER (instant), BLOCKLISTER / COMPLIANCE on the recipients (instant) |
| **PAUSER** | `pause`, `unpause`, cancel scheduled upgrades | none | freeze all transfers (DoS); **unpause during an incident**, which removes the circuit breaker the COMPLIANCE_OFFICER, MASTER_MINTER and BRIDGE rows rely on; veto every upgrade by cancelling it (each new attempt costs another 2 days) | nobody instantly: ADMIN revokes in 2 days; cannot move a single token |
| **BLOCKLISTER** | `blocklist`, `unBlocklist` | none | censor any holder (bridges and minters included); release a sanctioned address | PAUSER pauses instantly (global, also stops honest holders); ADMIN revokes in 2 days; cannot move a single token |
| **COMPLIANCE_OFFICER** | `freeze`, `unfreeze`, `seize`, `burnFrozen` (v2: `setTransferCapFlag`) | none | **freeze + seize any holder's full balance to any unrestricted address**, instantly | PAUSER pauses (seize and burnFrozen revert while paused); every action carries an `orderRef` and emits events |
| **BRIDGE** | `crosschainMint` / `crosschainBurn` within the per-bridge rolling limits (mint also reserve-gated) | none | mint up to the bridge mint limit per 24 h; burn up to the bridge burn limit per 24 h from any unrestricted holder | BLOCKLISTER or COMPLIANCE_OFFICER blocklists / freezes the bridge address (instant, both entry points refuse a restricted bridge, other holders unaffected); PAUSER (instant, global); ADMIN lowers limits or revokes in 2 days |
| **Reserve attestor** (a signing key, not a role) | sign attestations | none | inflate reserves (removes the reserve cap; minters keep their allowance and rolling limit, bridges their rolling limit) or deflate them (blocks issuance) | ADMIN replaces the attestor in 2 days; PAUSER stops issuance meanwhile (global) |

## Worst-case issuance per 24 hours

With an honest attestor, total issuance in any rolling 24 h window is bounded by

```
min( reserve headroom,
     Σ over minters  min(allowance_i, dailyLimit_i)  +  Σ over bridges bridgeMintLimit )
```

and each `dailyLimit_i` is at most `minterLimitCeiling`, which only ADMIN can raise (2-day delay). A compromised MASTER_MINTER cannot add minters (it cannot grant the MINTER role) and cannot lift a minter above the ceiling. Reconfiguring or removing a minter never resets its rolling window (the checkpoint history is kept), so a remove / re-add cycle does not buy extra issuance. Both properties are covered by tests (`test_removeAndReconfigure_doesNotResetRollingWindow`, `test_ceiling_boundsMasterMinter`, `testFuzz_rollingLimitMatchesReferenceModel`) and by invariant I-4.

With the demo deployment parameters (ceiling 5,000,000 tPD, one minter, bridge mint limit 2,000,000 tPD) a simultaneous compromise of MASTER_MINTER, the minter and the bridge can create at most 7,000,000 tPD per 24 h, and never more than the attested reserve headroom.

## Notes per role

**ADMIN.** Every AccessManager admin selector (`grantRole`, `revokeRole`, `setRoleAdmin`, `setRoleGuardian`, `setGrantDelay`, `setTargetFunctionRole`, `setTargetClosed`, `updateAuthority`, `labelRole`, `setTargetAdminDelay`) and every ADMIN-only token selector (`setReserveAttestor`, `setMinterLimitCeiling`, `setBridgeLimits`, v2 `setFlaggedDailyCap`) must be scheduled 2 days ahead because the governance member holds ADMIN with a 2-day execution delay. That holds in every configuration: the deployment ends by granting governance ADMIN with the delay and the deployer renounces its own ADMIN, or, when the deployer is governance, re-grants itself ADMIN with the delay (`test_governanceEqualsDeployer_adminKeepsDelay`). `VerifyRoles` fails on an extra ADMIN member, on a wrong or pending ADMIN delay, and on any operation still scheduled. AccessManager does not let ADMIN have a guardian, so a scheduled admin operation can only be cancelled by its scheduler or by another ADMIN member. **Known limitation:** the default wiring has a single ADMIN member; a production deployment should add a second one (for example a security council multisig, also with a delay) whose job is to cancel malicious schedules.

**UPGRADER.** The upgrade is the most powerful operation in the system, so it has both the delay and a guardian: PAUSER can cancel a scheduled upgrade during the 2-day window (`test_upgrade_pauserGuardianCancels`). The v2 initializer takes no argument, so an upgrade executed without calling it could only ever install the documented default.

**COMPLIANCE_OFFICER.** GENIUS-style obligations require the issuer to be able to freeze, seize and burn without delay, so this role is instant, and it is therefore the key whose compromise does the most immediate damage. Mitigations in the code: seizures only work on frozen accounts, never credit a restricted account, need a non-zero lawful-order reference and revert while paused, so the pauser is the circuit breaker. Hardening option (not enabled in the demo): grant COMPLIANCE_OFFICER with an execution delay and set PAUSER as its guardian; seizures then become scheduled, cancellable operations, at the cost of slower execution of genuine orders.

**BRIDGE.** ERC-7802 lets a bridge burn from any holder without an allowance (the bridge contract is trusted to do so only for users who initiated a transfer). That is why the burn side has its own cap, separate from the mint side and from minter allowances. Bridges have no allowance, so bridge issuance has two caps (rolling limit, reserves), not three. A blocklisted or frozen bridge address can neither mint nor burn (`test_crosschain_restrictedBridgeIsRefused`), which makes the blocklist the instant, targeted way to contain a compromised or sanctioned bridge contract.

**PAUSER.** The pause is the brake every other row relies on, which makes this key's compromise subtle: it cannot move funds, but it can lift the brake during an incident and veto upgrades (including a fix) by cancelling each attempt. No instant counter exists in the default wiring; ADMIN revokes it in 2 days. Hardening option (not enabled): a second, independent pauser, or shrink-only instant powers for other roles (for example a PAUSER-callable `suspendBridge`, lower-only limit setters) so fewer incidents depend on the global pause.

**Reserve attestor.** Attestations are EIP-712 signatures bound to this chain id and this proxy address, must be strictly newer than the recorded one and at most 26 h old, so an old, higher figure cannot be replayed. The attestor can be an ERC-1271 contract (for example a multisig of the accounting firm).
