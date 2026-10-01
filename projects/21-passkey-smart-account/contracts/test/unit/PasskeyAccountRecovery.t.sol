// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Account as OZAccount} from "@openzeppelin/contracts/account/Account.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {IEntryPointV09} from "../utils/IEntryPointV09.sol";

/// @dev ERC-1271 guardian (a contract wallet) that approves hashes registered by its owner.
contract MockContractGuardian is IERC1271 {
    mapping(bytes32 => bool) public approvedHashes;

    function approveHash(bytes32 hash) external {
        approvedHashes[hash] = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return approvedHashes[hash] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    function approveRecoveryOn(PasskeyAccount account, IPasskeyAccount.Passkey calldata key) external {
        account.approveRecovery(key);
    }
}

/// @notice Guardians, 2-of-3 recovery with a 48h timelock, owner veto, rotation and emergency freeze.
contract PasskeyAccountRecoveryTest is BaseTest {
    PasskeyAccount internal account;
    address internal g0;
    uint256 internal g0Pk;
    address internal g1;
    uint256 internal g1Pk;
    address internal g2;
    IPasskeyAccount.Passkey internal newKey;

    function setUp() public override {
        super.setUp();
        (g0, g0Pk) = makeAddrAndKey("guardian0");
        (g1, g1Pk) = makeAddrAndKey("guardian1");
        g2 = makeAddr("guardian2");
        address[] memory g = new address[](3);
        g[0] = g0;
        g[1] = g1;
        g[2] = g2;
        account = _createAccount(_initParams(PASSKEY_PK, g, 2), bytes32(0));
        newKey = _passkey(PASSKEY_PK_2);
    }

    function _ownerCall(bytes memory callData) internal {
        _handle(_signPasskey(_op(address(account), callData), PASSKEY_PK));
    }

    function _approvalDigest(IPasskeyAccount.Passkey memory key, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                account.RECOVERY_APPROVAL_TYPEHASH(), key.qx, key.qy, key.rpIdHash, account.recoveryEpoch(), deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PasskeyAccount"),
                keccak256("1"),
                block.chainid,
                address(account)
            )
        );
        return MessageHashUtils.toTypedDataHash(domain, structHash);
    }

    function _schedule() internal returns (bytes32 id) {
        vm.prank(g0);
        account.approveRecovery(newKey);
        vm.prank(g1);
        account.approveRecovery(newKey);
        id = account.recoveryIdFor(newKey);
    }

    // ------------------------------------------------------------------ happy path

    function test_Recovery_TwoOfThreeAfterTimelock() public {
        bytes32 id = account.recoveryIdFor(newKey);
        vm.prank(g0);
        vm.expectEmit(address(account));
        emit IPasskeyAccount.RecoveryApproved(g0, id, 1);
        account.approveRecovery(newKey);
        assertEq(account.pendingRecovery().executableAt, 0);

        uint48 expectedAt = uint48(block.timestamp) + 48 hours;
        vm.prank(g1);
        vm.expectEmit(address(account));
        emit IPasskeyAccount.RecoveryScheduled(id, expectedAt);
        account.approveRecovery(newKey);
        assertEq(account.pendingRecovery().executableAt, expectedAt);
        assertEq(account.recoveryApprovals(id), 2);
        assertTrue(account.hasApproved(id, g1));

        vm.warp(expectedAt);
        vm.prank(makeAddr("anyone"));
        account.executeRecovery();
        assertEq(account.passkey().qx, newKey.qx);
        assertEq(account.pendingRecovery().executableAt, 0);

        // The new passkey controls the account; the old one does not.
        _handle(_signPasskey(_op(address(account), _single(makeAddr("r"), 1 ether, "")), PASSKEY_PK_2));
        assertEq(makeAddr("r").balance, 1 ether);
        _handleExpectFailedOp(
            _signPasskey(_op(address(account), _single(makeAddr("r"), 1 ether, "")), PASSKEY_PK), "AA24 signature error"
        );
    }

    function test_Recovery_RevertsBeforeTimelock() public {
        _schedule();
        uint48 executableAt = account.pendingRecovery().executableAt;
        vm.warp(executableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.RecoveryTimelockActive.selector, executableAt));
        account.executeRecovery();
    }

    function test_Recovery_RevertsWhenNothingScheduled() public {
        vm.expectRevert(IPasskeyAccount.NoRecoveryScheduled.selector);
        account.executeRecovery();
    }

    function test_Recovery_OneApprovalIsNotEnough() public {
        vm.prank(g0);
        account.approveRecovery(newKey);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(IPasskeyAccount.NoRecoveryScheduled.selector);
        account.executeRecovery();
    }

    function test_Recovery_RevertsForNonGuardian() public {
        address stranger = makeAddr("stranger");
        IPasskeyAccount.Passkey memory key = newKey;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.NotGuardian.selector, stranger));
        account.approveRecovery(key);
    }

    function test_Recovery_RevertsOnDoubleApproval() public {
        IPasskeyAccount.Passkey memory key = newKey;
        bytes32 id = account.recoveryIdFor(key);
        vm.startPrank(g0);
        account.approveRecovery(key);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AlreadyApproved.selector, g0, id));
        account.approveRecovery(key);
        vm.stopPrank();
    }

    function test_Recovery_RevertsOnInvalidNewPasskey() public {
        IPasskeyAccount.Passkey memory bad = newKey;
        bad.qx = bytes32(0);
        vm.prank(g0);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidPasskey.selector, bad.qx, bad.qy));
        account.approveRecovery(bad);
    }

    function test_Recovery_SecondProposalBlockedWhileScheduled() public {
        bytes32 id = _schedule();
        IPasskeyAccount.Passkey memory other = _passkey(ATTACKER_PASSKEY_PK);
        vm.prank(g2);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.RecoveryAlreadyScheduled.selector, id));
        account.approveRecovery(other);
    }

    function test_Recovery_ApprovalsForDifferentKeysDoNotCombine() public {
        vm.prank(g0);
        account.approveRecovery(newKey);
        IPasskeyAccount.Passkey memory other = _passkey(ATTACKER_PASSKEY_PK);
        vm.prank(g1);
        account.approveRecovery(other);
        assertEq(account.pendingRecovery().executableAt, 0);
    }

    // ------------------------------------------------------------------ owner veto

    function test_Veto_CancelsScheduledRecovery() public {
        bytes32 id = _schedule();
        vm.expectEmit(address(account));
        emit IPasskeyAccount.RecoveryEpochBumped(1, id);
        _ownerCall(abi.encodeCall(PasskeyAccount.cancelRecovery, ()));
        assertEq(account.pendingRecovery().executableAt, 0);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(IPasskeyAccount.NoRecoveryScheduled.selector);
        account.executeRecovery();
        // Old approvals are void in the new epoch.
        assertEq(account.recoveryApprovals(account.recoveryIdFor(newKey)), 0);
    }

    function test_Veto_OnlyOwner() public {
        vm.prank(g0);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, g0));
        account.cancelRecovery();
    }

    function test_Veto_UserOperationRejectedWhileFrozen() public {
        _schedule();
        vm.prank(g2);
        account.freeze();
        // No user operation is valid during a freeze, the veto included (see the gas-drain regression below).
        _handleExpectFailedOp(
            _signPasskey(_op(address(account), abi.encodeCall(PasskeyAccount.cancelRecovery, ())), PASSKEY_PK),
            "AA22 expired or not due"
        );
        assertGt(account.pendingRecovery().executableAt, 0);
    }

    function test_Veto_RelayedWorksWhileFrozenAndCostsTheAccountNothing() public {
        bytes32 id = _schedule();
        vm.prank(g2);
        account.freeze();
        uint256 balance = address(account).balance;
        uint256 deposit = entryPoint.balanceOf(address(account));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _webauthnSig(PASSKEY_PK, account.cancelRecoveryDigest(deadline));
        vm.expectEmit(address(account));
        emit IPasskeyAccount.RecoveryEpochBumped(1, id);
        vm.prank(makeAddr("relayer"));
        account.cancelRecoveryWithSig(deadline, sig);
        assertEq(account.pendingRecovery().executableAt, 0);
        assertEq(address(account).balance, balance);
        assertEq(entryPoint.balanceOf(address(account)), deposit);
    }

    function test_Veto_RelayedSignatureWorksOnce() public {
        _schedule();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _webauthnSig(PASSKEY_PK, account.cancelRecoveryDigest(deadline));
        account.cancelRecoveryWithSig(deadline, sig);
        // The veto bumped the epoch the signature covers.
        vm.expectRevert(IPasskeyAccount.InvalidVetoSignature.selector);
        account.cancelRecoveryWithSig(deadline, sig);
    }

    function test_Veto_RelayedRejectsOtherSigners() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = account.cancelRecoveryDigest(deadline);
        // Signatures are built first: the helpers call precompiles, which `expectRevert` would take for the call.
        bytes memory attackerSig = _webauthnSig(ATTACKER_PASSKEY_PK, digest);
        // A guardian's key is not the owner's; the EOA signer type only works in 7702 mode.
        bytes memory guardianSig = _eoaSig(g0Pk, digest);
        vm.expectRevert(IPasskeyAccount.InvalidVetoSignature.selector);
        account.cancelRecoveryWithSig(deadline, attackerSig);
        vm.expectRevert(IPasskeyAccount.InvalidVetoSignature.selector);
        account.cancelRecoveryWithSig(deadline, guardianSig);
        vm.expectRevert(IPasskeyAccount.InvalidVetoSignature.selector);
        account.cancelRecoveryWithSig(deadline, "");
    }

    function test_Veto_RelayedSignatureIsBoundToTheAccountAndDeadline() public {
        // Same passkey, another account: the EIP-712 domain carries the verifying contract.
        PasskeyAccount other = _createAccount(_initParams(PASSKEY_PK, _noGuardians(), 0), bytes32("other"));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sigForOther = _webauthnSig(PASSKEY_PK, other.cancelRecoveryDigest(deadline));
        vm.expectRevert(IPasskeyAccount.InvalidVetoSignature.selector);
        account.cancelRecoveryWithSig(deadline, sigForOther);
        // The deadline is signed too, and enforced.
        bytes memory sig = _webauthnSig(PASSKEY_PK, account.cancelRecoveryDigest(deadline));
        vm.expectRevert(IPasskeyAccount.InvalidVetoSignature.selector);
        account.cancelRecoveryWithSig(deadline + 1, sig);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.SignatureExpired.selector, deadline));
        account.cancelRecoveryWithSig(deadline, sig);
    }

    /// Regression (critical): the veto used to stay valid during a freeze. A thief holding the passkey signed vetoes
    /// with a huge preVerificationGas and fee, submitted them with itself as beneficiary and collected the account's
    /// ETH as gas payment. Every user operation now fails validation while frozen, so nothing moves.
    function test_Freeze_StolenPasskeyCannotSpendEthAsVetoGas() public {
        vm.prank(g0);
        account.freeze();
        address thief = makeAddr("thief");
        uint256 balance = address(account).balance;
        uint256 deposit = entryPoint.balanceOf(address(account));
        assertEq(balance, 10 ether);

        // Prefund (1M + 50k + 8M gas) x 1000 gwei = 9.05 ETH fits the 10 ETH balance; 1M verification gas also covers
        // the pure-Solidity P-256 path on a Prague EVM.
        PackedUserOperation memory op = _op(address(account), abi.encodeCall(PasskeyAccount.cancelRecovery, ()));
        op.accountGasLimits = _pack(1_000_000, 50_000);
        op.preVerificationGas = 8_000_000;
        op.gasFees = _pack(1000 gwei, 1000 gwei);
        op = _signPasskey(op, PASSKEY_PK);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(abi.encodeWithSelector(IEntryPointV09.FailedOp.selector, 0, "AA22 expired or not due"));
        vm.prank(thief, thief);
        entryPoint.handleOps(ops, payable(thief));

        assertEq(thief.balance, 0);
        assertEq(address(account).balance, balance);
        assertEq(entryPoint.balanceOf(address(account)), deposit);
        assertGt(account.frozenUntil(), block.timestamp);
    }

    /// Same attack routed through the token paymaster: the account's TUSD cannot be converted into gas either.
    function test_Freeze_StolenPasskeyCannotSpendTokensAsVetoGas() public {
        vm.prank(admin);
        usd.mint(address(account), 1_000_000e6);
        _ownerCall(_single(address(usd), 0, abi.encodeCall(usd.approve, (address(paymaster), type(uint256).max))));
        vm.prank(g0);
        account.freeze();
        uint256 tokens = usd.balanceOf(address(account));

        PackedUserOperation memory op = _op(address(account), abi.encodeCall(PasskeyAccount.cancelRecovery, ()));
        op.preVerificationGas = 9_000_000;
        op.gasFees = _pack(1000 gwei, 1000 gwei);
        op = _signPasskey(_withPaymaster(op, hex"00", 80_000), PASSKEY_PK);
        _handleExpectFailedOp(op, "AA22 expired or not due");
        assertEq(usd.balanceOf(address(account)), tokens);
    }

    // ------------------------------------------------------------------ signature approvals

    function test_ApproveWithSig_EoaGuardian() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g0Pk, _approvalDigest(newKey, deadline));
        vm.prank(makeAddr("relayer"));
        account.approveRecoveryWithSig(newKey, g0, deadline, abi.encodePacked(r, s, v));
        assertTrue(account.hasApproved(account.recoveryIdFor(newKey), g0));
    }

    function test_ApproveWithSig_Erc1271Guardian() public {
        MockContractGuardian cg = new MockContractGuardian();
        _ownerCall(abi.encodeCall(PasskeyAccount.addGuardian, (address(cg))));
        uint256 deadline = block.timestamp + 1 days;
        cg.approveHash(_approvalDigest(newKey, deadline));
        account.approveRecoveryWithSig(newKey, address(cg), deadline, "");
        assertTrue(account.hasApproved(account.recoveryIdFor(newKey), address(cg)));
    }

    function test_ApproveWithSig_RevertsOnBadSignature() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g1Pk, _approvalDigest(newKey, deadline));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidGuardianSignature.selector, g0));
        account.approveRecoveryWithSig(newKey, g0, deadline, abi.encodePacked(r, s, v));
    }

    function test_ApproveWithSig_RevertsAfterDeadline() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g0Pk, _approvalDigest(newKey, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.SignatureExpired.selector, deadline));
        account.approveRecoveryWithSig(newKey, g0, deadline, abi.encodePacked(r, s, v));
    }

    function test_ApproveWithSig_RevertsForNonGuardian() public {
        (address stranger, uint256 strangerPk) = makeAddrAndKey("stranger");
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strangerPk, _approvalDigest(newKey, deadline));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.NotGuardian.selector, stranger));
        account.approveRecoveryWithSig(newKey, stranger, deadline, abi.encodePacked(r, s, v));
    }

    function test_ApproveWithSig_SignatureDiesWithEpoch() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(g0Pk, _approvalDigest(newKey, deadline));
        _ownerCall(abi.encodeCall(PasskeyAccount.cancelRecovery, ()));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidGuardianSignature.selector, g0));
        account.approveRecoveryWithSig(newKey, g0, deadline, abi.encodePacked(r, s, v));
    }

    // ------------------------------------------------------------------ guardian management

    function test_AddRemoveGuardian_BumpsEpoch() public {
        vm.prank(g0);
        account.approveRecovery(newKey);
        address g3 = makeAddr("guardian3");
        _ownerCall(abi.encodeCall(PasskeyAccount.addGuardian, (g3)));
        assertTrue(account.isGuardian(g3));
        assertEq(account.recoveryEpoch(), 1);
        _ownerCall(abi.encodeCall(PasskeyAccount.removeGuardian, (g3)));
        assertFalse(account.isGuardian(g3));
        assertEq(account.recoveryEpoch(), 2);
    }

    function test_RemoveGuardian_RevertsBelowThreshold() public {
        _ownerCall(abi.encodeCall(PasskeyAccount.removeGuardian, (g2)));
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidThreshold.selector, 2, 1));
        account.removeGuardian(g1);
    }

    /// Regression: removing the last guardian used to be impossible (threshold >= 1 with no guardians left, and
    /// threshold 0 refused while a guardian existed), so an owner could never turn social recovery off.
    function test_RemoveGuardian_LastGuardianTurnsRecoveryOff() public {
        address[] memory one = new address[](1);
        one[0] = g0;
        PasskeyAccount single = _createAccount(_initParams(PASSKEY_PK, one, 1), bytes32("single"));
        vm.prank(address(single));
        vm.expectEmit(address(single));
        emit IPasskeyAccount.GuardianThresholdChanged(0);
        single.removeGuardian(g0);
        assertEq(single.guardians().length, 0);
        assertEq(single.guardianThreshold(), 0);
        // Recovery is off: nobody can approve or freeze any more.
        vm.prank(g0);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.NotGuardian.selector, g0));
        single.approveRecovery(newKey);
    }

    function test_RemoveGuardian_AllGuardiansInOneBatch() public {
        Execution[] memory calls = new Execution[](4);
        calls[0] = Execution(address(account), 0, abi.encodeCall(PasskeyAccount.setGuardianThreshold, (1)));
        calls[1] = Execution(address(account), 0, abi.encodeCall(PasskeyAccount.removeGuardian, (g0)));
        calls[2] = Execution(address(account), 0, abi.encodeCall(PasskeyAccount.removeGuardian, (g1)));
        calls[3] = Execution(address(account), 0, abi.encodeCall(PasskeyAccount.removeGuardian, (g2)));
        _ownerCall(_batch(calls));
        assertEq(account.guardians().length, 0);
        assertEq(account.guardianThreshold(), 0);
        // And back on again.
        _ownerCall(abi.encodeCall(PasskeyAccount.addGuardian, (g0)));
        _ownerCall(abi.encodeCall(PasskeyAccount.setGuardianThreshold, (1)));
        assertEq(account.guardianThreshold(), 1);
    }

    function test_RemoveGuardian_RevertsForUnknown() public {
        address stranger = makeAddr("stranger");
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.NotGuardian.selector, stranger));
        account.removeGuardian(stranger);
    }

    function test_SetThreshold() public {
        _ownerCall(abi.encodeCall(PasskeyAccount.setGuardianThreshold, (3)));
        assertEq(account.guardianThreshold(), 3);
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidThreshold.selector, 4, 3));
        account.setGuardianThreshold(4);
    }

    function test_GuardianManagement_OnlyOwner() public {
        address g3 = makeAddr("guardian3");
        vm.startPrank(g0);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, g0));
        account.addGuardian(g3);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, g0));
        account.removeGuardian(g1);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, g0));
        account.setGuardianThreshold(1);
        vm.stopPrank();
    }

    function test_AddGuardian_RevertsAtMax() public {
        vm.startPrank(address(account));
        for (uint256 i = 0; i < 5; ++i) {
            account.addGuardian(address(uint160(0xAAA0 + i)));
        }
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.TooManyGuardians.selector, 8));
        account.addGuardian(address(0xBBBB));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ rotation

    function test_RotatePasskey() public {
        IPasskeyAccount.Passkey memory key = newKey;
        vm.expectEmit(address(account));
        emit IPasskeyAccount.PasskeyChanged(key.qx, key.qy, key.rpIdHash);
        _ownerCall(abi.encodeCall(PasskeyAccount.rotatePasskey, (key)));
        assertEq(account.passkey().qy, key.qy);
    }

    function test_RotatePasskey_OnlyOwner() public {
        IPasskeyAccount.Passkey memory key = newKey;
        vm.prank(g0);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, g0));
        account.rotatePasskey(key);
    }

    // ------------------------------------------------------------------ freeze

    function test_Freeze_ByGuardianBlocksOwnerOps() public {
        vm.prank(g2);
        account.freeze();
        uint48 until = account.frozenUntil();
        assertEq(until, uint48(block.timestamp) + 7 days);
        // The freeze is enforced as `validAfter` by the EntryPoint (no TIMESTAMP opcode in validation).
        _handleExpectFailedOp(
            _signPasskey(_op(address(account), _single(makeAddr("r"), 1 ether, "")), PASSKEY_PK),
            "AA22 expired or not due"
        );
        // Direct self-calls are blocked too.
        IPasskeyAccount.Passkey memory key = newKey;
        vm.startPrank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AccountFrozen.selector, until));
        account.rotatePasskey(key);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AccountFrozen.selector, until));
        account.addGuardian(makeAddr("x"));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AccountFrozen.selector, until));
        account.removeGuardian(g0);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AccountFrozen.selector, until));
        account.setGuardianThreshold(1);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AccountFrozen.selector, until));
        account.execute(MODE_BATCH, abi.encode(new bytes[](0)));
        vm.stopPrank();
    }

    function test_Freeze_ValidationReturnsValidAfter() public {
        vm.prank(g2);
        account.freeze();
        PackedUserOperation memory op = _op(address(account), _single(makeAddr("r"), 1, ""));
        op.signature = _webauthnSig(PASSKEY_PK, keccak256("h"));
        vm.prank(address(entryPoint));
        uint256 vd = account.validateUserOp(op, keccak256("h"), 0);
        (address agg, uint48 validAfter, uint48 validUntil,) = ERC4337Utils.parseValidationData(vd);
        assertEq(agg, address(0));
        assertEq(validAfter, account.frozenUntil());
        // validUntil 0 means "no expiry"; OpenZeppelin reports it as the maximum 47-bit timestamp.
        assertEq(validUntil, ERC4337Utils.BLOCK_RANGE_MASK);
    }

    function test_Freeze_ExpiresAfterDuration() public {
        vm.prank(g2);
        account.freeze();
        vm.warp(block.timestamp + 7 days + 1);
        _handle(_signPasskey(_op(address(account), _single(makeAddr("r"), 1 ether, "")), PASSKEY_PK));
        assertEq(makeAddr("r").balance, 1 ether);
    }

    function test_Freeze_OnlyExtends() public {
        vm.prank(g0);
        account.freeze();
        uint48 first = account.frozenUntil();
        vm.warp(block.timestamp + 1 days);
        vm.prank(g1);
        account.freeze();
        assertEq(account.frozenUntil(), first + 1 days);
    }

    function test_Freeze_ByOwner() public {
        _ownerCall(abi.encodeCall(PasskeyAccount.freeze, ()));
        assertGt(account.frozenUntil(), block.timestamp);
    }

    function test_Freeze_RevertsForStranger() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.FreezeUnauthorized.selector, stranger));
        account.freeze();
    }

    function test_Freeze_LiftedByExecutedRecovery() public {
        vm.prank(g2);
        account.freeze();
        _schedule();
        vm.warp(block.timestamp + 48 hours);
        vm.expectEmit(address(account));
        emit IPasskeyAccount.FreezeLifted();
        account.executeRecovery();
        assertEq(account.frozenUntil(), 0);
        _handle(_signPasskey(_op(address(account), _single(makeAddr("r"), 1 ether, "")), PASSKEY_PK_2));
    }

    function test_Freeze_OncePerGuardianPerEpoch() public {
        assertTrue(account.freezeAvailable(g2));
        vm.prank(g2);
        account.freeze();
        assertFalse(account.freezeAvailable(g2));
        assertTrue(account.freezeAvailable(g0));
        vm.warp(block.timestamp + 6 days);
        vm.prank(g2);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.FreezeAlreadyUsed.selector, g2, 0));
        account.freeze();
        assertFalse(account.freezeAvailable(makeAddr("stranger")));
    }

    /// Regression: one compromised guardian used to keep the account frozen forever by re-freezing every few days,
    /// while `removeGuardian` stayed blocked by the freeze. Its single freeze now expires and the owner removes it.
    function test_Freeze_GriefingGuardianCannotLockTheAccountForever() public {
        vm.prank(g2);
        account.freeze();
        uint48 until = account.frozenUntil();
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AccountFrozen.selector, until));
        account.removeGuardian(g2);

        vm.warp(block.timestamp + 6 days);
        vm.prank(g2);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.FreezeAlreadyUsed.selector, g2, 0));
        account.freeze();

        vm.warp(uint256(until) + 1); // the EntryPoint accepts an operation only strictly after validAfter
        _ownerCall(abi.encodeCall(PasskeyAccount.removeGuardian, (g2)));
        assertFalse(account.isGuardian(g2));
        vm.prank(g2);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.FreezeUnauthorized.selector, g2));
        account.freeze();
    }

    function test_Freeze_VetoRestoresGuardianFreezes() public {
        // Against a thief who vetoes every recovery, each veto bumps the epoch and gives guardians a new freeze.
        vm.prank(g0);
        account.freeze();
        _schedule();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        account.cancelRecoveryWithSig(deadline, _webauthnSig(PASSKEY_PK, account.cancelRecoveryDigest(deadline)));
        assertTrue(account.freezeAvailable(g0));
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.prank(g0);
        account.freeze();
        assertEq(account.frozenUntil(), uint48(vm.getBlockTimestamp()) + 7 days);
    }

    function test_Freeze_OwnerPathIsNotRateLimited() public {
        vm.startPrank(address(account));
        account.freeze();
        account.freeze();
        vm.stopPrank();
        assertEq(account.frozenUntil(), uint48(block.timestamp) + 7 days);
    }

    function test_Freeze_BlocksErc1271() public {
        bytes32 hash = keccak256("message");
        vm.prank(g0);
        account.freeze();
        assertEq(account.isValidSignature(hash, ""), bytes4(0xffffffff));
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_Recovery_NeverExecutesEarly(uint256 elapsed) public {
        _schedule();
        uint48 executableAt = account.pendingRecovery().executableAt;
        elapsed = bound(elapsed, 0, 48 hours - 1);
        vm.warp(block.timestamp + elapsed);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.RecoveryTimelockActive.selector, executableAt));
        account.executeRecovery();
    }

    function testFuzz_Freeze_BlocksUntilExactExpiry(uint256 elapsed) public {
        vm.prank(g0);
        account.freeze();
        uint48 until = account.frozenUntil();
        elapsed = bound(elapsed, 0, 7 days - 1);
        vm.warp(block.timestamp + elapsed);
        vm.prank(address(account));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.AccountFrozen.selector, until));
        account.execute(MODE_BATCH, abi.encode(new bytes[](0)));
    }
}
