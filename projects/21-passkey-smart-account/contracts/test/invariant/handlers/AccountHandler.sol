// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";

import {PasskeyAccount} from "../../../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../../../src/PasskeyAccountFactory.sol";
import {IPasskeyAccount} from "../../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../../utils/BaseTest.sol";
import {IEntryPointV09} from "../../utils/IEntryPointV09.sol";

/// @notice Drives a guarded account through authorized and unauthorized actions, recovery, veto and freeze.
/// Ghost variables record what *should* have happened; the invariant test compares them with on-chain state.
/// Every action either succeeds or fails in a way the handler expects and counts, so the campaign can run with
/// `fail_on_revert = true`: an unexpected revert is a failure, not a silently discarded call.
contract AccountHandler is BaseTest {
    PasskeyAccount public account;
    address public sink;
    address public thief;
    address[3] public guardianSet;

    /// @dev Candidate passkeys. Index 0 is the initial key; recoveries and rotations pick among all of them.
    uint256[4] public keys = [PASSKEY_PK, PASSKEY_PK_2, uint256(0xC0FFEE), uint256(0xD00D)];

    // ----- ghosts
    uint256 public currentKeyIndex;
    uint256 public ghostAuthorizedOutflow;
    uint256 public ghostForgeriesAccepted;
    uint256 public ghostUnauthorizedDirectCallsAccepted;
    uint256 public ghostOwnerOpsWhileFrozen;
    /// @dev Wei the account lost (balance plus EntryPoint deposit) across operations submitted while it was frozen.
    uint256 public ghostValueLostWhileFrozen;
    uint256 public ghostEarlyRecoveries;
    uint256 public ghostRecoveriesExecuted;
    uint256 public ghostVetoes;
    uint256 public ghostRelayedVetoesWhileFrozen;
    uint256 public ghostVetoLeftPending;
    uint256 public ghostRepeatedFreezes;
    uint256 public ghostExtremeGasVetoesWhileFrozen;
    /// @dev Timestamp at which the currently scheduled recovery reached its threshold (0 = none scheduled).
    uint256 public ghostScheduledAt;

    mapping(bytes32 => uint256) public calls;

    constructor(IEntryPointV09 ep, PasskeyAccountFactory factory_, address[3] memory guardians_) {
        entryPoint = ep;
        factory = factory_;
        guardianSet = guardians_;
        sink = makeAddr("sink");
        thief = makeAddr("thief");
        address[] memory g = new address[](3);
        for (uint256 i = 0; i < 3; ++i) {
            g[i] = guardians_[i];
        }
        account = PasskeyAccount(payable(factory_.createAccount(_initParams(PASSKEY_PK, g, 2), bytes32("inv"))));
        vm.deal(address(account), 1000 ether);
        bundlerEoa = makeAddr("inv-bundler");
        beneficiary = payable(makeAddr("inv-beneficiary"));
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Account value an operation can spend: ETH balance plus EntryPoint deposit.
    function _value() internal view returns (uint256) {
        return address(account).balance + entryPoint.balanceOf(address(account));
    }

    function _submit(PackedUserOperation memory op) internal returns (bool accepted) {
        return _submitAs(op, bundlerEoa, beneficiary);
    }

    function _submitAs(PackedUserOperation memory op, address submitter, address payable to)
        internal
        returns (bool accepted)
    {
        bool frozen = _frozen();
        uint256 valueBefore = _value();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(submitter, submitter);
        try entryPoint.handleOps(ops, to) {
            accepted = true;
        } catch {
            accepted = false;
        }
        uint256 valueAfter = _value();
        if (frozen && valueAfter < valueBefore) ghostValueLostWhileFrozen += valueBefore - valueAfter;
    }

    function _frozen() internal view returns (bool) {
        return block.timestamp < account.frozenUntil();
    }

    function _currentKey() internal view returns (uint256) {
        return keys[currentKeyIndex];
    }

    function _afterVeto() internal {
        ghostVetoes++;
        if (account.pendingRecovery().executableAt != 0) ghostVetoLeftPending++;
        ghostScheduledAt = 0;
    }

    // ------------------------------------------------------------------ owner (authorized) actions

    function authorizedTransfer(uint256 amountSeed) external {
        calls["authorizedTransfer"]++;
        uint256 amount = bound(amountSeed, 1, 1 ether);
        bool frozen = _frozen();
        PackedUserOperation memory op = _signPasskey(_op(address(account), _single(sink, amount, "")), _currentKey());
        uint256 before = sink.balance;
        bool accepted = _submit(op);
        if (accepted) {
            if (frozen) ghostOwnerOpsWhileFrozen++;
            ghostAuthorizedOutflow += sink.balance - before;
        }
    }

    function ownerRotate(uint256 keySeed) external {
        calls["ownerRotate"]++;
        uint256 idx = bound(keySeed, 0, keys.length - 1);
        bool frozen = _frozen();
        IPasskeyAccount.Passkey memory next = _passkey(keys[idx]);
        PackedUserOperation memory op =
            _signPasskey(_op(address(account), abi.encodeCall(PasskeyAccount.rotatePasskey, (next))), _currentKey());
        if (_submit(op)) {
            if (frozen) ghostOwnerOpsWhileFrozen++;
            if (account.passkey().qx == next.qx) currentKeyIndex = idx;
        }
    }

    /// @dev Veto as a user operation: valid only while the account is not frozen.
    function ownerVeto() external {
        calls["ownerVeto"]++;
        bool frozen = _frozen();
        PackedUserOperation memory op =
            _signPasskey(_op(address(account), abi.encodeCall(PasskeyAccount.cancelRecovery, ())), _currentKey());
        if (_submit(op)) {
            if (frozen) ghostOwnerOpsWhileFrozen++;
            _afterVeto();
        }
    }

    /// @dev Relayed veto: signed by the current passkey, submitted and paid for by a third party. Must always work,
    /// frozen or not, and must not cost the account anything.
    function ownerVetoRelayed(uint256 relayerSeed) external {
        calls["ownerVetoRelayed"]++;
        bool frozen = _frozen();
        uint256 valueBefore = _value();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _webauthnSig(_currentKey(), account.cancelRecoveryDigest(deadline));
        vm.prank(address(uint160(bound(relayerSeed, 1, type(uint160).max))));
        account.cancelRecoveryWithSig(deadline, sig);
        if (frozen) {
            ghostRelayedVetoesWhileFrozen++;
            if (_value() < valueBefore) ghostValueLostWhileFrozen += valueBefore - _value();
        }
        _afterVeto();
    }

    // ------------------------------------------------------------------ attacker actions (must never succeed)

    /// @dev The critical-finding attack: whoever holds the current passkey signs a veto with extreme gas values and
    /// submits it with itself as beneficiary, hoping to collect the account's ETH as gas payment during a freeze.
    function thiefVetoWithExtremeGas(uint256 pvgSeed, uint256 feeSeed) external {
        calls["thiefVetoWithExtremeGas"]++;
        if (!_frozen()) return; // outside a freeze the passkey holder is the owner and may spend what it likes
        PackedUserOperation memory op = _op(address(account), abi.encodeCall(PasskeyAccount.cancelRecovery, ()));
        op.accountGasLimits = _pack(300_000, 50_000);
        op.preVerificationGas = bound(pvgSeed, 1_000_000, 20_000_000);
        uint256 fee = bound(feeSeed, 100 gwei, 10_000 gwei);
        op.gasFees = _pack(fee, fee);
        op = _signPasskey(op, _currentKey());
        ghostExtremeGasVetoesWhileFrozen++;
        if (_submitAs(op, thief, payable(thief))) ghostOwnerOpsWhileFrozen++;
    }

    function forgedPasskeyTransfer(uint256 pkSeed, uint256 amountSeed) external {
        calls["forgedPasskeyTransfer"]++;
        uint256 pk = bound(pkSeed, 1, 1e60);
        for (uint256 i = 0; i < keys.length; ++i) {
            if (pk == keys[i]) pk += 1;
        }
        uint256 amount = bound(amountSeed, 1, 1 ether);
        PackedUserOperation memory op = _signPasskey(_op(address(account), _single(sink, amount, "")), pk);
        if (_submit(op)) ghostForgeriesAccepted++;
    }

    function forgedEoaTransfer(uint256 pkSeed) external {
        calls["forgedEoaTransfer"]++;
        uint256 pk = bound(pkSeed, 1, 1e60);
        PackedUserOperation memory op = _signEoa(_op(address(account), _single(sink, 1 ether, "")), pk);
        if (_submit(op)) ghostForgeriesAccepted++;
    }

    function replayOldSignature(uint256 amountSeed) external {
        calls["replayOldSignature"]++;
        // Sign for the current nonce, let it execute, then try to replay the exact same operation.
        uint256 amount = bound(amountSeed, 1, 0.1 ether);
        bool frozen = _frozen();
        PackedUserOperation memory op = _signPasskey(_op(address(account), _single(sink, amount, "")), _currentKey());
        uint256 before = sink.balance;
        if (_submit(op)) {
            if (frozen) ghostOwnerOpsWhileFrozen++;
            ghostAuthorizedOutflow += sink.balance - before;
            if (_submit(op)) ghostForgeriesAccepted++;
        }
    }

    function directCall(uint256 callerSeed, uint256 which) external {
        calls["directCall"]++;
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        if (caller == address(account) || caller == address(entryPoint)) return;
        IPasskeyAccount.Passkey memory key = _passkey(keys[1]);
        bytes memory data;
        uint256 w = which % 6;
        if (w == 0) {
            data = _single(sink, 1 ether, "");
        } else if (w == 1) {
            data = abi.encodeCall(PasskeyAccount.rotatePasskey, (key));
        } else if (w == 2) {
            data = abi.encodeCall(PasskeyAccount.addGuardian, (caller));
        } else if (w == 3) {
            data = abi.encodeCall(PasskeyAccount.cancelRecovery, ());
        } else if (w == 4) {
            data = abi.encodeCall(PasskeyAccount.initialize, (_initParams(keys[2], _noGuardians(), 0)));
        } else {
            // A relayed veto signed by a passkey that is not the current one.
            uint256 deadline = block.timestamp + 1 hours;
            uint256 wrongKey = keys[(currentKeyIndex + 1) % keys.length];
            bytes memory sig = _webauthnSig(wrongKey, account.cancelRecoveryDigest(deadline));
            data = abi.encodeCall(PasskeyAccount.cancelRecoveryWithSig, (deadline, sig));
        }
        vm.prank(caller);
        (bool ok,) = address(account).call(data);
        if (ok) ghostUnauthorizedDirectCallsAccepted++;
    }

    // ------------------------------------------------------------------ guardians and time

    function guardianApprove(uint256 guardianSeed, uint256 keySeed) external {
        calls["guardianApprove"]++;
        address g = guardianSet[bound(guardianSeed, 0, 2)];
        IPasskeyAccount.Passkey memory key = _passkey(keys[bound(keySeed, 0, keys.length - 1)]);
        bool wasScheduled = account.pendingRecovery().executableAt != 0;
        vm.prank(g);
        try account.approveRecovery(key) {
            IPasskeyAccount.PendingRecovery memory p = account.pendingRecovery();
            if (!wasScheduled && p.executableAt != 0) ghostScheduledAt = block.timestamp;
        } catch {
            // Expected refusals: a recovery is already scheduled, or this guardian already approved this key.
        }
    }

    /// @dev A guardian may freeze once per recovery epoch. A refused first freeze is a bug (revert: fails the
    /// campaign); an accepted second freeze in the same epoch is counted and checked by INV-10.
    function guardianFreeze(uint256 guardianSeed) external {
        calls["guardianFreeze"]++;
        address g = guardianSet[bound(guardianSeed, 0, 2)];
        bool available = account.freezeAvailable(g);
        vm.prank(g);
        try account.freeze() {
            if (!available) ghostRepeatedFreezes++;
        } catch {
            require(!available, "guardian freeze refused although available");
        }
    }

    function executeRecovery() external {
        calls["executeRecovery"]++;
        IPasskeyAccount.PendingRecovery memory p = account.pendingRecovery();
        try account.executeRecovery() {
            ghostRecoveriesExecuted++;
            // Independent of the contract's own bookkeeping: threshold time recorded by the handler + 48h.
            if (ghostScheduledAt == 0 || block.timestamp < ghostScheduledAt + 48 hours) ghostEarlyRecoveries++;
            for (uint256 i = 0; i < keys.length; ++i) {
                if (_passkey(keys[i]).qx == p.newPasskey.qx) currentKeyIndex = i;
            }
            ghostScheduledAt = 0;
        } catch {
            // Expected refusals: nothing scheduled, or the timelock is still running.
        }
    }

    function warp(uint256 secondsSeed) external {
        calls["warp"]++;
        vm.warp(block.timestamp + bound(secondsSeed, 1, 8 days));
    }
}
