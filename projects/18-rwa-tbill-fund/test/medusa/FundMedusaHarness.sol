// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FundDeployment, FundContracts, FundConfig} from "../../script/FundDeployment.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {IERC7540Deposit} from "../../src/interfaces/IERC7540.sol";
import {ComplianceProbe, MockERC1271Issuer, MockUSDC} from "../mocks/Mocks.sol";

/// @notice Minimal proxy so that the harness can act as several independent wallets without cheatcodes.
contract Actor {
    address internal immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function exec(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        require(msg.sender == owner, "actor: not owner");
        (ok, ret) = target.call(data);
    }
}

/// @title FundMedusaHarness
/// @notice Medusa harness for the compliance and vault invariants. The harness is the fund's governance and holds
///         every operational role; investors are `Actor` proxies. Claims are issued by an ERC-1271 issuer
///         contract, so no signing cheatcode is required. Medusa advances block time between calls, which drives
///         lockups, recovery timelocks and NAV freshness.
/// @dev Two kinds of checks:
///      - Assertion mode (I-1): every action that moves shares or cash first predicts, from an independent model,
///        whether the movement is admissible, and `assert`s after a successful call that it was. The model never
///        asks the token whether an account is eligible: it keeps its own copy of wallet bindings, claim expiries,
///        pending recoveries and retired wallets, updated only from this harness's successful actions.
///      - Property mode: `property_*` functions (I-2, I-3, I-4, I-6, V-1, V-2, V-3) are checked after every call.
contract FundMedusaHarness {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant N = 6;
    uint256 internal constant REQUIRED_TOPICS = 3;
    uint64 internal constant CLAIM_LIFETIME = 36_500 days;
    bytes32 internal constant ORDER_DOC = "ORDER-DOC";

    /// @dev A single-leaf dividend distribution (root = leaf, empty proof).
    struct Dividend {
        uint256 id;
        address account;
        uint256 amount;
    }

    MockUSDC internal usdc;
    FundContracts internal f;
    ComplianceProbe internal probe;
    MockERC1271Issuer internal issuer;

    Actor[] internal actors;
    Actor internal flex;
    bytes32[] internal ids;
    uint16[3] internal countries = [uint16(840), 276, 702];
    uint256 internal claimNonce;
    uint256 internal orderCount;
    Dividend[] internal dividends;

    // Ghost ledger (holdings; see ComplianceHandler for the model).
    mapping(address => bytes32) internal gWalletId;
    mapping(bytes32 => uint256) internal gIdBalance;
    mapping(bytes32 => uint16) internal gIdCountry;

    // Independent eligibility model.
    mapping(address => bytes32) internal gBinding;
    mapping(bytes32 => mapping(uint256 => uint64)) internal gClaimExpiry;
    mapping(address => bool) internal gRetired;
    mapping(address => bool) internal gPending;

    // Ghost cash flows of the vault (V-3).
    uint256 internal gDeposited;
    uint256 internal gToppedUp;
    uint256 internal gPaidOut;

    constructor() {
        usdc = new MockUSDC();
        f = FundDeployment.deploy(
            FundConfig({
                asset: usdc,
                decimals: 6,
                name: "Demo T-Bill Fund Share",
                symbol: "dTBILL",
                initialNav: 1e18,
                lockupPeriod: 1 days,
                fundAdmin: address(this),
                transferAgent: address(this),
                navOracle: address(this),
                complianceOfficer: address(this)
            }),
            address(this)
        );

        issuer = new MockERC1271Issuer();
        f.registry.setTrustedIssuer(address(issuer), (1 << 1) | (1 << 2) | (1 << 3));
        probe = new ComplianceProbe(address(f.engine));
        f.engine.addModule(address(probe));
        f.maxHolders.setCountryCap(702, 2);
        f.documents.setDocument(ORDER_DOC, "ipfs://orders", keccak256("orders"));

        for (uint256 i; i < N; ++i) {
            Actor actor = new Actor();
            actors.push(actor);
            bytes32 id = keccak256(abi.encode("medusa-identity", i));
            ids.push(id);
            _bind(address(actor), id);
            _issue(id, 1, 1);
            _issue(id, 2, 1);
            _issue(id, 3, countries[i % 3]);
        }
        // An actor that is never onboarded, to probe eligibility.
        actors.push(new Actor());
        // A wallet that gets re-bound between identities, even while holding.
        flex = new Actor();
        actors.push(flex);
        _bind(address(flex), ids[0]);
    }

    // ---------------------------------------------------------------- model

    /// @notice Independent eligibility model (bound, every required claim valid, not retired, no pending recovery).
    function expectedEligible(address wallet) public view returns (bool) {
        if (wallet == address(0) || gRetired[wallet] || gPending[wallet]) return false;
        bytes32 id = gBinding[wallet];
        if (id == bytes32(0)) return false;
        for (uint256 topic = 1; topic <= REQUIRED_TOPICS; ++topic) {
            if (gClaimExpiry[id][topic] <= block.timestamp) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------- helpers

    function _bind(address wallet, bytes32 id) internal {
        f.registry.registerWallet(wallet, id);
        gBinding[wallet] = id;
    }

    function _issue(bytes32 identity, uint256 topic, uint32 data) internal returns (bool) {
        IdentityRegistry.Claim memory c = IdentityRegistry.Claim({
            identity: identity,
            topic: topic,
            data: data,
            issuer: address(issuer),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + CLAIM_LIFETIME,
            nonce: ++claimNonce
        });
        issuer.approve(f.registry.claimDigest(c), true);
        try f.registry.addClaim(c, "") {
            gClaimExpiry[identity][topic] = c.expiresAt;
            return true;
        } catch {
            return false;
        }
    }

    function _actor(uint256 seed) internal view returns (Actor) {
        return actors[seed % actors.length];
    }

    function _call(Actor actor, address target, bytes memory data) internal returns (bool ok) {
        (ok,) = actor.exec(target, data);
    }

    function _unfrozen(address account) internal view returns (uint256) {
        uint256 balance = f.share.balanceOf(account);
        uint256 frozen = f.share.getFrozenTokens(account);
        return balance > frozen ? balance - frozen : 0;
    }

    /// @dev Whether a user-initiated debit of `amount` respects the lockup of `from`.
    function _unlocked(address from, uint256 amount) internal view returns (bool) {
        uint256 locked = f.lockup.lockedBalanceOf(from);
        uint256 balance = f.share.balanceOf(from);
        return locked == 0 || amount <= (balance > locked ? balance - locked : 0);
    }

    function _ghostMove(address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 fromId = from == address(0) ? bytes32(0) : gWalletId[from];
        bytes32 toId;
        if (to != address(0)) {
            toId = gWalletId[to];
            if (toId == bytes32(0)) toId = f.registry.identityOf(to);
        }
        bool same = from != address(0) && to != address(0) && fromId == toId;
        if (!same) {
            if (from != address(0)) gIdBalance[fromId] -= amount;
            if (to != address(0)) {
                if (gIdBalance[toId] == 0) gIdCountry[toId] = f.registry.investorCountry(toId);
                gIdBalance[toId] += amount;
            }
        }
        if (from != address(0) && f.share.balanceOf(from) == 0) delete gWalletId[from];
        if (to != address(0) && gWalletId[to] == bytes32(0)) gWalletId[to] = toId;
    }

    // ---------------------------------------------------------------- vault actions

    function subscribe(uint8 who, uint64 assets) external {
        Actor actor = _actor(who);
        uint256 amount = 1 + uint256(assets) % (1_000_000 * USDC);
        bool eligible = expectedEligible(address(actor));
        usdc.mint(address(actor), amount);
        _call(actor, address(usdc), abi.encodeCall(usdc.approve, (address(f.vault), amount)));
        if (_call(
                actor,
                address(f.vault),
                abi.encodeCall(f.vault.requestDeposit, (amount, address(actor), address(actor)))
            )) {
            assert(eligible);
            gDeposited += amount;
        }
    }

    function closeEpoch() external {
        if (f.vault.epochAwaitingSettlement() == 0) f.vault.closeEpoch();
    }

    function postAndSettle(uint256 navSeed) external {
        uint256 epochId = f.vault.epochAwaitingSettlement();
        if (epochId == 0 || block.timestamp <= f.vault.getEpoch(epochId).cutoff) return;
        (, uint64 latestAsOf) = f.vault.latestNav();
        if (block.timestamp <= latestAsOf) return;
        (uint256 minNav, uint256 maxNav) = f.vault.navBounds();
        uint256 nav = minNav + navSeed % (maxNav - minNav + 1);
        f.vault.postNav(uint128(nav), uint64(block.timestamp));
        uint256 topUp = f.vault.getEpoch(epochId).redeemShares * nav / 1e18 + 1;
        usdc.mint(address(f.vault), topUp);
        gToppedUp += topUp;
        f.vault.settleEpoch();
    }

    function claimDeposit(uint8 who, uint8 receiverSeed) external {
        Actor actor = _actor(who);
        address receiver = address(_actor(receiverSeed));
        uint256 claimable = f.vault.maxDeposit(address(actor));
        if (claimable == 0) return;
        bool receiverOk = expectedEligible(receiver);
        uint256 before = f.share.balanceOf(receiver);
        if (_call(
                actor, address(f.vault), abi.encodeCall(IERC7540Deposit.deposit, (claimable, receiver, address(actor)))
            )) {
            assert(receiverOk);
            _ghostMove(address(0), receiver, f.share.balanceOf(receiver) - before);
        }
    }

    function requestRedeem(uint8 who, uint64 amount) external {
        Actor actor = _actor(who);
        uint256 balance = f.share.balanceOf(address(actor));
        if (balance == 0) return;
        uint256 shares = amount % 3 == 0 ? balance : 1 + uint256(amount) % balance;
        bool senderOk = expectedEligible(address(actor));
        uint256 unfrozen = _unfrozen(address(actor));
        bool unlocked = _unlocked(address(actor), shares);
        if (_call(
                actor, address(f.vault), abi.encodeCall(f.vault.requestRedeem, (shares, address(actor), address(actor)))
            )) {
            assert(senderOk && shares <= unfrozen && unlocked);
            _ghostMove(address(actor), address(0), shares);
        }
    }

    function claimRedeem(uint8 who, uint8 receiverSeed) external {
        Actor actor = _actor(who);
        address receiver = address(_actor(receiverSeed));
        uint256 shares = f.vault.maxRedeem(address(actor));
        if (shares == 0) return;
        bool receiverOk = expectedEligible(receiver);
        (bool ok, bytes memory ret) =
            actor.exec(address(f.vault), abi.encodeCall(f.vault.redeem, (shares, receiver, address(actor))));
        if (ok) {
            assert(receiverOk);
            gPaidOut += abi.decode(ret, (uint256));
        }
    }

    // ---------------------------------------------------------------- share movements

    function transfer(uint8 fromSeed, uint8 toSeed, uint64 amount) external {
        Actor from = _actor(fromSeed);
        address to = address(_actor(toSeed));
        uint256 balance = f.share.balanceOf(address(from));
        uint256 value = amount % 3 == 0 ? balance : (balance == 0 ? 0 : uint256(amount) % (balance + 1));
        bool allowed = expectedEligible(address(from)) && expectedEligible(to) && value <= _unfrozen(address(from))
            && _unlocked(address(from), value);
        bool predicted = f.share.canTransfer(address(from), to, value);
        if (_call(from, address(f.share), abi.encodeCall(f.share.transfer, (to, value)))) {
            assert(allowed && predicted);
            _ghostMove(address(from), to, value);
        } else {
            assert(!predicted);
        }
    }

    function transferFrom(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint64 amount) external {
        Actor owner = _actor(ownerSeed);
        Actor spender = _actor(spenderSeed);
        address to = address(_actor(toSeed));
        uint256 balance = f.share.balanceOf(address(owner));
        uint256 value = amount % 3 == 0 ? balance : (balance == 0 ? 0 : uint256(amount) % (balance + 1));
        _call(owner, address(f.share), abi.encodeCall(f.share.approve, (address(spender), value)));
        bool allowed = expectedEligible(address(owner)) && expectedEligible(to) && value <= _unfrozen(address(owner))
            && _unlocked(address(owner), value);
        if (_call(spender, address(f.share), abi.encodeCall(f.share.transferFrom, (address(owner), to, value)))) {
            assert(allowed);
            _ghostMove(address(owner), to, value);
        }
    }

    /// @dev The harness issues a lawful order for exactly this movement (fund admin) and executes it (agent).
    function forcedTransfer(uint8 fromSeed, uint8 toSeed, uint64 amount) external {
        address from = address(_actor(fromSeed));
        address to = address(_actor(toSeed));
        uint256 balance = f.share.balanceOf(from);
        uint256 value = amount % 3 == 0 ? balance : (balance == 0 ? 0 : uint256(amount) % (balance + 1));
        bytes32 orderId = keccak256(abi.encode("order", ++orderCount));
        try f.share.issueLawfulOrder(orderId, from, to, value, uint64(block.timestamp + 1 days), ORDER_DOC) {}
        catch {
            return;
        }
        bool receiverOk = expectedEligible(to);
        try f.share.forcedTransfer(from, to, value, orderId) {
            assert(receiverOk);
            _ghostMove(from, to, value);
            try f.share.forcedTransfer(from, to, 1, orderId) {
                assert(false); // an order never authorises more than it names
            } catch {}
        } catch {}
    }

    function freeze(uint8 who, uint64 amount) external {
        f.share.setFrozenTokens(address(_actor(who)), amount);
    }

    // ---------------------------------------------------------------- identity churn

    function changeCountry(uint8 idSeed, uint8 countrySeed) external {
        _issue(ids[idSeed % ids.length], 3, countries[countrySeed % 3]);
    }

    function toggleClaim(uint8 idSeed, bool accreditation) external {
        bytes32 id = ids[idSeed % ids.length];
        uint256 topic = accreditation ? 2 : 1;
        if (gClaimExpiry[id][topic] > block.timestamp) {
            try f.registry.removeClaim(id, topic) {
                gClaimExpiry[id][topic] = 0;
            } catch {}
        } else {
            _issue(id, topic, 1);
        }
    }

    function rebindFlex(uint8 idSeed) external {
        bytes32 id = ids[idSeed % ids.length];
        if (f.registry.identityOf(address(flex)) != bytes32(0)) f.registry.unregisterWallet(address(flex));
        _bind(address(flex), id);
    }

    function initiateRecovery(uint8 who) external {
        address lost = address(_actor(who));
        bytes32 id = f.engine.resolveIdentity(lost);
        if (id == bytes32(0) || actors.length >= 16) return;
        Actor successor = new Actor();
        _bind(address(successor), id);
        actors.push(successor);
        try f.share.initiateRecovery(lost, address(successor), "case") {
            gPending[lost] = true;
        } catch {}
    }

    function vetoRecovery(uint8 who) external {
        Actor lost = _actor(who);
        if (_call(lost, address(f.share), abi.encodeCall(f.share.vetoRecovery, ()))) gPending[address(lost)] = false;
    }

    function executeRecovery(uint8 who) external {
        address lost = address(_actor(who));
        (address successor,,) = f.share.pendingRecovery(lost);
        if (successor == address(0)) return;
        bool receiverOk = expectedEligible(successor);
        uint256 amount = f.share.balanceOf(lost);
        try f.share.executeRecovery(lost) {
            assert(receiverOk);
            gPending[lost] = false;
            gRetired[lost] = true;
            _ghostMove(lost, successor, amount);
        } catch {}
    }

    // ---------------------------------------------------------------- dividends

    function createDividend(uint8 who, uint32 amountSeed) external {
        address account = address(_actor(who));
        uint256 amount = 1 + uint256(amountSeed) % (1000 * USDC);
        usdc.mint(address(this), amount);
        usdc.approve(address(f.distributor), amount);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        uint256 id = f.distributor.createDistribution(leaf, amount, uint64(block.timestamp));
        dividends.push(Dividend({id: id, account: account, amount: amount}));
    }

    function claimDividend(uint8 seed) external {
        if (dividends.length == 0) return;
        Dividend memory d = dividends[seed % dividends.length];
        bool alreadyClaimed = f.distributor.claimed(d.id, d.account);
        address payee = f.share.currentWalletOf(d.account);
        bool frozen = f.share.getFrozenTokens(payee) != 0;
        bool eligible = expectedEligible(payee);
        uint256 cashBefore = usdc.balanceOf(payee);
        try f.distributor.claim(d.id, d.account, d.amount, new bytes32[](0)) returns (address paidTo, bool escrowed) {
            assert(!alreadyClaimed && paidTo == payee);
            if (frozen) assert(escrowed && usdc.balanceOf(payee) == cashBefore);
            else assert(eligible && usdc.balanceOf(payee) == cashBefore + d.amount);
        } catch {
            assert(alreadyClaimed || !(frozen || eligible));
        }
    }

    function releaseEscrow(uint8 who) external {
        address wallet = address(_actor(who));
        if (f.distributor.escrowed(wallet) == 0) return;
        address payee = f.share.currentWalletOf(wallet);
        bool payable_ = f.share.getFrozenTokens(payee) == 0 && expectedEligible(payee);
        try f.distributor.releaseEscrow(wallet) {
            assert(payable_);
        } catch {
            assert(!payable_);
        }
    }

    // ---------------------------------------------------------------- properties

    /// @notice I-2: the probe module (fed only by the engine) mirrors every balance and the supply.
    function property_engineSawEveryMovement() external view returns (bool) {
        for (uint256 i; i < actors.length; ++i) {
            if (probe.mirror(address(actors[i])) != f.share.balanceOf(address(actors[i]))) return false;
        }
        return probe.mirroredSupply() == f.share.totalSupply() && f.engine.trackedSupply() == f.share.totalSupply();
    }

    /// @notice I-3: per-country holder counts equal a recount from the ghost ledger.
    function property_holderCountsExact() external view returns (bool) {
        uint256 total;
        for (uint256 c; c < countries.length; ++c) {
            uint256 expected;
            for (uint256 i; i < ids.length; ++i) {
                if (gIdBalance[ids[i]] != 0 && gIdCountry[ids[i]] == countries[c]) ++expected;
            }
            if (f.engine.holderCount(countries[c]) != expected) return false;
            total += expected;
        }
        return f.engine.totalHolders() == total;
    }

    /// @notice I-4: investor ledger equals the sum of attributed wallet balances.
    function property_investorLedgerMatches() external view returns (bool) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 sum;
            for (uint256 w; w < actors.length; ++w) {
                if (gWalletId[address(actors[w])] == ids[i]) sum += f.share.balanceOf(address(actors[w]));
            }
            if (sum != gIdBalance[ids[i]] || sum != f.engine.investorBalance(ids[i])) return false;
        }
        return true;
    }

    /// @notice I-6: the token's eligibility equals the independent model for every wallet.
    function property_eligibilityMatchesModel() external view returns (bool) {
        for (uint256 i; i < actors.length; ++i) {
            address wallet = address(actors[i]);
            bool expected = expectedEligible(wallet);
            if (f.share.canReceive(wallet) != expected || f.share.canSend(wallet) != expected) return false;
        }
        return true;
    }

    /// @notice V-1: pending deposits plus reserved redemptions are backed by vault assets.
    function property_vaultSolvent() external view returns (bool) {
        return
            usdc.balanceOf(address(f.vault))
                >= f.vault.totalPendingDepositAssets() + f.vault.totalReservedRedeemAssets();
    }

    /// @notice V-2: global pending totals equal the sum over controllers; global claimable totals cover them.
    function property_requestBookkeeping() external view returns (bool) {
        uint256 pendingAssets;
        uint256 pendingShares;
        uint256 claimableShares;
        uint256 claimableAssets;
        for (uint256 i; i < actors.length; ++i) {
            address controller = address(actors[i]);
            pendingAssets += f.vault.pendingDepositRequest(0, controller);
            pendingShares += f.vault.pendingRedeemRequest(0, controller);
            claimableShares += f.vault.maxMint(controller);
            claimableAssets += f.vault.maxWithdraw(controller);
        }
        return f.vault.totalPendingDepositAssets() == pendingAssets
            && f.vault.totalPendingRedeemShares() == pendingShares
            && f.vault.totalClaimableDepositShares() >= claimableShares
            && f.vault.totalReservedRedeemAssets() >= claimableAssets;
    }

    /// @notice V-3: the vault's cash equals deposits plus liquidity top-ups minus redemption payouts, exactly.
    function property_assetConservation() external view returns (bool) {
        return usdc.balanceOf(address(f.vault)) + gPaidOut == gDeposited + gToppedUp;
    }
}
