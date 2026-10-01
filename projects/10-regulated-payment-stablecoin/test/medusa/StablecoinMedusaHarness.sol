// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {Roles} from "../../src/access/Roles.sol";
import {TestPaymentDollarV1} from "../../src/TestPaymentDollarV1.sol";
import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";

/// @notice Smart-contract account driven by the harness. It signs through ERC-1271 by approving digests, so the
///         Medusa campaign exercises the `bytes` / ERC-1271 signature paths without cheatcodes. One instance also
///         acts as governance (ADMIN with the 2-day delay), so the harness never holds ADMIN itself.
contract MedusaActor is IERC1271 {
    address internal immutable HARNESS;
    mapping(bytes32 digest => bool) internal approved;

    error OnlyHarness();

    constructor() {
        HARNESS = msg.sender;
    }

    function approveDigest(bytes32 digest) external {
        require(msg.sender == HARNESS, OnlyHarness());
        approved[digest] = true;
    }

    function exec(address target, bytes calldata data) external returns (bool ok) {
        require(msg.sender == HARNESS, OnlyHarness());
        (ok,) = target.call(data);
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approved[digest] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @notice Medusa harness. Deploys the production wiring (`StablecoinDeployment`): a separate governance account holds
///         ADMIN with the real 2-day delay and the deployer (this harness) renounces ADMIN, exactly as in
///         `Deploy.s.sol`; the harness keeps the operational roles, the attestor key (as an ERC-1271 signer) and the
///         UPGRADER role with its 2-day delay. Five `MedusaActor` smart accounts hold the tokens (two are minters).
///
///         Two kinds of checks run. The `property_` functions (property mode) are evaluated after every call. The
///         actions themselves carry `assert` postconditions (assertion mode): a successful value movement must not
///         have happened while paused or with a restricted party, must move exactly the amount it was asked to and
///         keep the supply consistent; a mint must stay within the attested reserves and consume the allowance;
///         revoking an allowance must never fail; the upgrade must preserve balances and the EIP-712 domain. With
///         `failOnArithmeticUnderflow`, an underflow of the harness's own ghost accounting is reported as well.
contract StablecoinMedusaHarness is IERC1271 {
    bytes32 internal constant ORDER_REF = keccak256("medusa-order");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant TRANSFER_AUTH_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant RECEIVE_AUTH_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant ATTESTATION_TYPEHASH =
        keccak256("ReserveAttestation(uint256 reserves,uint64 asOf,bytes32 reportHash)");
    uint256 internal constant N = 5;

    TestPaymentDollarV1 public token;
    AccessManager public manager;
    MedusaActor[N] public actors;
    MedusaActor public governor;
    mapping(bytes32 digest => bool) internal attestorApproved;

    bytes internal pendingUpgrade;
    bytes internal pendingWiring;
    bool public upgraded;
    bool public wired;

    // ---- ghost state -------------------------------------------------------------------------------------------
    mapping(address account => uint256) public lockedBalance;
    mapping(address minter => bool) public minterConfigured;
    mapping(address minter => uint256) public allowanceBase;
    mapping(address minter => uint256) public mintedSinceConfig;
    uint256 public netIssued;
    bool public supplyIncreasedSinceAttestation;
    bool public movedWhilePaused;
    bool public restrictedMoveSucceeded;

    /// @dev State observed just before a value-moving call.
    struct Pre {
        uint256 fromBalance;
        uint256 toBalance;
        uint256 supply;
        bool paused;
        bool restricted;
    }

    constructor() {
        for (uint256 i; i < N; ++i) {
            actors[i] = new MedusaActor();
        }
        governor = new MedusaActor();
        address[] memory minters = new address[](2);
        minters[0] = address(actors[3]);
        minters[1] = address(actors[4]);
        StablecoinDeployment.Deployment memory d = StablecoinDeployment.deploy(
            StablecoinDeployment.Config({
                deployer: address(this),
                governance: address(governor),
                masterMinter: address(this),
                pauser: address(this),
                blocklister: address(this),
                complianceOfficer: address(this),
                bridge: address(this),
                upgrader: address(this),
                attestor: address(this),
                minters: minters,
                governanceDelay: Roles.GOVERNANCE_DELAY,
                minterLimitCeiling: 2_000_000e6,
                bridgeMintLimit: 3_000_000e6,
                bridgeBurnLimit: 2_000_000e6
            })
        );
        token = d.token;
        manager = d.manager;
        configureMinter(0, 20_000_000e6, 1_000_000e6);
        configureMinter(1, 20_000_000e6, 1_000_000e6);
        attest(10_000_000e6);
    }

    /// @notice The harness is the reserve attestor: it "signs" by approving the digest it is about to submit.
    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return attestorApproved[digest] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    // ============================================================================================================
    // Value-moving actions
    // ============================================================================================================

    function transfer(uint8 from, uint8 to, uint256 amount) external {
        (MedusaActor a, address b) = (_actor(from), address(_actor(to)));
        amount = _clamp(amount, 0, token.balanceOf(address(a)));
        Pre memory p = _pre(address(a), b, false);
        if (a.exec(address(token), abi.encodeCall(token.transfer, (b, amount)))) {
            _assertMoved(p, address(a), b, amount);
        }
    }

    function approve(uint8 owner, uint8 spender, uint256 amount) external {
        (MedusaActor o, address s) = (_actor(owner), address(_actor(spender)));
        bool paused = token.paused();
        bool restricted = _restricted(address(o)) || _restricted(s);
        if (o.exec(address(token), abi.encodeCall(token.approve, (s, amount)))) {
            // Granting needs an unpaused token and unrestricted parties.
            assert(amount == 0 || (!paused && !restricted));
            assert(token.allowance(address(o), s) == amount);
        } else {
            // Revoking is always possible; a grant is refused only while paused or with a restricted party.
            assert(amount != 0 && (paused || restricted));
        }
    }

    function transferFrom(uint8 spender, uint8 from, uint8 to, uint256 amount) external {
        (MedusaActor s, address a, address b) = (_actor(spender), address(_actor(from)), address(_actor(to)));
        amount = _clamp(amount, 0, token.balanceOf(a));
        Pre memory p = _pre(a, b, _restricted(address(s)));
        uint256 allowanceBefore = token.allowance(a, address(s));
        if (s.exec(address(token), abi.encodeCall(token.transferFrom, (a, b, amount)))) {
            _assertMoved(p, a, b, amount);
            _assertAllowanceSpent(a, address(s), allowanceBefore, amount);
        }
    }

    function permitAndTransferFrom(uint8 owner, uint8 spender, uint8 to, uint256 amount) external {
        (MedusaActor o, MedusaActor s, address b) = (_actor(owner), _actor(spender), address(_actor(to)));
        amount = _clamp(amount, 0, token.balanceOf(address(o)));
        uint256 deadline = block.timestamp + 1 hours;
        o.approveDigest(
            _digest(
                keccak256(
                    abi.encode(PERMIT_TYPEHASH, address(o), address(s), amount, token.nonces(address(o)), deadline)
                )
            )
        );
        bool pausedBefore = token.paused();
        bool restrictedBefore = _restricted(address(o)) || _restricted(address(s));
        try token.permit(address(o), address(s), amount, deadline, hex"01") {
            assert(amount == 0 || (!pausedBefore && !restrictedBefore));
            assert(token.allowance(address(o), address(s)) == amount);
        } catch {
            return;
        }
        Pre memory p = _pre(address(o), b, _restricted(address(s)));
        if (s.exec(address(token), abi.encodeCall(token.transferFrom, (address(o), b, amount)))) {
            _assertMoved(p, address(o), b, amount);
            _assertAllowanceSpent(address(o), address(s), amount, amount);
        }
    }

    function transferWithAuthorization(uint8 from, uint8 to, uint256 amount, bytes32 nonce) external {
        (MedusaActor a, address b) = (_actor(from), address(_actor(to)));
        amount = _clamp(amount, 0, token.balanceOf(address(a)));
        (uint256 va, uint256 vb) = (block.timestamp - 1, block.timestamp + 1 hours);
        a.approveDigest(_digest(keccak256(abi.encode(TRANSFER_AUTH_TYPEHASH, address(a), b, amount, va, vb, nonce))));
        Pre memory p = _pre(address(a), b, false);
        try token.transferWithAuthorization(address(a), b, amount, va, vb, nonce, hex"01") {
            _assertMoved(p, address(a), b, amount);
            assert(token.authorizationState(address(a), nonce));
        } catch {}
    }

    function receiveWithAuthorization(uint8 from, uint8 to, uint256 amount, bytes32 nonce) external {
        (MedusaActor a, MedusaActor b) = (_actor(from), _actor(to));
        amount = _clamp(amount, 0, token.balanceOf(address(a)));
        (uint256 va, uint256 vb) = (block.timestamp - 1, block.timestamp + 1 hours);
        a.approveDigest(
            _digest(keccak256(abi.encode(RECEIVE_AUTH_TYPEHASH, address(a), address(b), amount, va, vb, nonce)))
        );
        bytes memory call = abi.encodeWithSignature(
            "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)",
            address(a),
            address(b),
            amount,
            va,
            vb,
            nonce,
            hex"01"
        );
        Pre memory p = _pre(address(a), address(b), false);
        if (b.exec(address(token), call)) {
            _assertMoved(p, address(a), address(b), amount);
            assert(token.authorizationState(address(a), nonce));
        }
    }

    function mint(uint8 minterIndex, uint8 to, uint256 amount) external {
        MedusaActor m = actors[3 + (minterIndex % 2)];
        address b = address(_actor(to));
        amount = _clamp(amount, 1, 600_000e6);
        Pre memory p = _pre(address(m), b, false);
        uint256 allowanceBefore = token.minterAllowance(address(m));
        if (m.exec(address(token), abi.encodeCall(token.mint, (b, amount)))) {
            _afterMove(p.paused, p.restricted);
            netIssued += amount;
            mintedSinceConfig[address(m)] += amount;
            supplyIncreasedSinceAttestation = true;
            assert(!p.paused && !p.restricted);
            assert(token.totalSupply() == p.supply + amount);
            assert(token.balanceOf(b) == p.toBalance + amount);
            assert(token.minterAllowance(address(m)) == allowanceBefore - amount);
            _assertWithinReserves();
        }
    }

    function burn(uint8 minterIndex, uint256 amount) external {
        MedusaActor m = actors[3 + (minterIndex % 2)];
        amount = _clamp(amount, 1, token.balanceOf(address(m)));
        Pre memory p = _pre(address(m), address(m), false);
        if (m.exec(address(token), abi.encodeCall(token.burn, (amount)))) {
            _afterMove(p.paused, p.restricted);
            netIssued -= amount;
            assert(!p.paused && !p.restricted);
            assert(token.totalSupply() == p.supply - amount);
            assert(token.balanceOf(address(m)) == p.fromBalance - amount);
        }
    }

    function crosschainMint(uint8 to, uint256 amount) external {
        address b = address(_actor(to));
        amount = _clamp(amount, 1, 800_000e6);
        Pre memory p = _pre(b, b, false);
        try token.crosschainMint(b, amount) {
            _afterMove(p.paused, p.restricted);
            netIssued += amount;
            supplyIncreasedSinceAttestation = true;
            assert(!p.paused && !p.restricted);
            assert(token.totalSupply() == p.supply + amount);
            assert(token.balanceOf(b) == p.toBalance + amount);
            _assertWithinReserves();
        } catch {}
    }

    function crosschainBurn(uint8 from, uint256 amount) external {
        address a = address(_actor(from));
        amount = _clamp(amount, 1, token.balanceOf(a));
        Pre memory p = _pre(a, a, false);
        try token.crosschainBurn(a, amount) {
            _afterMove(p.paused, p.restricted);
            netIssued -= amount;
            assert(!p.paused && !p.restricted);
            assert(token.totalSupply() == p.supply - amount);
            assert(token.balanceOf(a) == p.fromBalance - amount);
        } catch {}
    }

    function seize(uint8 from, uint8 to, uint256 amount) external {
        (address a, address b) = (address(_actor(from)), address(_actor(to)));
        amount = _clamp(amount, 1, token.balanceOf(a));
        Pre memory p = _pre(a, b, false);
        bool sourceFrozen = token.isFrozen(a);
        bool recipientRestricted = _restricted(b);
        try token.seize(a, b, amount, ORDER_REF) {
            if (p.paused) movedWhilePaused = true;
            if (amount > lockedBalance[a]) restrictedMoveSucceeded = true;
            else lockedBalance[a] -= amount;
            // A lawful order: unpaused, from a frozen account, never into a restricted one, exact amounts.
            assert(!p.paused && sourceFrozen && !recipientRestricted);
            assert(token.balanceOf(a) == p.fromBalance - amount);
            assert(token.balanceOf(b) == p.toBalance + amount);
            assert(token.totalSupply() == p.supply);
        } catch {}
    }

    function burnFrozen(uint8 account) external {
        address a = address(_actor(account));
        Pre memory p = _pre(a, a, false);
        bool frozen = token.isFrozen(a);
        try token.burnFrozen(a, ORDER_REF) {
            if (p.paused) movedWhilePaused = true;
            lockedBalance[a] = 0;
            netIssued -= p.fromBalance;
            assert(!p.paused && frozen);
            assert(token.balanceOf(a) == 0);
            assert(token.totalSupply() == p.supply - p.fromBalance);
        } catch {}
    }

    // ============================================================================================================
    // Controls
    // ============================================================================================================

    function freeze(uint8 account) external {
        address a = address(_actor(account));
        bool before = _restricted(a);
        try token.freeze(a, ORDER_REF) {
            if (!before) lockedBalance[a] = token.balanceOf(a);
        } catch {}
    }

    function unfreeze(uint8 account) external {
        try token.unfreeze(address(_actor(account)), ORDER_REF) {} catch {}
    }

    function blocklist(uint8 account) external {
        address a = address(_actor(account));
        bool before = _restricted(a);
        try token.blocklist(a) {
            if (!before) lockedBalance[a] = token.balanceOf(a);
        } catch {}
    }

    function unBlocklist(uint8 account) external {
        try token.unBlocklist(address(_actor(account))) {} catch {}
    }

    function pause() external {
        try token.pause() {} catch {}
    }

    function unpause() external {
        try token.unpause() {} catch {}
    }

    function attest(uint256 reserves) public {
        (, uint64 latest,,) = token.latestReserveAttestation();
        if (block.timestamp <= latest) return;
        uint64 asOf = uint64(block.timestamp);
        attestorApproved[_digest(keccak256(abi.encode(ATTESTATION_TYPEHASH, reserves, asOf, bytes32(0))))] = true;
        try token.submitReserveAttestation(reserves, asOf, bytes32(0), hex"01") {
            supplyIncreasedSinceAttestation = false;
            (uint256 recorded, uint64 recordedAsOf,, uint256 supplyAt) = token.latestReserveAttestation();
            assert(recorded == reserves && recordedAsOf == asOf && supplyAt == token.totalSupply());
        } catch {}
    }

    function configureMinter(uint8 minterIndex, uint256 allowance, uint256 dailyLimit) public {
        address m = address(actors[3 + (minterIndex % 2)]);
        dailyLimit = _clamp(dailyLimit, 0, token.minterLimitCeiling());
        try token.configureMinter(m, allowance, uint208(dailyLimit)) {
            minterConfigured[m] = true;
            allowanceBase[m] = allowance;
            mintedSinceConfig[m] = 0;
            // The token must install exactly what the master minter asked for.
            assert(token.isMinter(m) && token.minterAllowance(m) == allowance);
            assert(token.minterDailyLimit(m) == dailyLimit);
        } catch {}
    }

    function removeMinter(uint8 minterIndex) external {
        address m = address(actors[3 + (minterIndex % 2)]);
        try token.removeMinter(m) {
            minterConfigured[m] = false;
            allowanceBase[m] = 0;
            mintedSinceConfig[m] = 0;
            assert(!token.isMinter(m) && token.minterAllowance(m) == 0 && token.minterDailyLimit(m) == 0);
        } catch {}
    }

    /// @notice Schedules the v1 -> v2 upgrade (UPGRADER, 2-day delay) and, through the governance account, the v2
    ///         selector wiring (ADMIN, 2-day delay); schedules that expired are renewed.
    function scheduleUpgrade() external {
        if (pendingUpgrade.length == 0) {
            pendingUpgrade = StablecoinDeployment.v2UpgradeCalldata(address(new TestPaymentDollarV2()));
            pendingWiring = StablecoinDeployment.v2WiringCalldata(address(token));
        }
        if (!upgraded && manager.getSchedule(manager.hashOperation(address(this), address(token), pendingUpgrade)) == 0)
        {
            manager.schedule(address(token), pendingUpgrade, 0);
        }
        if (
            !wired
                && manager.getSchedule(manager.hashOperation(address(governor), address(manager), pendingWiring)) == 0
        ) {
            governor.exec(
                address(manager), abi.encodeCall(AccessManager.schedule, (address(manager), pendingWiring, 0))
            );
        }
    }

    /// @notice Executes whichever scheduled operation Medusa's random time jumps have made ready. The upgrade must
    ///         preserve the supply, every balance and the EIP-712 domain.
    function executeUpgrade() external {
        if (pendingUpgrade.length == 0) return;
        if (!upgraded) {
            uint256 supply = token.totalSupply();
            uint256[N] memory balances;
            for (uint256 i; i < N; ++i) {
                balances[i] = token.balanceOf(address(actors[i]));
            }
            bytes32 domain = token.DOMAIN_SEPARATOR();
            try manager.execute(address(token), pendingUpgrade) {
                upgraded = true;
                assert(keccak256(bytes(token.implementationVersion())) == keccak256("2"));
                assert(token.totalSupply() == supply && token.DOMAIN_SEPARATOR() == domain);
                for (uint256 i; i < N; ++i) {
                    assert(token.balanceOf(address(actors[i])) == balances[i]);
                }
            } catch {}
        }
        if (!wired) {
            wired = governor.exec(
                address(manager), abi.encodeCall(AccessManager.execute, (address(manager), pendingWiring))
            );
        }
    }

    function setTransferCapFlag(uint8 account, bool flagged) external {
        if (!upgraded) return;
        address a = address(_actor(account));
        try TestPaymentDollarV2(address(token)).setTransferCapFlag(a, flagged) {
            assert(TestPaymentDollarV2(address(token)).isTransferCapFlagged(a) == flagged);
        } catch {}
    }

    // ============================================================================================================
    // Properties
    // ============================================================================================================

    /// I-1: a restricted account's balance only changes through seize / burnFrozen, and never increases.
    function property_restrictedBalancesOnlyMoveThroughLawfulOrders() external view returns (bool) {
        for (uint256 i; i < N; ++i) {
            address a = address(actors[i]);
            if (_restricted(a) && token.balanceOf(a) != lockedBalance[a]) return false;
        }
        return !restrictedMoveSucceeded;
    }

    /// I-2: supply <= attested reserves, unless the latest attestation reported a shortfall (then no growth since).
    function property_supplyBoundedByAttestedReserves() external view returns (bool) {
        (uint256 reserves,,, uint256 supplyAtAttestation) = token.latestReserveAttestation();
        uint256 supply = token.totalSupply();
        if (supplyIncreasedSinceAttestation) return supply <= reserves;
        return supply <= (reserves > supplyAtAttestation ? reserves : supplyAtAttestation);
    }

    /// I-3: remaining allowance + minted since configuration == configured allowance.
    function property_minterAllowanceConservation() external view returns (bool) {
        for (uint256 i = 3; i < N; ++i) {
            address m = address(actors[i]);
            uint256 expected = minterConfigured[m] ? allowanceBase[m] - mintedSinceConfig[m] : 0;
            if (token.minterAllowance(m) != expected) return false;
        }
        return true;
    }

    /// I-5: supply equals the sum of balances and the net of every issuance path.
    function property_supplyAccounting() external view returns (bool) {
        uint256 sum;
        for (uint256 i; i < N; ++i) {
            sum += token.balanceOf(address(actors[i]));
        }
        return sum == token.totalSupply() && netIssued == token.totalSupply();
    }

    /// I-6: nothing moves while paused.
    function property_nothingMovesWhilePaused() external view returns (bool) {
        return !movedWhilePaused;
    }

    // ============================================================================================================
    // Internals
    // ============================================================================================================

    function _pre(address from, address to, bool extraRestricted) internal view returns (Pre memory p) {
        p.fromBalance = token.balanceOf(from);
        p.toBalance = token.balanceOf(to);
        p.supply = token.totalSupply();
        p.paused = token.paused();
        p.restricted = extraRestricted || _restricted(from) || _restricted(to);
    }

    /// @dev Postcondition of a successful ordinary movement of `amount` (I-1 and I-6 checked at the call itself).
    function _assertMoved(Pre memory p, address from, address to, uint256 amount) internal {
        _afterMove(p.paused, p.restricted);
        assert(!p.paused);
        assert(!p.restricted);
        assert(token.totalSupply() == p.supply);
        if (from == to) {
            assert(token.balanceOf(from) == p.fromBalance);
        } else {
            assert(token.balanceOf(from) == p.fromBalance - amount);
            assert(token.balanceOf(to) == p.toBalance + amount);
        }
    }

    /// @dev `transferFrom` consumes exactly `amount` of a finite allowance and leaves an infinite one untouched.
    function _assertAllowanceSpent(address owner, address spender, uint256 before, uint256 amount) internal view {
        uint256 expected = before == type(uint256).max ? before : before - amount;
        assert(token.allowance(owner, spender) == expected);
    }

    /// @dev I-2 at the call: right after a supply increase the supply is covered by the latest attestation.
    function _assertWithinReserves() internal view {
        (uint256 reserves,,,) = token.latestReserveAttestation();
        assert(token.totalSupply() <= reserves);
    }

    function _afterMove(bool wasPaused, bool touchedRestricted) internal {
        if (wasPaused) movedWhilePaused = true;
        if (touchedRestricted) restrictedMoveSucceeded = true;
    }

    function _restricted(address account) internal view returns (bool) {
        return token.isFrozen(account) || token.isBlocklisted(account);
    }

    function _actor(uint8 i) internal view returns (MedusaActor) {
        return actors[i % N];
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
}
