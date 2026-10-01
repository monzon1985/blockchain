// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AMMPair} from "../../src/AMMPair.sol";
import {IAMMPair} from "../../src/interfaces/IAMMPair.sol";
import {FlashBorrower, ReentrancyProbe, WrongMagicCallee} from "../mocks/Callees.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AMMTestBase} from "../utils/AMMTestBase.sol";

/// @notice Flash swaps: callback validation and the transient lock seen from inside the callback.
contract AMMPairFlashSwapTest is AMMTestBase {
    AMMPair internal pair;

    function setUp() public override {
        super.setUp();
        _addLiquidity(address(this), address(tokenA), address(tokenB), 100 ether, 100 ether);
        pair = _pair(address(tokenA), address(tokenB));
    }

    function _fund(address who) internal {
        MockERC20(pair.token0()).mint(who, 10 ether);
        MockERC20(pair.token1()).mint(who, 10 ether);
    }

    function test_flashSwap_repaidWithFeeSucceeds_andCalleeSeesTheLock() public {
        FlashBorrower borrower = new FlashBorrower(factory);
        _fund(address(borrower));
        uint256 kBefore = _k(pair);
        borrower.borrow(pair, 1 ether, 0);
        assertTrue(borrower.observedLocked(), "lock held during callback");
        assertFalse(pair.isLocked(), "lock released afterwards");
        assertGt(_k(pair), kBefore);
    }

    function test_flashSwap_bothSidesRepaidSucceeds() public {
        FlashBorrower borrower = new FlashBorrower(factory);
        _fund(address(borrower));
        borrower.borrow(pair, 1 ether, 2 ether);
    }

    function test_flashSwap_underpaidRevertsWithK() public {
        FlashBorrower borrower = new FlashBorrower(factory);
        _fund(address(borrower));
        borrower.setRepayNumerator(997); // repays principal + 1 wei: no fee
        vm.expectPartialRevert(IAMMPair.K.selector);
        borrower.borrow(pair, 1 ether, 0);
    }

    function test_flashSwap_rejectsWrongMagicValue() public {
        WrongMagicCallee callee = new WrongMagicCallee();
        _fund(address(callee));
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InvalidCallbackReturn.selector, bytes32(0)));
        callee.borrow(pair, 1 ether, 0);
    }

    function test_flashSwap_rejectsTargetWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.CallbackTargetNotContract.selector, bob));
        pair.swap(1 ether, 0, bob, hex"01");
    }

    function test_flashSwap_calleeMustAuthenticateThePair() public {
        FlashBorrower borrower = new FlashBorrower(factory);
        // A fake "pair" calling the callback directly is rejected by the callee's own check.
        vm.mockCall(address(this), abi.encodeWithSignature("token0()"), abi.encode(address(tokenA)));
        vm.mockCall(address(this), abi.encodeWithSignature("token1()"), abi.encode(address(tokenB)));
        vm.expectRevert(abi.encodeWithSelector(FlashBorrower.UnknownPair.selector, address(this)));
        borrower.ammSwapCall(address(borrower), 1, 0, "");
    }

    function _probe(ReentrancyProbe.Attempt attempt) internal returns (ReentrancyProbe probe) {
        probe = new ReentrancyProbe();
        _fund(address(probe));
        probe.run(pair, attempt, 1 ether, 0);
        assertTrue(probe.sawLocked(), "isLocked() true inside the callback");
        assertEq(
            probe.revertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "reentry reverts with the guard error"
        );
    }

    function test_readOnlyReentrancy_getReservesRevertsInsideCallback() public {
        _probe(ReentrancyProbe.Attempt.GetReserves);
    }

    function test_reentrancy_swapBlocked() public {
        _probe(ReentrancyProbe.Attempt.Swap);
    }

    function test_reentrancy_mintBlocked() public {
        _probe(ReentrancyProbe.Attempt.Mint);
    }

    function test_reentrancy_burnBlocked() public {
        _probe(ReentrancyProbe.Attempt.Burn);
    }

    function test_reentrancy_skimBlocked() public {
        _probe(ReentrancyProbe.Attempt.Skim);
    }

    function test_reentrancy_syncBlocked() public {
        _probe(ReentrancyProbe.Attempt.Sync);
    }
}
