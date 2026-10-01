# Kestrel Protocol — Security Review

A self-directed security review of the **Kestrel** DeFi protocol, written as a portfolio exercise.
The protocol is *vulnerable by design*: its author seeded twelve bugs modelled on public incidents
(2022–2025) and the [OWASP Smart Contract Top 10 (2026)](https://scs.owasp.org/sctop10/), then
exploited, fixed and locked each one down with a property.

> **This is a technical demonstration, not a paid audit.** Nothing here has been professionally
> audited or deployed with real funds; "Kestrel" is fictional. Because the reviewer also seeded the
> bugs, §6 is a reconstruction of how tool leads map to the seeded bugs, not the log of a blind
> review. The tool scoreboard (§7) is derived mechanically from stored tool output.

| | |
|---|---|
| **Protocol** | Kestrel: weighted AMM, native-ETH share vault, isolated lending, token governance, EIP-712 relayer, transparent proxy + risk config |
| **Versions** | v1 = `src/vulnerable/`, v2 = `src/fixed/` (same commit; one tagged fix per finding, see [`diffs/`](diffs)) |
| **Review methods** | Manual review; Foundry exploits and regressions; spec-only Foundry invariants; Medusa; Halmos; Slither with three custom detectors |
| **Seeded findings** | 8 High · 2 Medium · 2 Low |
| **Found in re-review** | 1 High · 2 Medium · 1 Low (fixed) |
| **Informational / Gas** | 6 · 3 |

---

## 1. Scope

<!-- BEGIN:nsloc -->
| Contract | nSLOC v1 (`src/vulnerable`) | nSLOC v2 (`src/fixed`) | Description |
| --- | ---: | ---: | --- |
| `KestrelPool.sol` | 414 | 423 | Two-asset weighted AMM: proportional and exact-share joins, single and batch swaps, LP rewards, native-sponsored swap, TWAP accumulator |
| `KestrelVault.sol` | 84 | 88 | Native-ETH share vault (ERC-4626-shaped), dead-share inflation guard |
| `KestrelLending.sol` | 143 | 143 | Isolated lending market priced from the TWAP oracle and the vault share price |
| `KestrelGovernor.sol` | 117 | 117 | Snapshot proposals plus a supermajority emergency path |
| `KestrelRelayer.sol` | 72 | 79 | EIP-712 gasless-swap relayer (ECDSA and ERC-1271) |
| `KestrelProxy.sol` | 79 | 83 | Transparent proxy in front of the risk config |
| `lib/FixedPointMath.sol` | 47 | 51 | WAD/mulDiv helpers and the Q128 checked shift |
| **In-scope total** | **956** | **984** | |
| `shared/GovToken.sol` | 25 | 25 | ERC20Votes + ERC20FlashMint + ERC20Permit governance token |
| `shared/KestrelConfig.sol` | 79 | 79 | Risk parameters (LTV, ETH price) behind the proxy |
| `shared/PoolTwapOracle.sol` | 58 | 58 | Fixed-period TWAP with staleness bound |
| `shared/IKestrelConfig.sol` | 5 | 5 | Config interface |
| `shared/IPriceOracle.sol` | 4 | 4 | Oracle interface |
| **Shared total** | **171** | **171** | identical in both trees |

nSLOC = non-blank lines that are not entirely comments, counted by `scripts/report.mjs` (`node scripts/report.mjs` regenerates this table).
<!-- END:nsloc -->

Out of scope: test code, scripts and the OpenZeppelin, Solady and forge-std dependencies (Soldeer,
pinned in `soldeer.lock`).

## 2. Roles and trust assumptions

- **Pool owner** (`Ownable2Step`) sets the LP reward rate and withdraws collected native fees. A
  compromised owner can mis-set emissions (bounded by the funded reserve) and take the fees; it
  cannot touch reserves or LP shares.
- **Risk owner** (config, two-step ownership) sets the LTV (≤ 90 %) and the ETH reference price that
  values vault-share collateral. The price is a trusted input: an owner who sets an absurd price
  lets borrowers drain the lending liquidity.
- **Proxy admin** upgrades the config implementation, and so controls the risk parameters.
- **GovToken owner** (`Ownable`) can mint governance tokens; the fixtures and demos use it to seed
  balances. A compromised owner could mint a 66.66 % stake, hold it for the 50-block lookback and
  move the treasury through the emergency path, so a deployment would renounce the role or hand it
  to governance.
- **Governance holders.** Normal proposals use the voting power at the block before creation; an
  account holding 66.66 % of the supply for 50 blocks may execute an emergency action at once.
- **Keepers** (anyone) advance the TWAP oracle; they cannot change a published price.
- **Relayers** (anyone) submit signed swaps; they cannot forge or replay authorizations.
- **Users** trade, provide liquidity, deposit and borrow permissionlessly in an isolated market.

## 3. Severity classification

Severity = Impact × Likelihood.

| | High impact | Medium impact | Low impact |
|---|---|---|---|
| **High likelihood** | High | High | Medium |
| **Medium likelihood** | High | Medium | Low |
| **Low likelihood** | Medium | Low | Low |

*Impact*: funds at risk or protocol solvency. *Likelihood*: cost and preconditions of the attack.
Informational findings are not vulnerabilities; Gas findings are optimizations.

## 4. Findings summary

| ID | Bug | Title | OWASP 2026 | Severity | Status |
|---|---|---|---|---|---|
| [H-01](#h-01) | SC03 | Lending values collateral at the AMM spot price | SC03 Price Oracle Manipulation | High | Fixed |
| [H-02](#h-02) | SC04 | Emergency execution weighs live balances (flash-loan governance) | SC04 Flash Loan-Facilitated Attacks | High | Fixed |
| [H-03](#h-03) | SC05 | Duplicate-asset `batchSwap` double-counts a reserve | SC05 Lack of Input Validation | High | Fixed |
| [H-04](#h-04) | SC08 | Read-only reentrancy on the vault share price | SC08 Reentrancy | High | Fixed |
| [H-05](#h-05) | SC01 | Unprotected reward-rate setter drains the reward reserve | SC01 Access Control | High | Fixed |
| [H-06](#h-06) | SC09 | Flawed shift guard lets exact-share joins mint for dust | SC09 Integer Overflow and Underflow | High | Fixed |
| [H-07](#h-07) | SC10 | Proxy admin slot collides with the config's initializer flags | SC10 Proxy & Upgradeability | High | Fixed |
| [H-08](#h-08) | REPLAY | Relayer signatures lack chain id and nonce | SC02 Business Logic | High | Fixed |
| [M-01](#m-01) | SC02 | Swap fee bypassed through the batch path | SC02 Business Logic | Medium | Fixed |
| [M-02](#m-02) | SC06 | Unchecked ETH refund strands funds | SC06 Unchecked External Calls | Medium | Fixed |
| [L-01](#l-01) | SC07a | Batch downscaling rounds toward the trader | SC07 Arithmetic Errors | Low | Fixed |
| [L-02](#l-02) | SC07b | Vault `withdraw` rounds burned shares down | SC07 Arithmetic Errors | Low | Fixed |
| [R-01](#r-01) | — | Permissionless oracle `update()` could freeze lending; stale TWAP | SC03 / availability | High | Fixed |
| [R-02](#r-02) | — | First-depositor share inflation in the vault | SC07 Arithmetic Errors | Medium | Fixed |
| [R-03](#r-03) | — | Native sponsor fees locked in the pool | SC02 Business Logic | Medium | Fixed |
| [R-04](#r-04) | — | Proposal existence check fails when the snapshot block is 0 | SC05 Lack of Input Validation | Low | Fixed |
| [I-01](#i-01) … [I-06](#i-06) | — | Informational | — | Info | Acknowledged |
| [G-01](#g-01) … [G-03](#g-03) | — | Gas | — | Gas | See text |

Every seeded finding is closed three ways: an exploit (`test/exploits/`, using an attack contract
in `test/attacks/`) that passes on v1 and fails on v2; a minimal fix whose diff is embedded below
and stored in [`diffs/`](diffs); and at least one property (Foundry invariant, Medusa property or
Halmos check) that fails on v1 and holds on v2. `scripts/scoreboard.mjs --check` verifies all three
from stored evidence in CI.

---

## 5. Detailed findings

### <a id="h-01"></a>H-01 · Lending values collateral at the AMM spot price (SC03)

**Description.** `KestrelLending.collateralValue` prices the ERC-20 collateral with
`KestrelPool.spotPrice0In1()`, an instantaneous ratio of the pool reserves that any swap moves.

**Impact.** In one transaction an attacker buys the collateral token to pump its spot price,
borrows against the inflated valuation and sells back. The PoC pledges 80,000 collateral, pumps
with 2,000,000 debt tokens, borrows the market's entire 500,000 liquidity and unwinds, netting over
400,000 debt tokens; the position is left more than 6x under water at the time-weighted price.
**Likelihood** high (flash-loanable, one transaction). **Severity: High.**

**Proof of Concept.** [`test/exploits/SC03_SpotOracle.t.sol`](../test/exploits/SC03_SpotOracle.t.sol)
with [`SpotOracleAttacker`](../test/attacks/SpotOracleAttacker.sol).

**Recommended mitigation.** Value collateral from a manipulation-resistant price. The fix reads the
fixed-period TWAP oracle (whose own hardening is R-01).

**Fix.**

<!-- BEGIN:diff-SC03 -->
```diff
diff --git a/KestrelLending.sol b/KestrelLending.sol
--- a/KestrelLending.sol
+++ b/KestrelLending.sol
@@ -218,7 +218,7 @@
     function collateralValue(address account) public view returns (uint256 value) {
         uint256 amount = collateralOf[account];
         if (amount > 0) {
-            uint256 price = pool.spotPrice0In1();
+            uint256 price = oracle.priceToken0In1(); // [SC03] time-weighted, never the AMM spot
             value = FixedPointMath.mulWadDown(amount, price);
         }
         uint256 shares = vaultCollateralOf[account];
```
<!-- END:diff-SC03 -->

**Properties.** `invariant_valuationIgnoresSameBlockSwaps` / `property_valuationIgnoresSameBlockSwaps`;
regressions in `SC03_SpotOracle.t.sol` (the same attack reverts with
`Undercollateralized(500000e18, 60000e18)`).

---

### <a id="h-02"></a>H-02 · Emergency execution weighs live balances (SC04)

**Description.** `emergencyExecute` compares the caller's current `token.balanceOf` against
66.66 % of the past supply. `GovToken` supports ERC-3156 flash mints, so the balance is not stake.

**Impact.** An attacker flash-mints 70 % of the supply, executes an arbitrary call that transfers
the treasury, and repays (Beanstalk, 2022). The same works with tokens borrowed for a single block.
**Likelihood** high. **Severity: High.**

**Proof of Concept.** [`test/exploits/SC04_FlashGovernance.t.sol`](../test/exploits/SC04_FlashGovernance.t.sol)
with [`FlashGovAttacker`](../test/attacks/FlashGovAttacker.sol) and
[`BorrowedStakeAttacker`](../test/attacks/BorrowedStakeAttacker.sol) (one-block loan).

**Recommended mitigation.** Weigh support with checkpointed votes from well before the action, so
stake must be held, not borrowed. The fix uses `getPastVotes` at `block.number - emergencyLookback`
(50 blocks), where the supply was already measured.

**Fix.**

<!-- BEGIN:diff-SC04 -->
```diff
diff --git a/KestrelGovernor.sol b/KestrelGovernor.sol
--- a/KestrelGovernor.sol
+++ b/KestrelGovernor.sol
@@ -203,7 +203,9 @@
     {
         uint256 timepoint = block.number > emergencyLookback ? block.number - emergencyLookback : 0;
         uint256 supply = token.getPastTotalSupply(timepoint);
-        uint256 weight = token.balanceOf(msg.sender);
+        // [SC04] Weight is the caller's checkpointed votes at `timepoint`, not its live balance:
+        // stake that was flash-minted, borrowed or bought within the lookback carries no weight.
+        uint256 weight = token.getPastVotes(msg.sender, timepoint);
         uint256 required = supply * emergencyQuorumBps / BPS;
         require(weight > 0 && weight >= required, InsufficientSupport(weight, required));
         emit EmergencyExecuted(msg.sender, target, weight);
```
<!-- END:diff-SC04 -->

**Properties.** `invariant_treasuryNeedsDurableStake` / `property_treasuryNeedsDurableStake`; Halmos
`check_flashMintCannotPassEmergencyQuorum`; regressions for the flash loan, the one-block loan and a
stake held just short of the lookback (`InsufficientSupport(0, 666600e18)`).

---

### <a id="h-03"></a>H-03 · Duplicate-asset `batchSwap` double-counts a reserve (SC05)

**Description.** `batchSwap` snapshots `_reserveOf(assets[i])` into one running balance per index
and never checks that `assets` is duplicate-free. Two indices of the same token price against two
copies of the same reserve, and settlement writes the token's reserve once per index, the stale
last write winning.

**Impact.** The attacker is paid more than a fair swap and the pool's recorded reserve ends above
its real balance: the pool is insolvent and the last LPs to exit cannot be paid.
**Likelihood** high. **Severity: High.**

**Proof of Concept.** [`test/exploits/SC05_DuplicateBatch.t.sol`](../test/exploits/SC05_DuplicateBatch.t.sol)
with [`DuplicateBatchAttacker`](../test/attacks/DuplicateBatchAttacker.sol).

**Recommended mitigation.** Reject duplicated assets (or key running balances by token).

**Fix.**

<!-- BEGIN:diff-SC05 -->
```diff
diff --git a/KestrelPool.sol b/KestrelPool.sol
--- a/KestrelPool.sol
+++ b/KestrelPool.sol
@@ -148,6 +148,9 @@
     /// @notice Thrown when a batch is malformed: fewer than two assets, an out-of-range index or
     ///         a step whose input and output index are equal.
     error BadAssetIndex();
+    /// @notice Thrown when {batchSwap} lists the same asset twice. [SC05]
+    /// @param asset The repeated asset.
+    error DuplicateAsset(address asset);
     /// @notice Thrown when burning more LP shares than the caller holds.
     /// @param shares Requested shares.
     /// @param balance Available shares.
@@ -384,6 +387,13 @@
         uint256 n = assets.length;
         require(n >= 2, BadAssetIndex());
         _syncOracle();
+        // [SC05] Reject duplicated assets, so each token has exactly one running balance and
+        // settlement writes each reserve once.
+        for (uint256 i = 0; i < n; ++i) {
+            for (uint256 j = i + 1; j < n; ++j) {
+                require(assets[i] != assets[j], DuplicateAsset(assets[i]));
+            }
+        }
         uint256[] memory bal = new uint256[](n);
         for (uint256 i = 0; i < n; ++i) {
             bal[i] = _reserveOf(assets[i]);
```
<!-- END:diff-SC05 -->

**Properties.** `invariant_poolSolvency` / `property_poolSolvency`; the regression reverts with
`DuplicateAsset(collateral)`.

---

### <a id="h-04"></a>H-04 · Read-only reentrancy on the vault share price (SC08)

**Description.** `KestrelVault.redeem` burns the shares, sends the ETH and only then decrements
`totalManaged`. During the recipient's callback the supply is already reduced while the managed
balance is not, and the unguarded `convertToAssets` reports an inflated price.

**Impact.** The lending market values pledged vault shares with `convertToAssets`. Reentering
`borrow` from the redemption callback borrows 250,000 against collateral with 150,000 of honest
borrowing power, leaving bad debt (Curve 2022, Sentiment 2023). **Likelihood** high.
**Severity: High.**

**Proof of Concept.** [`test/exploits/SC08_ReadOnlyReentrancy.t.sol`](../test/exploits/SC08_ReadOnlyReentrancy.t.sol)
with [`ReadOnlyReentrancyAttacker`](../test/attacks/ReadOnlyReentrancyAttacker.sol).

**Recommended mitigation.** Settle all accounting before the ETH transfer, and make price views
revert while a state-changing call is in flight.

**Fix.**

<!-- BEGIN:diff-SC08 -->
```diff
diff --git a/KestrelVault.sol b/KestrelVault.sol
--- a/KestrelVault.sol
+++ b/KestrelVault.sol
@@ -58,6 +58,8 @@
     error NoShares();
     /// @notice Thrown when the ETH transfer to the receiver fails.
     error EthTransferFailed();
+    /// @notice Thrown when a price view is read while a state-changing call is in flight. [SC08]
+    error ReentrantRead();
 
     /// @notice Deploy the vault share token.
     constructor() ERC20("Kestrel ETH Vault", "kETH") { }
@@ -123,8 +125,8 @@
         // vault's favor), so a non-zero share count always redeems a non-zero amount.
         assets = _convertToAssets(shares);
         _burn(msg.sender, shares);
+        totalManaged -= assets; // [SC08] effects before the ETH transfer: the price is never stale
         _sendEth(receiver, assets);
-        totalManaged -= assets;
         emit Withdraw(msg.sender, receiver, assets, shares);
     }
 
@@ -132,6 +134,7 @@
     /// @param assets ETH (wei).
     /// @return shares Corresponding shares.
     function convertToShares(uint256 assets) external view returns (uint256 shares) {
+        require(!_reentrancyGuardEntered(), ReentrantRead()); // [SC08] no reads mid-operation
         shares = _convertToShares(assets);
     }
 
@@ -139,12 +142,14 @@
     /// @param shares Vault shares.
     /// @return assets Corresponding ETH (wei).
     function convertToAssets(uint256 shares) external view returns (uint256 assets) {
+        require(!_reentrancyGuardEntered(), ReentrantRead()); // [SC08] no reads mid-operation
         assets = _convertToAssets(shares);
     }
 
     /// @notice Price of 1e18 shares in ETH (wei).
     /// @return price ETH per 1e18 shares.
     function pricePerShare() external view returns (uint256 price) {
+        require(!_reentrancyGuardEntered(), ReentrantRead()); // [SC08] no reads mid-operation
         price = _convertToAssets(1e18);
     }
```
<!-- END:diff-SC08 -->

**Properties.** `invariant_integratorsSeeConsistentPrice` / `property_integratorsSeeConsistentPrice`;
the regression's reentrant borrow fails with `ReentrantRead()`.

---

### <a id="h-05"></a>H-05 · Unprotected reward-rate setter drains the reward reserve (SC01)

**Description.** `KestrelPool.setRewardRate` has no access control.

**Impact.** Any LP raises the emission rate and claims the entire reward reserve (all 1,000 tokens
in the PoC). **Likelihood** high. **Severity: High.**

**Proof of Concept.** [`test/exploits/SC01_RewardSetter.t.sol`](../test/exploits/SC01_RewardSetter.t.sol)
with [`RewardRateAttacker`](../test/attacks/RewardRateAttacker.sol).

**Recommended mitigation.** Restrict the setter to the owner.

**Fix.**

<!-- BEGIN:diff-SC01 -->
```diff
diff --git a/KestrelPool.sol b/KestrelPool.sol
--- a/KestrelPool.sol
+++ b/KestrelPool.sol
@@ -434,8 +434,9 @@
     }
 
     /// @notice Set the reward emission rate.
+    /// @dev Owner only. [SC01]
     /// @param newRate New reward rate in reward-token units per second.
-    function setRewardRate(uint256 newRate) external {
+    function setRewardRate(uint256 newRate) external onlyOwner {
         _globalRewardUpdate();
         rewardRate = newRate;
         emit RewardRateSet(newRate);
```
<!-- END:diff-SC01 -->

**Properties.** `invariant_privilegedActionsOwnerOnly` / `property_privilegedActionsOwnerOnly`; the
regression reverts with `OwnableUnauthorizedAccount(attacker)`.

---

### <a id="h-06"></a>H-06 · Flawed shift guard lets exact-share joins mint for dust (SC09)

**Description.** `FixedPointMath.checkedShl` is meant to report any shift that loses set bits, but
checks a fixed top-64-bit mask instead of the top `shift` bits (the Cetus `checked_shlw` class,
2025). `KestrelPool.addLiquidityExactShares` scales the requested shares by 2^128 through it to
compute the pro-rata ratio. A share count in [2^128, 2^192) passes the guard, the shift wraps, and
the computed cost collapses to a few wei.

**Impact.** The attacker mints 2^128 + 1 shares for at most 2 wei of each token and removes them
for essentially the whole pool. **Likelihood** high (one call, no capital). **Severity: High.**

**Proof of Concept.** [`test/exploits/SC09_ExactSharesOverflow.t.sol`](../test/exploits/SC09_ExactSharesOverflow.t.sol)
with [`ExactSharesAttacker`](../test/attacks/ExactSharesAttacker.sol), plus a library-level witness
and a fuzzed one.

**Recommended mitigation.** Flag the shift whenever `n >> (256 - shift) != 0` (and any non-zero `n`
for shifts of a full word or more).

**Fix.**

<!-- BEGIN:diff-SC09 -->
```diff
diff --git a/lib/FixedPointMath.sol b/lib/FixedPointMath.sol
--- a/lib/FixedPointMath.sol
+++ b/lib/FixedPointMath.sol
@@ -106,13 +106,19 @@
     /// @return result The shifted value (0 when overflow is reported).
     /// @return overflow True when the shift would lose set bits.
     function checkedShl(uint256 n, uint256 shift) internal pure returns (uint256 result, bool overflow) {
-        // Reject any value that already uses the top 64 bits of the word.
-        if (n & (0xFFFFFFFFFFFFFFFF << 192) != 0) {
+        // [SC09] A left shift by `shift` drops exactly the bits at positions >= 256 - shift, so
+        // the guard must depend on `shift`. A fixed mask (e.g. the top 64 bits) misses the bits
+        // just below it whenever `shift` exceeds the mask width.
+        if (shift >= 256) {
+            overflow = n != 0;
+            return (result, overflow);
+        }
+        if (shift != 0 && n >> (256 - shift) != 0) {
             overflow = true;
             return (result, overflow);
         }
         unchecked {
-            // The guard above bounds `n`, so the shift cannot lose set bits.
+            // Safe: the guard above proved that no set bit is shifted out. [SC09]
             result = n << shift;
         }
     }
```
<!-- END:diff-SC09 -->

**Properties.** `invariant_joinsPayProRata` / `property_joinsPayProRata`; Halmos
`check_checkedShlIsLossless` and `check_checkedShlFullWord`; the regression reverts with
`SharesTooLarge(2**128 + 1)`, plus a fuzzed reversibility property.

---

### <a id="h-07"></a>H-07 · Proxy admin slot collides with the config's initializer flags (SC10)

**Description.** `KestrelProxy` keeps its admin as an ordinary state variable in slot 0.
`KestrelConfig` (pre-ERC-7201 layout) keeps its OpenZeppelin-3.x-style `_initialized` and
`_initializing` flags in bytes 0 and 1 of slot 0. Behind the proxy those bytes are the low bytes of
the admin address, so `_initializing` reads `true` and the `initializer` modifier admits every call
(Audius, 2022).

**Impact.** Anyone calls `initialize` again through the proxy, becomes the risk owner and installs
any LTV and ETH price; the PoC then borrows the market's 500,000 liquidity against 1 ETH of vault
shares. **Likelihood** high. **Severity: High.**

**Proof of Concept.** [`test/exploits/SC10_ProxyCollision.t.sol`](../test/exploits/SC10_ProxyCollision.t.sol)
with [`ConfigReinitAttacker`](../test/attacks/ConfigReinitAttacker.sol).

**Recommended mitigation.** Keep proxy state out of the sequential layout (EIP-1967 slots).

**Fix.**

<!-- BEGIN:diff-SC10 -->
```diff
diff --git a/KestrelProxy.sol b/KestrelProxy.sol
--- a/KestrelProxy.sol
+++ b/KestrelProxy.sol
@@ -10,9 +10,9 @@
     /// @notice EIP-1967 implementation slot: `keccak256("eip1967.proxy.implementation") - 1`.
     bytes32 private constant IMPLEMENTATION_SLOT =
         0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
-
-    /// @notice The proxy administrator.
-    address private _admin;
+    /// @notice EIP-1967 admin slot: `keccak256("eip1967.proxy.admin") - 1`. The admin lives here,
+    ///         outside the sequential layout, so it cannot collide with implementation storage. [SC10]
+    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
 
     /// @notice Emitted when the implementation changes.
     /// @param implementation The new implementation.
@@ -97,14 +97,20 @@
         _delegate(_getImplementation());
     }
 
-    /// @dev Read the admin.
+    /// @dev Read the admin from the EIP-1967 admin slot. [SC10]
     function _getAdmin() private view returns (address account) {
-        account = _admin;
+        // Reads one fixed storage slot; no memory is touched.
+        assembly ("memory-safe") {
+            account := sload(ADMIN_SLOT)
+        }
     }
 
-    /// @dev Write the admin.
+    /// @dev Write the admin to the EIP-1967 admin slot. [SC10]
     function _setAdmin(address account) private {
-        _admin = account;
+        // Writes one fixed storage slot; no memory is touched.
+        assembly ("memory-safe") {
+            sstore(ADMIN_SLOT, account)
+        }
     }
 
     /// @dev Read the implementation from the EIP-1967 slot.
```
<!-- END:diff-SC10 -->

**Properties.** `invariant_configChangesAuthorized` / `property_configChangesAuthorized`; the
regression's second `initialize` reverts with `AlreadyInitialized()` and slot 0 holds only the flags.

---

### <a id="h-08"></a>H-08 · Relayer signatures lack chain id and nonce (REPLAY)

**Description.** `KestrelRelayer`'s EIP-712 domain omits `chainId` and is cached at deployment, and
the request's `nonce` is never checked or consumed.

**Impact.** Anyone who sees one signed request replays it until the deadline, spending the user's
allowance again and again, and the same signature is valid on every other chain or fork.
**Likelihood** high. **Severity: High.**

**Proof of Concept.** [`test/exploits/Replay_CrossChain.t.sol`](../test/exploits/Replay_CrossChain.t.sol)
with [`SignatureReplayer`](../test/attacks/SignatureReplayer.sol).

**Recommended mitigation.** Bind `block.chainid` into the domain (rebuilding it after a fork) and
verify and increment a per-user nonce.

**Fix.**

<!-- BEGIN:diff-REPLAY -->
```diff
diff --git a/KestrelRelayer.sol b/KestrelRelayer.sol
--- a/KestrelRelayer.sol
+++ b/KestrelRelayer.sol
@@ -19,9 +19,9 @@
     /// @notice The pool swaps are routed through.
     KestrelPool public immutable pool;
 
-    /// @notice EIP-712 domain type hash.
+    /// @notice EIP-712 domain type hash. [REPLAY] It binds the chain id.
     bytes32 private constant DOMAIN_TYPEHASH =
-        keccak256("EIP712Domain(string name,string version,address verifyingContract)");
+        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
     /// @notice EIP-712 type hash for {SwapRequest}.
     bytes32 private constant SWAP_REQUEST_TYPEHASH = keccak256(
         "SwapRequest(address user,address tokenIn,uint256 amountIn,uint256 minOut,address to,uint256 nonce,uint256 deadline)"
@@ -33,6 +33,8 @@
 
     /// @notice Domain separator computed at deployment.
     bytes32 private immutable _cachedDomainSeparator;
+    /// @notice Chain id the cached separator was computed for. [REPLAY]
+    uint256 private immutable _cachedChainId;
 
     /// @notice Next nonce each user must sign.
     mapping(address user => uint256 nonce) public nonces;
@@ -70,18 +72,24 @@
     error ExpiredSignature(uint256 deadline);
     /// @notice Thrown when `signature` is not a valid signature by `req.user` over the request.
     error InvalidSignature();
+    /// @notice Thrown when the request's nonce is not the user's current nonce. [REPLAY]
+    /// @param provided Nonce in the request.
+    /// @param expected Current nonce.
+    error InvalidNonce(uint256 provided, uint256 expected);
 
     /// @notice Deploy the relayer.
     /// @param _pool The pool to route swaps through.
     constructor(KestrelPool _pool) {
         pool = _pool;
+        _cachedChainId = block.chainid; // [REPLAY]
         _cachedDomainSeparator = _buildDomainSeparator();
     }
 
     /// @notice The EIP-712 domain separator signatures must use.
     /// @return separator The domain separator.
     function domainSeparator() public view returns (bytes32 separator) {
-        separator = _cachedDomainSeparator;
+        // [REPLAY] Recompute after a fork or on another chain: the separator follows the chain id.
+        separator = block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
     }
 
     /// @notice EIP-712 digest a user signs for `req`.
@@ -116,6 +124,10 @@
         require(
             SignatureChecker.isValidSignatureNow(req.user, hashRequest(req), signature), InvalidSignature()
         );
+        // [REPLAY] Verify and consume the user's nonce: each signature is valid exactly once.
+        uint256 expected = nonces[req.user];
+        require(req.nonce == expected, InvalidNonce(req.nonce, expected));
+        nonces[req.user] = expected + 1;
 
         IERC20(req.tokenIn).safeTransferFrom(req.user, address(this), req.amountIn);
         IERC20(req.tokenIn).forceApprove(address(pool), req.amountIn);
@@ -125,6 +137,8 @@
 
     /// @dev Hash the EIP-712 domain for the current chain.
     function _buildDomainSeparator() private view returns (bytes32 separator) {
-        separator = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, address(this)));
+        // [REPLAY] `block.chainid` is part of the domain, so a signature never transfers across chains.
+        separator =
+            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
     }
 }
```
<!-- END:diff-REPLAY -->

**Properties.** `invariant_signaturesSingleUse` / `property_signaturesSingleUse`; regressions: the
replay reverts with `InvalidNonce(0, 1)`, and a signature for the current nonce made on chain A
reverts with `InvalidSignature()` on chain B and succeeds back on A.

---

### <a id="m-01"></a>M-01 · Swap fee bypassed through the batch path (SC02)

**Description.** The batch path prices each step on the full input; the single-swap path deducts
the 0.30 % swap fee first.

**Impact.** Routing through `batchSwap` avoids the fee, so LPs lose the fee revenue on that volume.
No principal is at risk. **Likelihood** high. **Severity: Medium.**

**Proof of Concept.** [`test/exploits/SC02_FeeBypass.t.sol`](../test/exploits/SC02_FeeBypass.t.sol)
with [`FeeBypassAttacker`](../test/attacks/FeeBypassAttacker.sol).

**Recommended mitigation.** Charge the same fee on every path.

**Fix.**

<!-- BEGIN:diff-SC02 -->
```diff
diff --git a/KestrelPool.sol b/KestrelPool.sol
--- a/KestrelPool.sol
+++ b/KestrelPool.sol
@@ -571,7 +571,9 @@
         view
         returns (uint256 outAmt)
     {
-        uint256 outScaled = _outGivenInScaled(aIn, aOut, balIn, balOut, amountIn);
+        // [SC02] Charge the swap fee exactly as the single-swap path does.
+        uint256 amountInNet = _netOfFee(amountIn);
+        uint256 outScaled = _outGivenInScaled(aIn, aOut, balIn, balOut, amountInNet);
         uint256 scaleOut = _scaleOf(aOut);
         outAmt = FixedPointMath.mulDivUp(outScaled, 1, scaleOut);
     }
```
<!-- END:diff-SC02 -->

**Properties.** `invariant_batchMatchesSingleSwap` / `property_batchMatchesSingleSwap`; a regression
and a fuzzed regression show the batch output equals `getAmountOut` for any size and direction.

---

### <a id="m-02"></a>M-02 · Unchecked ETH refund strands funds (SC06)

**Description.** `swapWithNativeSponsor` refunds the ETH overpayment with a low-level call whose
result is ignored.

**Impact.** A caller that cannot receive ETH (many contract wallets and routers) still gets its
swap; the overpayment stays in the pool outside `nativeFeesCollected`, so not even the owner can
recover it. **Likelihood** medium (requires such a caller). **Severity: Medium.**

**Proof of Concept.** [`test/exploits/SC06_UncheckedRefund.t.sol`](../test/exploits/SC06_UncheckedRefund.t.sol)
with [`RefundStrander`](../test/attacks/RefundStrander.sol).

**Recommended mitigation.** Check the refund and revert on failure.

**Fix.**

<!-- BEGIN:diff-SC06 -->
```diff
diff --git a/KestrelPool.sol b/KestrelPool.sol
--- a/KestrelPool.sol
+++ b/KestrelPool.sol
@@ -170,6 +170,8 @@
     /// @param sent Value sent.
     /// @param required Value required.
     error InsufficientNativeFee(uint256 sent, uint256 required);
+    /// @notice Thrown when the native-currency refund of a sponsored swap fails. [SC06]
+    error RefundFailed();
     /// @notice Thrown when a native fee withdrawal transfer fails.
     error NativeTransferFailed();
     /// @notice Thrown when withdrawing more native fees than were collected.
@@ -369,7 +371,9 @@
         emit NativeFeeCollected(msg.sender, nativeSwapFee);
         uint256 refund = msg.value - nativeSwapFee;
         if (refund > 0) {
-            msg.sender.call{ value: refund }("");
+            // [SC06] Check the refund: a failed refund reverts the swap instead of stranding ETH.
+            (bool ok,) = msg.sender.call{ value: refund }("");
+            require(ok, RefundFailed());
         }
     }
```
<!-- END:diff-SC06 -->

**Properties.** `invariant_nativeFeeAccounting` / `property_nativeFeeAccounting`; the regression
reverts with `RefundFailed()`.

---

### <a id="l-01"></a>L-01 · Batch downscaling rounds toward the trader (SC07a)

**Description.** The batch path downscales a step's 18-decimal output to the token's decimals
rounding up, while the single path rounds down (Balancer v2's 2025 exploit attacked rounding in
batch-swap scaling).

**Impact.** At most one unit of a low-decimal output token per batch step (one micro-USDC on the
6-decimal pool). 1,000 swaps extract at most 1,000 units for millions of gas: uneconomic here, but
a correctness bug that compounds with any other precision issue. **Severity: Low.**

**Proof of Concept.** [`test/exploits/SC07a_ScalingRounding.t.sol`](../test/exploits/SC07a_ScalingRounding.t.sol)
with [`BatchRoundingAttacker`](../test/attacks/BatchRoundingAttacker.sol), which drives the reusable
[`PrecisionAmplifier`](../test/helpers/PrecisionAmplifier.sol) over a fee-free 6-decimal pool.

**Recommended mitigation.** Round every output toward the pool.

**Fix.**

<!-- BEGIN:diff-SC07a -->
```diff
diff --git a/KestrelPool.sol b/KestrelPool.sol
--- a/KestrelPool.sol
+++ b/KestrelPool.sol
@@ -589,7 +589,8 @@
         uint256 amountInNet = _netOfFee(amountIn);
         uint256 outScaled = _outGivenInScaled(aIn, aOut, balIn, balOut, amountInNet);
         uint256 scaleOut = _scaleOf(aOut);
-        outAmt = FixedPointMath.mulDivUp(outScaled, 1, scaleOut);
+        // [SC07a] Downscale rounding DOWN, toward the pool, as the single-swap path does.
+        outAmt = outScaled / scaleOut;
     }
 
     /// @dev Input amount net of the swap fee (fee rounded up, in the pool's favor).
```
<!-- END:diff-SC07a -->

**Properties.** `invariant_poolRoundingFavorsPool` / `property_poolRoundingFavorsPool` (the same
amplifier, driven by the stateful handler); a regression and a fuzzed regression measure zero error.

---

### <a id="l-02"></a>L-02 · Vault `withdraw` rounds burned shares down (SC07b)

**Description.** When a share is worth more than one wei, `withdraw` computes the shares to burn
rounding down, so a withdrawal smaller than one share's value burns nothing (Bunni's 2025 exploit
attacked withdrawal rounding).

**Impact.** Each free withdrawal takes less than one share's value in wei; the PoC extracts 500 wei
in 500 calls. With a 1:1 wei-to-share start the share value stays small, so the attack does not pay
for its gas here, but it breaks share-price monotonicity and would be severe where a share is worth
many asset units. **Severity: Low** (re-rated from High in the first draft).

**Proof of Concept.** [`test/exploits/SC07b_VaultRounding.t.sol`](../test/exploits/SC07b_VaultRounding.t.sol)
with [`DustWithdrawAttacker`](../test/attacks/DustWithdrawAttacker.sol), which uses the same
`PrecisionAmplifier`.

**Recommended mitigation.** Round the shares to burn up.

**Fix.**

<!-- BEGIN:diff-SC07b -->
```diff
diff --git a/KestrelVault.sol b/KestrelVault.sol
--- a/KestrelVault.sol
+++ b/KestrelVault.sol
@@ -102,7 +102,9 @@
     function withdraw(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
         require(assets > 0, ZeroAmount());
         require(assets <= totalManaged, InsufficientAssets(assets, totalManaged));
-        shares = FixedPointMath.mulDivDown(assets, totalSupply(), totalManaged);
+        // [SC07b] Round the shares to burn UP, in the vault's favor: any non-zero withdrawal
+        // burns at least one share, so no withdrawal is free.
+        shares = FixedPointMath.mulDivUp(assets, totalSupply(), totalManaged);
         require(balanceOf(msg.sender) >= shares, InsufficientShares(shares, balanceOf(msg.sender)));
         _burn(msg.sender, shares);
         totalManaged -= assets;
```
<!-- END:diff-SC07b -->

**Properties.** `invariant_vaultRoundingFavorsVault`, `invariant_sharePriceMonotonic` and their
Medusa counterparts; Halmos `check_withdrawNeverUnderburnsShares`; regressions measure zero
extracted value and fuzz arbitrary share prices.

---

### Issues found while re-reviewing the first round of fixes

These affected code shared by both trees, so they are not part of the seeded set; they are fixed in
both trees and each has a regression test.

#### <a id="r-01"></a>R-01 · Permissionless oracle `update()` could freeze lending; stale TWAP (High)

The first TWAP oracle let anyone reset its window, after which reads reverted for 30 minutes; the
market priced every account on every health check, so one call every 30 minutes froze all borrows
and collateral withdrawals, debt-free ones included. The average also had no age bound, so a crash
after a quiet month barely moved it. **Fix:** a fixed-period oracle that only closes a full period,
publishes the average of the last completed window, discards windows longer than one hour and
refuses reads older than one hour; the market skips the oracle for accounts without debt or without
ERC-20 collateral. Regressions: [`Review_OracleLiveness.t.sol`](../test/regression/Review_OracleLiveness.t.sol).

#### <a id="r-02"></a>R-02 · First-depositor share inflation in the vault (Medium)

`accrue` raised the share price without minting shares and the first deposit had no protection, so
a front-runner depositing dust and donating could take part of the next deposit. **Fix:** the first
deposit mints 1,000 dead shares, `accrue` requires a non-zero supply and `deposit` takes a
`minShares` bound. Regressions: [`Review_VaultInflation.t.sol`](../test/regression/Review_VaultInflation.t.sol)
(the attacker loses more than 99 % of the donation; `minShares` refuses the manipulated price).

#### <a id="r-03"></a>R-03 · Native sponsor fees locked in the pool (Medium)

`nativeFeesCollected` grew but nothing could withdraw it. **Fix:** owner-only
`withdrawNativeFees(to, amount)` with CEI, an event and a checked transfer; unit-tested.

#### <a id="r-04"></a>R-04 · Proposal existence check fails when the snapshot block is 0 (Low)

`propose` used `snapshot == 0` as "does not exist"; at block 1 the snapshot is 0, so an identical
proposal in the same block overwrote the first and reset its votes. **Fix:** existence is
`deadline != 0`; unit-tested at block 1.

---

### Informational

#### <a id="i-01"></a>I-01 · `KestrelConfig` keeps a sequential, pre-ERC-7201 layout

Intentional: it is the layout SC10 breaks, and it is safe behind the EIP-1967 proxy of v2. The
implementation locks its own initializer in the constructor. A production config should use
namespaced storage and OpenZeppelin's current `Initializable`.

#### <a id="i-02"></a>I-02 · The TWAP needs a keeper, and fails closed

If nobody calls `update()` for an hour, borrows and collateral withdrawals of indebted accounts
revert until a new period is published; debt-free accounts and repayments are unaffected. A
production deployment should fund a keeper.

#### <a id="i-03"></a>I-03 · The emergency path has no timelock or guardian veto

The fix makes the stake durable (50 blocks); it does not delay execution. A holder of 66.66 % of
the supply for 50 blocks can still move the treasury at once, which is the stated purpose of the
path. A timelock or veto would change the trust model and is left as future work.

#### <a id="i-04"></a>I-04 · No liquidations; the ETH price is a trusted parameter

Positions that become unhealthy cannot be liquidated, and the risk owner sets the ETH price used for
vault-share collateral. Both are scope limits of the demo.

#### <a id="i-05"></a>I-05 · The vault is ERC-4626-shaped, not ERC-4626

The asset is native ETH and `withdraw`/`redeem` take no `owner`; integrators must not assume the
ERC-4626 interface.

#### <a id="i-06"></a>I-06 · Vault-share collateral is valued at the vault's share price

The custom detector flags `collateralValue ← convertToAssets` on both trees. Reviewed and accepted:
the price moves only by donation, which the dead shares make unprofitable (R-02), and it cannot be
read mid-operation (H-04 fix). Triaged in `slither.triage.json`.

---

### Gas

Figures from the committed gas bench (table below; `test/gas/GasBench.t.sol`).

#### <a id="g-01"></a>G-01 · `batchSwap` pays for the duplicate scan

The O(n²) duplicate check (H-03 fix) and the fee (M-01 fix) add about 1,000 gas to a two-asset
batch. For n ≤ 4 the quadratic scan is cheaper than sorting; a caller-sorted `assets` array checked
in O(n) would be the alternative for larger batches.

#### <a id="g-02"></a>G-02 · The relayer caches its domain separator

The H-08 fix caches the separator together with the chain id it was built for and rebuilds it only
after a fork (OpenZeppelin `EIP712` style) instead of hashing the domain on every call. Most of the
extra cost of `relaySwap` is the nonce SSTORE, which replay protection requires.

#### <a id="g-03"></a>G-03 · 128-bit fast path in `mulDivDown/Up`

When both factors fit in 128 bits the product cannot overflow, so plain arithmetic replaces
Solady's 512-bit routine. Results are identical (fuzzed differential test against Solady), the
common case is cheaper, and the expression stays linear for the Halmos properties.

<!-- BEGIN:gas -->
| Operation (fix it pays for) | v1 gas | v2 gas | Δ | Δ % |
| --- | ---: | ---: | ---: | ---: |
| `KestrelGovernor.emergencyExecute [SC04]` | 67,760 | 73,231 | +5,471 | +8.1% |
| `KestrelLending.borrow [SC03]` | 128,534 | 128,055 | -479 | -0.4% |
| `KestrelPool.addLiquidityExactShares [SC09]` | 143,989 | 144,108 | +119 | +0.1% |
| `KestrelPool.batchSwap (2 assets, 1 step) [SC02 SC05 SC07a]` | 107,862 | 108,867 | +1,005 | +0.9% |
| `KestrelPool.setRewardRate (owner) [SC01]` | 52,061 | 54,224 | +2,163 | +4.2% |
| `KestrelPool.swap` | 101,867 | 101,868 | +1 | +0.0% |
| `KestrelPool.swapWithNativeSponsor (with refund) [SC06]` | 132,490 | 132,518 | +28 | +0.0% |
| `KestrelProxy -> KestrelConfig.ethPrice [SC10]` | 9,520 | 9,550 | +30 | +0.3% |
| `KestrelRelayer.relaySwap [REPLAY]` | 150,302 | 168,496 | +18,194 | +12.1% |
| `KestrelVault.convertToAssets [SC08]` | 4,915 | 5,064 | +149 | +3.0% |
| `KestrelVault.deposit` | 59,767 | 59,854 | +87 | +0.1% |
| `KestrelVault.redeem [SC08]` | 49,854 | 49,944 | +90 | +0.2% |
| `KestrelVault.withdraw [SC07b]` | 49,827 | 50,076 | +249 | +0.5% |

Measured by `test/gas/GasBench.t.sol` with `vm.snapshotGasLastCall` under each profile; snapshots committed in `gas/vulnerable/` and `gas/fixed/` and checked in CI with `FORGE_SNAPSHOT_CHECK=true`.
<!-- END:gas -->

---

## 6. Tool leads, reconstructed

The reviewer seeded these bugs, so this is not the log of a blind review. It records, for every
lead the tools produced on v1, how it maps to the seeded bugs and how it was confirmed or rejected
with a PoC — the discipline an AI-assisted workflow needs, because a tool's hunch is not a finding.

| Lead source | Lead | Verdict | How confirmed or rejected |
|---|---|---|---|
| `kestrel-spot-price-collateral` | `collateralValue` consumes `spotPrice0In1` | Confirmed → H-01 | A same-transaction pump PoC borrowed the whole market |
| `kestrel-spot-price-collateral` | `collateralValue` consumes `convertToAssets` (both trees) | Accepted risk → I-06 | Donation is unprofitable (R-02 regression); mid-operation reads revert (H-04 fix) |
| `kestrel-unchecked-callback` | `emergencyExecute` gated by `balanceOf` | Confirmed → H-02 | Flash-mint and one-block-loan PoCs drained the treasury |
| Slither `reentrancy-eth` | `KestrelVault.redeem` writes `totalManaged` after the ETH call | Confirmed → H-04 | The redeem callback's borrow used an inflated price |
| Slither `unchecked-lowlevel` | ignored refund in `swapWithNativeSponsor` | Confirmed → M-02 | A wallet without `receive` stranded 5 ETH |
| Slither `arbitrary-send-erc20` | `relaySwap` pulls from `req.user` (both trees) | Rejected as flagged; led to H-08 | `req.user` is the verified signer; reading the domain and the nonce handling found the replay |
| Slither `arbitrary-send-eth` | `emergencyExecute` (both trees) | Rejected as flagged; H-02 is the real issue | Arbitrary execution is the purpose; the weakness is the weight, not the call |
| Foundry invariants (13 failing) | solvency, fee parity, rounding, pro-rata joins, access, quorum, replay, config | Confirmed → all twelve | Each shrunk counterexample was reduced to a direct PoC (e.g. one batch over `[debt, col, debt, debt]` for H-03, a join of exactly 2^128 shares for H-06; triage notes in §7) |
| Medusa (13 failing) | the same 13 rules | Confirmed (same mapping) | Medusa's pro-rata counterexample joined with about 2^151 shares for a few wei |
| Halmos (4 failing) | rounding, flash quorum, checked shift | Confirmed → L-02, H-02, H-06 | Counterexamples: a 256-wei withdrawal that burns 187 shares instead of 188, a flash loan of about 2^127, a value just below 2^192 shifted by 65 bits |
| Manual review | Q128 scaling in `addLiquidityExactShares`; proxy layout against config layout | Confirmed → H-06, H-07 | Read the shift guard against the shift amount, and slot 0 of both contracts |

## 7. Blind tool-detection scoreboard

Each tool ran on both builds with no hint about the bug sites. `scripts/blind-run.sh` stores the
normalized output in [`../scoreboard/evidence/`](../scoreboard/evidence), and `scripts/scoreboard.mjs`
derives the table below from it (also in [`DETECTION_TABLE.md`](../scoreboard/DETECTION_TABLE.md)).

<!-- BEGIN:scoreboard-summary -->
**12/12** seeded bugs were surfaced by at least one tool on the vulnerable build without hints (Foundry inv. 12, Medusa 12, Halmos 3, Slither (std) 2, Slither (custom) 2). Static analysis alone (standard + custom Slither detectors) surfaced **4/12**; the other 8 needed a property written from the specification and a stateful or symbolic tool to falsify it. All 12 are closed by an exploit that passes on v1 and fails on v2 and by attack regressions that pass on v2 and fail on v1.
<!-- END:scoreboard-summary -->

<!-- BEGIN:scoreboard-table -->
**Crediting rule.** A tool is credited with a bug only when (1) its signal is present in the vulnerable-build evidence, (2) the same signal is absent from the fixed-build evidence, and (3) the auditor traced the signal to the bug's root cause, recorded below. Slither signals are keyed by check, function and (for kestrel-* detectors) source, and must point at one of the bug's sites; property signals are keyed by invariant/property name. Every signal that fires on v1 and not on v2 must be attributed to a bug or listed under `unattributed` with a reason. scripts/scoreboard.mjs --check enforces all of this against scoreboard/evidence/.

| Bug | Finding | OWASP SC Top 10:2026 | Title | Foundry inv. | Medusa | Halmos | Slither (std) | Slither (custom) | Exploit v1 ✓ / v2 ✗ | Regression v2 ✓ / v1 ✗ |
| --- | --- | --- | --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `SC01` | [H-05](#h-05) | SC01:2026 Access Control | Unprotected reward-rate setter drains the reward reserve | ✅ | ✅ | — | — | — | 1/1 | 1/1 |
| `SC02` | [M-01](#m-01) | SC02:2026 Business Logic | Swap fee bypassed through the batch path | ✅ | ✅ | — | — | — | 1/1 | 2/2 |
| `SC03` | [H-01](#h-01) | SC03:2026 Price Oracle Manipulation | Lending values collateral at the AMM spot price | ✅ | ✅ | — | — | ✅ | 1/1 | 2/2 |
| `SC04` | [H-02](#h-02) | SC04:2026 Flash Loan-Facilitated Attacks | Emergency execution weighs live balances (flash-loan governance) | ✅ | ✅ | ✅ | — | ✅ | 2/2 | 3/3 |
| `SC05` | [H-03](#h-03) | SC05:2026 Lack of Input Validation | Duplicate-asset batchSwap double-counts a reserve | ✅ | ✅ | — | — | — | 1/1 | 1/1 |
| `SC06` | [M-02](#m-02) | SC06:2026 Unchecked External Calls | Unchecked ETH refund strands funds | ✅ | ✅ | — | ✅ | — | 1/1 | 1/1 |
| `SC07a` | [L-01](#l-01) | SC07:2026 Arithmetic Errors | Batch downscaling rounds toward the trader | ✅ | ✅ | — | — | — | 1/1 | 2/2 |
| `SC07b` | [L-02](#l-02) | SC07:2026 Arithmetic Errors | Vault withdraw rounds burned shares down (free dust withdrawals) | ✅ | ✅ | ✅ | — | — | 1/1 | 2/2 |
| `SC08` | [H-04](#h-04) | SC08:2026 Reentrancy | Read-only reentrancy on the vault share price | ✅ | ✅ | — | ✅ | — | 1/1 | 1/1 |
| `SC09` | [H-06](#h-06) | SC09:2026 Integer Overflow and Underflow | Flawed shift guard lets exact-share joins mint for dust (Cetus) | ✅ | ✅ | ✅ | — | — | 3/3 | 3/3 |
| `SC10` | [H-07](#h-07) | SC10:2026 Proxy & Upgradeability | Proxy admin slot collides with the config's initializer flags (Audius) | ✅ | ✅ | — | — | — | 1/1 | 2/2 |
| `REPLAY` | [H-08](#h-08) | SC02:2026 Business Logic (signature replay) | Relayer signatures lack chain id and nonce (replay) | ✅ | ✅ | — | — | — | 1/1 | 2/2 |

**12/12** seeded bugs were surfaced by at least one tool on the vulnerable build without hints (Foundry inv. 12, Medusa 12, Halmos 3, Slither (std) 2, Slither (custom) 2). Static analysis alone (standard + custom Slither detectors) surfaced **4/12**; the other 8 needed a property written from the specification and a stateful or symbolic tool to falsify it. All 12 are closed by an exploit that passes on v1 and fails on v2 and by attack regressions that pass on v2 and fail on v1.

Budgets: Foundry invariants 128 runs x depth 64 (8192 calls, seed 0x4b65737472656c, 1 worker); Medusa 180 s on 4 workers (Medusa 1.5.1 exposes no RNG seed; the corpus is kept as a CI artifact); Halmos 7 properties; Slither 0.11.6 with the kestrel plugin.

### Signals per bug

- `SC01`: Foundry inv. `invariant_privilegedActionsOwnerOnly`; Medusa `property_privilegedActionsOwnerOnly`. The counterexample is a non-owner actor whose setRewardRate call succeeded; the only owner-only entry point without onlyOwner is setRewardRate.
- `SC02`: Foundry inv. `invariant_batchMatchesSingleSwap`; Medusa `property_batchMatchesSingleSwap`. On the 18-decimal main pool the batch output exceeded the single-swap quote by ~0.3% of the input, the swap fee; rounding cannot differ at scale 1, so the excess is the missing fee.
- `SC03`: Foundry inv. `invariant_valuationIgnoresSameBlockSwaps`; Medusa `property_valuationIgnoresSameBlockSwaps`; Slither (custom) `kestrel-spot-price-collateral@KestrelLending.collateralValue(address)#spotPrice0In1`. A same-block swap changed collateralValue; the detector names the source, pool.spotPrice0In1, which disappears once the market reads the TWAP oracle.
- `SC04`: Foundry inv. `invariant_treasuryNeedsDurableStake`; Medusa `property_treasuryNeedsDurableStake`; Halmos `check_flashMintCannotPassEmergencyQuorum`; Slither (custom) `kestrel-unchecked-callback@KestrelGovernor.emergencyExecute(address,uint256,bytes)#authorization from a flash-loanable balance`. The treasury moved inside a flash loan through emergencyExecute; the Halmos model is a loan of about 2**127 tokens, and the detector traces the quorum condition to token.balanceOf(msg.sender).
- `SC05`: Foundry inv. `invariant_poolSolvency`; Medusa `property_poolSolvency`. Reduced counterexamples are batches whose asset list repeats a token: settlement writes the token's reserve once per index and the stale last write leaves the recorded reserve above the balance.
- `SC06`: Foundry inv. `invariant_nativeFeeAccounting`; Medusa `property_nativeFeeAccounting`; Slither (std) `unchecked-lowlevel@KestrelPool.swapWithNativeSponsor(address,uint256,uint256,address)`. The pool held more ETH than its accounted fees after a contract wallet without receive() overpaid; Slither points at the ignored refund call result.
- `SC07a`: Foundry inv. `invariant_poolRoundingFavorsPool`; Medusa `property_poolRoundingFavorsPool`. The precision amplifier measured one 6-decimal unit per tiny batch swap above the single-swap quote on the fee-free pool, where only the downscaling direction differs between the paths.
- `SC07b`: Foundry inv. `invariant_vaultRoundingFavorsVault`; Foundry inv. `invariant_sharePriceMonotonic`; Medusa `property_vaultRoundingFavorsVault`; Medusa `property_sharePriceMonotonic`; Halmos `check_withdrawNeverUnderburnsShares`. Dust withdrawals at a share price above 1 burned zero shares (amplifier error, falling price); the Halmos model withdraws 256 wei at a share price of about 1.37 and burns 187 shares where 188 are owed.
- `SC08`: Foundry inv. `invariant_integratorsSeeConsistentPrice`; Medusa `property_integratorsSeeConsistentPrice`; Slither (std) `reentrancy-eth@KestrelVault.redeem(uint256,address)`. An integrator reading convertToAssets during the redemption's ETH callback saw a price above both the before and after prices; Slither flags totalManaged written after the external call in redeem.
- `SC09`: Foundry inv. `invariant_joinsPayProRata`; Medusa `property_joinsPayProRata`; Halmos `check_checkedShlIsLossless`; Halmos `check_checkedShlFullWord`. Foundry's shrunk counterexample joins with exactly 2**128 shares (the Q128 constant in the bytecode dictionary) and the recorded Medusa run with about 2**151; both pass the top-64-bit guard, wrap the Q128 ratio and pay a few wei. Halmos models a value just below 2**192 shifted by 65 bits, and the same value shifted by a full word.
- `SC10`: Foundry inv. `invariant_configChangesAuthorized`; Medusa `property_configChangesAuthorized`. A random actor's initialize() succeeded through the proxy and replaced the risk owner; reading slot 0 of the proxy showed the admin address where the initializer flags should be.
- `REPLAY`: Foundry inv. `invariant_signaturesSingleUse`; Medusa `property_signaturesSingleUse`. A previously relayed request executed again; Slither's arbitrary-send-erc20 also fires on relaySwap but on both trees, so it is not credited.

### Custom detector precision on the protocol

A hit is a true positive when it is credited above (fires on v1 at the bug site and not on v2); every other hit is a false positive or a triaged accepted risk.

| Detector | v1 hits | True positives | Precision on v1 | v2 hits (triaged) |
| --- | ---: | ---: | ---: | ---: |
| `kestrel-spot-price-collateral` | 2 | 1 | 50% | 1 |
| `kestrel-unchecked-callback` | 1 | 1 | 100% | 0 |
| `kestrel-div-before-mul-loop` | 0 | 0 | n/a | 0 |
<!-- END:scoreboard-table -->

## 8. Appendix — tooling and reproducibility

| Tool | Version | Role |
|---|---|---|
| Foundry | 1.8.3 | exploits, regressions, unit, invariants, gas, coverage, lint |
| Medusa | 1.5.1 (crytic-compile 0.4.2) | stateful property fuzzing |
| Halmos | 0.3.3 (yices) | symbolic properties |
| Slither | 0.11.6 + `kestrel` plugin | static analysis, custom detectors, triage gate |
| Node | 24 | evidence normalization, scoreboard, fix diffs, report tables |

- `node scripts/fixdiffs.mjs --check` regenerates [`diffs/`](diffs) from the trees and proves the
  twelve patches compose into `src/fixed`.
- `node scripts/report.mjs --check` regenerates the nSLOC, gas and embedded-diff blocks of this
  report.
- `node scripts/scoreboard.mjs --check` re-derives §7 from the evidence and fails on any
  unattributed signal, uncredited claim or broken exploit/regression closure.

## References

- OWASP Smart Contract Top 10 (2026) — https://scs.owasp.org/sctop10/
- Beanstalk (2022), flash-loan governance; Audius (2022), proxy storage collision and
  re-initialization; Curve (2022) and Sentiment (2023), read-only reentrancy; Cetus (2025),
  `checked_shlw` overflow; Bunni (2025), withdrawal rounding; Balancer v2 (2025), batch-swap
  scaling and rounding.
- Report structure adapted from the public Cyfrin and Spearbit report templates.
