// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {IEntryPointV09} from "../utils/IEntryPointV09.sol";

contract PasskeyAccountInitTest is BaseTest {
    uint256 internal constant EOA_PK = 0xE0A;
    address internal eoa;

    function setUp() public override {
        super.setUp();
        eoa = _delegate(EOA_PK);
    }

    function _guardians3() internal returns (address[] memory g) {
        g = new address[](3);
        g[0] = makeAddr("g0");
        g[1] = makeAddr("g1");
        g[2] = makeAddr("g2");
    }

    function _initDigest(address account, IPasskeyAccount.InitParams memory p, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                implementation.INITIALIZE_TYPEHASH(),
                p.passkey.qx,
                p.passkey.qy,
                p.passkey.rpIdHash,
                keccak256(abi.encodePacked(p.guardians)),
                p.threshold,
                deadline
            )
        );
        (, string memory name, string memory version, uint256 chainId,,,) =
            PasskeyAccount(payable(account)).eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                account
            )
        );
        return MessageHashUtils.toTypedDataHash(domain, structHash);
    }

    // ------------------------------------------------------------------ constructor / implementation

    function test_Constructor_LocksImplementation() public {
        assertTrue(implementation.initialized());
        assertEq(implementation.FACTORY(), address(factory));
        assertEq(address(implementation.entryPoint()), address(entryPoint));
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        vm.prank(address(factory));
        vm.expectRevert(IPasskeyAccount.AlreadyInitialized.selector);
        implementation.initialize(p);
    }

    function test_Constructor_RevertsOnZeroEntryPoint() public {
        vm.expectRevert(IPasskeyAccount.InvalidEntryPoint.selector);
        new PasskeyAccount(IEntryPoint(address(0)), address(0));
    }

    function test_StorageSlot_MatchesErc7201Formula() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("passkeysa.account.v1")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, 0x1ab98a993e960ba9421ad09bc249211ba6a0e1facaa807b437fdd35018ef2000);
    }

    // ------------------------------------------------------------------ initialize (7702)

    function test_Initialize_SelfCall() public {
        address[] memory g = _guardians3();
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, g, 2);
        vm.expectEmit(eoa);
        emit IPasskeyAccount.AccountInitialized(p.passkey.qx, p.passkey.qy, p.passkey.rpIdHash, 3, 2);
        vm.prank(eoa);
        PasskeyAccount(payable(eoa)).initialize(p);
        PasskeyAccount acct = PasskeyAccount(payable(eoa));
        assertTrue(acct.initialized());
        assertEq(acct.passkey().qx, _passkey(PASSKEY_PK).qx);
        assertEq(acct.guardians().length, 3);
        assertEq(acct.guardianThreshold(), 2);
        assertTrue(acct.isGuardian(g[1]));
    }

    function test_Initialize_ViaEntryPoint_SignedByEoa() public {
        bytes memory callData = abi.encodeCall(PasskeyAccount.initialize, (_initParams(PASSKEY_PK, _noGuardians(), 0)));
        _handle(_signEoa(_op(eoa, callData), EOA_PK));
        assertTrue(PasskeyAccount(payable(eoa)).initialized());
    }

    function test_Initialize_ViaEntryPoint_RejectsAttackerPasskey() public {
        // Before initialization there is no passkey: a user operation signed by any passkey fails validation.
        bytes memory callData =
            abi.encodeCall(PasskeyAccount.initialize, (_initParams(ATTACKER_PASSKEY_PK, _noGuardians(), 0)));
        _handleExpectFailedOp(_signPasskey(_op(eoa, callData), ATTACKER_PASSKEY_PK), "AA24 signature error");
        assertFalse(PasskeyAccount(payable(eoa)).initialized());
    }

    function test_Initialize_RevertsForThirdParty() public {
        address attacker = makeAddr("attacker");
        IPasskeyAccount.InitParams memory p = _initParams(ATTACKER_PASSKEY_PK, _noGuardians(), 0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InitializerUnauthorized.selector, attacker));
        PasskeyAccount(payable(eoa)).initialize(p);
    }

    function test_Initialize_RevertsForFactoryOnDelegatedEoa() public {
        IPasskeyAccount.InitParams memory p = _initParams(ATTACKER_PASSKEY_PK, _noGuardians(), 0);
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InitializerUnauthorized.selector, address(factory)));
        PasskeyAccount(payable(eoa)).initialize(p);
    }

    function test_Initialize_RevertsTwice() public {
        IPasskeyAccount.InitParams memory p1 = _initParams(PASSKEY_PK, _noGuardians(), 0);
        IPasskeyAccount.InitParams memory p2 = _initParams(PASSKEY_PK_2, _noGuardians(), 0);
        vm.startPrank(eoa);
        PasskeyAccount(payable(eoa)).initialize(p1);
        vm.expectRevert(IPasskeyAccount.AlreadyInitialized.selector);
        PasskeyAccount(payable(eoa)).initialize(p2);
        vm.stopPrank();
    }

    function test_Initialize_RevertsOnInvalidPasskey() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        p.passkey.qy = bytes32(uint256(p.passkey.qy) ^ 1);
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidPasskey.selector, p.passkey.qx, p.passkey.qy));
        PasskeyAccount(payable(eoa)).initialize(p);
    }

    function test_Initialize_RevertsOnBadGuardians() public {
        address[] memory g = new address[](2);
        g[0] = makeAddr("g0");
        g[1] = g[0];
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, g, 1);
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidGuardian.selector, g[0]));
        PasskeyAccount(payable(eoa)).initialize(p);

        p.guardians[1] = address(0);
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidGuardian.selector, address(0)));
        PasskeyAccount(payable(eoa)).initialize(p);

        p.guardians[1] = eoa;
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidGuardian.selector, eoa));
        PasskeyAccount(payable(eoa)).initialize(p);
    }

    function test_Initialize_RevertsOnTooManyGuardians() public {
        address[] memory g = new address[](9);
        for (uint256 i = 0; i < 9; ++i) {
            g[i] = address(uint160(0x1000 + i));
        }
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, g, 2);
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.TooManyGuardians.selector, 8));
        PasskeyAccount(payable(eoa)).initialize(p);
    }

    function test_Initialize_RevertsOnBadThreshold() public {
        address[] memory g = _guardians3();
        IPasskeyAccount.InitParams memory p4 = _initParams(PASSKEY_PK, g, 4);
        IPasskeyAccount.InitParams memory p0 = _initParams(PASSKEY_PK, g, 0);
        IPasskeyAccount.InitParams memory pNone = _initParams(PASSKEY_PK, _noGuardians(), 1);
        vm.startPrank(eoa);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidThreshold.selector, 4, 3));
        PasskeyAccount(payable(eoa)).initialize(p4);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidThreshold.selector, 0, 3));
        PasskeyAccount(payable(eoa)).initialize(p0);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.InvalidThreshold.selector, 1, 0));
        PasskeyAccount(payable(eoa)).initialize(pNone);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ initializeWithSig

    function test_InitializeWithSig_RelayedByAnyone() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _guardians3(), 2);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_PK, _initDigest(eoa, p, deadline));
        vm.prank(makeAddr("relayer"));
        PasskeyAccount(payable(eoa)).initializeWithSig(p, deadline, abi.encodePacked(r, s, v));
        assertTrue(PasskeyAccount(payable(eoa)).initialized());
        assertEq(PasskeyAccount(payable(eoa)).guardianThreshold(), 2);
    }

    function test_InitializeWithSig_RevertsOnTamperedParams() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_PK, _initDigest(eoa, p, deadline));
        IPasskeyAccount.InitParams memory tampered = _initParams(ATTACKER_PASSKEY_PK, _noGuardians(), 0);
        vm.expectRevert(IPasskeyAccount.InvalidInitSignature.selector);
        PasskeyAccount(payable(eoa)).initializeWithSig(tampered, deadline, abi.encodePacked(r, s, v));
    }

    function test_InitializeWithSig_RevertsOnWrongSigner() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, _initDigest(eoa, p, deadline));
        vm.expectRevert(IPasskeyAccount.InvalidInitSignature.selector);
        PasskeyAccount(payable(eoa)).initializeWithSig(p, deadline, abi.encodePacked(r, s, v));
    }

    function test_InitializeWithSig_RevertsAfterDeadline() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_PK, _initDigest(eoa, p, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IPasskeyAccount.SignatureExpired.selector, deadline));
        PasskeyAccount(payable(eoa)).initializeWithSig(p, deadline, abi.encodePacked(r, s, v));
    }

    function test_InitializeWithSig_CannotReplay() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_PK, _initDigest(eoa, p, deadline));
        PasskeyAccount(payable(eoa)).initializeWithSig(p, deadline, abi.encodePacked(r, s, v));
        vm.expectRevert(IPasskeyAccount.AlreadyInitialized.selector);
        PasskeyAccount(payable(eoa)).initializeWithSig(p, deadline, abi.encodePacked(r, s, v));
    }

    // ------------------------------------------------------------------ 7702 initCode marker path

    function test_Initialize_Via7702InitCodeMarker() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_PK, _initDigest(eoa, p, deadline));
        bytes memory initCall =
            abi.encodeCall(PasskeyAccount.initializeWithSig, (p, deadline, abi.encodePacked(r, s, v)));
        // EntryPoint v0.9: initCode = 0x7702 marker padded to 20 bytes || call data run by SenderCreator on the sender.
        bytes memory initCode = abi.encodePacked(bytes20(bytes2(0x7702)), initCall);
        PackedUserOperation memory op = _op(eoa, _single(makeAddr("nobody"), 0, ""));
        op.initCode = initCode;
        // After the init stage the passkey exists, so the operation may already be signed by it.
        _handle(_signPasskey(op, PASSKEY_PK));
        assertTrue(PasskeyAccount(payable(eoa)).initialized());
    }

    function test_Initialize_Via7702InitCodeMarker_RejectsPlainInitialize() public {
        bytes memory initCall =
            abi.encodeCall(PasskeyAccount.initialize, (_initParams(ATTACKER_PASSKEY_PK, _noGuardians(), 0)));
        PackedUserOperation memory op = _op(eoa, "");
        op.initCode = abi.encodePacked(bytes20(bytes2(0x7702)), initCall);
        op = _signPasskey(op, ATTACKER_PASSKEY_PK);
        address senderCreator = entryPoint.senderCreator();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPointV09.FailedOpWithRevert.selector,
                0,
                "AA13 EIP7702 sender init failed",
                abi.encodeWithSelector(IPasskeyAccount.InitializerUnauthorized.selector, senderCreator)
            )
        );
        vm.prank(bundlerEoa, bundlerEoa);
        entryPoint.handleOps(ops, beneficiary);
        assertFalse(PasskeyAccount(payable(eoa)).initialized());
    }
}
