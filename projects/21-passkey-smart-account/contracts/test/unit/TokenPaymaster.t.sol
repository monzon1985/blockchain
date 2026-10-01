// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Paymaster} from "@openzeppelin/contracts/account/paymaster/Paymaster.sol";
import {IEntryPoint, IPaymaster, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {TestUSD} from "../../src/TestUSD.sol";
import {TokenPaymaster} from "../../src/TokenPaymaster.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract TokenPaymasterTest is BaseTest {
    PasskeyAccount internal account;
    address internal recipient = makeAddr("recipient");

    struct Outcome {
        bool success;
        uint256 actualGasCost;
        uint256 tokenAmount;
        bool sponsoredEvent;
    }

    function setUp() public override {
        super.setUp();
        account = _createAccount(PASSKEY_PK);
        vm.prank(admin);
        usd.mint(address(account), 1000e6);
    }

    function _approvePaymaster() internal {
        vm.prank(address(account));
        usd.approve(address(paymaster), type(uint256).max);
    }

    function _userFundedOp(bytes memory callData, uint128 postOpGas)
        internal
        view
        returns (PackedUserOperation memory)
    {
        return _signPasskey(_withPaymaster(_op(address(account), callData), hex"00", postOpGas), PASSKEY_PK);
    }

    function _transferCall(uint256 amount) internal view returns (bytes memory) {
        return _single(address(usd), 0, abi.encodeCall(IERC20.transfer, (recipient, amount)));
    }

    function _run(PackedUserOperation memory op) internal returns (Outcome memory o) {
        bytes32 hash = entryPoint.getUserOpHash(op);
        vm.recordLogs();
        _handle(op);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 opEvent = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
        bytes32 sponsored = keccak256("UserOperationSponsored(bytes32,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == opEvent && logs[i].topics[1] == hash) {
                (, o.success, o.actualGasCost,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
            }
            if (logs[i].topics[0] == sponsored && logs[i].topics[1] == hash) {
                (o.tokenAmount,) = abi.decode(logs[i].data, (uint256, uint256));
                o.sponsoredEvent = true;
            }
        }
    }

    // ------------------------------------------------------------------ user-funded mode

    function test_UserFunded_ChargesTokensAndCoversGas() public {
        _approvePaymaster();
        uint256 userBefore = usd.balanceOf(address(account));
        uint256 pmTokensBefore = usd.balanceOf(address(paymaster));
        uint256 depositBefore = entryPoint.balanceOf(address(paymaster));
        uint256 accountEthBefore = address(account).balance;

        Outcome memory o = _run(_userFundedOp(_transferCall(10e6), 80_000));

        assertTrue(o.success);
        assertTrue(o.sponsoredEvent);
        assertEq(usd.balanceOf(recipient), 10e6);
        // The sender paid exactly the reported charge, in tokens; no ETH left the account.
        assertEq(userBefore - usd.balanceOf(address(account)), 10e6 + o.tokenAmount);
        assertEq(usd.balanceOf(address(paymaster)) - pmTokensBefore, o.tokenAmount);
        assertEq(address(account).balance, accountEthBefore);
        // The paymaster's ETH deposit paid the gas, and the token charge covers it at the configured price.
        assertEq(depositBefore - entryPoint.balanceOf(address(paymaster)), o.actualGasCost);
        assertGe(o.tokenAmount * 1e18, o.actualGasCost * PRICE);
    }

    function test_UserFunded_RejectedWithoutAllowance() public {
        _handleExpectFailedOp(_userFundedOp(_transferCall(1e6), 80_000), "AA34 signature error");
    }

    function test_UserFunded_RejectedWithoutBalance() public {
        _approvePaymaster();
        vm.prank(address(account));
        usd.transfer(recipient, 1000e6);
        _handleExpectFailedOp(_userFundedOp(_transferCall(0), 80_000), "AA34 signature error");
    }

    function test_Rejects_PostOpGasBelowMinimum() public {
        _approvePaymaster();
        _handleExpectFailedOp(_userFundedOp(_transferCall(1e6), 59_999), "AA34 signature error");
    }

    function test_Rejects_PostOpGasAboveMaximum() public {
        _approvePaymaster();
        _handleExpectFailedOp(_userFundedOp(_transferCall(1e6), 200_001), "AA34 signature error");
    }

    function test_Rejects_MalformedPaymasterData() public {
        _approvePaymaster();
        bytes[4] memory bad = [bytes(""), hex"0000", hex"02", hex"01"];
        for (uint256 i = 0; i < bad.length; ++i) {
            PackedUserOperation memory op =
                _signPasskey(_withPaymaster(_op(address(account), _transferCall(1)), bad[i], 80_000), PASSKEY_PK);
            _handleExpectFailedOp(op, "AA34 signature error");
        }
    }

    function test_PostOpPenalty_IsChargedToTheSender() public {
        _approvePaymaster();
        // Same state for both runs, so only the postOp limit differs.
        uint256 snap = vm.snapshotState();
        Outcome memory low = _run(_userFundedOp(_transferCall(1e6), 60_000));
        vm.revertToState(snap);
        Outcome memory high = _run(_userFundedOp(_transferCall(1e6), 200_000));
        // A larger postOp limit raises the EntryPoint's unused-gas penalty; the sender pays it, not the paymaster.
        assertGt(high.actualGasCost, low.actualGasCost);
        assertGt(high.tokenAmount, low.tokenAmount);
        assertGe(high.tokenAmount * 1e18, high.actualGasCost * PRICE);
    }

    function test_Griefing_DrainingBalanceDuringExecutionDoesNotHurtPaymaster() public {
        _approvePaymaster();
        uint256 pmBefore = usd.balanceOf(address(paymaster));
        // The operation moves every remaining token away and revokes the allowance while it executes.
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution({
            target: address(usd), value: 0, callData: abi.encodeCall(IERC20.approve, (address(paymaster), 0))
        });
        // The second call moves out everything left after the worst-case prefund.
        PackedUserOperation memory op = _withPaymaster(_op(address(account), ""), hex"00", 80_000);
        uint256 maxCharge = paymaster.quote(_maxNativeCost(op));
        calls[1] = Execution({
            target: address(usd), value: 0, callData: abi.encodeCall(IERC20.transfer, (recipient, 1000e6 - maxCharge))
        });
        op.callData = _batch(calls);
        op = _signPasskey(op, PASSKEY_PK);
        Outcome memory o = _run(op);
        assertTrue(o.success);
        assertEq(usd.balanceOf(address(paymaster)) - pmBefore, o.tokenAmount);
        assertGe(o.tokenAmount * 1e18, o.actualGasCost * PRICE);
    }

    function test_Griefing_RevertingExecutionIsStillCharged() public {
        _approvePaymaster();
        uint256 pmBefore = usd.balanceOf(address(paymaster));
        Outcome memory o = _run(_userFundedOp(_transferCall(2000e6), 80_000)); // more than the balance: reverts
        assertFalse(o.success);
        assertGt(o.tokenAmount, 0);
        assertEq(usd.balanceOf(address(paymaster)) - pmBefore, o.tokenAmount);
    }

    function _maxNativeCost(PackedUserOperation memory op) internal pure returns (uint256) {
        uint256 vgl = uint256(op.accountGasLimits) >> 128;
        uint256 cgl = uint128(uint256(op.accountGasLimits));
        uint256 maxFee = uint128(uint256(op.gasFees));
        uint256 postOp = uint128(bytes16(_slice(op.paymasterAndData, 36, 16)));
        uint256 penalty = postOp > 40_000 ? postOp / 10 : 0;
        uint256 required = vgl + cgl + 300_000 + postOp + op.preVerificationGas;
        return required * maxFee + (30_000 + penalty) * maxFee;
    }

    function _slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = b[start + i];
        }
    }

    // ------------------------------------------------------------------ sponsor-guaranteed mode

    function _guaranteedOp(address sender, bytes memory initCode, bytes memory callData, uint48 validUntil)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _op(sender, callData);
        op.initCode = initCode;
        op = _withPaymaster(op, abi.encodePacked(bytes1(0x01), validUntil, uint48(0)), 120_000);
        // The user signs first (the paymaster signature is excluded from the v0.9 user op hash) ...
        bytes32 hash = entryPoint.getUserOpHash(_appendPaymasterSig(_copy(op), new bytes(65)));
        op.signature = _webauthnSig(PASSKEY_PK_2, hash);
        // ... then the sponsor co-signs the same hash.
        op = _appendPaymasterSig(op, _guaranteeSig(hash, validUntil, 0));
    }

    function _copy(PackedUserOperation memory op) internal pure returns (PackedUserOperation memory c) {
        c = abi.decode(abi.encode(op), (PackedUserOperation));
    }

    function _newAccountSetup() internal returns (address predicted, bytes memory initCode) {
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK_2, _noGuardians(), 0);
        predicted = factory.getAddress(p, 0);
        initCode = abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (p, bytes32(0))));
        vm.prank(admin);
        usd.mint(predicted, 50e6);
    }

    function test_Guaranteed_FirstOpApprovesAndPaysWithoutEth() public {
        (address predicted, bytes memory initCode) = _newAccountSetup();
        assertEq(predicted.balance, 0);
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution({
            target: address(usd),
            value: 0,
            callData: abi.encodeCall(IERC20.approve, (address(paymaster), type(uint256).max))
        });
        calls[1] =
            Execution({target: address(usd), value: 0, callData: abi.encodeCall(IERC20.transfer, (recipient, 5e6))});
        uint256 pmBefore = usd.balanceOf(address(paymaster));

        Outcome memory o = _run(_guaranteedOp(predicted, initCode, _batch(calls), uint48(block.timestamp + 1 hours)));

        assertTrue(o.success);
        assertGt(predicted.code.length, 0);
        assertEq(usd.balanceOf(recipient), 5e6);
        assertEq(usd.balanceOf(predicted), 45e6 - o.tokenAmount);
        assertEq(usd.balanceOf(address(paymaster)) - pmBefore, o.tokenAmount);
        assertGe(o.tokenAmount * 1e18, o.actualGasCost * PRICE);
    }

    function test_Guaranteed_UnpaidOpIsAbsorbedByPaymaster() public {
        (address predicted, bytes memory initCode) = _newAccountSetup();
        // No approval in the batch: postOp cannot pull the cost from the sender.
        uint256 pmTokensBefore = usd.balanceOf(address(paymaster));
        uint256 depositBefore = entryPoint.balanceOf(address(paymaster));
        Outcome memory o = _run(
            _guaranteedOp(
                predicted,
                initCode,
                _single(address(usd), 0, abi.encodeCall(IERC20.transfer, (recipient, 1e6))),
                uint48(block.timestamp + 1 hours)
            )
        );
        assertTrue(o.success);
        assertEq(usd.balanceOf(address(paymaster)), pmTokensBefore);
        assertEq(depositBefore - entryPoint.balanceOf(address(paymaster)), o.actualGasCost);
    }

    function test_Guaranteed_RejectsBadSponsorSignature() public {
        (address predicted, bytes memory initCode) = _newAccountSetup();
        PackedUserOperation memory op =
            _guaranteedOp(predicted, initCode, _single(recipient, 0, ""), uint48(block.timestamp + 1 hours));
        // Corrupt one byte of the sponsor signature (it sits right before the 10-byte suffix).
        op.paymasterAndData[op.paymasterAndData.length - 20] ^= 0xff;
        _handleExpectFailedOp(op, "AA34 signature error");
    }

    function test_Guaranteed_RejectsExpiredGuarantee() public {
        (address predicted, bytes memory initCode) = _newAccountSetup();
        PackedUserOperation memory op =
            _guaranteedOp(predicted, initCode, _single(recipient, 0, ""), uint48(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 2 hours);
        _handleExpectFailedOp(op, "AA32 paymaster expired or not due");
    }

    function test_Guaranteed_RejectsWhenSponsorDisabled() public {
        (address predicted, bytes memory initCode) = _newAccountSetup();
        vm.prank(admin);
        paymaster.setSponsorSigner(address(0));
        PackedUserOperation memory op =
            _guaranteedOp(predicted, initCode, _single(recipient, 0, ""), uint48(block.timestamp + 1 hours));
        _handleExpectFailedOp(op, "AA34 signature error");
    }

    function test_Guaranteed_RejectsMissingSignature() public {
        (address predicted, bytes memory initCode) = _newAccountSetup();
        PackedUserOperation memory op = _op(predicted, _single(recipient, 0, ""));
        op.initCode = initCode;
        op = _withPaymaster(op, abi.encodePacked(bytes1(0x01), uint48(0), uint48(0)), 120_000);
        op = _signPasskey(op, PASSKEY_PK_2);
        _handleExpectFailedOp(op, "AA34 signature error");
    }

    // ------------------------------------------------------------------ admin

    function test_Admin_SetTokenPrice() public {
        vm.expectEmit(address(paymaster));
        emit TokenPaymaster.TokenPriceUpdated(PRICE, 2500e6);
        vm.prank(admin);
        paymaster.setTokenPrice(2500e6);
        assertEq(paymaster.tokenPerNative(), 2500e6);
    }

    function test_Admin_SetTokenPriceBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(TokenPaymaster.PriceOutOfBounds.selector, 1e6 - 1));
        paymaster.setTokenPrice(1e6 - 1);
        vm.expectRevert(abi.encodeWithSelector(TokenPaymaster.PriceOutOfBounds.selector, 1e13 + 1));
        paymaster.setTokenPrice(1e13 + 1);
        vm.stopPrank();
    }

    function test_Admin_OnlyOwner() public {
        address stranger = makeAddr("stranger");
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(err);
        paymaster.setTokenPrice(2000e6);
        vm.expectRevert(err);
        paymaster.setSponsorSigner(stranger);
        vm.expectRevert(err);
        paymaster.withdraw(payable(stranger), 1);
        vm.expectRevert(err);
        paymaster.addStake(1);
        vm.expectRevert(err);
        paymaster.unlockStake();
        vm.expectRevert(err);
        paymaster.withdrawStake(payable(stranger));
        vm.expectRevert(err);
        paymaster.withdrawTokens(stranger, 1);
        vm.stopPrank();
    }

    function test_Admin_DepositWithdraw() public {
        vm.deal(address(this), 1 ether);
        paymaster.deposit{value: 1 ether}();
        assertEq(entryPoint.balanceOf(address(paymaster)), 101 ether);
        address payable to = payable(makeAddr("treasury"));
        vm.prank(admin);
        paymaster.withdraw(to, 5 ether);
        assertEq(to.balance, 5 ether);
    }

    function test_Admin_StakeLifecycle() public {
        IEntryPointV09Like ep = IEntryPointV09Like(address(entryPoint));
        assertTrue(ep.getDepositInfo(address(paymaster)).staked);
        vm.prank(admin);
        paymaster.unlockStake();
        vm.warp(block.timestamp + 1 days);
        address payable to = payable(makeAddr("treasury"));
        vm.prank(admin);
        paymaster.withdrawStake(to);
        assertEq(to.balance, 1 ether);
    }

    function test_Admin_WithdrawTokens() public {
        vm.startPrank(admin);
        vm.expectEmit(address(paymaster));
        emit TokenPaymaster.TokensWithdrawn(admin, 100e6);
        paymaster.withdrawTokens(admin, 100e6);
        assertEq(usd.balanceOf(admin), 100e6);
        paymaster.withdrawTokens(admin, type(uint256).max);
        assertEq(usd.balanceOf(address(paymaster)), 0);
        vm.expectRevert(TokenPaymaster.ZeroAddress.selector);
        paymaster.withdrawTokens(address(0), 1);
        vm.stopPrank();
    }

    function test_Admin_SponsorSignerEvent() public {
        address newSigner = makeAddr("newSponsor");
        vm.expectEmit(address(paymaster));
        emit TokenPaymaster.SponsorSignerUpdated(sponsor, newSigner);
        vm.prank(admin);
        paymaster.setSponsorSigner(newSigner);
        assertEq(paymaster.sponsorSigner(), newSigner);
    }

    function test_Constructor_Validation() public {
        vm.expectRevert(TokenPaymaster.ZeroAddress.selector);
        new TokenPaymaster(IEntryPoint(address(0)), usd, admin, PRICE);
        vm.expectRevert(TokenPaymaster.ZeroAddress.selector);
        new TokenPaymaster(IEntryPoint(address(entryPoint)), IERC20(address(0)), admin, PRICE);
        vm.expectRevert(abi.encodeWithSelector(TokenPaymaster.PriceOutOfBounds.selector, 0));
        new TokenPaymaster(IEntryPoint(address(entryPoint)), usd, admin, 0);
    }

    function test_EntryPointOnlyHooks() public {
        PackedUserOperation memory op = _op(address(account), "");
        vm.expectRevert(abi.encodeWithSelector(Paymaster.PaymasterUnauthorized.selector, address(this)));
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        vm.expectRevert(abi.encodeWithSelector(Paymaster.PaymasterUnauthorized.selector, address(this)));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0, 0);
    }

    function test_Quote_RoundsUp() public view {
        assertEq(paymaster.quote(1e18), PRICE);
        assertEq(paymaster.quote(1), 1); // 3000e6 * 1 / 1e18 rounds up to one unit
        assertEq(paymaster.quote(0), 0);
    }

    function test_TestUSD_Metadata() public view {
        assertEq(usd.decimals(), 6);
        assertEq(usd.symbol(), "TUSD");
        assertEq(usd.owner(), admin);
    }

    function test_TestUSD_OnlyOwnerMints() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        usd.mint(stranger, 1);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_ChargeAlwaysCoversGas(uint256 price, uint128 postOpGas, uint128 maxFee, uint128 tip) public {
        price = bound(price, 1e6, 1e10);
        postOpGas = uint128(bound(postOpGas, 60_000, 200_000));
        maxFee = uint128(bound(maxFee, 1 gwei, 200 gwei));
        tip = uint128(bound(tip, 0, maxFee));
        vm.prank(admin);
        paymaster.setTokenPrice(price);
        vm.prank(admin);
        usd.mint(address(account), 1_000_000e6);
        _approvePaymaster();
        PackedUserOperation memory op = _op(address(account), _transferCall(1e6));
        op.gasFees = _pack(tip, maxFee);
        op = _signPasskey(_withPaymaster(op, hex"00", postOpGas), PASSKEY_PK);
        uint256 depositBefore = entryPoint.balanceOf(address(paymaster));
        Outcome memory o = _run(op);
        assertTrue(o.success);
        assertEq(depositBefore - entryPoint.balanceOf(address(paymaster)), o.actualGasCost);
        assertGe(o.tokenAmount * 1e18, o.actualGasCost * price);
    }
}

interface IEntryPointV09Like {
    struct DepositInfo {
        uint256 deposit;
        bool staked;
        uint112 stake;
        uint32 unstakeDelaySec;
        uint48 withdrawTime;
    }

    function getDepositInfo(address account) external view returns (DepositInfo memory info);
}
