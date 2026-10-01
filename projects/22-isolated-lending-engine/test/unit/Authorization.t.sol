// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {Authorization, ILendingEngine} from "../../src/interfaces/ILendingEngine.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract AuthorizationTest is BaseTest {
    uint256 internal signerKey = 0xA11CE;
    address internal signer;
    address internal manager = makeAddr("manager");
    address internal relayer = makeAddr("relayer");

    function setUp() public override {
        super.setUp();
        signer = vm.addr(signerKey);
    }

    function _auth(address authorizer, bool status, uint256 nonce_, uint256 deadline)
        internal
        view
        returns (Authorization memory)
    {
        return Authorization({
            authorizer: authorizer, authorized: manager, isAuthorized: status, nonce: nonce_, deadline: deadline
        });
    }

    function _digest(Authorization memory a) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(engine.AUTHORIZATION_TYPEHASH(), a));
        return keccak256(abi.encodePacked("\x19\x01", engine.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 key, Authorization memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(a));
        return abi.encodePacked(r, s, v);
    }

    function test_setAuthorization() public {
        vm.expectEmit(address(engine));
        emit ILendingEngine.SetAuthorization(supplier, supplier, manager, true);
        vm.prank(supplier);
        engine.setAuthorization(manager, true);
        assertTrue(engine.isAuthorized(supplier, manager));

        vm.prank(supplier);
        engine.setAuthorization(manager, false);
        assertFalse(engine.isAuthorized(supplier, manager));
    }

    function test_domainSeparator_matchesEip712() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IsolatedLendingEngine"),
                keccak256("1"),
                block.chainid,
                address(engine)
            )
        );
        assertEq(engine.DOMAIN_SEPARATOR(), expected);
    }

    function test_setAuthorizationWithSig() public {
        Authorization memory a = _auth(signer, true, 0, block.timestamp + 1 hours);
        bytes memory sig = _sign(signerKey, a);

        vm.expectEmit(address(engine));
        emit ILendingEngine.IncrementNonce(relayer, signer, 0);
        vm.expectEmit(address(engine));
        emit ILendingEngine.SetAuthorization(relayer, signer, manager, true);
        vm.prank(relayer);
        engine.setAuthorizationWithSig(a, sig);

        assertTrue(engine.isAuthorized(signer, manager));
        assertEq(engine.nonce(signer), 1);
    }

    function test_setAuthorizationWithSig_managerCanThenBorrow() public {
        Authorization memory a = _auth(signer, true, 0, block.timestamp);
        engine.setAuthorizationWithSig(a, _sign(signerKey, a));

        _supply(supplier, 100e18);
        _approveAll(signer);
        _supplyCollateral(signer, 100e18);
        vm.prank(manager);
        engine.borrow(marketParams, 10e18, 0, signer, manager);
        assertEq(loanToken.balanceOf(manager), 10e18);
    }

    function test_setAuthorizationWithSig_revertsWhenExpired() public {
        Authorization memory a = _auth(signer, true, 0, block.timestamp - 1);
        bytes memory sig = _sign(signerKey, a);
        vm.expectRevert(
            abi.encodeWithSelector(ILendingEngine.SignatureExpired.selector, block.timestamp - 1, block.timestamp)
        );
        engine.setAuthorizationWithSig(a, sig);
    }

    function test_setAuthorizationWithSig_revertsOnWrongNonce() public {
        Authorization memory a = _auth(signer, true, 1, block.timestamp);
        bytes memory sig = _sign(signerKey, a);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InvalidNonce.selector, 0, 1));
        engine.setAuthorizationWithSig(a, sig);
    }

    function test_setAuthorizationWithSig_revertsOnReplay() public {
        Authorization memory a = _auth(signer, true, 0, block.timestamp);
        bytes memory sig = _sign(signerKey, a);
        engine.setAuthorizationWithSig(a, sig);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InvalidNonce.selector, 1, 0));
        engine.setAuthorizationWithSig(a, sig);
    }

    function test_setAuthorizationWithSig_revertsOnWrongSigner() public {
        Authorization memory a = _auth(signer, true, 0, block.timestamp);
        bytes memory sig = _sign(0xB0B, a);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InvalidSignature.selector, signer));
        engine.setAuthorizationWithSig(a, sig);
    }

    function test_setAuthorizationWithSig_revertsOnTamperedMessage() public {
        Authorization memory a = _auth(signer, true, 0, block.timestamp);
        bytes memory sig = _sign(signerKey, a);
        a.isAuthorized = false;
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InvalidSignature.selector, signer));
        engine.setAuthorizationWithSig(a, sig);
    }

    function test_setAuthorizationWithSig_revertsOnOtherChain() public {
        Authorization memory a = _auth(signer, true, 0, block.timestamp);
        bytes memory sig = _sign(signerKey, a);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InvalidSignature.selector, signer));
        engine.setAuthorizationWithSig(a, sig);
    }

    function test_setAuthorizationWithSig_erc1271Wallet() public {
        SmartWallet wallet = new SmartWallet(signer);
        Authorization memory a = _auth(address(wallet), true, 0, block.timestamp);
        engine.setAuthorizationWithSig(a, _sign(signerKey, a));
        assertTrue(engine.isAuthorized(address(wallet), manager));
    }

    function test_setAuthorizationWithSig_erc1271WalletRejects() public {
        SmartWallet wallet = new SmartWallet(signer);
        Authorization memory a = _auth(address(wallet), true, 0, block.timestamp);
        bytes memory sig = _sign(0xB0B, a);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.InvalidSignature.selector, address(wallet)));
        engine.setAuthorizationWithSig(a, sig);
    }
}

/// @dev ERC-1271 wallet controlled by a single EOA key.
contract SmartWallet is IERC1271 {
    address internal immutable OWNER;

    constructor(address owner_) {
        OWNER = owner_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == OWNER ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}
