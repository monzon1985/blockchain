// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";

import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../../src/PasskeyAccountFactory.sol";
import {TestUSD} from "../../src/TestUSD.sol";
import {TokenPaymaster} from "../../src/TokenPaymaster.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {IEntryPointV09} from "./IEntryPointV09.sol";

/// @notice Shared fixture: EntryPoint v0.9, factory, TestUSD, paymaster, and helpers to build WebAuthn assertions
/// and user operations.
abstract contract BaseTest is Test {
    /// @dev ERC-7821 single-batch execution mode (call type 0x01, default exec type, no selector, no opData).
    bytes32 internal constant MODE_BATCH = bytes32(uint256(0x01) << 248);

    string internal constant RP_ID = "wallet.test";
    string internal constant ORIGIN = "https://wallet.test";
    bytes1 internal constant FLAGS_UP_UV = 0x05;

    /// @dev `{"type":"webauthn.get",` is 23 characters long.
    uint256 internal constant CHALLENGE_INDEX = 23;
    uint256 internal constant TYPE_INDEX = 1;

    uint256 internal constant PASSKEY_PK = 0xA11CE;
    uint256 internal constant PASSKEY_PK_2 = 0xB0B;
    uint256 internal constant ATTACKER_PASSKEY_PK = 0xBAD;

    /// @dev 3000 TUSD per ETH, in 6-decimal units per 1e18 wei.
    uint256 internal constant PRICE = 3000e6;

    IEntryPointV09 internal entryPoint;
    PasskeyAccountFactory internal factory;
    PasskeyAccount internal implementation;
    TestUSD internal usd;
    TokenPaymaster internal paymaster;

    address internal admin = makeAddr("admin");
    address payable internal beneficiary = payable(makeAddr("beneficiary"));
    address internal bundlerEoa = makeAddr("bundler");
    uint256 internal sponsorPk;
    address internal sponsor;

    struct WebAuthnOpts {
        string rpId;
        string origin;
        bytes1 flags;
        string typ;
        bool highS;
        bytes32 challengeOverride;
    }

    function setUp() public virtual {
        EntryPoint ep = new EntryPoint();
        vm.label(address(ep), "EntryPoint");
        entryPoint = IEntryPointV09(address(ep));
        factory = new PasskeyAccountFactory(IEntryPoint(address(ep)));
        implementation = factory.ACCOUNT_IMPLEMENTATION();
        usd = new TestUSD(admin);
        paymaster = new TokenPaymaster(IEntryPoint(address(ep)), usd, admin, PRICE);
        (sponsor, sponsorPk) = makeAddrAndKey("sponsor");

        vm.deal(admin, 1000 ether);
        vm.startPrank(admin);
        paymaster.deposit{value: 100 ether}();
        paymaster.addStake{value: 1 ether}(1 days);
        paymaster.setSponsorSigner(sponsor);
        usd.mint(address(paymaster), 1_000_000e6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Passkeys and WebAuthn assertions
    // ---------------------------------------------------------------------------------------------------------------

    function _passkey(uint256 pk) internal pure returns (IPasskeyAccount.Passkey memory) {
        return _passkey(pk, RP_ID);
    }

    function _passkey(uint256 pk, string memory rpId) internal pure returns (IPasskeyAccount.Passkey memory key) {
        (uint256 x, uint256 y) = vm.publicKeyP256(pk);
        key = IPasskeyAccount.Passkey({qx: bytes32(x), qy: bytes32(y), rpIdHash: sha256(bytes(rpId))});
    }

    function _defaultOpts() internal pure returns (WebAuthnOpts memory) {
        return WebAuthnOpts({
            rpId: RP_ID, origin: ORIGIN, flags: FLAGS_UP_UV, typ: "webauthn.get", highS: false, challengeOverride: 0
        });
    }

    /// @dev Valid assertion over `challenge` by passkey `pk`, prefixed with the WebAuthn signature type.
    function _webauthnSig(uint256 pk, bytes32 challenge) internal pure returns (bytes memory) {
        return _webauthnSig(pk, challenge, _defaultOpts());
    }

    function _webauthnSig(uint256 pk, bytes32 challenge, WebAuthnOpts memory o) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x00), _webauthnAuth(pk, challenge, o));
    }

    /// @dev ABI encoding of OpenZeppelin's `WebAuthnAuth` tuple, as produced by the wallet from a browser assertion.
    function _webauthnAuth(uint256 pk, bytes32 challenge, WebAuthnOpts memory o) internal pure returns (bytes memory) {
        bytes32 signedChallenge = o.challengeOverride == bytes32(0) ? challenge : o.challengeOverride;
        bytes memory authenticatorData = abi.encodePacked(sha256(bytes(o.rpId)), o.flags, uint32(1));
        string memory clientDataJSON = string.concat(
            '{"type":"',
            o.typ,
            '","challenge":"',
            Base64.encodeURL(abi.encodePacked(signedChallenge)),
            '","origin":"',
            o.origin,
            '","crossOrigin":false}'
        );
        bytes32 digest = sha256(abi.encodePacked(authenticatorData, sha256(bytes(clientDataJSON))));
        (bytes32 r, bytes32 s) = vm.signP256(pk, digest);
        uint256 sNum = uint256(s);
        bool isHigh = sNum > P256.N / 2;
        if (isHigh != o.highS) s = bytes32(P256.N - sNum);
        return abi.encode(r, s, CHALLENGE_INDEX, TYPE_INDEX, authenticatorData, clientDataJSON);
    }

    function _eoaSig(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return abi.encodePacked(bytes1(0x01), r, s, v);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Accounts
    // ---------------------------------------------------------------------------------------------------------------

    function _initParams(uint256 pk, address[] memory guardians_, uint8 threshold)
        internal
        pure
        returns (IPasskeyAccount.InitParams memory)
    {
        return IPasskeyAccount.InitParams({passkey: _passkey(pk), guardians: guardians_, threshold: threshold});
    }

    function _noGuardians() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _createAccount(uint256 pk) internal returns (PasskeyAccount) {
        return _createAccount(_initParams(pk, _noGuardians(), 0), bytes32(0));
    }

    function _createAccount(IPasskeyAccount.InitParams memory params, bytes32 salt) internal returns (PasskeyAccount) {
        address account = factory.createAccount(params, salt);
        vm.deal(account, 10 ether);
        return PasskeyAccount(payable(account));
    }

    /// @dev Delegates `eoa` to the implementation through a real EIP-7702 authorization.
    function _delegate(uint256 eoaPk) internal returns (address eoa) {
        eoa = vm.addr(eoaPk);
        vm.signAndAttachDelegation(address(implementation), eoaPk);
        // Any call carries the authorization; a zero-value self-call is the cheapest.
        vm.prank(eoa);
        (bool ok,) = eoa.call("");
        ok; // the call target has code after the delegation is applied; its result is irrelevant
        vm.deal(eoa, 10 ether);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // User operations
    // ---------------------------------------------------------------------------------------------------------------

    function _op(address sender, bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = entryPoint.getNonce(sender, 0);
        op.callData = callData;
        op.accountGasLimits = _pack(1_000_000, 500_000);
        op.preVerificationGas = 60_000;
        op.gasFees = _pack(1 gwei, 5 gwei);
    }

    function _withPaymaster(PackedUserOperation memory op, bytes memory paymasterData, uint128 postOpGas)
        internal
        view
        returns (PackedUserOperation memory)
    {
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(300_000), postOpGas, paymasterData);
        return op;
    }

    /// @dev Appends an EntryPoint v0.9 paymaster signature suffix (`sig || uint16(len) || magic`).
    function _appendPaymasterSig(PackedUserOperation memory op, bytes memory sig)
        internal
        pure
        returns (PackedUserOperation memory)
    {
        op.paymasterAndData = abi.encodePacked(op.paymasterAndData, sig, uint16(sig.length), bytes8(0x22e325a297439656));
        return op;
    }

    function _guaranteeSig(bytes32 userOpHash, uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(sponsorPk, paymaster.sponsorGuaranteeDigest(userOpHash, validUntil, validAfter));
        return abi.encodePacked(r, s, v);
    }

    function _signPasskey(PackedUserOperation memory op, uint256 pk)
        internal
        view
        returns (PackedUserOperation memory)
    {
        op.signature = _webauthnSig(pk, entryPoint.getUserOpHash(op));
        return op;
    }

    function _signEoa(PackedUserOperation memory op, uint256 pk) internal view returns (PackedUserOperation memory) {
        op.signature = _eoaSig(pk, entryPoint.getUserOpHash(op));
        return op;
    }

    function _handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundlerEoa, bundlerEoa);
        entryPoint.handleOps(ops, beneficiary);
    }

    function _handleExpectFailedOp(PackedUserOperation memory op, string memory reason) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(abi.encodeWithSelector(IEntryPointV09.FailedOp.selector, 0, reason));
        vm.prank(bundlerEoa, bundlerEoa);
        entryPoint.handleOps(ops, beneficiary);
    }

    function _pack(uint256 high, uint256 low) internal pure returns (bytes32) {
        return bytes32((high << 128) | low);
    }

    function _batch(Execution[] memory calls) internal pure returns (bytes memory) {
        return abi.encodeCall(PasskeyAccount.execute, (MODE_BATCH, abi.encode(calls)));
    }

    function _single(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution({target: target, value: value, callData: data});
        return _batch(calls);
    }
}
