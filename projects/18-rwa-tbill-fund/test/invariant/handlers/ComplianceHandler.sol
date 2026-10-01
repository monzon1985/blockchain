// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {FundContracts} from "../../../script/FundDeployment.sol";
import {IdentityRegistry} from "../../../src/identity/IdentityRegistry.sol";
import {MockUSDC} from "../../mocks/Mocks.sol";
import {StandardMerkleTree} from "../../utils/StandardMerkleTree.sol";

/// @notice Roles and keys the handler acts with.
struct HandlerRoles {
    address fundAdmin;
    address transferAgent;
    address navOracle;
    address complianceOfficer;
    address issuer;
    uint256 issuerKey;
}

/// @notice Drives every path that can move shares (transfer, transferFrom, 7540 claim, redemption request,
///         forced transfer, recovery) plus dividend payouts, interleaved with the state changes that make
///         compliance hard to keep straight (freezes, country changes, claim removal and expiry, wallet
///         rebinding, the trading window, time).
/// @dev Every attempted movement is checked against an independent model *before* the call: if the call
///      succeeds although the model says it had to fail, `violations` is incremented. The model never asks the
///      token (`canSend` / `canReceive`) whether an account is eligible, since that would share the code under
///      test: it keeps its own ghost copy of every wallet binding, of the expiry of every required claim, of
///      retired wallets and of the trading window, updated only from the handler's own successful actions (the
///      handler never changes trusted issuers or required topics). A separate ghost ledger (wallet -> identity
///      snapshot, identity -> country snapshot, identity balances) is maintained from observed balance changes
///      and compared with the engine by the invariant functions.
contract ComplianceHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant REQUIRED_TOPICS = 3; // topics 1..3: KYC, accreditation, jurisdiction
    uint64 internal constant CLAIM_LIFETIME = 3650 days;
    bytes32 internal constant ORDER_DOC = "ORDER-DOC";
    uint16[5] internal COUNTRIES = [uint16(840), 276, 702, 826, 250];

    /// @dev A funded dividend distribution and its leaves.
    struct Distribution {
        uint256 id;
        address[] accounts;
        uint256[] amounts;
    }

    FundContracts internal f;
    MockUSDC internal usdc;
    HandlerRoles internal roles;

    address[] public actors;
    bytes32[] public identities;
    address public immutable outsider;
    address public immutable flexWallet;

    // ---------------------------------------------------------------- ghost ledger (holdings)
    mapping(address wallet => bytes32 identity) public gWalletId;
    mapping(bytes32 identity => uint256 balance) public gIdBalance;
    mapping(bytes32 identity => uint16 country) public gIdCountry;

    // ---------------------------------------------------------------- ghost identity model (eligibility)
    mapping(address wallet => bytes32 identity) public gBinding;
    mapping(bytes32 identity => mapping(uint256 topic => uint64 expiresAt)) public gClaimExpiry;
    mapping(address wallet => bool retired) public gRetired;

    // ---------------------------------------------------------------- ghost trading window
    bool public gWindowOn;
    uint8 internal gMask;
    uint32 internal gOpen;
    uint32 internal gClose;

    Distribution[] internal distributions;

    uint256 public violations;
    string public lastViolation;
    uint256 internal claimNonce;
    uint256 internal spareCount;
    uint256 internal orderCount;

    mapping(bytes32 => uint256) public calls;

    constructor(
        FundContracts memory contracts,
        MockUSDC usdc_,
        HandlerRoles memory roles_,
        address[] memory initialActors,
        bytes32[] memory initialIdentities,
        address flexWallet_
    ) {
        f = contracts;
        usdc = usdc_;
        roles = roles_;
        actors = initialActors;
        identities = initialIdentities;
        outsider = makeAddr("outsider");
        actors.push(outsider);
        flexWallet = flexWallet_;

        // Initial state of the identity model, captured once; from here on it evolves only through the handler.
        for (uint256 i; i < actors.length; ++i) {
            gBinding[actors[i]] = f.registry.identityOf(actors[i]);
        }
        for (uint256 i; i < identities.length; ++i) {
            for (uint256 topic = 1; topic <= REQUIRED_TOPICS; ++topic) {
                gClaimExpiry[identities[i]][topic] = f.registry.getClaim(identities[i], topic).expiresAt;
            }
        }
        vm.prank(roles.fundAdmin);
        f.documents.setDocument(ORDER_DOC, "ipfs://orders", keccak256("orders"));
    }

    // ---------------------------------------------------------------- views for invariants and tests

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function identityCount() external view returns (uint256) {
        return identities.length;
    }

    function distributionCount() external view returns (uint256) {
        return distributions.length;
    }

    function distributionAccount(uint256 index, uint256 leaf) external view returns (address) {
        return distributions[index].accounts[leaf];
    }

    function countries() external view returns (uint16[5] memory) {
        return COUNTRIES;
    }

    /// @notice Independent eligibility model: bound to an identity, every required claim unexpired (and never
    ///         removed), not retired by a recovery. Pending recoveries never outlive a handler call.
    function expectedEligible(address wallet) public view returns (bool) {
        if (wallet == address(0) || gRetired[wallet]) return false;
        bytes32 identity = gBinding[wallet];
        if (identity == bytes32(0)) return false;
        for (uint256 topic = 1; topic <= REQUIRED_TOPICS; ++topic) {
            if (gClaimExpiry[identity][topic] <= block.timestamp) return false;
        }
        return true;
    }

    /// @notice Independent model of the trading window (UTC weekday mask and seconds of day).
    function expectedWindowOpen() public view returns (bool) {
        if (!gWindowOn) return true;
        uint256 weekday = (block.timestamp / 1 days + 3) % 7; // 1970-01-01 was a Thursday (Monday = 0)
        uint256 second = block.timestamp % 1 days;
        return (gMask >> weekday) & 1 == 1 && second >= gOpen && second < gClose;
    }

    // ---------------------------------------------------------------- helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _identity(uint256 seed) internal view returns (bytes32) {
        return identities[bound(seed, 0, identities.length - 1)];
    }

    function _flag(bool bad, string memory why) internal {
        if (bad) {
            ++violations;
            lastViolation = why;
        }
    }

    /// @dev One call in four moves the whole balance: full exits are where holder bookkeeping breaks.
    function _amount(uint256 seed, uint256 balance) internal pure returns (uint256) {
        if (seed % 4 == 0) return balance;
        return bound(seed, 0, balance);
    }

    function _unfrozen(address account) internal view returns (uint256) {
        uint256 balance = f.share.balanceOf(account);
        uint256 frozen = f.share.getFrozenTokens(account);
        return balance > frozen ? balance - frozen : 0;
    }

    /// @dev Records a movement of `amount` from `from` to `to` (zero address = mint / burn) in the ghost ledger.
    function _ghostMove(address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 fromId = from == address(0) ? bytes32(0) : gWalletId[from];
        bytes32 toId = bytes32(0);
        if (to != address(0)) {
            toId = gWalletId[to];
            if (toId == bytes32(0)) toId = f.registry.identityOf(to);
        }
        bool sameInvestor = from != address(0) && to != address(0) && fromId == toId;
        if (!sameInvestor) {
            if (from != address(0)) gIdBalance[fromId] -= amount;
            if (to != address(0)) {
                if (gIdBalance[toId] == 0) gIdCountry[toId] = f.registry.investorCountry(toId);
                gIdBalance[toId] += amount;
            }
        }
        if (from != address(0) && f.share.balanceOf(from) == 0) delete gWalletId[from];
        if (to != address(0) && gWalletId[to] == bytes32(0)) gWalletId[to] = toId;
    }

    /// @dev Signs and relays a claim issued now. Only an accepted claim updates the model.
    function _signClaim(bytes32 identity, uint256 topic, uint32 data) internal returns (bool accepted) {
        uint64 expiresAt;
        (accepted, expiresAt) = _relayClaim(identity, topic, data);
        if (accepted) gClaimExpiry[identity][topic] = expiresAt;
    }

    function _relayClaim(bytes32 identity, uint256 topic, uint32 data)
        internal
        returns (bool accepted, uint64 expiresAt)
    {
        IdentityRegistry.Claim memory c = IdentityRegistry.Claim({
            identity: identity,
            topic: topic,
            data: data,
            issuer: roles.issuer,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + CLAIM_LIFETIME,
            nonce: ++claimNonce
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(roles.issuerKey, f.registry.claimDigest(c));
        try f.registry.addClaim(c, abi.encodePacked(r, s, v)) {
            return (true, c.expiresAt);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Registers pre-existing holdings (seeded before the campaign) in the ghost ledger. Not a target.
    function seedGhost(address wallet) external {
        uint256 balance = f.share.balanceOf(wallet);
        if (balance == 0) return;
        bytes32 identity = f.registry.identityOf(wallet);
        gWalletId[wallet] = identity;
        if (gIdBalance[identity] == 0) gIdCountry[identity] = f.registry.investorCountry(identity);
        gIdBalance[identity] += balance;
    }

    // ---------------------------------------------------------------- vault flows (mint / burn)

    /// @dev Request, settle and claim in one step so that issuance happens often within a short sequence.
    function subscribe(uint256 actorSeed, uint256 receiverSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        if (!expectedEligible(actor)) return;
        assets = bound(assets, 1, 1_000_000 * USDC);
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(f.vault), assets);
        try f.vault.requestDeposit(assets, actor, actor) {
            vm.stopPrank();
        } catch {
            vm.stopPrank();
            return; // refused up front (eligibility or a cap at the lowest acceptable NAV)
        }
        this.settleEpoch(assets);
        this.claimDeposit(actorSeed, receiverSeed, type(uint256).max);
        ++calls[keccak256("subscribe")];
    }

    function requestDeposit(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1, 1_000_000 * USDC);
        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(f.vault), assets);
        bool eligible = expectedEligible(actor);
        try f.vault.requestDeposit(assets, actor, actor) {
            ++calls[keccak256("requestDeposit")];
            _flag(!eligible, "subscription accepted for an ineligible controller");
        } catch {}
        vm.stopPrank();
    }

    function settleEpoch(uint256 navSeed) external {
        if (f.vault.epochAwaitingSettlement() == 0) {
            vm.prank(roles.fundAdmin);
            f.vault.closeEpoch();
        }
        vm.warp(block.timestamp + 1 hours);
        (uint256 minNav, uint256 maxNav) = f.vault.navBounds();
        uint128 nav = uint128(bound(navSeed, minNav, maxNav));
        vm.prank(roles.navOracle);
        f.vault.postNav(nav, uint64(block.timestamp));
        // Top up liquidity for redemptions (stands in for the custodian returning assets).
        uint256 redeemShares = f.vault.getEpoch(f.vault.epochAwaitingSettlement()).redeemShares;
        usdc.mint(address(f.vault), redeemShares * nav / 1e18 + 1);
        vm.prank(roles.fundAdmin);
        f.vault.settleEpoch();
        ++calls[keccak256("settleEpoch")];
    }

    /// @dev 7540 claim = mint through the compliance path, to a possibly different (possibly ineligible) receiver.
    function claimDeposit(uint256 actorSeed, uint256 receiverSeed, uint256 pct) external {
        address controller = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        uint256 claimable = f.vault.maxDeposit(controller);
        if (claimable == 0) return;
        uint256 assets = bound(pct, 1, claimable);
        bool receiverOk = expectedEligible(receiver);
        if (gRetired[controller]) {
            // A recovered (retired) wallet has lost its claim rights to its successor.
            vm.prank(controller);
            try f.vault.deposit(assets, receiver, controller) returns (uint256 stolen) {
                _flag(true, "retired wallet claimed a subscription");
                _ghostMove(address(0), receiver, stolen);
                return;
            } catch {}
        }
        uint256 before = f.share.balanceOf(receiver);
        vm.prank(f.share.currentWalletOf(controller)); // claims follow recoveries
        try f.vault.deposit(assets, receiver, controller) returns (uint256 shares) {
            ++calls[keccak256("claimDeposit")];
            _flag(!receiverOk, "mint to ineligible receiver");
            _flag(f.share.balanceOf(receiver) != before + shares, "mint amount mismatch");
            _ghostMove(address(0), receiver, shares);
        } catch {}
    }

    /// @dev A settled subscription that compliance refuses to mint becomes a redemption (no share moves).
    function convertUnclaimable(uint256 actorSeed) external {
        address controller = _actor(actorSeed);
        uint256 supply = f.share.totalSupply();
        vm.prank(f.share.currentWalletOf(controller));
        try f.vault.convertUnclaimableDeposit(controller) returns (uint256 shares) {
            ++calls[keccak256("convert")];
            _flag(shares == 0, "empty conversion");
            _flag(f.share.totalSupply() != supply, "conversion moved shares");
        } catch {}
    }

    function requestRedeem(uint256 actorSeed, uint256 amount) external {
        address owner = _actor(actorSeed);
        uint256 balance = f.share.balanceOf(owner);
        if (balance == 0) return;
        amount = amount % 4 == 0 ? balance : bound(amount, 1, balance);
        bool senderOk = expectedEligible(owner);
        uint256 unfrozen = _unfrozen(owner);
        uint256 locked = f.lockup.lockedBalanceOf(owner);
        vm.prank(owner);
        try f.vault.requestRedeem(amount, owner, owner) {
            ++calls[keccak256("requestRedeem")];
            _flag(!senderOk, "burn by ineligible sender");
            _flag(amount > unfrozen, "burn of frozen shares");
            _flag(locked != 0 && amount + locked > balance, "burn of locked shares");
            _ghostMove(owner, address(0), amount);
        } catch {}
    }

    function claimRedeem(uint256 actorSeed, uint256 receiverSeed) external {
        address controller = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        uint256 shares = f.vault.maxRedeem(controller);
        if (shares == 0) return;
        bool receiverOk = expectedEligible(receiver);
        if (gRetired[controller]) {
            vm.prank(controller);
            try f.vault.redeem(shares, receiver, controller) {
                _flag(true, "retired wallet claimed a redemption");
                return;
            } catch {}
        }
        vm.prank(f.share.currentWalletOf(controller));
        try f.vault.redeem(shares, receiver, controller) {
            ++calls[keccak256("claimRedeem")];
            _flag(!receiverOk, "redemption proceeds to ineligible wallet");
        } catch {}
    }

    // ---------------------------------------------------------------- peer-to-peer

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = f.share.balanceOf(from);
        amount = _amount(amount, balance);
        bool senderOk = expectedEligible(from);
        bool receiverOk = expectedEligible(to);
        bool windowOpen = expectedWindowOpen();
        uint256 unfrozen = _unfrozen(from);
        uint256 locked = f.lockup.lockedBalanceOf(from);
        bool predicted = f.share.canTransfer(from, to, amount);
        vm.prank(from);
        try f.share.transfer(to, amount) {
            ++calls[keccak256("transfer")];
            _flag(!senderOk || !receiverOk, "transfer between ineligible parties");
            _flag(!windowOpen, "transfer outside the trading window");
            _flag(amount > unfrozen, "transfer of frozen shares");
            _flag(locked != 0 && amount + locked > balance, "transfer of locked shares");
            _flag(!predicted, "transfer succeeded although canTransfer said no");
            _ghostMove(from, to, amount);
        } catch {
            _flag(predicted, "canTransfer said yes but the transfer failed");
        }
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        amount = _amount(amount, f.share.balanceOf(owner));
        vm.prank(owner);
        f.share.approve(spender, amount);
        bool senderOk = expectedEligible(owner);
        bool receiverOk = expectedEligible(to);
        bool windowOpen = expectedWindowOpen();
        uint256 unfrozen = _unfrozen(owner);
        uint256 locked = f.lockup.lockedBalanceOf(owner);
        uint256 balance = f.share.balanceOf(owner);
        vm.prank(spender);
        try f.share.transferFrom(owner, to, amount) {
            ++calls[keccak256("transferFrom")];
            _flag(!senderOk || !receiverOk, "transferFrom between ineligible parties");
            _flag(!windowOpen, "transferFrom outside the trading window");
            _flag(amount > unfrozen, "transferFrom of frozen shares");
            _flag(locked != 0 && amount + locked > balance, "transferFrom of locked shares");
            _ghostMove(owner, to, amount);
        } catch {}
    }

    // ---------------------------------------------------------------- enforcement

    /// @dev The fund administrator issues a lawful order for exactly this movement; the transfer agent executes it.
    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = _amount(amount, f.share.balanceOf(from));
        bytes32 orderId = keccak256(abi.encode("order", ++orderCount));
        vm.prank(roles.fundAdmin);
        try f.share.issueLawfulOrder(orderId, from, to, amount, uint64(block.timestamp + 1 days), ORDER_DOC) {}
        catch {
            return; // zero amount or identical parties: no order can name them
        }
        bool receiverOk = expectedEligible(to);
        vm.prank(roles.transferAgent);
        try f.share.forcedTransfer(from, to, amount, orderId) {
            ++calls[keccak256("forcedTransfer")];
            _flag(!receiverOk, "forced transfer to ineligible wallet");
            _ghostMove(from, to, amount);
            vm.prank(roles.transferAgent);
            try f.share.forcedTransfer(from, to, 1, orderId) {
                _flag(true, "lawful order executed beyond its amount");
            } catch {}
        } catch {}
    }

    function freeze(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, 2 * f.share.balanceOf(actor) + 1);
        vm.prank(roles.complianceOfficer);
        f.share.setFrozenTokens(actor, amount);
        ++calls[keccak256("freeze")];
    }

    /// @dev The compliance officer binds a fresh successor wallet; the transfer agent initiates, waits out the
    ///      timelock and executes (or cancels if the successor stopped qualifying meanwhile).
    function recover(uint256 actorSeed) external {
        address lost = _actor(actorSeed);
        bytes32 identity = f.engine.resolveIdentity(lost);
        if (identity == bytes32(0) || actors.length >= 24) return;
        (address pending,,) = f.share.pendingRecovery(lost);
        if (pending != address(0) || f.share.successorOf(lost) != address(0)) return;
        if (block.timestamp < f.share.recoveryCooldownUntil(lost)) return;

        address successor = makeAddr(string.concat("spare", vm.toString(++spareCount)));
        vm.prank(roles.complianceOfficer);
        f.registry.registerWallet(successor, identity);
        gBinding[successor] = identity;
        actors.push(successor);

        vm.startPrank(roles.transferAgent);
        try f.share.initiateRecovery(lost, successor, "case") {
            vm.warp(block.timestamp + 2 days);
            bool receiverOk = expectedEligible(successor);
            uint256 amount = f.share.balanceOf(lost);
            try f.share.executeRecovery(lost) {
                ++calls[keccak256("recover")];
                _flag(!receiverOk, "recovery to ineligible wallet");
                gRetired[lost] = true;
                _ghostMove(lost, successor, amount);
            } catch {
                f.share.cancelRecovery(lost);
            }
        } catch {}
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- identity churn

    function changeCountry(uint256 identitySeed, uint256 countrySeed) external {
        vm.warp(block.timestamp + 1);
        if (_signClaim(_identity(identitySeed), 3, COUNTRIES[bound(countrySeed, 0, 4)])) {
            ++calls[keccak256("changeCountry")];
        }
    }

    /// @dev Removes the KYC or accreditation claim of an identity if the model says it is valid, else renews it.
    function toggleClaim(uint256 identitySeed, uint256 topicSeed) external {
        bytes32 identity = _identity(identitySeed);
        uint256 topic = topicSeed % 2 == 0 ? 1 : 2;
        if (gClaimExpiry[identity][topic] > block.timestamp) {
            vm.prank(roles.complianceOfficer);
            try f.registry.removeClaim(identity, topic) {
                gClaimExpiry[identity][topic] = 0;
                ++calls[keccak256("toggleClaim")];
                // A claim signed no later than the removal (here: in the same second) must not undo it. The model
                // is left untouched, so a revival would also surface as an I-6 mismatch.
                (bool revived,) = _relayClaim(identity, topic, 1);
                _flag(revived, "removed claim revived by a claim signed before the removal");
            } catch {}
        } else {
            vm.warp(block.timestamp + 1); // a claim must be issued after the removal watermark
            if (_signClaim(identity, topic, 1)) ++calls[keccak256("toggleClaim")];
        }
    }

    /// @dev Re-binds the flex wallet to another identity, even while it holds shares.
    function rebindFlexWallet(uint256 identitySeed) external {
        bytes32 identity = _identity(identitySeed);
        vm.startPrank(roles.complianceOfficer);
        if (f.registry.identityOf(flexWallet) != bytes32(0)) f.registry.unregisterWallet(flexWallet);
        f.registry.registerWallet(flexWallet, identity);
        vm.stopPrank();
        gBinding[flexWallet] = identity;
        ++calls[keccak256("rebind")];
    }

    /// @dev One call in three opens a random trading window; the others switch it off.
    function setTransferWindow(uint256 seed, uint256 openSeed, uint256 lengthSeed) external {
        vm.startPrank(roles.complianceOfficer);
        if (seed % 3 == 0) {
            uint8 mask = uint8(bound(seed >> 8, 1, 0x7f));
            uint32 open = uint32(bound(openSeed, 0, 1 days - 1));
            uint32 close = uint32(bound(lengthSeed, open + 1, 1 days));
            f.transferWindow.setWindow(mask, open, close);
            (gWindowOn, gMask, gOpen, gClose) = (true, mask, open, close);
        } else {
            f.transferWindow.disableWindow();
            gWindowOn = false;
        }
        vm.stopPrank();
        ++calls[keccak256("setTransferWindow")];
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 3 days));
        ++calls[keccak256("warp")];
    }

    // ---------------------------------------------------------------- dividends

    /// @dev Funds a distribution with 2 to 4 leaves for distinct actors (a real multi-leaf Merkle tree).
    function createDividend(uint256 seed) external {
        uint256 n = 2 + seed % 3;
        address[] memory accounts = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 start = seed % actors.length;
        uint256 total;
        for (uint256 k; k < n; ++k) {
            accounts[k] = actors[(start + k) % actors.length];
            amounts[k] = bound(uint256(keccak256(abi.encode(seed, k))), 1, 1000 * USDC);
            total += amounts[k];
        }
        (bytes32[] memory tree,) = StandardMerkleTree.build(accounts, amounts);
        usdc.mint(roles.fundAdmin, total);
        vm.startPrank(roles.fundAdmin);
        usdc.approve(address(f.distributor), total);
        uint256 id = f.distributor.createDistribution(tree[0], total, uint64(block.timestamp));
        vm.stopPrank();
        distributions.push();
        Distribution storage dist = distributions[distributions.length - 1];
        dist.id = id;
        dist.accounts = accounts;
        dist.amounts = amounts;
        ++calls[keccak256("createDividend")];
    }

    /// @dev Claims one leaf of a past distribution; one call in four first tries to over-claim with the real proof.
    function claimDividend(uint256 distSeed, uint256 leafSeed, uint256 overclaimSeed) external {
        if (distributions.length == 0) return;
        Distribution storage dist = distributions[distSeed % distributions.length];
        uint256 leaf = leafSeed % dist.accounts.length;
        address account = dist.accounts[leaf];
        uint256 amount = dist.amounts[leaf];
        (bytes32[] memory tree, uint256[] memory index) = StandardMerkleTree.build(dist.accounts, dist.amounts);
        bytes32[] memory proof = StandardMerkleTree.proof(tree, index[leaf]);

        if (overclaimSeed % 4 == 0) {
            try f.distributor.claim(dist.id, account, amount + 1, proof) {
                _flag(true, "dividend over-claim accepted");
            } catch {}
        }

        bool alreadyClaimed = f.distributor.claimed(dist.id, account);
        address payee = f.share.currentWalletOf(account);
        bool frozen = f.share.getFrozenTokens(payee) != 0;
        bool eligible = expectedEligible(payee);
        uint256 cashBefore = usdc.balanceOf(payee);
        uint256 escrowBefore = f.distributor.escrowed(payee);
        try f.distributor.claim(dist.id, account, amount, proof) returns (address paidTo, bool escrowed) {
            ++calls[keccak256("dividendClaim")];
            _flag(alreadyClaimed, "dividend claimed twice");
            _flag(paidTo != payee, "dividend paid to the wrong wallet");
            if (frozen) {
                _flag(!escrowed || f.distributor.escrowed(payee) != escrowBefore + amount, "frozen holder not escrowed");
                _flag(usdc.balanceOf(payee) != cashBefore, "frozen holder paid");
            } else {
                _flag(!eligible, "dividend paid to ineligible wallet");
                _flag(usdc.balanceOf(payee) != cashBefore + amount, "dividend amount mismatch");
            }
        } catch {
            _flag(!alreadyClaimed && (frozen || eligible), "dividend claim failed for a payable holder");
        }
    }

    function releaseEscrow(uint256 actorSeed) external {
        address wallet = _actor(actorSeed);
        if (f.distributor.escrowed(wallet) == 0) return;
        address payee = f.share.currentWalletOf(wallet);
        bool payable_ = f.share.getFrozenTokens(payee) == 0 && expectedEligible(payee);
        try f.distributor.releaseEscrow(wallet) {
            ++calls[keccak256("releaseEscrow")];
            _flag(!payable_, "escrow released to frozen or ineligible wallet");
        } catch {
            _flag(payable_, "escrow release failed for a payable wallet");
        }
    }
}
