// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ISchnorrVault} from "../src/ISchnorrVault.sol";
import {SchnorrSecp256k1} from "../src/SchnorrSecp256k1.sol";
import {SchnorrVault} from "../src/SchnorrVault.sol";
import {MockERC20, ReentrantRecipient, RejectingRecipient} from "./utils/Mocks.sol";
import {SchnorrTestBase} from "./utils/SchnorrTestBase.sol";

/// @notice Unit tests: every external function, happy path and every revert.
contract SchnorrVaultTest is SchnorrTestBase {
    SchnorrVault internal vault;
    MockERC20 internal token;
    Key internal group;
    Key internal nextGroup;

    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal relayer = makeAddr("relayer");

    uint256 internal constant ETH_LIMIT = 10 ether;
    uint256 internal constant TOKEN_LIMIT = 1000e18;
    uint256 internal constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        group = makeKey(0xA11CE);
        nextGroup = makeKey(0xB0B);
        token = new MockERC20();
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(token);
        uint256[] memory limits = new uint256[](2);
        limits[0] = ETH_LIMIT;
        limits[1] = TOKEN_LIMIT;
        vault = new SchnorrVault(group.x, group.parity, guardian, tokens, limits);
        vm.deal(address(vault), 100 ether);
        token.mint(address(vault), 1_000_000e18);
    }

    // ------------------------------------------------------------------ helpers

    function _withdraw(ISchnorrVault.WithdrawalIntent memory intent) internal {
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.prank(relayer);
        vault.withdraw(intent, sig);
    }

    function _rotation(Key memory to, uint256 nonce)
        internal
        view
        returns (
            ISchnorrVault.KeyRotation memory r,
            SchnorrSecp256k1.Signature memory current,
            SchnorrSecp256k1.Signature memory next
        )
    {
        r = ISchnorrVault.KeyRotation({
            newPubKeyX: to.x, newPubKeyYParity: to.parity, nonce: nonce, deadline: T0 + 1 hours
        });
        bytes32 digest = vault.hashKeyRotation(r);
        current = schnorrSign(group, digest);
        next = schnorrSign(to, digest);
    }

    function _limitUpdate(address asset, uint256 newLimit, uint256 nonce)
        internal
        view
        returns (ISchnorrVault.DailyLimitUpdate memory u, SchnorrSecp256k1.Signature memory sig)
    {
        u = ISchnorrVault.DailyLimitUpdate({
            token: asset, newLimit: newLimit, nonce: nonce, deadline: T0 + 1 hours
        });
        sig = schnorrSign(group, vault.hashDailyLimitUpdate(u));
    }

    // -------------------------------------------------------------- constructor

    function test_constructorStoresConfiguration() public view {
        (uint256 x, uint8 parity, uint64 epoch) = vault.groupKey();
        assertEq(x, group.x);
        assertEq(parity, group.parity);
        assertEq(epoch, 0);
        assertEq(vault.guardian(), guardian);
        assertEq(vault.owner(), guardian);
        assertEq(vault.dailyLimit(address(0)), ETH_LIMIT);
        assertEq(vault.dailyLimit(address(token)), TOKEN_LIMIT);
        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            vault.eip712Domain();
        assertEq(name, "SchnorrVault");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(vault));
        assertTrue(vault.domainSeparator() != bytes32(0));
    }

    function test_constructorEmitsInitialLimits() public {
        address[] memory tokens = new address[](1);
        uint256[] memory limits = new uint256[](1);
        limits[0] = 7;
        vm.expectEmit(true, false, false, true);
        emit ISchnorrVault.DailyLimitUpdated(address(0), 0, 7);
        new SchnorrVault(group.x, group.parity, guardian, tokens, limits);
    }

    function test_constructorRevertsOnInvalidKey() public {
        address[] memory none = new address[](0);
        uint256[] memory noLimits = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidGroupKey.selector, 0, 0));
        new SchnorrVault(0, 0, guardian, none, noLimits);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidGroupKey.selector, Q, 1));
        new SchnorrVault(Q, 1, guardian, none, noLimits);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidGroupKey.selector, group.x, 2));
        new SchnorrVault(group.x, 2, guardian, none, noLimits);
    }

    function test_constructorRevertsOnLengthMismatch() public {
        address[] memory tokens = new address[](2);
        uint256[] memory limits = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.LengthMismatch.selector, 2, 1));
        new SchnorrVault(group.x, group.parity, guardian, tokens, limits);
    }

    function test_constructorRevertsOnOversizedLimit() public {
        address[] memory tokens = new address[](1);
        uint256[] memory limits = new uint256[](1);
        limits[0] = uint256(type(uint128).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ISchnorrVault.LimitTooLarge.selector, limits[0], type(uint128).max
            )
        );
        new SchnorrVault(group.x, group.parity, guardian, tokens, limits);
    }

    function test_constructorRevertsOnZeroGuardian() public {
        address[] memory none = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SchnorrVault(group.x, group.parity, address(0), none, new uint256[](0));
    }

    // ----------------------------------------------------------------- deposits

    function test_receiveEmitsDeposited() public {
        vm.deal(alice, 1 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.Deposited(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // --------------------------------------------------------------- withdrawals

    function test_withdrawEth() public {
        ISchnorrVault.WithdrawalIntent memory intent =
            withdrawal(alice, address(0), 1 ether, 1, T0 + 1 hours);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ISchnorrVault.Withdrawn(1, address(0), alice, 1 ether);
        _withdraw(intent);
        assertEq(alice.balance, 1 ether);
        assertTrue(vault.isNonceUsed(1));
        assertFalse(vault.isNonceUsed(2));
        assertEq(vault.spentToday(address(0)), 1 ether);
        assertEq(vault.remainingToday(address(0)), ETH_LIMIT - 1 ether);
    }

    function test_withdrawToken() public {
        _withdraw(withdrawal(alice, address(token), 5e18, 7, T0));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(vault.spentToday(address(token)), 5e18);
        assertEq(vault.spentToday(address(0)), 0);
    }

    function test_withdrawAtExactDeadlineSucceeds() public {
        _withdraw(withdrawal(alice, address(0), 1, 1, block.timestamp));
        assertEq(alice.balance, 1);
    }

    function test_withdrawRevertsOnZeroRecipient() public {
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(address(0), address(0), 1, 1, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert(ISchnorrVault.ZeroRecipient.selector);
        vault.withdraw(intent, sig);
    }

    function test_withdrawRevertsOnZeroAmount() public {
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 0, 1, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert(ISchnorrVault.ZeroAmount.selector);
        vault.withdraw(intent, sig);
    }

    function test_withdrawRevertsWhenExpired() public {
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 1, T0 - 1);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.IntentExpired.selector, T0 - 1, T0));
        vault.withdraw(intent, sig);
    }

    function test_withdrawRevertsOnReplay() public {
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 42, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vault.withdraw(intent, sig);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.NonceAlreadyUsed.selector, 42));
        vault.withdraw(intent, sig);
    }

    function test_nonceIsSharedAcrossIntentTypes() public {
        (ISchnorrVault.DailyLimitUpdate memory u, SchnorrSecp256k1.Signature memory sig) =
            _limitUpdate(address(0), 1 ether, 5);
        vault.updateDailyLimit(u, sig);
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 5, T0);
        SchnorrSecp256k1.Signature memory wsig = signWithdrawal(vault, group, intent);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.NonceAlreadyUsed.selector, 5));
        vault.withdraw(intent, wsig);
    }

    function test_withdrawRevertsOnInvalidSignature() public {
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 1, T0);
        bytes32 digest = vault.hashWithdrawal(intent);
        SchnorrSecp256k1.Signature memory sig = schnorrSign(nextGroup, digest);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidSignature.selector, digest));
        vault.withdraw(intent, sig);
        // A signature for a different intent does not transfer.
        SchnorrSecp256k1.Signature memory other =
            signWithdrawal(vault, group, withdrawal(alice, address(0), 2, 1, T0));
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidSignature.selector, digest));
        vault.withdraw(intent, other);
    }

    function test_signatureIsBoundToVaultAndChain() public {
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 1, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        address[] memory none = new address[](1);
        uint256[] memory limits = new uint256[](1);
        limits[0] = 1 ether;
        SchnorrVault twin = new SchnorrVault(group.x, group.parity, guardian, none, limits);
        vm.deal(address(twin), 1 ether);
        bytes32 twinDigest = twin.hashWithdrawal(intent);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidSignature.selector, twinDigest));
        twin.withdraw(intent, sig);
        vm.chainId(1);
        bytes32 otherChain = vault.hashWithdrawal(intent);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidSignature.selector, otherChain));
        vault.withdraw(intent, sig);
    }

    function test_withdrawRevertsOverDailyLimit() public {
        _withdraw(withdrawal(alice, address(0), 6 ether, 1, T0));
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 5 ether, 2, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISchnorrVault.DailyLimitExceeded.selector, address(0), 5 ether, 4 ether
            )
        );
        vault.withdraw(intent, sig);
    }

    function test_unlistedTokenHasZeroLimit() public {
        MockERC20 other = new MockERC20();
        other.mint(address(vault), 1);
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(other), 1, 1, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.DailyLimitExceeded.selector, address(other), 1, 0)
        );
        vault.withdraw(intent, sig);
    }

    function test_dailyLimitResetsAtUtcMidnight() public {
        uint256 midnight = (T0 / 1 days + 1) * 1 days;
        vm.warp(midnight - 1);
        _withdraw(withdrawal(alice, address(0), ETH_LIMIT, 1, midnight + 1 days));
        assertEq(vault.remainingToday(address(0)), 0);
        vm.warp(midnight);
        assertEq(vault.spentToday(address(0)), 0);
        assertEq(vault.remainingToday(address(0)), ETH_LIMIT);
        _withdraw(withdrawal(alice, address(0), ETH_LIMIT, 2, midnight + 1 days));
        assertEq(alice.balance, 2 * ETH_LIMIT);
    }

    function test_withdrawRevertsWhenPaused() public {
        vm.prank(guardian);
        vault.pause();
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 1, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.withdraw(intent, sig);
        vm.prank(guardian);
        vault.unpause();
        vault.withdraw(intent, sig);
        assertEq(alice.balance, 1);
    }

    function test_failedEthTransferBubblesAndKeepsNonce() public {
        RejectingRecipient bad = new RejectingRecipient();
        ISchnorrVault.WithdrawalIntent memory intent =
            withdrawal(address(bad), address(0), 1, 1, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert(RejectingRecipient.NoEth.selector);
        vault.withdraw(intent, sig);
        assertFalse(vault.isNonceUsed(1));
        assertEq(vault.spentToday(address(0)), 0);
    }

    function test_withdrawRevertsWhenVaultIsEmpty() public {
        vm.deal(address(vault), 0);
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1 ether, 1, T0);
        SchnorrSecp256k1.Signature memory sig = signWithdrawal(vault, group, intent);
        vm.expectRevert();
        vault.withdraw(intent, sig);
    }

    function test_reentrancyIsBlocked() public {
        ReentrantRecipient attacker = new ReentrantRecipient();
        ISchnorrVault.WithdrawalIntent memory first =
            withdrawal(address(attacker), address(0), 1 ether, 1, T0);
        ISchnorrVault.WithdrawalIntent memory second =
            withdrawal(address(attacker), address(0), 1 ether, 2, T0);
        attacker.arm(vault, second, signWithdrawal(vault, group, second));
        vault.withdraw(first, signWithdrawal(vault, group, first));
        assertEq(address(attacker).balance, 1 ether);
        assertEq(
            attacker.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertFalse(vault.isNonceUsed(2));
    }

    // ------------------------------------------------------------- key rotation

    function test_rotateGroupKey() public {
        (
            ISchnorrVault.KeyRotation memory r,
            SchnorrSecp256k1.Signature memory current,
            SchnorrSecp256k1.Signature memory next
        ) = _rotation(nextGroup, 9);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.GroupKeyRotated(
            1, group.x, group.parity, nextGroup.x, nextGroup.parity, 9
        );
        vault.rotateGroupKey(r, current, next);
        (uint256 x, uint8 parity, uint64 epoch) = vault.groupKey();
        assertEq(x, nextGroup.x);
        assertEq(parity, nextGroup.parity);
        assertEq(epoch, 1);

        // The old key is now powerless; the new key signs.
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 10, T0);
        SchnorrSecp256k1.Signature memory stale = signWithdrawal(vault, group, intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISchnorrVault.InvalidSignature.selector, vault.hashWithdrawal(intent)
            )
        );
        vault.withdraw(intent, stale);
        vault.withdraw(intent, signWithdrawal(vault, nextGroup, intent));
    }

    function test_rotationRequiresProofOfPossession() public {
        (ISchnorrVault.KeyRotation memory r, SchnorrSecp256k1.Signature memory current,) =
            _rotation(nextGroup, 9);
        bytes32 digest = vault.hashKeyRotation(r);
        // "New key signature" produced by the old group: rejected.
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.InvalidProofOfPossession.selector, digest)
        );
        vault.rotateGroupKey(r, current, current);
    }

    function test_rotationRequiresCurrentKey() public {
        (ISchnorrVault.KeyRotation memory r,, SchnorrSecp256k1.Signature memory next) =
            _rotation(nextGroup, 9);
        bytes32 digest = vault.hashKeyRotation(r);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidSignature.selector, digest));
        vault.rotateGroupKey(r, next, next);
    }

    function test_rotationRevertsOnInvalidOrSameKey() public {
        (ISchnorrVault.KeyRotation memory r, SchnorrSecp256k1.Signature memory c,) =
            _rotation(nextGroup, 9);
        r.newPubKeyX = Q;
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.InvalidGroupKey.selector, Q, r.newPubKeyYParity)
        );
        vault.rotateGroupKey(r, c, c);
        r.newPubKeyX = group.x;
        r.newPubKeyYParity = group.parity;
        vm.expectRevert(ISchnorrVault.RotationToSameKey.selector);
        vault.rotateGroupKey(r, c, c);
    }

    function test_rotationToNegatedKeyIsAllowed() public {
        // Same x, other parity is a different key (the negation); it needs its own PoP.
        Key memory negated = Key({sk: Q - group.sk, x: group.x, parity: group.parity ^ 1});
        (
            ISchnorrVault.KeyRotation memory r,
            SchnorrSecp256k1.Signature memory c,
            SchnorrSecp256k1.Signature memory n
        ) = _rotation(negated, 9);
        vault.rotateGroupKey(r, c, n);
        (, uint8 parity,) = vault.groupKey();
        assertEq(parity, group.parity ^ 1);
    }

    function test_retiredKeysCannotBeReactivated() public {
        (
            ISchnorrVault.KeyRotation memory r,
            SchnorrSecp256k1.Signature memory c,
            SchnorrSecp256k1.Signature memory n
        ) = _rotation(nextGroup, 9);
        vault.rotateGroupKey(r, c, n);
        assertTrue(vault.retiredKey(vault.keyId(group.x, group.parity)));
        assertFalse(vault.retiredKey(vault.keyId(nextGroup.x, nextGroup.parity)));
        // The new group (willingly) tries to rotate back to the retired key.
        ISchnorrVault.KeyRotation memory back = ISchnorrVault.KeyRotation({
            newPubKeyX: group.x, newPubKeyYParity: group.parity, nonce: 10, deadline: T0
        });
        bytes32 digest = vault.hashKeyRotation(back);
        SchnorrSecp256k1.Signature memory byNext = schnorrSign(nextGroup, digest);
        SchnorrSecp256k1.Signature memory byOld = schnorrSign(group, digest);
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.KeyRetired.selector, group.x, group.parity)
        );
        vault.rotateGroupKey(back, byNext, byOld);
    }

    function test_rotationRevertsWhenExpiredOrReplayed() public {
        (
            ISchnorrVault.KeyRotation memory r,
            SchnorrSecp256k1.Signature memory c,
            SchnorrSecp256k1.Signature memory n
        ) = _rotation(nextGroup, 9);
        vm.warp(r.deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.IntentExpired.selector, r.deadline, r.deadline + 1)
        );
        vault.rotateGroupKey(r, c, n);
        vm.warp(T0);
        vault.rotateGroupKey(r, c, n);
        vm.expectRevert(ISchnorrVault.RotationToSameKey.selector);
        vault.rotateGroupKey(r, c, n);
    }

    function test_rotationWorksWhilePaused() public {
        vm.prank(guardian);
        vault.pause();
        (
            ISchnorrVault.KeyRotation memory r,
            SchnorrSecp256k1.Signature memory c,
            SchnorrSecp256k1.Signature memory n
        ) = _rotation(nextGroup, 9);
        vault.rotateGroupKey(r, c, n);
        (,, uint64 epoch) = vault.groupKey();
        assertEq(epoch, 1);
    }

    // ------------------------------------------------------------- daily limits

    function test_limitDecreaseAppliesImmediately() public {
        (ISchnorrVault.DailyLimitUpdate memory u, SchnorrSecp256k1.Signature memory sig) =
            _limitUpdate(address(0), 1 ether, 3);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.DailyLimitDecreased(address(0), ETH_LIMIT, 1 ether, 3);
        vault.updateDailyLimit(u, sig);
        assertEq(vault.dailyLimit(address(0)), 1 ether);
    }

    function test_limitDecreaseBelowSpentBlocksFurtherWithdrawals() public {
        _withdraw(withdrawal(alice, address(0), 3 ether, 1, T0));
        (ISchnorrVault.DailyLimitUpdate memory u, SchnorrSecp256k1.Signature memory sig) =
            _limitUpdate(address(0), 1 ether, 2);
        vault.updateDailyLimit(u, sig);
        assertEq(vault.remainingToday(address(0)), 0);
        ISchnorrVault.WithdrawalIntent memory intent = withdrawal(alice, address(0), 1, 3, T0);
        SchnorrSecp256k1.Signature memory wsig = signWithdrawal(vault, group, intent);
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.DailyLimitExceeded.selector, address(0), 1, 0)
        );
        vault.withdraw(intent, wsig);
    }

    function test_limitIncreaseIsTimeLocked() public {
        (ISchnorrVault.DailyLimitUpdate memory u, SchnorrSecp256k1.Signature memory sig) =
            _limitUpdate(address(0), 50 ether, 3);
        uint64 effectiveAt = uint64(T0 + vault.LIMIT_INCREASE_DELAY());
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.DailyLimitIncreaseQueued(address(0), 50 ether, effectiveAt, 3);
        vault.updateDailyLimit(u, sig);
        assertEq(vault.dailyLimit(address(0)), ETH_LIMIT);
        (uint128 pendingLimit, uint64 activation, uint64 epoch) = vault.pendingLimit(address(0));
        assertEq(epoch, 0);
        assertEq(pendingLimit, 50 ether);
        assertEq(activation, effectiveAt);

        vm.warp(effectiveAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISchnorrVault.IncreaseNotMature.selector, address(0), effectiveAt, effectiveAt - 1
            )
        );
        vault.activateDailyLimit(address(0));

        vm.warp(effectiveAt);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.DailyLimitUpdated(address(0), ETH_LIMIT, 50 ether);
        vm.prank(alice); // permissionless
        vault.activateDailyLimit(address(0));
        assertEq(vault.dailyLimit(address(0)), 50 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.NoPendingIncrease.selector, address(0))
        );
        vault.activateDailyLimit(address(0));
    }

    function test_decreaseCancelsPendingIncrease() public {
        (ISchnorrVault.DailyLimitUpdate memory up, SchnorrSecp256k1.Signature memory s1) =
            _limitUpdate(address(0), 50 ether, 3);
        vault.updateDailyLimit(up, s1);
        (ISchnorrVault.DailyLimitUpdate memory down, SchnorrSecp256k1.Signature memory s2) =
            _limitUpdate(address(0), 2 ether, 4);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.DailyLimitIncreaseCancelled(address(0), 50 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.DailyLimitDecreased(address(0), ETH_LIMIT, 2 ether, 4);
        vault.updateDailyLimit(down, s2);
        (, uint64 activation,) = vault.pendingLimit(address(0));
        assertEq(activation, 0);
        vm.warp(T0 + 3 days);
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.NoPendingIncrease.selector, address(0))
        );
        vault.activateDailyLimit(address(0));
        assertEq(vault.dailyLimit(address(0)), 2 ether);
    }

    function test_limitUpdateReverts() public {
        (ISchnorrVault.DailyLimitUpdate memory u, SchnorrSecp256k1.Signature memory sig) =
            _limitUpdate(address(0), uint256(type(uint128).max) + 1, 3);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISchnorrVault.LimitTooLarge.selector, u.newLimit, type(uint128).max
            )
        );
        vault.updateDailyLimit(u, sig);

        (u, sig) = _limitUpdate(address(0), 1, 3);
        bytes32 digest = vault.hashDailyLimitUpdate(u);
        SchnorrSecp256k1.Signature memory wrong = schnorrSign(nextGroup, digest);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidSignature.selector, digest));
        vault.updateDailyLimit(u, wrong);
    }

    // ------------------------------------------------------------------ guardian

    function test_guardianCanCancelPendingIncrease() public {
        (ISchnorrVault.DailyLimitUpdate memory u, SchnorrSecp256k1.Signature memory sig) =
            _limitUpdate(address(token), 1e30, 3);
        vault.updateDailyLimit(u, sig);
        vm.prank(guardian);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.DailyLimitIncreaseCancelled(address(token), 1e30);
        vault.cancelDailyLimitIncrease(address(token));
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(ISchnorrVault.NoPendingIncrease.selector, address(token))
        );
        vault.cancelDailyLimitIncrease(address(token));
    }

    function test_onlyGuardianCanPauseUnpauseAndCancel() public {
        bytes memory notOwner =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(notOwner);
        vault.pause();
        vm.expectRevert(notOwner);
        vault.unpause();
        vm.expectRevert(notOwner);
        vault.cancelDailyLimitIncrease(address(0));
        vm.expectRevert(notOwner);
        vault.renounceOwnership();
        vm.stopPrank();
    }

    function test_pauseStateMachine() public {
        vm.startPrank(guardian);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.unpause();
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
        vault.unpause();
        vm.stopPrank();
        assertFalse(vault.paused());
    }

    function test_guardianCannotBeRenounced() public {
        vm.prank(guardian);
        vm.expectRevert(ISchnorrVault.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.guardian(), guardian);
    }

    function test_guardianTwoStepTransfer() public {
        vm.prank(guardian);
        vault.transferOwnership(alice);
        assertEq(vault.pendingOwner(), alice);
        assertEq(vault.guardian(), guardian);
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.guardian(), alice);
    }

    function _queueGuardian(address newGuardian, uint256 nonce) internal {
        ISchnorrVault.GuardianUpdate memory u =
            ISchnorrVault.GuardianUpdate({newGuardian: newGuardian, nonce: nonce, deadline: T0});
        vault.queueGuardianReplacement(u, schnorrSign(group, vault.hashGuardianUpdate(u)));
    }

    function test_groupCanReplaceGuardianAfterTheTimeLock() public {
        vm.prank(guardian);
        vault.transferOwnership(relayer); // pending two-step transfer, cleared on replacement
        ISchnorrVault.GuardianUpdate memory u =
            ISchnorrVault.GuardianUpdate({newGuardian: alice, nonce: 77, deadline: T0 + 7 days});
        SchnorrSecp256k1.Signature memory sig = schnorrSign(group, vault.hashGuardianUpdate(u));
        uint64 effectiveAt = uint64(T0 + vault.GUARDIAN_CHANGE_DELAY());
        vm.expectEmit(true, false, false, true, address(vault));
        emit ISchnorrVault.GuardianReplacementQueued(alice, effectiveAt, 77);
        vault.queueGuardianReplacement(u, sig);
        (address queued, uint64 activation, uint64 epoch) = vault.pendingGuardian();
        assertEq(queued, alice);
        assertEq(activation, effectiveAt);
        assertEq(epoch, 0);
        assertEq(vault.guardian(), guardian, "the current guardian stays in charge meanwhile");

        // The current guardian can still act during the delay.
        vm.prank(guardian);
        vault.pause();

        vm.warp(effectiveAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISchnorrVault.GuardianReplacementNotMature.selector, effectiveAt, effectiveAt - 1
            )
        );
        vault.activateGuardianReplacement();

        vm.warp(effectiveAt);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ISchnorrVault.GuardianReplacedByGroup(guardian, alice);
        vm.prank(relayer); // permissionless
        vault.activateGuardianReplacement();
        assertEq(vault.guardian(), alice);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(alice);
        vault.unpause();

        vm.expectRevert(ISchnorrVault.NoPendingGuardianReplacement.selector);
        vault.activateGuardianReplacement();
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.NonceAlreadyUsed.selector, 77));
        vault.queueGuardianReplacement(u, sig);
    }

    function test_queueGuardianReplacementReverts() public {
        ISchnorrVault.GuardianUpdate memory u =
            ISchnorrVault.GuardianUpdate({newGuardian: address(0), nonce: 1, deadline: T0});
        SchnorrSecp256k1.Signature memory sig = schnorrSign(group, vault.hashGuardianUpdate(u));
        vm.expectRevert(ISchnorrVault.ZeroGuardian.selector);
        vault.queueGuardianReplacement(u, sig);
        u.newGuardian = alice;
        bytes32 digest = vault.hashGuardianUpdate(u);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.InvalidSignature.selector, digest));
        vault.queueGuardianReplacement(u, sig);
        vm.expectRevert(ISchnorrVault.NoPendingGuardianReplacement.selector);
        vault.activateGuardianReplacement();
    }

    function test_newerGuardianUpdateSupersedesTheQueuedOne() public {
        _queueGuardian(alice, 1);
        _queueGuardian(relayer, 2);
        vm.warp(T0 + vault.GUARDIAN_CHANGE_DELAY());
        vault.activateGuardianReplacement();
        assertEq(vault.guardian(), relayer);
    }

    /// @notice A key rotation voids every change queued under the retired key, so a
    ///         group that rotates away from a leaked key also discards whatever the
    ///         thief queued (a guardian takeover, a limit raise).
    function test_rotationVoidsQueuedChanges() public {
        _queueGuardian(alice, 1);
        (ISchnorrVault.DailyLimitUpdate memory up, SchnorrSecp256k1.Signature memory s) =
            _limitUpdate(address(0), 1000 ether, 2);
        vault.updateDailyLimit(up, s);
        (
            ISchnorrVault.KeyRotation memory r,
            SchnorrSecp256k1.Signature memory c,
            SchnorrSecp256k1.Signature memory n
        ) = _rotation(nextGroup, 3);
        vault.rotateGroupKey(r, c, n);
        vm.warp(T0 + 3 days);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.QueuedUnderRetiredKey.selector, 0, 1));
        vault.activateGuardianReplacement();
        vm.expectRevert(abi.encodeWithSelector(ISchnorrVault.QueuedUnderRetiredKey.selector, 0, 1));
        vault.activateDailyLimit(address(0));
        assertEq(vault.guardian(), guardian);
        assertEq(vault.dailyLimit(address(0)), ETH_LIMIT);
    }

    // --------------------------------------------------------------------- views

    function test_isNonceUsedCoversTheWholeBitmapWord() public {
        _withdraw(withdrawal(alice, address(0), 1, 255, T0));
        _withdraw(withdrawal(alice, address(0), 1, 256, T0));
        _withdraw(withdrawal(alice, address(0), 1, type(uint256).max, T0));
        assertTrue(vault.isNonceUsed(255));
        assertTrue(vault.isNonceUsed(256));
        assertTrue(vault.isNonceUsed(type(uint256).max));
        assertFalse(vault.isNonceUsed(254));
        assertEq(vault.nonceBitmap(0), uint256(1) << 255);
        assertEq(vault.nonceBitmap(1), 1);
    }

    function test_typeHashesMatchTheirTypeStrings() public view {
        assertEq(
            vault.WITHDRAWAL_TYPEHASH(),
            keccak256(
                "WithdrawalIntent(address to,address token,uint256 amount,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(
            vault.KEY_ROTATION_TYPEHASH(),
            keccak256(
                "KeyRotation(uint256 newPubKeyX,uint8 newPubKeyYParity,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(
            vault.DAILY_LIMIT_UPDATE_TYPEHASH(),
            keccak256(
                "DailyLimitUpdate(address token,uint256 newLimit,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(
            vault.GUARDIAN_UPDATE_TYPEHASH(),
            keccak256("GuardianUpdate(address newGuardian,uint256 nonce,uint256 deadline)")
        );
    }
}
