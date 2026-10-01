// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {IEntryPointV09} from "../utils/IEntryPointV09.sol";

interface ISenderCreator {
    function createSender(bytes calldata initCode) external returns (address);
}

/// @notice ERC-7562 storage rules, checked on the exact storage accesses made by each validation frame
/// (recorded with `vm.startStateDiffRecording`). Frames are invoked the way the EntryPoint invokes them.
///
/// Rules exercised: STO-010 (account storage), STO-021/022 (associated storage of the sender in external contracts),
/// STO-031/032 (staked paymaster: own storage and storage associated with it). Any access outside these sets fails.
contract ValidationStorageRulesTest is BaseTest {
    PasskeyAccount internal account;

    struct Access {
        address target;
        bytes32 slot;
        bool isWrite;
    }

    function setUp() public override {
        super.setUp();
        account = _createAccount(PASSKEY_PK);
        vm.startPrank(admin);
        usd.mint(address(account), 1000e6);
        vm.stopPrank();
        vm.prank(address(account));
        usd.approve(address(paymaster), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _flatten(Vm.AccountAccess[] memory diff) internal view returns (Access[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < diff.length; ++i) {
            n += diff[i].storageAccesses.length;
        }
        out = new Access[](n);
        uint256 k;
        for (uint256 i = 0; i < diff.length; ++i) {
            for (uint256 j = 0; j < diff[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = diff[i].storageAccesses[j];
                if (s.account == address(entryPoint)) continue; // the EntryPoint is trusted, not an entity
                out[k++] = Access(s.account, s.slot, s.isWrite);
            }
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    /// @dev OpenZeppelin ERC20 layout: `_balances` at slot 0, `_allowances` at slot 1.
    function _balanceSlot(address holder) internal pure returns (bytes32) {
        return keccak256(abi.encode(holder, uint256(0)));
    }

    function _allowanceSlot(address holder, address spender) internal pure returns (bytes32) {
        return keccak256(abi.encode(spender, keccak256(abi.encode(holder, uint256(1)))));
    }

    /// @dev A token slot is associated with `entity` if it is `keccak(entity || x)` for the mappings the token uses.
    function _tokenSlotAssociatedWith(bytes32 slot, address entity, address other) internal pure returns (bool) {
        return
            slot == _balanceSlot(entity) || slot == _allowanceSlot(other, entity)
                || slot == _allowanceSlot(entity, entity);
    }

    function _signedUserFundedOp() internal view returns (PackedUserOperation memory op, bytes32 hash) {
        op = _withPaymaster(
            _op(address(account), _single(address(usd), 0, abi.encodeCall(IERC20.transfer, (address(1), 1)))),
            hex"00",
            80_000
        );
        hash = entryPoint.getUserOpHash(op);
        op.signature = _webauthnSig(PASSKEY_PK, hash);
    }

    // ------------------------------------------------------------------ account frame

    function test_Sto010_AccountValidationTouchesOnlyAccountStorage() public {
        (PackedUserOperation memory op, bytes32 hash) = _signedUserFundedOp();
        vm.startStateDiffRecording();
        vm.prank(address(entryPoint));
        uint256 vd = account.validateUserOp(op, hash, 0);
        Access[] memory acc = _flatten(vm.stopAndReturnStateDiff());
        assertEq(vd, 0);
        assertGt(acc.length, 0);
        for (uint256 i = 0; i < acc.length; ++i) {
            assertEq(acc[i].target, address(account), "account validation touched foreign storage");
            assertFalse(acc[i].isWrite, "account validation wrote storage");
        }
    }

    function test_Sto010_FrozenAccountValidationStillOnlyReadsOwnStorage() public {
        vm.prank(address(account));
        account.freeze();
        (PackedUserOperation memory op, bytes32 hash) = _signedUserFundedOp();
        vm.startStateDiffRecording();
        vm.prank(address(entryPoint));
        account.validateUserOp(op, hash, 0);
        Access[] memory acc = _flatten(vm.stopAndReturnStateDiff());
        for (uint256 i = 0; i < acc.length; ++i) {
            assertEq(acc[i].target, address(account));
        }
    }

    function test_Sto022_FactoryDeploymentWritesOnlySenderStorage() public {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK_2, _noGuardians(), 0);
        address sender = factory.getAddress(p, 0);
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (p, bytes32(0))));
        address creator = entryPoint.senderCreator();
        vm.startStateDiffRecording();
        vm.prank(address(entryPoint));
        address created = ISenderCreator(creator).createSender(initCode);
        Access[] memory acc = _flatten(vm.stopAndReturnStateDiff());
        assertEq(created, sender);
        for (uint256 i = 0; i < acc.length; ++i) {
            assertEq(acc[i].target, sender, "factory touched storage outside the new account");
        }
    }

    // ------------------------------------------------------------------ paymaster frame

    function test_Sto032_UserFundedPaymasterValidation() public {
        (PackedUserOperation memory op, bytes32 hash) = _signedUserFundedOp();
        vm.startStateDiffRecording();
        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, hash, 1e16);
        Access[] memory acc = _flatten(vm.stopAndReturnStateDiff());
        assertEq(vd, 0);
        bool touchedOwn;
        for (uint256 i = 0; i < acc.length; ++i) {
            if (acc[i].target == address(paymaster)) {
                touchedOwn = true; // STO-031: allowed because the paymaster is staked
                continue;
            }
            assertEq(acc[i].target, address(usd), "paymaster validation touched an unexpected contract");
            bool ok = _tokenSlotAssociatedWith(acc[i].slot, address(account), address(paymaster))
                || _tokenSlotAssociatedWith(acc[i].slot, address(paymaster), address(account));
            assertTrue(ok, "token slot not associated with sender or paymaster");
        }
        assertTrue(touchedOwn);
        assertTrue(IEntryPointV09(address(entryPoint)).getDepositInfo(address(paymaster)).staked);
    }

    function test_Sto032_GuaranteedPaymasterValidationTouchesOnlyPaymasterAssociatedSlots() public {
        PackedUserOperation memory op = _op(address(account), "");
        op = _withPaymaster(op, abi.encodePacked(bytes1(0x01), uint48(0), uint48(0)), 120_000);
        bytes32 hash = entryPoint.getUserOpHash(_appendPaymasterSig(_clone(op), new bytes(65)));
        op.signature = _webauthnSig(PASSKEY_PK, hash);
        op = _appendPaymasterSig(op, _guaranteeSig(hash, 0, 0));
        vm.startStateDiffRecording();
        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, hash, 1e16);
        Access[] memory acc = _flatten(vm.stopAndReturnStateDiff());
        assertEq(vd, 0);
        for (uint256 i = 0; i < acc.length; ++i) {
            if (acc[i].target == address(paymaster)) continue;
            assertEq(acc[i].target, address(usd));
            // The paymaster fronts the prefund from its own float: only its own balance and self-allowance move.
            assertTrue(
                acc[i].slot == _balanceSlot(address(paymaster))
                    || acc[i].slot == _allowanceSlot(address(paymaster), address(paymaster)),
                "guaranteed validation touched sender or third-party token storage"
            );
        }
    }

    function _clone(PackedUserOperation memory op) internal pure returns (PackedUserOperation memory) {
        return abi.decode(abi.encode(op), (PackedUserOperation));
    }
}
