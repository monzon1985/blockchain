// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/account/AgentAccountFactory.sol";
import {BudgetExecutor} from "../../src/modules/BudgetExecutor.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MaliciousDelegatecallExecutor, StorageClobberer} from "../utils/Mocks.sol";
import {Account as OZAccount} from "@openzeppelin/contracts/account/Account.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution, MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract AgentAccountTest is Fixture {
    AgentAccount internal account;

    function setUp() public override {
        super.setUp();
        account = _createAccount(_defaultPolicy(), _payees());
        _mint(address(account), 10 * ONE);
    }

    function test_Initialized() public view {
        assertEq(account.signer(), owner);
        assertEq(account.accountId(), "x402-local.AgentAccount.v1.0.0");
        assertTrue(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, address(executor), ""));
    }

    function test_RevertWhen_InitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        account.initialize(relayer, address(executor), "");
    }

    function test_RevertWhen_ImplementationInitialized() public {
        AgentAccount impl = AgentAccount(payable(factory.ACCOUNT_IMPLEMENTATION()));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(relayer, address(executor), "");
    }

    function test_RevertWhen_InitializedWithZeroOwner() public {
        bytes memory data = abi.encode(_defaultPolicy(), _payees());
        vm.expectRevert(AgentAccount.ZeroOwner.selector);
        factory.createAccount(address(0), data, bytes32(0));
    }

    function test_OwnerExecutesDirectly() public {
        vm.prank(owner);
        account.execute(
            bytes32(0), abi.encodePacked(address(token), uint256(0), abi.encodeCall(IERC20.transfer, (owner, ONE)))
        );
        assertEq(token.balanceOf(owner), ONE);
    }

    function test_OwnerExecutesBatch() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(token), 0, abi.encodeCall(IERC20.transfer, (owner, ONE)));
        calls[1] = Execution(address(token), 0, abi.encodeCall(IERC20.transfer, (payee, ONE)));
        vm.prank(owner);
        account.execute(bytes32(bytes1(0x01)), abi.encode(calls));
        assertEq(token.balanceOf(owner) + token.balanceOf(payee), 2 * ONE);
    }

    function test_RevertWhen_StrangerExecutes() public {
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, session));
        vm.prank(session);
        account.execute(bytes32(0), abi.encodePacked(address(token), uint256(0), ""));
    }

    function test_RevertWhen_SessionKeyTriesToInstallModules() public {
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, session));
        vm.prank(session);
        account.uninstallModule(MODULE_TYPE_EXECUTOR, address(executor), "");
    }

    function test_DelegatecallModeUnsupported() public view {
        assertFalse(account.supportsExecutionMode(bytes32(bytes1(0xff))));
        assertTrue(account.supportsExecutionMode(bytes32(0)));
        assertTrue(account.supportsExecutionMode(bytes32(bytes1(0x01))));
    }

    function test_RevertWhen_OwnerRequestsDelegatecall() public {
        StorageClobberer clobberer = new StorageClobberer();
        vm.expectRevert(AgentAccount.DelegatecallDisabled.selector);
        vm.prank(owner);
        account.execute(
            bytes32(bytes1(0xff)), abi.encodePacked(address(clobberer), abi.encodeCall(StorageClobberer.clobber, ()))
        );
    }

    function test_RevertWhen_ExecutorRequestsDelegatecall() public {
        MaliciousDelegatecallExecutor evil = new MaliciousDelegatecallExecutor();
        StorageClobberer clobberer = new StorageClobberer();
        vm.prank(owner);
        account.installModule(MODULE_TYPE_EXECUTOR, address(evil), "");

        vm.expectRevert(AgentAccount.DelegatecallDisabled.selector);
        evil.attack(address(account), address(clobberer), abi.encodeCall(StorageClobberer.clobber, ()));
        // Single CALL mode from the same executor works, so the rejection is specific to delegatecall.
        evil.single(address(account), address(token), abi.encodeCall(IERC20.transfer, (payee, 1)));
        assertEq(token.balanceOf(payee), 1);
    }

    function test_ERC1271_NestedTypedData() public view {
        bytes32 appSeparator = _domainSeparator(address(reputation));
        bytes32 contentsHash = keccak256("contents");
        string memory contentsType = "Note(bytes32 body)";
        bytes memory sig = _erc7739Sign(ownerKey, account, appSeparator, contentsHash, "Note", contentsType);
        bytes32 hash = MessageHashUtils.toTypedDataHash(appSeparator, contentsHash);
        assertEq(account.isValidSignature(hash, sig), IERC1271.isValidSignature.selector);

        bytes memory wrongKey = _erc7739Sign(sessionKey, account, appSeparator, contentsHash, "Note", contentsType);
        assertEq(account.isValidSignature(hash, wrongKey), bytes4(0xffffffff));
    }

    function test_ERC1271_RawOwnerSignatureRejected() public view {
        // A plain ECDSA signature over the app digest is not accepted: ERC-7739 wrapping is required, which stops
        // one owner signature from being replayed across several accounts the same key controls.
        bytes32 hash = keccak256("digest");
        assertEq(account.isValidSignature(hash, _sign(ownerKey, hash)), bytes4(0xffffffff));
    }

    function test_ERC7739Detection() public view {
        bytes32 probe = 0x7739773977397739773977397739773977397739773977397739773977397739;
        assertEq(account.isValidSignature(probe, ""), bytes4(0x77390001));
    }

    // ------------------------------------------------------------------ factory

    function test_Factory_PredictsAndIsIdempotent() public {
        bytes memory data = abi.encode(_defaultPolicy(), _payees());
        address predicted = factory.predictAccount(owner, data, bytes32(uint256(5)));
        assertEq(predicted.code.length, 0);
        address created = factory.createAccount(owner, data, bytes32(uint256(5)));
        assertEq(created, predicted);
        assertEq(factory.createAccount(owner, data, bytes32(uint256(5))), created, "second call returns existing");
    }

    function test_Factory_SaltBindsPolicy() public {
        // A front-runner who deploys "for" the owner with their own session key lands on a different address.
        BudgetExecutor.Policy memory honest = _defaultPolicy();
        BudgetExecutor.Policy memory evil = _defaultPolicy();
        evil.sessionKey = relayer;
        address honestAddr = factory.predictAccount(owner, abi.encode(honest, _payees()), bytes32(uint256(9)));
        address evilAddr = factory.createAccount(owner, abi.encode(evil, _payees()), bytes32(uint256(9)));
        assertTrue(honestAddr != evilAddr);
        assertEq(honestAddr.code.length, 0);
    }

    /// @notice Regression: funds sent to a predicted address stay recoverable after the policy's session expired.
    ///         The salt commits to `validUntil`, so an expiry check at install time would lock them forever.
    function test_Factory_CounterfactualAddressDeployableAfterSessionExpiry() public {
        BudgetExecutor.Policy memory p = _defaultPolicy();
        bytes memory data = abi.encode(p, _payees());
        address predicted = factory.predictAccount(owner, data, bytes32(uint256(21)));
        _mint(predicted, 100 * ONE);
        vm.warp(uint256(p.validUntil) + 1);

        address created = factory.createAccount(owner, data, bytes32(uint256(21)));
        assertEq(created, predicted);
        assertGt(created.code.length, 0);
        vm.prank(owner);
        AgentAccount(payable(created))
            .execute(
                bytes32(0),
                abi.encodePacked(address(token), uint256(0), abi.encodeCall(IERC20.transfer, (owner, 100 * ONE)))
            );
        assertEq(token.balanceOf(owner), 100 * ONE);
    }

    function test_RevertWhen_FactoryWithoutExecutor() public {
        vm.expectRevert(AgentAccountFactory.ZeroExecutor.selector);
        new AgentAccountFactory(address(0));
    }

    function test_Factory_EmitsOnCreate() public {
        bytes memory data = abi.encode(_defaultPolicy(), _payees());
        bytes32 salt = factory.accountSalt(owner, data, bytes32(uint256(11)));
        address predicted = factory.predictAccount(owner, data, bytes32(uint256(11)));
        vm.expectEmit(address(factory));
        emit AgentAccountFactory.AccountCreated(predicted, owner, salt);
        factory.createAccount(owner, data, bytes32(uint256(11)));
    }

    function test_ValidateUserOp_OwnerSignature() public {
        bytes32 userOpHash = keccak256("userOpHash");
        PackedUserOperation memory op = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: _sign(ownerKey, userOpHash)
        });
        vm.prank(address(account.entryPoint()));
        assertEq(account.validateUserOp(op, userOpHash, 0), 0, "owner signature accepted");

        op.signature = _sign(sessionKey, userOpHash);
        vm.prank(address(account.entryPoint()));
        assertEq(account.validateUserOp(op, userOpHash, 0), 1, "session key cannot sign user operations");
    }

    function test_ReceivesEther() public {
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        (bool ok,) = address(account).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(account).balance, 1 ether);
    }
}
