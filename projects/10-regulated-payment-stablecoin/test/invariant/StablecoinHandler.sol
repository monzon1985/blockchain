// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {TestPaymentDollarV1} from "../../src/TestPaymentDollarV1.sol";
import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";
import {Roles} from "../../src/access/Roles.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";

/// @notice Stateful fuzzing handler. Every value-moving entry point of the token is reachable (transfer,
///         transferFrom, permit + transferFrom with ECDSA and ERC-1271 permits, both ERC-3009 flavours in both
///         signature encodings, mint, burn, crosschainMint, crosschainBurn, seize, burnFrozen), next to every
///         control that changes who may move value (pause, blocklist, freeze, minter configuration, reserve
///         attestations including shortfalls, time) and a one-shot v1 -> v2 upgrade through the real 2-day schedule.
/// @dev Calls deliberately target restricted accounts and paused states: a revert is the expected outcome and is
///      counted, a success is recorded in ghost state that the invariants then check. Each action wraps the token
///      call in try/catch so ghost variables are only updated for calls that really went through.
contract StablecoinHandler is Test {
    struct Roster {
        address governance;
        address masterMinter;
        address pauser;
        address blocklister;
        address compliance;
        address bridge;
        address upgrader;
        uint256 attestorKey;
    }

    /// @notice The limits the deployment was configured with, passed in by the test rather than read back from the
    ///         token, so that a token installing the wrong limit cannot hide behind its own bookkeeping (I-4).
    struct Limits {
        uint256 minterCeiling;
        uint256 bridgeMint;
        uint256 bridgeBurn;
        uint256 flaggedDaily;
    }

    bytes32 internal constant ORDER_REF = keccak256("invariant-order");
    address internal constant RELAYER = address(0x5E1A7E5);
    string internal constant TRANSFER_BYTES_SIG =
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)";
    string internal constant TRANSFER_VRS_SIG =
        "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)";
    string internal constant RECEIVE_BYTES_SIG =
        "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)";
    string internal constant RECEIVE_VRS_SIG =
        "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)";
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant TRANSFER_AUTH_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant RECEIVE_AUTH_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_AUTH_TYPEHASH = keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");
    bytes32 internal constant ATTESTATION_TYPEHASH =
        keccak256("ReserveAttestation(uint256 reserves,uint64 asOf,bytes32 reportHash)");

    TestPaymentDollarV1 public token;
    AccessManager public manager;
    Roster internal roster;
    Limits internal limits;
    MockERC1271Wallet public wallet;
    uint256 internal walletOwnerKey;

    /// @dev Everyone who can ever hold tokens. Index 3 is the ERC-1271 wallet, 4 and 5 are the minters.
    address[] public holders;
    mapping(address account => uint256) internal keyOf;
    address[2] public minters;

    // ---- ghost state -------------------------------------------------------------------------------------------
    mapping(address account => uint256) public ghostLockedBalance;
    uint256 public ghostMinted;
    uint256 public ghostBurned;
    uint256 public ghostBridgeMinted;
    uint256 public ghostBridgeBurned;
    uint256 public ghostFrozenBurned;
    mapping(address minter => bool) public ghostMinterConfigured;
    mapping(address minter => uint256) public ghostAllowanceBase;
    mapping(address minter => uint256) public ghostMintedSinceConfig;
    /// @dev Daily limit the handler itself configured for each minter (0 after removal): the I-4 reference.
    mapping(address minter => uint256) public ghostMinterDailyLimit;
    bool public ghostSupplyIncreasedSinceAttestation;
    bool public ghostMovedWhilePaused;
    bool public ghostRestrictedMoveSucceeded;
    bool public ghostRollingLimitBreached;
    bool public ghostUpgradeSentinelBroken;
    bool public upgraded;
    address public implementationV2;

    mapping(bytes32 key => uint256[]) internal windowTimes;
    mapping(bytes32 key => uint256[]) internal windowAmounts;

    // ---- metrics -----------------------------------------------------------------------------------------------
    uint256 public movesSucceeded;
    uint256 public restrictedAttemptsBlocked;
    uint256 public lawfulOrdersExecuted;
    uint256 public shortfallAttestations;
    uint256 public callsAfterUpgrade;

    constructor(
        StablecoinDeployment.Deployment memory d,
        Roster memory roster_,
        Limits memory limits_,
        address[] memory eoaHolders,
        uint256[] memory eoaKeys,
        MockERC1271Wallet wallet_,
        uint256 walletOwnerKey_,
        address[2] memory minters_
    ) {
        token = d.token;
        manager = d.manager;
        roster = roster_;
        limits = limits_;
        wallet = wallet_;
        walletOwnerKey = walletOwnerKey_;
        minters = minters_;
        for (uint256 i; i < eoaHolders.length; ++i) {
            holders.push(eoaHolders[i]);
            keyOf[eoaHolders[i]] = eoaKeys[i];
            if (i == 2) holders.push(address(wallet_));
        }
    }

    // ============================================================================================================
    // Value-moving entry points
    // ============================================================================================================

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        (address from, address to) = (_party(fromSeed), _party(toSeed));
        amount = bound(amount, 0, token.balanceOf(from));
        Snapshot memory s = _snap(from, to);
        if (_as(from, abi.encodeCall(token.transfer, (to, amount)))) {
            _recordMove(s, from, amount);
        } else {
            _recordBlocked(s);
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        (address owner, address spender) = (_holder(ownerSeed), _holder(spenderSeed));
        _as(owner, abi.encodeCall(token.approve, (spender, bound(amount, 0, 1e15))));
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        (address spender, address from, address to) = (_party(spenderSeed), _party(fromSeed), _party(toSeed));
        amount = bound(amount, 0, token.balanceOf(from));
        Snapshot memory s = _snap(from, to);
        s.anyRestricted = s.anyRestricted || _restricted(spender);
        if (_as(spender, abi.encodeCall(token.transferFrom, (from, to, amount)))) {
            _recordMove(s, from, amount);
        } else {
            _recordBlocked(s);
        }
    }

    function permitAndTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount, bool asBytes)
        external
    {
        (address owner, address spender, address to) = (_party(ownerSeed), _party(spenderSeed), _party(toSeed));
        amount = bound(amount, 0, token.balanceOf(owner));
        if (!_permit(owner, spender, amount, asBytes || owner == address(wallet))) return;
        Snapshot memory s = _snap(owner, to);
        s.anyRestricted = s.anyRestricted || _restricted(spender);
        if (_as(spender, abi.encodeCall(token.transferFrom, (owner, to, amount)))) {
            _recordMove(s, owner, amount);
        } else {
            _recordBlocked(s);
        }
    }

    function transferWithAuthorization(uint256 fromSeed, uint256 toSeed, uint256 amount, bytes32 nonce, bool asBytes)
        external
    {
        (address from, address to) = (_party(fromSeed), _party(toSeed));
        amount = bound(amount, 0, token.balanceOf(from));
        bytes memory sig = _signAuth(TRANSFER_AUTH_TYPEHASH, from, to, amount, nonce);
        Snapshot memory s = _snap(from, to);
        bytes memory call = asBytes || from == address(wallet)
            ? abi.encodeWithSignature(TRANSFER_BYTES_SIG, from, to, amount, _va(), _vb(), nonce, sig)
            : _withVrs(TRANSFER_VRS_SIG, from, to, amount, nonce, sig);
        if (_as(RELAYER, call)) _recordMove(s, from, amount);
        else _recordBlocked(s);
    }

    function receiveWithAuthorization(uint256 fromSeed, uint256 toSeed, uint256 amount, bytes32 nonce, bool asBytes)
        external
    {
        (address from, address to) = (_party(fromSeed), _party(toSeed));
        amount = bound(amount, 0, token.balanceOf(from));
        bytes memory sig = _signAuth(RECEIVE_AUTH_TYPEHASH, from, to, amount, nonce);
        Snapshot memory s = _snap(from, to);
        bytes memory call = asBytes || from == address(wallet)
            ? abi.encodeWithSignature(RECEIVE_BYTES_SIG, from, to, amount, _va(), _vb(), nonce, sig)
            : _withVrs(RECEIVE_VRS_SIG, from, to, amount, nonce, sig);
        if (_as(to, call)) _recordMove(s, from, amount);
        else _recordBlocked(s);
    }

    function cancelAuthorization(uint256 fromSeed, bytes32 nonce) external {
        address from = _holder(fromSeed);
        bytes memory sig = _signAs(from, _digest(keccak256(abi.encode(CANCEL_AUTH_TYPEHASH, from, nonce))));
        try token.cancelAuthorization(from, nonce, sig) {} catch {}
    }

    function mint(uint256 minterSeed, uint256 toSeed, uint256 amount) external {
        address m = minters[minterSeed % 2];
        address to = _party(toSeed);
        bytes32 key = keccak256(abi.encode("minter", m));
        amount = _sized(amount, key, ghostMinterDailyLimit[m], 600_000e6);
        Snapshot memory s = _snap(m, to);
        vm.prank(m);
        try token.mint(to, amount) {
            _recordMove(s, address(0), 0);
            ghostMinted += amount;
            ghostMintedSinceConfig[m] += amount;
            ghostSupplyIncreasedSinceAttestation = true;
            _recordWindow(key, amount, ghostMinterDailyLimit[m]);
        } catch {
            _recordBlocked(s);
        }
    }

    function burn(uint256 minterSeed, uint256 amount) external {
        address m = minters[minterSeed % 2];
        uint256 balance = token.balanceOf(m);
        amount = bound(amount, 1, balance == 0 ? 1 : balance);
        Snapshot memory s = _snap(m, m);
        vm.prank(m);
        try token.burn(amount) {
            _recordMove(s, m, amount);
            ghostBurned += amount;
        } catch {
            _recordBlocked(s);
        }
    }

    function crosschainMint(uint256 toSeed, uint256 amount) external {
        address to = _party(toSeed);
        amount = _sized(amount, keccak256("bridge-mint"), limits.bridgeMint, 800_000e6);
        Snapshot memory s = _snap(to, to);
        vm.prank(roster.bridge);
        try token.crosschainMint(to, amount) {
            _recordMove(s, address(0), 0);
            ghostBridgeMinted += amount;
            ghostSupplyIncreasedSinceAttestation = true;
            _recordWindow(keccak256("bridge-mint"), amount, limits.bridgeMint);
        } catch {
            _recordBlocked(s);
        }
    }

    function crosschainBurn(uint256 fromSeed, uint256 amount) external {
        address from = _party(fromSeed);
        uint256 balance = token.balanceOf(from);
        amount = _sized(amount, keccak256("bridge-burn"), limits.bridgeBurn, balance == 0 ? 1 : balance);
        Snapshot memory s = _snap(from, from);
        vm.prank(roster.bridge);
        try token.crosschainBurn(from, amount) {
            _recordMove(s, from, amount);
            ghostBridgeBurned += amount;
            _recordWindow(keccak256("bridge-burn"), amount, limits.bridgeBurn);
        } catch {
            _recordBlocked(s);
        }
    }

    function seize(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        // Mostly aim at a frozen source and an unrestricted recipient so lawful orders actually execute; the raw
        // seeds are kept one time in eight so the refusal paths are exercised too.
        (address from, address to) = fromSeed % 8 == 5
            ? (_holder(fromSeed), _holder(toSeed))
            : (_pick(fromSeed, Want.FrozenWithBalance), _pick(toSeed, Want.Unrestricted));
        amount = bound(amount, 1, token.balanceOf(from) + 1);
        bool wasPaused = token.paused();
        vm.prank(roster.compliance);
        try token.seize(from, to, amount, ORDER_REF) {
            if (wasPaused) ghostMovedWhilePaused = true;
            // A seizure larger than the locked balance can only mean the frozen account was credited somehow:
            // record it instead of underflowing (an underflow would revert this call and hide the bug).
            if (amount > ghostLockedBalance[from]) ghostRestrictedMoveSucceeded = true;
            else ghostLockedBalance[from] -= amount;
            ++lawfulOrdersExecuted;
        } catch {}
    }

    function burnFrozen(uint256 seed) external {
        address account = seed % 8 == 5 ? _holder(seed) : _pick(seed, Want.FrozenWithBalance);
        uint256 balance = token.balanceOf(account);
        bool wasPaused = token.paused();
        vm.prank(roster.compliance);
        try token.burnFrozen(account, ORDER_REF) {
            if (wasPaused) ghostMovedWhilePaused = true;
            ghostLockedBalance[account] = 0;
            ghostFrozenBurned += balance;
            ++lawfulOrdersExecuted;
        } catch {}
    }

    // ============================================================================================================
    // Controls
    // ============================================================================================================

    function freeze(uint256 seed) external {
        address account = _holder(seed);
        bool before = _restricted(account);
        vm.prank(roster.compliance);
        try token.freeze(account, ORDER_REF) {
            if (!before) ghostLockedBalance[account] = token.balanceOf(account);
        } catch {}
    }

    function unfreeze(uint256 seed) external {
        address account = _pick(seed, Want.Frozen);
        vm.prank(roster.compliance);
        try token.unfreeze(account, ORDER_REF) {} catch {}
    }

    function blocklist(uint256 seed) external {
        address account = _holder(seed);
        bool before = _restricted(account);
        vm.prank(roster.blocklister);
        try token.blocklist(account) {
            if (!before) ghostLockedBalance[account] = token.balanceOf(account);
        } catch {}
    }

    function unBlocklist(uint256 seed) external {
        address account = _pick(seed, Want.Blocklisted);
        vm.prank(roster.blocklister);
        try token.unBlocklist(account) {} catch {}
    }

    function setPaused(uint256 seed) external {
        // Pause one time in eight so that most sequences still move value. (Residue 5 rather than 0: fuzzers favour
        // 0 and powers of two, which would otherwise make pauses far more frequent than intended.)
        bool pause_ = seed % 8 == 5;
        vm.prank(roster.pauser);
        if (pause_) {
            try token.pause() {} catch {}
        } else {
            try token.unpause() {} catch {}
        }
    }

    function attest(uint256 reservesSeed, uint256 ageSeed) external {
        (, uint64 latest,,) = token.latestReserveAttestation();
        if (block.timestamp <= latest) vm.warp(uint256(latest) + 1);
        uint256 supply = token.totalSupply();
        // One attestation in four reports a shortfall of up to 25 %, the others cover the supply.
        uint256 reserves = reservesSeed % 4 == 3 && supply >= 4
            ? bound(reservesSeed, supply - supply / 4, supply - 1)
            : bound(reservesSeed, supply, supply + 20_000_000e6);
        uint256 maxAge = block.timestamp - latest - 1;
        if (maxAge > 26 hours) maxAge = 26 hours;
        uint64 asOf = uint64(block.timestamp - bound(ageSeed, 0, maxAge));
        bytes32 digest = _digest(keccak256(abi.encode(ATTESTATION_TYPEHASH, reserves, asOf, bytes32(0))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(roster.attestorKey, digest);
        try token.submitReserveAttestation(reserves, asOf, bytes32(0), abi.encodePacked(r, s, v)) {
            ghostSupplyIncreasedSinceAttestation = false;
            if (reserves < supply) ++shortfallAttestations;
        } catch {}
    }

    function configureMinter(uint256 minterSeed, uint256 allowance, uint256 dailyLimit) external {
        address m = minters[minterSeed % 2];
        allowance = bound(allowance, 1_000_000e6, 20_000_000e6);
        // A zero limit (a paused minter) one time in eight; otherwise a usable limit up to the ceiling.
        dailyLimit = dailyLimit % 8 == 5 ? 0 : bound(dailyLimit, 100_000e6, limits.minterCeiling);
        vm.prank(roster.masterMinter);
        try token.configureMinter(m, allowance, uint208(dailyLimit)) {
            ghostMinterConfigured[m] = true;
            ghostAllowanceBase[m] = allowance;
            ghostMintedSinceConfig[m] = 0;
            ghostMinterDailyLimit[m] = dailyLimit;
        } catch {}
    }

    function removeMinter(uint256 minterSeed) external {
        address m = minters[minterSeed % 2];
        vm.prank(roster.masterMinter);
        try token.removeMinter(m) {
            ghostMinterConfigured[m] = false;
            ghostAllowanceBase[m] = 0;
            ghostMintedSinceConfig[m] = 0;
            ghostMinterDailyLimit[m] = 0;
        } catch {}
    }

    function warp(uint256 secondsSeed) external {
        // Usually a few hours (rolling windows slide, attestations age); one time in sixteen a jump of up to 30 h
        // so stale attestations and fully refilled windows are reached as well.
        uint256 maxJump = secondsSeed % 16 == 5 ? 30 hours : 6 hours;
        vm.warp(block.timestamp + bound(secondsSeed, 1, maxJump));
    }

    /// @notice One-shot upgrade through the production procedure (upgrader + governance schedule, 2-day wait,
    ///         execute), with sentinels taken immediately before and checked immediately after.
    function upgradeToV2() external {
        if (upgraded) return;
        Sentinels memory before = _sentinels();

        implementationV2 = address(new TestPaymentDollarV2());
        bytes memory upgradeCall = StablecoinDeployment.v2UpgradeCalldata(implementationV2);
        bytes memory wiringCall = StablecoinDeployment.v2WiringCalldata(address(token));
        vm.prank(roster.upgrader);
        manager.schedule(address(token), upgradeCall, 0);
        vm.prank(roster.governance);
        manager.schedule(address(manager), wiringCall, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        vm.prank(roster.upgrader);
        manager.execute(address(token), upgradeCall);
        vm.prank(roster.governance);
        manager.execute(address(manager), wiringCall);
        upgraded = true;

        if (keccak256(abi.encode(_sentinels())) != keccak256(abi.encode(before))) ghostUpgradeSentinelBroken = true;
    }

    struct Sentinels {
        uint256 supply;
        uint256[] balances;
        uint256[] nonces;
        bool[] restricted;
        uint256[] allowances;
        uint256[2] minterAllowances;
        bytes32 domainSeparator;
    }

    /// @dev Everything the upgrade must preserve: supply, every balance, permit nonce, restriction flag, the
    ///      allowance of each holder towards the next one, minter allowances and the EIP-712 domain.
    function _sentinels() internal view returns (Sentinels memory x) {
        uint256 n = holders.length;
        x.supply = token.totalSupply();
        x.balances = new uint256[](n);
        x.nonces = new uint256[](n);
        x.restricted = new bool[](n);
        x.allowances = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            x.balances[i] = token.balanceOf(holders[i]);
            x.nonces[i] = token.nonces(holders[i]);
            x.restricted[i] = _restricted(holders[i]);
            x.allowances[i] = token.allowance(holders[i], holders[(i + 1) % n]);
        }
        x.minterAllowances = [token.minterAllowance(minters[0]), token.minterAllowance(minters[1])];
        x.domainSeparator = token.DOMAIN_SEPARATOR();
    }

    /// @notice v2 only: flag or unflag a holder for the rolling outflow cap.
    function setTransferCapFlag(uint256 seed, bool flagged) external {
        if (!upgraded) return;
        vm.prank(roster.compliance);
        try TestPaymentDollarV2(address(token)).setTransferCapFlag(_holder(seed), flagged) {} catch {}
    }

    // ============================================================================================================
    // Views used by the invariants
    // ============================================================================================================

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    /// @notice Identifies the end state of a run for the campaign statistics: two `afterInvariant` rows with the same
    ///         fingerprint describe the same run (Foundry calls the hook once more after the last run).
    function runFingerprint() external view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.timestamp,
                token.totalSupply(),
                movesSucceeded,
                restrictedAttemptsBlocked,
                lawfulOrdersExecuted,
                shortfallAttestations,
                callsAfterUpgrade,
                upgraded
            )
        );
    }

    function isRestricted(address account) external view returns (bool) {
        return _restricted(account);
    }

    // ============================================================================================================
    // Internals
    // ============================================================================================================

    struct Snapshot {
        bool wasPaused;
        bool anyRestricted;
    }

    function _snap(address a, address b) internal view returns (Snapshot memory s) {
        s.wasPaused = token.paused();
        s.anyRestricted = _restricted(a) || _restricted(b);
    }

    /// @dev Bookkeeping after a successful movement through `_update`. `from` is the debited holder (or zero).
    function _recordMove(Snapshot memory s, address from, uint256 amount) internal {
        ++movesSucceeded;
        if (upgraded) ++callsAfterUpgrade;
        if (s.wasPaused) ghostMovedWhilePaused = true;
        if (s.anyRestricted) ghostRestrictedMoveSucceeded = true;
        if (upgraded && from != address(0) && TestPaymentDollarV2(address(token)).isTransferCapFlagged(from)) {
            _recordWindow(keccak256(abi.encode("flagged", from)), amount, limits.flaggedDaily);
        }
    }

    function _recordBlocked(Snapshot memory s) internal {
        if (s.anyRestricted) ++restrictedAttemptsBlocked;
    }

    /// @dev Appends a consumption to a reference log and flags a breach if the rolling 24 h sum exceeds `limit`, the
    ///      limit the handler configured (never a value read back from the token under test).
    function _recordWindow(bytes32 key, uint256 amount, uint256 limit) internal {
        windowTimes[key].push(block.timestamp);
        windowAmounts[key].push(amount);
        if (_windowUsed(key) > limit) ghostRollingLimitBreached = true;
    }

    /// @dev Reference usage of a rolling window: the sum of the logged consumptions in (now - 24 h, now], the same
    ///      half-open window `testFuzz_rollingLimitMatchesReferenceModel` checks the limiter against.
    function _windowUsed(bytes32 key) internal view returns (uint256 sum) {
        uint256[] storage times = windowTimes[key];
        for (uint256 i = times.length; i > 0; --i) {
            if (times[i - 1] + 24 hours <= block.timestamp) break;
            sum += windowAmounts[key][i - 1];
        }
    }

    /// @dev Amount for a rate-limited action. Usually random in [1, cap]; one time in eight exactly what the reference
    ///      model says is left in the window (fills it), and one time in eight one unit more than that, which a token
    ///      enforcing the configured limit must refuse. Without these edge probes the random amounts rarely reach a
    ///      limit, and a token that installed a larger limit than configured would go unnoticed by I-4.
    function _sized(uint256 seed, bytes32 key, uint256 limit, uint256 cap) internal view returns (uint256) {
        uint256 mode = seed % 8;
        if (mode == 5 || mode == 3) {
            uint256 used = _windowUsed(key);
            uint256 left = used >= limit ? 0 : limit - used;
            if (mode == 5) return left + 1;
            if (left != 0) return left;
        }
        return bound(seed, 1, cap);
    }

    function _restricted(address account) internal view returns (bool) {
        return token.isFrozen(account) || token.isBlocklisted(account);
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    enum Want {
        Frozen,
        FrozenWithBalance,
        Blocklisted,
        Unrestricted
    }

    /// @dev Half of the time any holder (restricted ones included, to exercise the refusals), half of the time an
    ///      unrestricted one (so that value keeps moving and the invariants see real balance changes).
    function _party(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? _holder(seed / 2) : _pick(seed / 2, Want.Unrestricted);
    }

    /// @dev First holder, scanning from `seed`, in the wanted state; falls back to `_holder(seed)`.
    function _pick(uint256 seed, Want want) internal view returns (address) {
        uint256 n = holders.length;
        for (uint256 i; i < n; ++i) {
            address h = holders[(seed % n + i) % n];
            bool matches;
            if (want == Want.Frozen) matches = token.isFrozen(h);
            else if (want == Want.FrozenWithBalance) matches = token.isFrozen(h) && token.balanceOf(h) > 0;
            else if (want == Want.Blocklisted) matches = token.isBlocklisted(h);
            else matches = !_restricted(h);
            if (matches) return h;
        }
        return _holder(seed);
    }

    /// @dev Performs `data` on the token as `account` (the wallet executes through its owner).
    function _as(address account, bytes memory data) internal returns (bool ok) {
        if (account == address(wallet)) {
            vm.prank(wallet.owner());
            try wallet.execute(address(token), data) {
                ok = true;
            } catch {}
        } else {
            vm.prank(account);
            (ok,) = address(token).call(data);
        }
    }

    /// @dev Signs an EIP-2612 permit as `owner` and submits it through the chosen entry point.
    function _permit(address owner, address spender, uint256 amount, bool asBytes) internal returns (bool) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signAs(
            owner,
            _digest(keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, amount, token.nonces(owner), deadline)))
        );
        bytes memory call = asBytes
            ? abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,bytes)", owner, spender, amount, deadline, sig
            )
            : _permitVrs(owner, spender, amount, deadline, sig);
        (bool ok,) = address(token).call(call);
        return ok;
    }

    function _permitVrs(address owner, address spender, uint256 amount, uint256 deadline, bytes memory sig)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = _split(sig);
        return abi.encodeWithSignature(
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", owner, spender, amount, deadline, v, r, s
        );
    }

    /// @dev Validity window used by every authorization: valid from one second ago for one hour.
    function _va() internal view returns (uint256) {
        return block.timestamp - 1;
    }

    function _vb() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    function _signAuth(bytes32 typehash, address from, address to, uint256 amount, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        return _signAs(from, _digest(keccak256(abi.encode(typehash, from, to, amount, _va(), _vb(), nonce))));
    }

    /// @dev ERC-3009 calldata for the `(v, r, s)` entry point named by `signature`.
    function _withVrs(
        string memory signature,
        address from,
        address to,
        uint256 amount,
        bytes32 nonce,
        bytes memory sig
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = _split(sig);
        return abi.encodeWithSignature(signature, from, to, amount, _va(), _vb(), nonce, v, r, s);
    }

    function _signAs(address account, bytes32 digest) internal view returns (bytes memory) {
        uint256 key = account == address(wallet) ? walletOwnerKey : keyOf[account];
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _split(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }
}
