// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Account as OZAccount} from "@openzeppelin/contracts/account/Account.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "../utils/BaseTest.sol";

/// @notice validateUserOp and execution: WebAuthn fixtures (valid, wrong challenge, wrong origin, high-s, ...),
/// the EOA signer, the freeze and every authorization path of `execute`.
contract PasskeyAccountValidationTest is BaseTest {
    PasskeyAccount internal account;
    address internal recipient = makeAddr("recipient");

    function setUp() public override {
        super.setUp();
        account = _createAccount(PASSKEY_PK);
    }

    function _validate(bytes memory signature) internal returns (uint256) {
        PackedUserOperation memory op = _op(address(account), "");
        op.signature = signature;
        vm.prank(address(entryPoint));
        return account.validateUserOp(op, keccak256("userOpHash"), 0);
    }

    function _sig(WebAuthnOpts memory o) internal pure returns (bytes memory) {
        return _webauthnSig(PASSKEY_PK, keccak256("userOpHash"), o);
    }

    // ------------------------------------------------------------------ WebAuthn fixtures

    function test_WebAuthn_Valid() public {
        assertEq(_validate(_sig(_defaultOpts())), ERC4337Utils.SIG_VALIDATION_SUCCESS);
    }

    function test_WebAuthn_WrongChallenge() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.challengeOverride = keccak256("some other user operation");
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_WebAuthn_WrongRpId() public {
        // An assertion produced for another relying party carries that RP id's hash in authenticatorData.
        WebAuthnOpts memory o = _defaultOpts();
        o.rpId = "evil.example";
        o.origin = "https://evil.example";
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_WebAuthn_WrongRpIdEvenWithTheRightOrigin() public {
        // Only the RP id hash decides: a matching origin string does not rescue an assertion for another RP id.
        WebAuthnOpts memory o = _defaultOpts();
        o.rpId = "evil.example";
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    /// Documents a deliberate limit (threat model T2): `clientDataJSON.origin` is never checked, only the RP id hash.
    /// Browsers let any origin whose registrable domain matches the RP id (e.g. a sibling subdomain of wallet.test)
    /// request assertions for that RP id, and such an assertion validates. Whoever controls the RP id's domain and
    /// all its subdomains is therefore part of the trusted computing base.
    function test_WebAuthn_OriginIsNotChecked_SameRpIdFromAnotherOriginIsAccepted() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.origin = "https://evil.example";
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_SUCCESS);
        o.origin = "https://phishing.wallet.test";
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_SUCCESS);
    }

    function test_WebAuthn_HighS() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.highS = true;
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_WebAuthn_HighSIsMalleatedValidSignature() public pure {
        // Sanity check of the fixture: flipping s back yields the valid low-s signature.
        WebAuthnOpts memory low = _defaultOpts();
        WebAuthnOpts memory high = _defaultOpts();
        high.highS = true;
        (, bytes32 sLow,,,,) = abi.decode(
            _webauthnAuth(PASSKEY_PK, keccak256("userOpHash"), low), (bytes32, bytes32, uint256, uint256, bytes, string)
        );
        (, bytes32 sHigh,,,,) = abi.decode(
            _webauthnAuth(PASSKEY_PK, keccak256("userOpHash"), high),
            (bytes32, bytes32, uint256, uint256, bytes, string)
        );
        assertEq(uint256(sHigh), P256.N - uint256(sLow));
    }

    function test_WebAuthn_MissingUserVerification() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.flags = 0x01; // UP only
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_WebAuthn_MissingUserPresence() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.flags = 0x04; // UV only
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_WebAuthn_BackupStateWithoutEligibility() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.flags = 0x15; // UP | UV | BS, without BE
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_WebAuthn_SyncedPasskeyFlagsAccepted() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.flags = 0x1D; // UP | UV | BE | BS: a synced (backed-up) passkey
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_SUCCESS);
    }

    function test_WebAuthn_WrongType() public {
        WebAuthnOpts memory o = _defaultOpts();
        o.typ = "webauthn.create";
        assertEq(_validate(_sig(o)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_WebAuthn_WrongKey() public {
        assertEq(
            _validate(_webauthnSig(ATTACKER_PASSKEY_PK, keccak256("userOpHash"))), ERC4337Utils.SIG_VALIDATION_FAILED
        );
    }

    function test_Signature_EmptyOrUnknownTypeFails() public {
        assertEq(_validate(""), ERC4337Utils.SIG_VALIDATION_FAILED);
        bytes memory sig = _sig(_defaultOpts());
        sig[0] = 0x02;
        assertEq(_validate(sig), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_Signature_MalformedWebAuthnEncodingFails() public {
        assertEq(_validate(abi.encodePacked(bytes1(0x00), bytes32(0))), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_Signature_ShortAuthenticatorDataFails() public {
        bytes memory encoded =
            abi.encode(bytes32(uint256(1)), bytes32(uint256(1)), CHALLENGE_INDEX, TYPE_INDEX, hex"0102", string("{}"));
        assertEq(_validate(abi.encodePacked(bytes1(0x00), encoded)), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_EoaSignature_FailsForFactoryAccount() public {
        // Nobody holds the key of a CREATE2 clone address, so the EOA signer is unusable outside 7702 mode.
        assertEq(_validate(_eoaSig(0xE0A, keccak256("userOpHash"))), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_OnlyEntryPoint() public {
        PackedUserOperation memory op = _op(address(account), "");
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, address(this)));
        account.validateUserOp(op, bytes32(0), 0);
    }

    function test_ValidateUserOp_PaysPrefund() public {
        PackedUserOperation memory op = _op(address(account), "");
        op.signature = _sig(_defaultOpts());
        uint256 before = address(entryPoint).balance;
        vm.prank(address(entryPoint));
        account.validateUserOp(op, keccak256("userOpHash"), 1 ether);
        assertEq(address(entryPoint).balance, before + 1 ether);
    }

    function testFuzz_WebAuthn_AnyChallengeRoundTrips(bytes32 challenge, uint256 pkSeed) public {
        uint256 pk = bound(pkSeed, 1, P256.N - 1);
        PasskeyAccount acct = _createAccount(_initParams(pk, _noGuardians(), 0), bytes32(pkSeed));
        PackedUserOperation memory op = _op(address(acct), "");
        op.signature = _webauthnSig(pk, challenge);
        vm.prank(address(entryPoint));
        assertEq(acct.validateUserOp(op, challenge, 0), ERC4337Utils.SIG_VALIDATION_SUCCESS);
    }

    function testFuzz_WebAuthn_SignatureForOtherChallengeFails(bytes32 challenge, bytes32 other) public {
        vm.assume(challenge != other);
        PackedUserOperation memory op = _op(address(account), "");
        op.signature = _webauthnSig(PASSKEY_PK, other);
        vm.prank(address(entryPoint));
        assertEq(account.validateUserOp(op, challenge, 0), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    function testFuzz_Signature_GarbageNeverValidates(bytes calldata garbage) public {
        assertEq(_validate(garbage), ERC4337Utils.SIG_VALIDATION_FAILED);
    }

    // ------------------------------------------------------------------ end-to-end through the EntryPoint

    function test_HandleOps_BatchTransfersEth() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution({target: recipient, value: 1 ether, callData: ""});
        calls[1] = Execution({target: makeAddr("other"), value: 2 ether, callData: ""});
        _handle(_signPasskey(_op(address(account), _batch(calls)), PASSKEY_PK));
        assertEq(recipient.balance, 1 ether);
        assertEq(makeAddr("other").balance, 2 ether);
    }

    function test_HandleOps_RejectsWrongPasskey() public {
        _handleExpectFailedOp(
            _signPasskey(_op(address(account), _single(recipient, 1 ether, "")), ATTACKER_PASSKEY_PK),
            "AA24 signature error"
        );
    }

    function test_HandleOps_DeploysThroughInitCode() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK_2, _noGuardians(), 0);
        address predicted = factory.getAddress(p, bytes32("x"));
        vm.deal(predicted, 5 ether);
        PackedUserOperation memory op = _op(predicted, _single(recipient, 1 ether, ""));
        op.initCode = abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (p, bytes32("x"))));
        _handle(_signPasskey(op, PASSKEY_PK_2));
        assertGt(predicted.code.length, 0);
        assertEq(recipient.balance, 1 ether);
    }

    // ------------------------------------------------------------------ execute authorization

    function test_Execute_RevertsForStranger() public {
        bytes memory data = abi.encode(new Execution[](0));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, stranger));
        account.execute(MODE_BATCH, data);
    }

    function test_Execute_RevertsOnUnsupportedMode() public {
        bytes memory data = abi.encode(new Execution[](0));
        vm.prank(address(entryPoint));
        vm.expectRevert(ERC7821.UnsupportedExecutionMode.selector);
        account.execute(bytes32(0), data);
    }

    function test_Execute_SelfCallFromBatch() public {
        // A batch can call the account's own owner functions (msg.sender == address(this)).
        IPasskeyAccount.Passkey memory next = _passkey(PASSKEY_PK_2);
        bytes memory callData = _single(address(account), 0, abi.encodeCall(PasskeyAccount.rotatePasskey, (next)));
        _handle(_signPasskey(_op(address(account), callData), PASSKEY_PK));
        assertEq(account.passkey().qx, next.qx);
    }

    function test_Execute_BubblesRevert() public {
        bytes memory callData = _single(address(usd), 0, abi.encodeCall(usd.transfer, (recipient, 1)));
        PackedUserOperation memory op = _signPasskey(_op(address(account), callData), PASSKEY_PK);
        bytes32 hash = entryPoint.getUserOpHash(op);
        vm.recordLogs();
        _handle(op);
        // The inner ERC20 revert is reported by the EntryPoint, and the op is marked failed.
        assertFalse(_opSucceeded(hash));
    }

    function _opSucceeded(bytes32 hash) internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig && logs[i].topics[1] == hash) {
                (, bool success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                return success;
            }
        }
        revert("UserOperationEvent not found");
    }

    // ------------------------------------------------------------------ misc

    function test_SupportsInterfaces() public view {
        assertTrue(account.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(account.supportsInterface(0x1626ba7e)); // ERC-1271
        assertTrue(account.supportsInterface(0x150b7a02)); // ERC-721 receiver
        assertTrue(account.supportsInterface(0x4e2312e0)); // ERC-1155 receiver
        assertTrue(account.supportsInterface(type(IAccountLike).interfaceId));
        assertFalse(account.supportsInterface(0xdeadbeef));
    }

    function test_ReceivesEth() public {
        (bool ok,) = address(account).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_GetNonce() public view {
        assertEq(account.getNonce(), 0);
        assertEq(account.getNonce(7), uint256(7) << 64);
    }
}

interface IAccountLike {
    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external returns (uint256);
}
