// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Erc7739Helper} from "../utils/Erc7739Helper.sol";

/// @notice ERC-1271 through ERC-7739: nested typed data and nested personal sign, for both signers.
contract PasskeyAccountErc1271Test is BaseTest {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    PasskeyAccount internal account;
    address internal app = makeAddr("mailApp");

    function setUp() public override {
        super.setUp();
        account = _createAccount(PASSKEY_PK);
    }

    function test_TypedData_PasskeyValid() public view {
        bytes32 appSep = Erc7739Helper.appSeparator(app);
        bytes32 contents = Erc7739Helper.mailHash(address(0xB0B), "hello");
        bytes32 appHash = MessageHashUtils.toTypedDataHash(appSep, contents);
        bytes memory inner =
            _webauthnSig(PASSKEY_PK, Erc7739Helper.typedDataSignDigest(address(account), appSep, contents));
        assertEq(account.isValidSignature(appHash, Erc7739Helper.wrapTypedDataSig(inner, appSep, contents)), MAGIC);
    }

    function test_TypedData_RejectsRawSignatureOverAppHash() public view {
        // Signing the application hash directly (no ERC-7739 envelope) is not accepted.
        bytes32 appSep = Erc7739Helper.appSeparator(app);
        bytes32 appHash = MessageHashUtils.toTypedDataHash(appSep, Erc7739Helper.mailHash(address(0xB0B), "hello"));
        assertEq(account.isValidSignature(appHash, _webauthnSig(PASSKEY_PK, appHash)), bytes4(0xffffffff));
    }

    function test_TypedData_RejectsMismatchedContents() public view {
        bytes32 appSep = Erc7739Helper.appSeparator(app);
        bytes32 contents = Erc7739Helper.mailHash(address(0xB0B), "hello");
        bytes32 otherHash = MessageHashUtils.toTypedDataHash(appSep, Erc7739Helper.mailHash(address(0xB0B), "goodbye"));
        bytes memory inner =
            _webauthnSig(PASSKEY_PK, Erc7739Helper.typedDataSignDigest(address(account), appSep, contents));
        assertEq(
            account.isValidSignature(otherHash, Erc7739Helper.wrapTypedDataSig(inner, appSep, contents)),
            bytes4(0xffffffff)
        );
    }

    function test_PersonalSign_PasskeyValid() public view {
        bytes32 msgHash = MessageHashUtils.toEthSignedMessageHash(bytes("Sign in to Mail App"));
        bytes memory sig = _webauthnSig(PASSKEY_PK, Erc7739Helper.personalSignDigest(address(account), msgHash));
        assertEq(account.isValidSignature(msgHash, sig), MAGIC);
    }

    function test_PersonalSign_WrongKeyRejected() public view {
        bytes32 msgHash = MessageHashUtils.toEthSignedMessageHash(bytes("Sign in to Mail App"));
        bytes memory sig =
            _webauthnSig(ATTACKER_PASSKEY_PK, Erc7739Helper.personalSignDigest(address(account), msgHash));
        assertEq(account.isValidSignature(msgHash, sig), bytes4(0xffffffff));
    }

    function test_DetectionMagicValue() public view {
        assertEq(
            account.isValidSignature(0x7739773977397739773977397739773977397739773977397739773977397739, ""),
            bytes4(0x77390001)
        );
    }

    function test_Eip7702_EoaSignerThroughErc7739() public {
        uint256 eoaPk = 0xE0A;
        address eoa = _delegate(eoaPk);
        bytes32 msgHash = MessageHashUtils.toEthSignedMessageHash(bytes("hello from an upgraded EOA"));
        bytes memory sig = _eoaSig(eoaPk, Erc7739Helper.personalSignDigest(eoa, msgHash));
        assertEq(PasskeyAccount(payable(eoa)).isValidSignature(msgHash, sig), MAGIC);
        // Compatibility consequence of 7702 + ERC-7739: code-aware verifiers (OpenZeppelin 5.7 SignatureChecker,
        // Permit2) switch to ERC-1271 once the EOA has code, so a raw EOA signature is no longer accepted there.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPk, msgHash);
        assertFalse(SignatureChecker.isValidSignatureNow(eoa, msgHash, abi.encodePacked(r, s, v)));
        assertTrue(SignatureChecker.isValidSignatureNow(eoa, msgHash, sig));
    }

    function testFuzz_PersonalSign_AnyMessage(bytes calldata message) public view {
        bytes32 msgHash = MessageHashUtils.toEthSignedMessageHash(message);
        bytes memory sig = _webauthnSig(PASSKEY_PK, Erc7739Helper.personalSignDigest(address(account), msgHash));
        assertEq(account.isValidSignature(msgHash, sig), MAGIC);
    }
}
