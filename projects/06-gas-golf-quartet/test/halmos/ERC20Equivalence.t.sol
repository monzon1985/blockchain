// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {QuartetAssembly} from "../../src/assembly/QuartetAssembly.sol";
import {YulBytecode} from "../../src/generated/YulBytecode.sol";
import {QuartetSolidity} from "../../src/solidity/QuartetSolidity.sol";
import {Impl, RevertClass, RevertClassifier} from "../utils/RevertClassifier.sol";
import {StorageLayout} from "../utils/StorageLayout.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Test} from "forge-std/Test.sol";

/// @title ERC20Equivalence
/// @notice Halmos proofs that the Solidity, inline-assembly and Yul tokens are equivalent on `transfer`,
///         `approve`, `transferFrom` and the view functions, for every non-zero caller, every ABI-encoded
///         argument and symbolic prior state: the balances and allowances a call reads are written as
///         unconstrained symbolic words into each implementation's own storage layout
///         (test/utils/StorageLayout.sol) before the call. Each check compares the success flag, the return
///         data or revert class, and then, through the getters, the post-call state listed in its NatSpec.
///         `check_dirtyWordsAreRejected` covers calldata that ABI encoding cannot produce: address words
///         with bits above bit 159 and a `uint8 v` word above 255.
/// @dev Events are not visible to halmos 0.3.3 (no `recordLogs`); log equality is enforced by the lockstep
///      differential fuzzer. The one precondition is `msg.sender != address(0)`: OpenZeppelin (and so the
///      Solidity version) rejects a zero sender and the golfed versions do not check it (trick T15), so with
///      a zero caller they really do differ. No signed transaction has that sender, but an `eth_call`
///      without `from` does. Vyper is excluded (halmos cannot execute it through forge); it is covered by
///      differential fuzzing.
contract ERC20Equivalence is Test {
    address internal constant HOLDER = address(0xA11CE);
    uint256 internal constant SUPPLY = 1_000_000e18;

    address[3] internal tokens;
    Impl[3] internal impls = [Impl.Solidity, Impl.Assembly, Impl.Yul];

    struct Result {
        bool ok;
        bytes ret;
    }

    function setUp() public {
        tokens[0] = address(new QuartetSolidity(HOLDER, SUPPLY));
        tokens[1] = address(new QuartetAssembly(HOLDER, SUPPLY));
        bytes memory initcode = bytes.concat(YulBytecode.CREATION, abi.encode(HOLDER, SUPPLY));
        address yul;
        // Memory-safe: reads the initcode in place.
        assembly ("memory-safe") {
            yul := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(yul != address(0), "yul deploy failed");
        tokens[2] = yul;
    }

    /// @notice transfer: all three agree for any non-zero caller, recipient, amount and prior balances.
    ///         Post-state: the balances of the caller, the recipient and an arbitrary third address; the
    ///         allowances between caller and recipient (both directions); the nonces of both.
    function check_transfer(
        address caller,
        address to,
        uint256 amount,
        uint256 callerBalance,
        uint256 toBalance,
        address other
    ) external {
        vm.assume(caller != address(0));
        _setBalance(caller, callerBalance);
        _setBalance(to, toBalance);
        Result[3] memory r = _callAll(caller, abi.encodeCall(IERC20.transfer, (to, amount)));
        _assertAgree(r);
        _assertSameBalance(caller);
        _assertSameBalance(to);
        _assertSameBalance(other);
        _assertSameAllowance(caller, to);
        _assertSameAllowance(to, caller);
        _assertSameNonce(caller);
        _assertSameNonce(to);
    }

    /// @notice approve: all three agree for any non-zero caller, spender, amount and prior allowance.
    ///         Post-state: the allowance written and one at an arbitrary (owner, spender) pair; the balances
    ///         and nonces of the caller and the spender (an allowance write must not land on them).
    function check_approve(
        address caller,
        address spender,
        uint256 amount,
        uint256 prior,
        address otherOwner,
        address otherSpender
    ) external {
        vm.assume(caller != address(0));
        _setAllowance(caller, spender, prior);
        Result[3] memory r = _callAll(caller, abi.encodeCall(IERC20.approve, (spender, amount)));
        _assertAgree(r);
        _assertSameAllowance(caller, spender);
        _assertSameAllowance(otherOwner, otherSpender);
        _assertSameBalance(caller);
        _assertSameBalance(spender);
        _assertSameNonce(caller);
        _assertSameNonce(spender);
    }

    /// @notice transferFrom: all three agree for any non-zero caller, owner, recipient, amount, allowance
    ///         (including the infinite one and allowances held by the zero address) and balances.
    ///         Post-state: the allowance spent; the balances of the owner, the recipient and an arbitrary
    ///         third address; the nonces of the owner and the recipient.
    function check_transferFrom(
        address caller,
        address from,
        address to,
        uint256 amount,
        uint256 allowed,
        uint256 fromBalance,
        uint256 toBalance,
        address other
    ) external {
        vm.assume(caller != address(0));
        _setAllowance(from, caller, allowed);
        _setBalance(from, fromBalance);
        _setBalance(to, toBalance);
        Result[3] memory r = _callAll(caller, abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        _assertAgree(r);
        _assertSameAllowance(from, caller);
        _assertSameBalance(from);
        _assertSameBalance(to);
        _assertSameBalance(other);
        _assertSameNonce(from);
        _assertSameNonce(to);
    }

    /// @notice balanceOf, allowance, nonces, totalSupply, decimals, name and symbol read the same state.
    function check_views(address owner, address spender, uint256 balance, uint256 allowed, uint256 nonce) external {
        _setBalance(owner, balance);
        _setAllowance(owner, spender, allowed);
        for (uint256 i; i < 3; ++i) {
            vm.store(tokens[i], StorageLayout.nonceSlot(impls[i], owner), bytes32(nonce));
        }
        _assertAgree(_callAll(owner, abi.encodeCall(IERC20.balanceOf, (owner))));
        _assertAgree(_callAll(owner, abi.encodeCall(IERC20.allowance, (owner, spender))));
        _assertAgree(_callAll(owner, abi.encodeCall(IERC20Permit.nonces, (owner))));
        _assertAgree(_callAll(owner, abi.encodeCall(IERC20.totalSupply, ())));
        _assertAgree(_callAll(owner, abi.encodeWithSignature("decimals()")));
        _assertAgree(_callAll(owner, abi.encodeWithSignature("name()")));
        _assertAgree(_callAll(owner, abi.encodeWithSignature("symbol()")));
    }

    /// @notice ABI validation by hand (trick T8): for every address position of every function, a word with
    ///         any bit above bit 159 (every other word clean) makes all three revert with empty data, and so
    ///         does a `uint8 v` word above 255 in `permit`. Solidity's compiler-generated decoder is the
    ///         referent; the Yul object validates pairs of address words with one `shr(160, or(a, b))`.
    function check_dirtyWordsAreRejected(address caller, uint256 dirty, uint256 dirtyV, uint256 value) external {
        vm.assume(caller != address(0));
        vm.assume(dirty >> 160 != 0);
        vm.assume(dirtyV >> 8 != 0);
        address a = HOLDER;
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20.transfer.selector, dirty, value));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20.approve.selector, dirty, value));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20.transferFrom.selector, dirty, a, value));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20.transferFrom.selector, a, dirty, value));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20.balanceOf.selector, dirty));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20.allowance.selector, dirty, a));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20.allowance.selector, a, dirty));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(IERC20Permit.nonces.selector, dirty));
        bytes4 permit = IERC20Permit.permit.selector;
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(permit, dirty, a, value, value, 27, value, value));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(permit, a, dirty, value, value, 27, value, value));
        _assertAllRejectEmpty(caller, abi.encodeWithSelector(permit, a, a, value, value, dirtyV, value, value));
    }

    function _assertAllRejectEmpty(address caller, bytes memory data) internal {
        Result[3] memory r = _callAll(caller, data);
        for (uint256 i; i < 3; ++i) {
            assert(!r[i].ok);
            assert(r[i].ret.length == 0);
        }
    }

    function _setBalance(address owner, uint256 value) internal {
        for (uint256 i; i < 3; ++i) {
            vm.store(tokens[i], StorageLayout.balanceSlot(impls[i], owner), bytes32(value));
        }
    }

    function _setAllowance(address owner, address spender, uint256 value) internal {
        for (uint256 i; i < 3; ++i) {
            vm.store(tokens[i], StorageLayout.allowanceSlot(impls[i], owner, spender), bytes32(value));
        }
    }

    function _callAll(address caller, bytes memory data) internal returns (Result[3] memory r) {
        for (uint256 i; i < 3; ++i) {
            vm.prank(caller);
            (r[i].ok, r[i].ret) = tokens[i].call(data);
        }
    }

    function _assertAgree(Result[3] memory r) internal view {
        for (uint256 i = 1; i < 3; ++i) {
            assert(r[i].ok == r[0].ok);
            if (r[0].ok) {
                assert(r[i].ret.length == r[0].ret.length);
                assert(keccak256(r[i].ret) == keccak256(r[0].ret));
            } else {
                RevertClass expected = RevertClassifier.classify(impls[0], r[0].ret);
                assert(expected != RevertClass.Unknown && expected != RevertClass.Panic);
                assert(RevertClassifier.classify(impls[i], r[i].ret) == expected);
            }
        }
    }

    function _assertSameBalance(address owner) internal view {
        uint256 expected = IERC20(tokens[0]).balanceOf(owner);
        assert(IERC20(tokens[1]).balanceOf(owner) == expected);
        assert(IERC20(tokens[2]).balanceOf(owner) == expected);
    }

    function _assertSameAllowance(address owner, address spender) internal view {
        uint256 expected = IERC20(tokens[0]).allowance(owner, spender);
        assert(IERC20(tokens[1]).allowance(owner, spender) == expected);
        assert(IERC20(tokens[2]).allowance(owner, spender) == expected);
    }

    function _assertSameNonce(address owner) internal view {
        uint256 expected = IERC20Permit(tokens[0]).nonces(owner);
        assert(IERC20Permit(tokens[1]).nonces(owner) == expected);
        assert(IERC20Permit(tokens[2]).nonces(owner) == expected);
    }
}
