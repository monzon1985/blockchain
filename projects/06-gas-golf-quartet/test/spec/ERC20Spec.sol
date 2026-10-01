// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetToken} from "../../src/interfaces/IQuartetToken.sol";
import {QuartetSolidity} from "../../src/solidity/QuartetSolidity.sol";
import {QuartetBase} from "../utils/QuartetBase.sol";
import {Impl, RevertClass, RevertClassifier} from "../utils/RevertClassifier.sol";
import {StorageLayout} from "../utils/StorageLayout.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Forwards every call with DELEGATECALL, to observe a token running in someone else's context.
contract DelegateProxy {
    address private immutable _target;

    constructor(address target) {
        _target = target;
    }

    fallback() external payable {
        address target = _target;
        // Memory-safe: the call frame ends in this block.
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @title ERC20Spec
/// @notice The behavioural specification of the quartet, written once and run against every
///         implementation (and against OpenZeppelin, to show the specification is OpenZeppelin's).
///         Every success path and every revert path of the shared surface is exercised. Reverts are
///         compared by class; for the ERC-6093 family (OpenZeppelin, Solidity) the exact bytes are
///         checked as well.
abstract contract ERC20Spec is QuartetBase {
    IQuartetToken internal token;

    uint256 internal constant ALICE_KEY = 0xA11CE;
    uint256 internal constant BOB_KEY = 0xB0B;
    address internal alice;
    address internal bob;
    address internal carol;

    /// @notice The implementation this instance of the specification runs against.
    function _impl() internal pure virtual returns (Impl);

    function setUp() public virtual {
        alice = vm.addr(ALICE_KEY);
        bob = vm.addr(BOB_KEY);
        carol = makeAddr("carol");
        vm.warp(1_750_000_000);
        token = _deploy(_impl(), alice, SUPPLY);
    }

    // ------------------------------------------------------------------ helpers

    function _call(address caller, bytes memory data) internal returns (Outcome memory) {
        return _capture(caller, address(token), data, 0);
    }

    function _isErc6093() internal pure returns (bool) {
        return _impl() == Impl.OpenZeppelin || _impl() == Impl.Solidity;
    }

    /// @dev Asserts a revert of class `expected`; for the ERC-6093 family also the exact revert bytes.
    function _assertRevert(Outcome memory out, RevertClass expected, bytes memory erc6093Data) internal pure {
        assertFalse(out.ok, "expected a revert");
        assertEq(out.logs.length, 0, "a reverted call must not emit logs");
        assertEq(
            RevertClassifier.name(_classOf(_impl(), out)),
            RevertClassifier.name(expected),
            string.concat(_name(_impl()), ": wrong revert class")
        );
        if (_isErc6093() && erc6093Data.length != 0) assertEq(out.ret, erc6093Data, "wrong ERC-6093 revert data");
    }

    function _assertEmptyRevert(Outcome memory out) internal pure {
        _assertRevert(out, RevertClass.EmptyRevert, "");
    }

    function _assertReturnsTrue(Outcome memory out) internal pure {
        assertTrue(out.ok, "call reverted");
        assertEq(out.ret, abi.encode(true), "must return exactly abi.encode(true)");
    }

    function _assertSingleLog(Outcome memory out, bytes32 topic0, address a, address b, uint256 value) internal view {
        assertEq(out.logs.length, 1, "expected exactly one log");
        Vm.Log memory log = out.logs[0];
        assertEq(log.emitter, address(token), "log emitter");
        assertEq(log.topics.length, 3, "topic count");
        assertEq(log.topics[0], topic0, "event signature");
        assertEq(log.topics[1], bytes32(uint256(uint160(a))), "topic 1");
        assertEq(log.topics[2], bytes32(uint256(uint160(b))), "topic 2");
        assertEq(log.data, abi.encode(value), "event data");
    }

    function _transfer(address from, address to, uint256 amount) internal returns (Outcome memory) {
        return _call(from, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function _approve(address owner, address spender, uint256 amount) internal returns (Outcome memory) {
        return _call(owner, abi.encodeCall(IERC20.approve, (spender, amount)));
    }

    function _transferFrom(address spender, address from, address to, uint256 amount)
        internal
        returns (Outcome memory)
    {
        return _call(spender, abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
    }

    function _permitCall(
        address relayer,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (Outcome memory) {
        return _call(relayer, abi.encodeCall(IERC20Permit.permit, (owner, spender, value, deadline, v, r, s)));
    }

    // ------------------------------------------------------------------ metadata and construction

    function test_Metadata_ReturnsCanonicalAbiEncodings() public {
        assertEq(_call(bob, abi.encodeWithSignature("name()")).ret, abi.encode(TOKEN_NAME));
        assertEq(_call(bob, abi.encodeWithSignature("symbol()")).ret, abi.encode(TOKEN_SYMBOL));
        assertEq(_call(bob, abi.encodeWithSignature("decimals()")).ret, abi.encode(uint8(18)));
        assertEq(_call(bob, abi.encodeCall(IERC20.totalSupply, ())).ret, abi.encode(SUPPLY));
        assertEq(token.name(), TOKEN_NAME);
        assertEq(token.symbol(), TOKEN_SYMBOL);
        assertEq(token.decimals(), 18);
    }

    function test_Constructor_MintsWholeSupplyToHolder() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.nonces(alice), 0);
    }

    function test_Constructor_EmitsTransferFromZeroAddress() public {
        vm.recordLogs();
        (address deployed,) = _create(_initcode(_impl(), bob, 123), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(deployed != address(0));
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, deployed);
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(logs[0].data, abi.encode(uint256(123)));
    }

    function test_Constructor_AcceptsZeroAndMaxSupply() public {
        assertEq(_deploy(_impl(), bob, 0).balanceOf(bob), 0);
        assertEq(_deploy(_impl(), bob, type(uint256).max).totalSupply(), type(uint256).max);
    }

    function test_Constructor_RevertWhen_HolderIsZero() public {
        (address deployed, bytes memory revertData) = _create(_initcode(_impl(), address(0), SUPPLY), 0);
        assertEq(deployed, address(0));
        assertEq(
            RevertClassifier.name(RevertClassifier.classify(_impl(), revertData)),
            RevertClassifier.name(RevertClass.InvalidReceiver)
        );
    }

    function test_Constructor_RevertWhen_ValueIsSent() public {
        (address deployed, bytes memory revertData) = _create(_initcode(_impl(), alice, SUPPLY), 1 wei);
        assertEq(deployed, address(0));
        assertEq(revertData.length, 0);
    }

    /// @notice Characterization of a known difference outside the shared runtime surface: with the last
    ///         constructor word missing, OpenZeppelin, Solidity, assembly and Yul refuse to deploy, while
    ///         Vyper 0.4.3 reads the missing word as zero and deploys a token with zero supply. Only the
    ///         deployer can supply constructor arguments; the README's scope notes record the difference.
    function test_Constructor_TruncatedArguments() public {
        bytes memory initcode = _initcode(_impl(), bob, 77);
        // Memory-safe: shortens an array this function owns (drops the `supply` word).
        assembly ("memory-safe") {
            mstore(initcode, sub(mload(initcode), 0x20))
        }
        (address deployed, bytes memory revertData) = _create(initcode, 0);
        if (_impl() == Impl.Vyper) {
            assertTrue(deployed != address(0), "Vyper 0.4.3 does not check the constructor argument length");
            assertEq(IQuartetToken(deployed).totalSupply(), 0);
        } else {
            assertEq(deployed, address(0));
            assertEq(revertData.length, 0);
        }
    }

    /// @notice Characterization of trick T15, the one known runtime difference: with msg.sender ==
    ///         address(0) (no signed transaction has it, an `eth_call` without `from` does), OpenZeppelin and
    ///         the Solidity version reject `transfer`, `approve` and `transferFrom`, while the assembly, Yul and
    ///         Vyper versions skip that check and succeed. The halmos proofs assume a non-zero caller for this
    ///         reason, and the README states it; this test pins the behaviour so the documentation stays true.
    function test_ZeroSender_Characterization() public {
        Outcome memory transferOut = _call(address(0), abi.encodeCall(IERC20.transfer, (bob, 0)));
        Outcome memory approveOut = _call(address(0), abi.encodeCall(IERC20.approve, (bob, 1)));
        Outcome memory transferFromOut = _call(address(0), abi.encodeCall(IERC20.transferFrom, (alice, bob, 0)));
        if (_isErc6093()) {
            _assertRevert(
                transferOut,
                RevertClass.InvalidSender,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0))
            );
            _assertRevert(
                approveOut,
                RevertClass.InvalidApprover,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
            );
            _assertRevert(
                transferFromOut,
                RevertClass.InvalidSpender,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
            );
        } else {
            _assertReturnsTrue(transferOut);
            _assertSingleLog(transferOut, IERC20.Transfer.selector, address(0), bob, 0);
            _assertReturnsTrue(approveOut);
            assertEq(token.allowance(address(0), bob), 1);
            _assertReturnsTrue(transferFromOut);
        }
    }

    // ------------------------------------------------------------------ transfer

    function test_Transfer_MovesBalanceAndEmitsTransfer() public {
        Outcome memory out = _transfer(alice, bob, 100e18);
        _assertReturnsTrue(out);
        _assertSingleLog(out, IERC20.Transfer.selector, alice, bob, 100e18);
        assertEq(token.balanceOf(alice), SUPPLY - 100e18);
        assertEq(token.balanceOf(bob), 100e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_Transfer_ToSelfKeepsBalance() public {
        Outcome memory out = _transfer(alice, alice, 7e18);
        _assertReturnsTrue(out);
        _assertSingleLog(out, IERC20.Transfer.selector, alice, alice, 7e18);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_Transfer_EntireBalance() public {
        _assertReturnsTrue(_transfer(alice, bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
    }

    function test_Transfer_ZeroAmountFromEmptyAccount() public {
        Outcome memory out = _transfer(carol, bob, 0);
        _assertReturnsTrue(out);
        _assertSingleLog(out, IERC20.Transfer.selector, carol, bob, 0);
    }

    function test_Transfer_RevertWhen_ReceiverIsZero() public {
        _assertRevert(
            _transfer(alice, address(0), 1),
            RevertClass.InvalidReceiver,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function test_Transfer_RevertWhen_BalanceTooLow() public {
        _assertRevert(
            _transfer(bob, alice, 1),
            RevertClass.InsufficientBalance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1)
        );
        _assertRevert(
            _transfer(alice, bob, SUPPLY + 1),
            RevertClass.InsufficientBalance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY, SUPPLY + 1)
        );
    }

    function test_Transfer_RevertWhen_ReceiverIsZeroAndBalanceTooLow_ReportsReceiver() public {
        _assertRevert(
            _transfer(bob, address(0), 1),
            RevertClass.InvalidReceiver,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        _assertReturnsTrue(_transfer(alice, to, amount));
        if (to == alice) {
            assertEq(token.balanceOf(alice), SUPPLY);
        } else {
            assertEq(token.balanceOf(alice), SUPPLY - amount);
            assertEq(token.balanceOf(to), amount);
        }
    }

    function testFuzz_Transfer_RevertWhen_AmountExceedsBalance(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        _assertRevert(
            _transfer(alice, bob, amount),
            RevertClass.InsufficientBalance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY, amount)
        );
    }

    // ------------------------------------------------------------------ approve

    function test_Approve_SetsAllowanceAndEmitsApproval() public {
        Outcome memory out = _approve(alice, bob, 5e18);
        _assertReturnsTrue(out);
        _assertSingleLog(out, IERC20.Approval.selector, alice, bob, 5e18);
        assertEq(token.allowance(alice, bob), 5e18);
        assertEq(token.allowance(bob, alice), 0);
    }

    function test_Approve_OverwritesInsteadOfAdding() public {
        _approve(alice, bob, 5e18);
        _assertReturnsTrue(_approve(alice, bob, 2e18));
        assertEq(token.allowance(alice, bob), 2e18);
        _assertReturnsTrue(_approve(alice, bob, 0));
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_Approve_WithoutBalance() public {
        _assertReturnsTrue(_approve(carol, bob, type(uint256).max));
        assertEq(token.allowance(carol, bob), type(uint256).max);
    }

    function test_Approve_RevertWhen_SpenderIsZero() public {
        _assertRevert(
            _approve(alice, address(0), 1),
            RevertClass.InvalidSpender,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function testFuzz_Approve(address owner, address spender, uint256 amount) public {
        vm.assume(owner != address(0) && spender != address(0));
        Outcome memory out = _approve(owner, spender, amount);
        _assertReturnsTrue(out);
        _assertSingleLog(out, IERC20.Approval.selector, owner, spender, amount);
        assertEq(token.allowance(owner, spender), amount);
    }

    // ------------------------------------------------------------------ transferFrom

    function test_TransferFrom_SpendsAllowanceWithoutApprovalEvent() public {
        _approve(alice, bob, 10e18);
        Outcome memory out = _transferFrom(bob, alice, carol, 4e18);
        _assertReturnsTrue(out);
        // OpenZeppelin 5 semantics: spending an allowance emits Transfer only.
        _assertSingleLog(out, IERC20.Transfer.selector, alice, carol, 4e18);
        assertEq(token.allowance(alice, bob), 6e18);
        assertEq(token.balanceOf(carol), 4e18);
        assertEq(token.balanceOf(alice), SUPPLY - 4e18);
    }

    function test_TransferFrom_InfiniteAllowanceIsNeverDecreased() public {
        _approve(alice, bob, type(uint256).max);
        _assertReturnsTrue(_transferFrom(bob, alice, carol, 4e18));
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_TransferFrom_ExactAllowanceLeavesZero() public {
        _approve(alice, bob, 3e18);
        _assertReturnsTrue(_transferFrom(bob, alice, bob, 3e18));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 3e18);
    }

    function test_TransferFrom_ByOwnerStillNeedsAllowance() public {
        _assertRevert(
            _transferFrom(alice, alice, bob, 1),
            RevertClass.InsufficientAllowance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1)
        );
    }

    function test_TransferFrom_RevertWhen_AllowanceTooLow() public {
        _approve(alice, bob, 1e18);
        _assertRevert(
            _transferFrom(bob, alice, carol, 1e18 + 1),
            RevertClass.InsufficientAllowance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 1e18, 1e18 + 1)
        );
    }

    function test_TransferFrom_RevertWhen_AllowanceAndBalanceTooLow_ReportsAllowance() public {
        _approve(carol, bob, 1);
        _assertRevert(
            _transferFrom(bob, carol, alice, 2),
            RevertClass.InsufficientAllowance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 1, 2)
        );
    }

    function test_TransferFrom_RevertWhen_ReceiverIsZero() public {
        _approve(alice, bob, 10);
        _assertRevert(
            _transferFrom(bob, alice, address(0), 1),
            RevertClass.InvalidReceiver,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        assertEq(token.allowance(alice, bob), 10, "the allowance write must be rolled back");
    }

    function test_TransferFrom_RevertWhen_BalanceTooLow() public {
        _approve(carol, bob, 10);
        _assertRevert(
            _transferFrom(bob, carol, alice, 5),
            RevertClass.InsufficientBalance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, 5)
        );
        assertEq(token.allowance(carol, bob), 10, "the allowance write must be rolled back");
    }

    function test_TransferFrom_RevertWhen_FromIsZeroWithZeroAmount_ReportsApprover() public {
        _assertRevert(
            _transferFrom(bob, address(0), alice, 0),
            RevertClass.InvalidApprover,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
        );
    }

    function test_TransferFrom_RevertWhen_FromIsZeroWithAmount_ReportsAllowance() public {
        _assertRevert(
            _transferFrom(bob, address(0), alice, 1),
            RevertClass.InsufficientAllowance,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1)
        );
    }

    /// @dev Unreachable through calls (the zero address cannot approve), so the state is written directly.
    function test_TransferFrom_RevertWhen_FromIsZeroWithInfiniteAllowance_ReportsSender() public {
        vm.store(address(token), StorageLayout.allowanceSlot(_impl(), address(0), bob), bytes32(type(uint256).max));
        assertEq(token.allowance(address(0), bob), type(uint256).max);
        _assertRevert(
            _transferFrom(bob, address(0), alice, 1),
            RevertClass.InvalidSender,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0))
        );
    }

    function testFuzz_TransferFrom(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, allowed);
        _approve(alice, bob, allowed);
        _assertReturnsTrue(_transferFrom(bob, alice, carol, amount));
        assertEq(token.allowance(alice, bob), allowed - amount);
        assertEq(token.balanceOf(carol), amount);
    }

    // ------------------------------------------------------------------ permit

    function test_Permit_SetsAllowanceIncrementsNonceAndEmits() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 42e18, deadline);
        Outcome memory out = _permitCall(carol, alice, bob, 42e18, deadline, v, r, s);
        assertTrue(out.ok);
        assertEq(out.ret.length, 0, "permit returns nothing");
        _assertSingleLog(out, IERC20.Approval.selector, alice, bob, 42e18);
        assertEq(token.allowance(alice, bob), 42e18);
        assertEq(token.nonces(alice), 1);
    }

    function test_Permit_DeadlineEqualToTimestampIsValid() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 1, block.timestamp);
        assertTrue(_permitCall(bob, alice, bob, 1, block.timestamp, v, r, s).ok);
    }

    function test_Permit_ConsecutiveNonces() public {
        for (uint256 i; i < 3; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, i, type(uint256).max);
            assertTrue(_permitCall(bob, alice, bob, i, type(uint256).max, v, r, s).ok);
        }
        assertEq(token.nonces(alice), 3);
        assertEq(token.allowance(alice, bob), 2);
    }

    function test_Permit_RevertWhen_Expired() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 1, deadline);
        _assertRevert(
            _permitCall(bob, alice, bob, 1, deadline, v, r, s),
            RevertClass.PermitExpired,
            abi.encodeWithSelector(QuartetSolidity.ERC2612ExpiredSignature.selector, deadline)
        );
    }

    function test_Permit_RevertWhen_Replayed() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 1, block.timestamp);
        assertTrue(_permitCall(bob, alice, bob, 1, block.timestamp, v, r, s).ok);
        Outcome memory out = _permitCall(bob, alice, bob, 1, block.timestamp, v, r, s);
        _assertRevert(out, RevertClass.InvalidPermit, "");
        assertEq(token.nonces(alice), 1);
    }

    function test_Permit_RevertWhen_SignedByAnotherKey() public {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(BOB_KEY, _permitDigest(address(token), alice, bob, 1, token.nonces(alice), block.timestamp));
        _assertRevert(
            _permitCall(bob, alice, bob, 1, block.timestamp, v, r, s),
            RevertClass.InvalidPermit,
            abi.encodeWithSelector(QuartetSolidity.ERC2612InvalidSigner.selector, bob, alice)
        );
    }

    function test_Permit_RevertWhen_ValueDiffersFromSigned() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 100, block.timestamp);
        _assertRevert(_permitCall(bob, alice, bob, 101, block.timestamp, v, r, s), RevertClass.InvalidPermit, "");
    }

    function test_Permit_RevertWhen_SignatureIsMalleableHighS() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 1, block.timestamp);
        (uint8 v2, bytes32 s2) = _malleate(v, s);
        // The twin really is a valid ecrecover signature for alice: only the EIP-2 rule rejects it.
        bytes32 digest = _permitDigest(address(token), alice, bob, 1, 0, block.timestamp);
        assertEq(ecrecover(digest, v2, r, s2), alice);
        _assertRevert(
            _permitCall(bob, alice, bob, 1, block.timestamp, v2, r, s2),
            RevertClass.InvalidPermit,
            abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, s2)
        );
    }

    function test_Permit_RevertWhen_RecoveryByteIsInvalid() public {
        (, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 1, block.timestamp);
        uint8[4] memory badVs = [uint8(0), 1, 29, 255];
        for (uint256 i; i < badVs.length; ++i) {
            _assertRevert(
                _permitCall(bob, alice, bob, 1, block.timestamp, badVs[i], r, s),
                RevertClass.InvalidPermit,
                abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector)
            );
        }
    }

    /// @notice An unrecoverable signature makes ecrecover return address(0), which must never be accepted
    ///         as a signature by owner == address(0) (trick T6: `signer != 0` is half of the golfed check).
    ///         Each `r` below is one for which recovery fails whatever the digest, and the test asserts that
    ///         first: r = 0 and r = n are outside [1, n - 1], and r = 5 is no point's x-coordinate
    ///         (5**3 + 7 = 132 is a quadratic non-residue modulo the field prime). An `r` with a point,
    ///         such as 1, recovers a non-zero address and would not test this at all.
    function test_Permit_RevertWhen_OwnerIsZero() public {
        uint256 deadline = block.timestamp;
        bytes32 digest = _permitDigest(address(token), address(0), bob, 1, token.nonces(address(0)), deadline);
        uint256[3] memory rs = [uint256(0), SECP256K1_N, 5];
        for (uint256 i; i < rs.length; ++i) {
            for (uint8 v = 27; v <= 28; ++v) {
                bytes32 r = bytes32(rs[i]);
                bytes32 s = bytes32(uint256(2));
                assertEq(ecrecover(digest, v, r, s), address(0), "the signature must be unrecoverable");
                _assertRevert(_permitCall(bob, address(0), bob, 1, deadline, v, r, s), RevertClass.InvalidPermit, "");
                assertEq(token.allowance(address(0), bob), 0);
                assertEq(token.nonces(address(0)), 0);
            }
        }
    }

    function test_Permit_RevertWhen_SpenderIsZero() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, address(0), 1, block.timestamp);
        _assertRevert(
            _permitCall(bob, alice, address(0), 1, block.timestamp, v, r, s),
            RevertClass.InvalidSpender,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
        assertEq(token.nonces(alice), 0, "the nonce increment must be rolled back");
    }

    function testFuzz_Permit(uint256 key, address spender, uint256 value, uint256 deadline) public {
        key = bound(key, 1, SECP256K1_N - 1);
        vm.assume(spender != address(0));
        deadline = bound(deadline, block.timestamp, type(uint256).max);
        address owner = vm.addr(key);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, token, spender, value, deadline);
        Outcome memory out = _permitCall(carol, owner, spender, value, deadline, v, r, s);
        assertTrue(out.ok);
        _assertSingleLog(out, IERC20.Approval.selector, owner, spender, value);
        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
    }

    // ------------------------------------------------------------------ EIP-712 domain

    function test_DomainSeparator_MatchesEip712Formula() public view {
        assertEq(token.DOMAIN_SEPARATOR(), _expectedDomainSeparator(address(token)));
    }

    function test_DomainSeparator_FollowsChainIdAfterFork() public {
        bytes32 before = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 1, block.timestamp);
        vm.chainId(vm.getChainId() + 1);
        assertEq(token.DOMAIN_SEPARATOR(), _expectedDomainSeparator(address(token)));
        assertTrue(token.DOMAIN_SEPARATOR() != before);
        // A signature for the old chain id is no longer valid ...
        _assertRevert(_permitCall(bob, alice, bob, 1, block.timestamp, v, r, s), RevertClass.InvalidPermit, "");
        // ... and one for the new chain id is.
        (v, r, s) = _signPermit(ALICE_KEY, token, bob, 1, block.timestamp);
        assertTrue(_permitCall(bob, alice, bob, 1, block.timestamp, v, r, s).ok);
    }

    function test_DomainSeparator_UsesExecutingAddressUnderDelegatecall() public {
        DelegateProxy proxy = new DelegateProxy(address(token));
        assertEq(IQuartetToken(address(proxy)).DOMAIN_SEPARATOR(), _expectedDomainSeparator(address(proxy)));
    }

    // ------------------------------------------------------------------ ABI strictness

    function test_RevertWhen_CalldataIsTruncated() public {
        bytes[7] memory calls = [
            abi.encodeCall(IERC20.transfer, (bob, 1)),
            abi.encodeCall(IERC20.approve, (bob, 1)),
            abi.encodeCall(IERC20.transferFrom, (alice, bob, 1)),
            abi.encodeCall(IERC20.balanceOf, (alice)),
            abi.encodeCall(IERC20.allowance, (alice, bob)),
            abi.encodeCall(IERC20Permit.nonces, (alice)),
            abi.encodeCall(IERC20Permit.permit, (alice, bob, 1, 1, 27, bytes32(0), bytes32(0)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            bytes memory data = calls[i];
            // Memory-safe: shortens an array this function owns.
            assembly ("memory-safe") {
                mstore(data, sub(mload(data), 1))
            }
            _assertEmptyRevert(_call(alice, data));
        }
    }

    function test_ExtraTrailingCalldataIsIgnored() public {
        Outcome memory out = _call(alice, bytes.concat(abi.encodeCall(IERC20.transfer, (bob, 1)), hex"deadbeef"));
        _assertReturnsTrue(out);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_RevertWhen_AddressArgumentHasDirtyUpperBits() public {
        bytes memory data = abi.encodeCall(IERC20.transfer, (bob, 1));
        data[4] = 0x01; // First byte of the 32-byte address word.
        _assertEmptyRevert(_call(alice, data));
        data = abi.encodeCall(IERC20.balanceOf, (alice));
        data[15] = 0xff; // Last padding byte before the 20 address bytes.
        _assertEmptyRevert(_call(alice, data));
    }

    function test_RevertWhen_PermitRecoveryByteHasDirtyUpperBits() public {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, bob, 1, block.timestamp);
        bytes memory data = abi.encodeCall(IERC20Permit.permit, (alice, bob, 1, block.timestamp, v, r, s));
        data[4 + 4 * 32 + 30] = 0x01; // v is the fifth word; set a bit above its low byte.
        _assertEmptyRevert(_call(bob, data));
    }

    /// @dev Dirties word `word` of `clean` (the 32-byte argument word after the selector) at its highest bit
    ///      and, separately, at its lowest must-be-zero bit, with every other word clean, and requires an
    ///      empty revert each time. `zeroBytes` is 12 for an address, 31 for a uint8.
    function _assertRejectsDirtyWord(address caller, bytes memory clean, uint256 word, uint256 zeroBytes) internal {
        uint256 start = 4 + 32 * word;
        bytes memory dirty = bytes.concat(clean);
        dirty[start] = 0x80;
        _assertEmptyRevert(_call(caller, dirty));
        dirty = bytes.concat(clean);
        dirty[start + zeroBytes - 1] = 0x01;
        _assertEmptyRevert(_call(caller, dirty));
    }

    /// @notice Every address word of every function, one at a time and each with the other words clean: the
    ///         second address of `transferFrom` (`to`), `allowance` (`spender`) and `permit` (`spender`)
    ///         included. The Yul object validates such pairs with a single `shr(160, or(a, b))` (trick T8);
    ///         dropping `b` from it would let a dirty `to` be used directly as a storage slot. Each clean call
    ///         is made afterwards and must succeed, so the dirty bits alone are what the decoder rejected.
    function test_RevertWhen_AnyAddressWordHasDirtyUpperBits() public {
        _approve(alice, bob, 10);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, token, carol, 5, block.timestamp);
        bytes[7] memory calls = [
            abi.encodeCall(IERC20.transfer, (bob, 1)),
            abi.encodeCall(IERC20.approve, (carol, 1)),
            abi.encodeCall(IERC20.balanceOf, (alice)),
            abi.encodeCall(IERC20Permit.nonces, (alice)),
            abi.encodeCall(IERC20.transferFrom, (alice, carol, 1)),
            abi.encodeCall(IERC20.allowance, (alice, bob)),
            abi.encodeCall(IERC20Permit.permit, (alice, carol, 5, block.timestamp, v, r, s))
        ];
        // The caller of transferFrom is the approved spender; everything else is called by alice.
        address[7] memory callers = [alice, alice, alice, alice, bob, alice, alice];
        // Address words per call: one for the first four, two for transferFrom, allowance and permit.
        uint256[7] memory addressWords = [uint256(1), 1, 1, 1, 2, 2, 2];
        for (uint256 i; i < calls.length; ++i) {
            for (uint256 w; w < addressWords[i]; ++w) {
                _assertRejectsDirtyWord(callers[i], calls[i], w, 12);
            }
        }
        // Nothing moved, and every clean call succeeds.
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.allowance(alice, bob), 10);
        assertEq(token.nonces(alice), 0);
        for (uint256 i; i < calls.length; ++i) {
            assertTrue(_call(callers[i], calls[i]).ok, "the clean call must succeed");
        }
        assertEq(token.balanceOf(carol), 1);
        assertEq(token.allowance(alice, carol), 5);
        assertEq(token.nonces(alice), 1);
    }

    /// @dev The twelve selectors of the shared surface.
    function _surfaceSelectors() internal pure returns (bytes4[12] memory) {
        return [
            IERC20.transfer.selector,
            IERC20.approve.selector,
            IERC20.transferFrom.selector,
            IERC20.balanceOf.selector,
            IERC20.allowance.selector,
            IERC20.totalSupply.selector,
            IERC20Permit.permit.selector,
            IERC20Permit.nonces.selector,
            IERC20Permit.DOMAIN_SEPARATOR.selector,
            bytes4(keccak256("name()")),
            bytes4(keccak256("symbol()")),
            bytes4(keccak256("decimals()"))
        ];
    }

    function test_RevertWhen_SelectorIsUnknownOrShort() public {
        _assertEmptyRevert(_call(alice, hex""));
        _assertEmptyRevert(_call(alice, hex"a9059c"));
        // nonces(address) is 0x7ecebe00: these three bytes, zero-padded by CALLDATALOAD, ARE its selector, so
        // a dispatcher without a length check (the Yul object's) reaches nonces(), whose own length check
        // must reject the call.
        assertEq(IERC20Permit.nonces.selector, bytes4(0x7ecebe00));
        _assertEmptyRevert(_call(alice, hex"7ecebe"));
        _assertEmptyRevert(_call(alice, hex"12345678"));
        _assertEmptyRevert(_call(alice, abi.encodeWithSignature("mint(address,uint256)", alice, 1)));
        // Every 1-3 byte prefix of every selector of the surface.
        bytes4[12] memory selectors = _surfaceSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            for (uint256 len = 1; len < 4; ++len) {
                bytes memory prefix = abi.encodePacked(selectors[i]);
                // Memory-safe: shortens an array this function owns.
                assembly ("memory-safe") {
                    mstore(prefix, len)
                }
                _assertEmptyRevert(_call(alice, prefix));
            }
        }
    }

    function test_RevertWhen_ValueIsSent() public {
        bytes[5] memory calls = [
            abi.encodeCall(IERC20.transfer, (bob, 1)),
            abi.encodeCall(IERC20.approve, (bob, 1)),
            abi.encodeCall(IERC20.balanceOf, (alice)),
            abi.encodeCall(IERC20.totalSupply, ()),
            hex""
        ];
        vm.deal(alice, 1 ether);
        for (uint256 i; i < calls.length; ++i) {
            _assertEmptyRevert(_capture(alice, address(token), calls[i], 1 wei));
        }
    }
}
