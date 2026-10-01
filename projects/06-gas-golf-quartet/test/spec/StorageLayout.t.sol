// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetToken} from "../../src/interfaces/IQuartetToken.sol";
import {QuartetBase} from "../utils/QuartetBase.sol";
import {Impl} from "../utils/RevertClassifier.sol";
import {StorageLayout} from "../utils/StorageLayout.sol";

/// @title StorageLayoutTest
/// @notice Pins the storage layout of every implementation. The halmos proofs seed symbolic state through
///         these slot formulas, so a wrong formula would make them prove the wrong thing; these tests make
///         that impossible: each formula must locate the word written by a real call.
contract StorageLayoutTest is QuartetBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    IQuartetToken[5] internal tokens;

    function setUp() public {
        for (uint256 i; i < 5; ++i) {
            tokens[i] = _deploy(Impl(i), alice, SUPPLY);
        }
    }

    function test_SlotFormulasLocateRealState() public {
        for (uint256 i; i < 5; ++i) {
            Impl impl = Impl(i);
            IQuartetToken token = tokens[i];
            vm.prank(alice);
            token.transfer(bob, 3e18);
            vm.prank(alice);
            token.approve(bob, 77);

            assertEq(uint256(vm.load(address(token), StorageLayout.balanceSlot(impl, alice))), SUPPLY - 3e18);
            assertEq(uint256(vm.load(address(token), StorageLayout.balanceSlot(impl, bob))), 3e18);
            assertEq(uint256(vm.load(address(token), StorageLayout.allowanceSlot(impl, alice, bob))), 77);
            assertEq(uint256(vm.load(address(token), StorageLayout.allowanceSlot(impl, bob, alice))), 0);

            // Writing through the formula is observed by the getters.
            vm.store(address(token), StorageLayout.nonceSlot(impl, bob), bytes32(uint256(9)));
            assertEq(token.nonces(bob), 9, _name(impl));
            vm.store(address(token), StorageLayout.balanceSlot(impl, bob), bytes32(uint256(11)));
            assertEq(token.balanceOf(bob), 11, _name(impl));
        }
    }

    /// @notice Trick T2's layout claim, checked on the deployed tokens rather than on the formulas: an
    ///         allowance write changes that allowance and nothing else a getter can see. Every address
    ///         involved gets a distinct non-zero balance and nonce first, including `alias`, the address
    ///         whose Yul balance slot (and, 2**160 higher, nonce slot) shares the low 160 bits of the
    ///         allowance slot. A layout that keyed allowances into the balance or nonce range (an identity
    ///         or xor formula, a shared seed) fails here. That a keccak256 output lands below 2**161 only
    ///         with probability 2**-95 is the written argument in docs/THREAT_MODEL.md, not something a
    ///         test can show.
    function testFuzz_AllowanceWriteTouchesNoBalanceOrNonce(address owner, address spender, uint256 amount) public {
        vm.assume(owner != address(0) && spender != address(0));
        for (uint256 i; i < 5; ++i) {
            Impl impl = Impl(i);
            IQuartetToken token = tokens[i];
            address alias_ = address(uint160(uint256(StorageLayout.allowanceSlot(impl, owner, spender))));
            address[4] memory watched = [owner, spender, alias_, alice];
            for (uint256 j; j < watched.length; ++j) {
                vm.store(address(token), StorageLayout.balanceSlot(impl, watched[j]), _marker(watched[j], "balance"));
                vm.store(address(token), StorageLayout.nonceSlot(impl, watched[j]), _marker(watched[j], "nonce"));
            }

            vm.prank(owner);
            assertTrue(token.approve(spender, amount));

            assertEq(token.allowance(owner, spender), amount, _name(impl));
            for (uint256 j; j < watched.length; ++j) {
                assertEq(bytes32(token.balanceOf(watched[j])), _marker(watched[j], "balance"), _name(impl));
                assertEq(bytes32(token.nonces(watched[j])), _marker(watched[j], "nonce"), _name(impl));
            }
            assertEq(token.totalSupply(), SUPPLY, _name(impl));
        }
    }

    function _marker(address account, string memory what) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, what));
    }
}
