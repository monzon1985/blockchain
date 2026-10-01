// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PasskeyAccount} from "../../../src/PasskeyAccount.sol";
import {PasskeyAccountFactory} from "../../../src/PasskeyAccountFactory.sol";
import {TestUSD} from "../../../src/TestUSD.sol";
import {TokenPaymaster} from "../../../src/TokenPaymaster.sol";
import {BaseTest} from "../../utils/BaseTest.sol";
import {IEntryPointV09} from "../../utils/IEntryPointV09.sol";

/// @notice Sends randomized paymaster operations (user-funded, griefing and sponsor-guaranteed) through the real
/// EntryPoint while the admin moves the price, the deposit and the token float.
///
/// The books are rebuilt independently of the balances the invariants check: gas from the EntryPoint's
/// `UserOperationEvent.actualGasCost`, token charges from the paymaster's `UserOperationSponsored.tokenAmount` (and,
/// for guaranteed operations, from whether the handler let the sender repay), admin flows from the amounts the handler
/// itself moved. Inputs are pre-filtered (deposit and float floors, funded senders), so every operation must go
/// through: the campaign runs with `fail_on_revert = true` and `afterInvariant` checks that operations happened.
contract PaymasterHandler is BaseTest {
    PasskeyAccount[3] public accounts;

    /// @dev The deposit and token float are never withdrawn below these floors, so a valid operation always fits.
    uint256 public constant DEPOSIT_FLOOR = 10 ether;
    uint256 public constant FLOAT_FLOOR = 100_000e6;
    uint256 internal constant SENDER_REFILL_BELOW = 100_000e6;

    uint256 public immutable initialDeposit;
    uint256 public immutable initialFloat;

    // ----- books (from events and handler intent)
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostGasCharged;
    uint256 public ghostTokensCharged;
    uint256 public ghostTokensWithdrawn;

    // ----- per-operation checks
    uint256 public ghostUnderchargedOps;
    uint256 public ghostUnderchargedGuaranteedOps;
    uint256 public ghostMissingEvents;
    uint256 public ghostPostOpReverts;

    // ----- activity counters
    uint256 public ghostUserFundedOps;
    uint256 public ghostGriefingOps;
    uint256 public ghostGuaranteedOps;
    uint256 public ghostGuaranteedUnpaid;

    bytes32 private constant OP_EVENT =
        keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 private constant SPONSORED_EVENT = keccak256("UserOperationSponsored(bytes32,address,uint256,uint256)");
    bytes32 private constant POST_OP_REVERT_EVENT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");

    struct Outcome {
        uint256 gasCost;
        uint256 tokenAmount;
        /// @dev Signed change of the paymaster's token balance across the operation (negative = the float shrank).
        int256 tokenDelta;
    }

    constructor(
        IEntryPointV09 ep,
        PasskeyAccountFactory factory_,
        TestUSD usd_,
        TokenPaymaster paymaster_,
        address admin_,
        address sponsor_,
        uint256 sponsorPk_
    ) {
        entryPoint = ep;
        factory = factory_;
        usd = usd_;
        paymaster = paymaster_;
        admin = admin_;
        sponsor = sponsor_;
        sponsorPk = sponsorPk_;
        bundlerEoa = makeAddr("pm-bundler");
        beneficiary = payable(makeAddr("pm-beneficiary"));
        initialDeposit = ep.balanceOf(address(paymaster_));
        initialFloat = usd_.balanceOf(address(paymaster_));
        for (uint256 i = 0; i < 3; ++i) {
            PasskeyAccount a =
                PasskeyAccount(payable(factory_.createAccount(_initParams(PASSKEY_PK, _noGuardians(), 0), bytes32(i))));
            accounts[i] = a;
            vm.prank(admin_);
            usd_.mint(address(a), 1_000_000e6);
            vm.prank(address(a));
            usd_.approve(address(paymaster_), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Keeps the sender funded and approving, so a user-funded operation can always pay its worst case.
    function _prepare(uint256 accountSeed) internal returns (PasskeyAccount a) {
        a = accounts[accountSeed % 3];
        if (usd.balanceOf(address(a)) < SENDER_REFILL_BELOW) {
            vm.prank(admin);
            usd.mint(address(a), 1_000_000e6);
        }
        vm.prank(address(a));
        usd.approve(address(paymaster), type(uint256).max);
    }

    /// @dev Submits one operation (a revert fails the campaign) and reads its outcome from the logs.
    function _submit(PackedUserOperation memory op) internal returns (Outcome memory o) {
        uint256 floatBefore = usd.balanceOf(address(paymaster));
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.recordLogs();
        vm.prank(bundlerEoa, bundlerEoa);
        entryPoint.handleOps(ops, beneficiary);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawOp;
        bool sawSponsored;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.topics.length == 0) continue;
            if (log.emitter == address(entryPoint) && log.topics[0] == OP_EVENT && log.topics.length == 4) {
                if (address(uint160(uint256(log.topics[3]))) != address(paymaster)) continue;
                (,, o.gasCost,) = abi.decode(log.data, (uint256, bool, uint256, uint256));
                sawOp = true;
            } else if (log.emitter == address(paymaster) && log.topics[0] == SPONSORED_EVENT) {
                (o.tokenAmount,) = abi.decode(log.data, (uint256, uint256));
                sawSponsored = true;
            } else if (log.emitter == address(entryPoint) && log.topics[0] == POST_OP_REVERT_EVENT) {
                ghostPostOpReverts++;
            }
        }
        if (!sawOp || !sawSponsored) ghostMissingEvents++;
        ghostGasCharged += o.gasCost;
        o.tokenDelta = int256(usd.balanceOf(address(paymaster))) - int256(floatBefore);
    }

    /// @dev True when the tokens the paymaster actually kept, valued at `price`, are worth less than the gas it paid.
    function _undercharged(Outcome memory o, uint256 price) internal pure returns (bool) {
        return o.tokenDelta < 0 || uint256(o.tokenDelta) * 1e18 < o.gasCost * price;
    }

    function _userFunded(PasskeyAccount a, uint128 postOpGas, uint128 maxFee, uint128 tip, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _op(address(a), callData);
        op.gasFees = _pack(tip, maxFee);
        op = _signPasskey(_withPaymaster(op, hex"00", postOpGas), PASSKEY_PK);
    }

    // ------------------------------------------------------------------ operations

    /// @dev User-funded (mode 0x00) ERC-20 transfer paid in TestUSD.
    function userFundedTransfer(uint256 accountSeed, uint256 postOpSeed, uint256 feeSeed, uint256 tipSeed) external {
        PasskeyAccount a = _prepare(accountSeed);
        uint128 postOp = uint128(bound(postOpSeed, 60_000, 200_000));
        uint128 maxFee = uint128(bound(feeSeed, 1 gwei, 100 gwei));
        uint128 tip = uint128(bound(tipSeed, 0, maxFee));
        bytes memory callData = _single(address(usd), 0, abi.encodeCall(IERC20.transfer, (makeAddr("payee"), 1e6)));
        uint256 price = paymaster.tokenPerNative();
        Outcome memory o = _submit(_userFunded(a, postOp, maxFee, tip, callData));
        ghostUserFundedOps++;
        ghostTokensCharged += o.tokenAmount;
        if (_undercharged(o, price)) ghostUnderchargedOps++;
    }

    /// @dev Griefing attempt: revoke the allowance and move half the tokens away during execution, or revert.
    function griefingOp(uint256 accountSeed, uint256 postOpSeed, bool revertInstead) external {
        PasskeyAccount a = _prepare(accountSeed);
        uint128 postOp = uint128(bound(postOpSeed, 60_000, 200_000));
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(usd), 0, abi.encodeCall(IERC20.approve, (address(paymaster), 0)));
        uint256 bal = usd.balanceOf(address(a));
        uint256 amount = revertInstead ? bal * 2 + 1 : bal / 2;
        calls[1] = Execution(address(usd), 0, abi.encodeCall(IERC20.transfer, (makeAddr("sink"), amount)));
        uint256 price = paymaster.tokenPerNative();
        Outcome memory o = _submit(_userFunded(a, postOp, 5 gwei, 1 gwei, _batch(calls)));
        ghostGriefingOps++;
        ghostTokensCharged += o.tokenAmount;
        if (_undercharged(o, price)) ghostUnderchargedOps++;
    }

    /// @dev Sponsor-guaranteed (mode 0x01): the paymaster fronts the cost from its float and pulls it from the sender in
    /// postOp. With `payBack` the sender keeps its allowance and repays; otherwise it revokes the allowance during
    /// execution and the paymaster absorbs the cost (documented behaviour), so it must collect nothing.
    function guaranteedOp(uint256 accountSeed, bool payBack) external {
        PasskeyAccount a = _prepare(accountSeed);
        bytes memory callData = payBack
            ? _single(address(usd), 0, abi.encodeCall(IERC20.transfer, (makeAddr("payee"), 1)))
            : _single(address(usd), 0, abi.encodeCall(IERC20.approve, (address(paymaster), 0)));
        PackedUserOperation memory op = _op(address(a), callData);
        op = _withPaymaster(op, abi.encodePacked(bytes1(0x01), uint48(0), uint48(0)), 120_000);
        bytes32 hash = entryPoint.getUserOpHash(
            _appendPaymasterSig(abi.decode(abi.encode(op), (PackedUserOperation)), new bytes(65))
        );
        op.signature = _webauthnSig(PASSKEY_PK, hash);
        op = _appendPaymasterSig(op, _guaranteeSig(hash, 0, 0));
        uint256 price = paymaster.tokenPerNative();
        Outcome memory o = _submit(op);
        ghostGuaranteedOps++;
        if (payBack) {
            ghostTokensCharged += o.tokenAmount;
            if (_undercharged(o, price)) ghostUnderchargedGuaranteedOps++;
        } else {
            ghostGuaranteedUnpaid++;
        }
    }

    // ------------------------------------------------------------------ admin

    function setPrice(uint256 priceSeed) external {
        vm.prank(admin);
        paymaster.setTokenPrice(bound(priceSeed, 1e6, 1e10));
    }

    function topUp(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 10 ether);
        vm.deal(address(this), amount);
        paymaster.deposit{value: amount}();
        ghostDeposited += amount;
    }

    function withdrawDeposit(uint256 amountSeed) external {
        uint256 bal = entryPoint.balanceOf(address(paymaster));
        if (bal <= DEPOSIT_FLOOR) return;
        uint256 amount = bound(amountSeed, 0, bal - DEPOSIT_FLOOR);
        vm.prank(admin);
        paymaster.withdraw(payable(admin), amount);
        ghostWithdrawn += amount;
    }

    function withdrawTokens(uint256 amountSeed) external {
        uint256 bal = usd.balanceOf(address(paymaster));
        if (bal <= FLOAT_FLOOR) return;
        uint256 amount = bound(amountSeed, 0, bal - FLOAT_FLOOR);
        vm.prank(admin);
        paymaster.withdrawTokens(admin, amount);
        ghostTokensWithdrawn += amount;
    }
}
