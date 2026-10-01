// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Simple7702Account} from "account-abstraction/accounts/Simple7702Account.sol";
import {IEntryPoint as AAIEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {WebAuthnSolidityP256} from "./WebAuthnSolidityP256.sol";

/// @notice Same account, same checks; only the final P-256 step runs in pure Solidity. On an Osaka EVM the
/// EIP-7951 precompile is always present, so this harness is how the fallback is measured side by side.
contract PasskeyAccountSolidityP256 is PasskeyAccount {
    constructor(IEntryPoint ep, address factory_) PasskeyAccount(ep, factory_) {}

    function _verifyWebAuthn(bytes memory challenge, WebAuthn.WebAuthnAuth calldata auth, bytes32 qx, bytes32 qy)
        internal
        view
        override
        returns (bool)
    {
        WebAuthnSolidityP256.WebAuthnAuth memory a = WebAuthnSolidityP256.WebAuthnAuth({
            r: auth.r,
            s: auth.s,
            challengeIndex: auth.challengeIndex,
            typeIndex: auth.typeIndex,
            authenticatorData: auth.authenticatorData,
            clientDataJSON: auth.clientDataJSON
        });
        return WebAuthnSolidityP256.verify(challenge, a, qx, qy, true);
    }
}

/// @notice Gas benchmark. `forge snapshot --match-contract GasBench` records the per-test totals in `.gas-snapshot`;
/// `vm.snapshotGasLastFrame` records the isolated call costs in `snapshots/validateUserOp.json` and
/// `snapshots/handleOps.json`. CI checks both (`forge snapshot --check`, and `FORGE_SNAPSHOT_CHECK=true` on the test
/// run). Only the default (optimized) build may write them: the `coverage` profile disables snapshot emission.
contract GasBench is BaseTest {
    uint256 internal constant EOA_PK = 0xE0A;
    bytes32 internal constant HASH = keccak256("gas bench user operation");

    PasskeyAccount internal account;
    PasskeyAccount internal solidityP256Account;
    address internal eoa;
    Simple7702Account internal simple7702;
    address internal simpleEoa;

    function setUp() public override {
        super.setUp();
        account = _createAccount(PASSKEY_PK);

        PasskeyAccountSolidityP256 harness =
            new PasskeyAccountSolidityP256(IEntryPoint(address(entryPoint)), address(this));
        solidityP256Account = PasskeyAccount(payable(Clones.clone(address(harness))));
        solidityP256Account.initialize(_initParams(PASSKEY_PK, _noGuardians(), 0));

        eoa = _delegate(EOA_PK);
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        vm.prank(eoa);
        PasskeyAccount(payable(eoa)).initialize(p);

        // Baseline: eth-infinitism's reference EIP-7702 account (ECDSA only).
        simple7702 = new Simple7702Account(AAIEntryPoint(address(entryPoint)));
        simpleEoa = vm.addr(0x51A);
        vm.signAndAttachDelegation(address(simple7702), 0x51A);
        vm.prank(simpleEoa);
        (bool ok,) = simpleEoa.call("");
        require(ok, "delegation failed");

        vm.startPrank(admin);
        usd.mint(address(account), 1000e6);
        vm.stopPrank();
        vm.prank(address(account));
        usd.approve(address(paymaster), type(uint256).max);
    }

    function _validationOp(address sender, bytes memory signature)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _op(sender, "");
        op.signature = signature;
    }

    // ------------------------------------------------------------------ validateUserOp: the two P-256 paths

    function test_ValidateUserOp_WebAuthn_Eip7951Precompile() public {
        PackedUserOperation memory op = _validationOp(address(account), _webauthnSig(PASSKEY_PK, HASH));
        vm.prank(address(entryPoint));
        uint256 vd = account.validateUserOp(op, HASH, 0);
        vm.snapshotGasLastFrame("validateUserOp", "webauthn_eip7951_precompile");
        assertEq(vd, 0);
    }

    function test_ValidateUserOp_WebAuthn_SolidityFallback() public {
        PackedUserOperation memory op = _validationOp(address(solidityP256Account), _webauthnSig(PASSKEY_PK, HASH));
        vm.prank(address(entryPoint));
        uint256 vd = solidityP256Account.validateUserOp(op, HASH, 0);
        vm.snapshotGasLastFrame("validateUserOp", "webauthn_solidity_p256");
        assertEq(vd, 0);
    }

    function test_ValidateUserOp_Eip7702EoaSigner() public {
        PackedUserOperation memory op = _validationOp(eoa, _eoaSig(EOA_PK, HASH));
        vm.prank(address(entryPoint));
        uint256 vd = PasskeyAccount(payable(eoa)).validateUserOp(op, HASH, 0);
        vm.snapshotGasLastFrame("validateUserOp", "eip7702_eoa_ecdsa");
        assertEq(vd, 0);
    }

    function test_ValidateUserOp_Baseline_Simple7702Account() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x51A, HASH);
        PackedUserOperation memory op = _validationOp(simpleEoa, abi.encodePacked(r, s, v));
        vm.prank(address(entryPoint));
        uint256 vd = PasskeyAccount(payable(simpleEoa)).validateUserOp(op, HASH, 0);
        vm.snapshotGasLastFrame("validateUserOp", "baseline_simple7702account_ecdsa");
        assertEq(vd, 0);
    }

    // ------------------------------------------------------------------ full operations through handleOps

    function test_HandleOps_Erc20PaidBatchOfTwoTransfers() public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(usd), 0, abi.encodeCall(IERC20.transfer, (makeAddr("alice"), 1e6)));
        calls[1] = Execution(address(usd), 0, abi.encodeCall(IERC20.transfer, (makeAddr("bob"), 2e6)));
        PackedUserOperation memory op =
            _signPasskey(_withPaymaster(_op(address(account), _batch(calls)), hex"00", 80_000), PASSKEY_PK);
        _handle(op);
        vm.snapshotGasLastFrame("handleOps", "erc20_paid_batch_2_transfers");
    }

    function test_HandleOps_DeployAccountGuaranteedFirstOp() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK_2, _noGuardians(), 0);
        address predicted = factory.getAddress(p, 0);
        vm.prank(admin);
        usd.mint(predicted, 10e6);
        PackedUserOperation memory op = _op(
            predicted, _single(address(usd), 0, abi.encodeCall(IERC20.approve, (address(paymaster), type(uint256).max)))
        );
        op.initCode = abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (p, bytes32(0))));
        op = _withPaymaster(op, abi.encodePacked(bytes1(0x01), uint48(0), uint48(0)), 120_000);
        PackedUserOperation memory forHash = abi.decode(abi.encode(op), (PackedUserOperation));
        bytes32 hash = entryPoint.getUserOpHash(_appendPaymasterSig(forHash, new bytes(65)));
        op.signature = _webauthnSig(PASSKEY_PK_2, hash);
        op = _appendPaymasterSig(op, _guaranteeSig(hash, 0, 0));
        _handle(op);
        vm.snapshotGasLastFrame("handleOps", "deploy_and_approve_guaranteed");
    }

    function test_HandleOps_Eip7702UpgradeInitialize() public {
        address fresh = _delegate(0xF4E5);
        bytes memory callData = abi.encodeCall(PasskeyAccount.initialize, (_initParams(PASSKEY_PK, _noGuardians(), 0)));
        _handle(_signEoa(_op(fresh, callData), 0xF4E5));
        vm.snapshotGasLastFrame("handleOps", "eip7702_initialize_eoa_signed");
    }
}
