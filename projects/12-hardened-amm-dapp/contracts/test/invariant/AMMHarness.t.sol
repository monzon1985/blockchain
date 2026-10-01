// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";

import {AMMRouter} from "../../src/AMMRouter.sol";
import {IAMMPair} from "../../src/interfaces/IAMMPair.sol";
import {AMMMedusa} from "../medusa/AMMMedusa.sol";
import {AMMHandler} from "./AMMInvariant.t.sol";
import {AMMSystem} from "./AMMSystem.sol";

/// @notice Tests of the stateful-test harness itself: the handlers must not be able to pass vacuously. A broken
///         router is simulated with `vm.mockCall` / `vm.mockCallRevert`, and each test proves that the Foundry
///         handler (AMMHandler) and the Medusa harness (AMMMedusa) notice.
contract AMMHarnessTest is Test {
    AMMHandler internal handler;
    AMMMedusa internal medusa;

    function setUp() public {
        handler = new AMMHandler();
        medusa = new AMMMedusa();
    }

    function _mockSwapRevert(AMMSystem system, bytes memory reason) internal {
        vm.mockCallRevert(
            address(system.router()), abi.encodeWithSelector(AMMRouter.swapExactTokensForTokens.selector), reason
        );
    }

    // ------------------------------------------------------------------------------------------------------
    // Unexpected reverts are failures, expected ones are counted
    // ------------------------------------------------------------------------------------------------------

    function test_foundryHandler_reRaisesAnUnexpectedRouterRevert() public {
        bytes memory k = abi.encodeWithSelector(IAMMPair.K.selector, 1, 2);
        _mockSwapRevert(handler, k);
        vm.expectRevert(k);
        handler.swapExactIn(0, 0, 1e18);
    }

    function test_foundryHandler_reRaisesABareRevert() public {
        _mockSwapRevert(handler, "");
        vm.expectRevert(bytes(""));
        handler.swapExactIn(0, 0, 1e18);
    }

    function test_medusaHarness_turnsAnUnexpectedRevertIntoAnAssertionFailure() public {
        bytes memory k = abi.encodeWithSelector(IAMMPair.K.selector, 1, 2);
        _mockSwapRevert(medusa, k);
        vm.expectEmit(address(medusa));
        emit AMMMedusa.UnexpectedRevert(k);
        vm.expectRevert(stdError.assertionError);
        medusa.swapExactIn(0, 0, 1e18);
    }

    function test_expectedRevert_isSwallowedAndCountedAsAnAttempt() public {
        _mockSwapRevert(handler, abi.encodeWithSelector(IAMMPair.InsufficientOutputAmount.selector));
        handler.swapExactIn(0, 0, 1e18);
        assertEq(handler.swapAttempts(), 1);
        assertEq(handler.swapsExecuted(), 0);
    }

    function test_expectedErrorOfAnotherAction_isStillUnexpected() public {
        // InsufficientLiquidityBurned is expected from a withdrawal, never from a swap.
        bytes memory burned = abi.encodeWithSelector(IAMMPair.InsufficientLiquidityBurned.selector, 0, 0);
        _mockSwapRevert(handler, burned);
        vm.expectRevert(burned);
        handler.swapExactIn(0, 0, 1e18);
    }

    // ------------------------------------------------------------------------------------------------------
    // Successful calls are checked against their exact postconditions
    // ------------------------------------------------------------------------------------------------------

    function test_swapThatDeliversNothing_failsTheAssertion() public {
        // The router "succeeds" and reports the quote but moves no tokens.
        address[] memory path = new address[](2);
        (path[0], path[1]) = (address(handler.tokens(0)), address(handler.tokens(1)));
        uint256[] memory quoted = handler.router().getAmountsOut(1e18, path);
        vm.mockCall(
            address(handler.router()),
            abi.encodeWithSelector(AMMRouter.swapExactTokensForTokens.selector),
            abi.encode(quoted)
        );
        vm.expectRevert(stdError.assertionError);
        handler.swapExactIn(0, 0, 1e18);
    }

    function test_burnThatPaysNothing_failsTheAssertion() public {
        // The router reports a payout but transfers nothing (and burns nothing).
        vm.mockCall(
            address(handler.router()),
            abi.encodeWithSelector(AMMRouter.removeLiquidity.selector),
            abi.encode(uint256(1e18), uint256(1e18))
        );
        vm.expectRevert(stdError.assertionError);
        handler.removeLiquidity(0, 0, 5000);
    }

    function test_depositThatMintsTheWrongAmount_failsTheAssertion() public {
        vm.mockCall(
            address(handler.router()),
            abi.encodeWithSelector(AMMRouter.addLiquidity.selector),
            abi.encode(uint256(1e18), uint256(1e18), uint256(1e18))
        );
        vm.expectRevert(stdError.assertionError);
        handler.addLiquidity(0, 0, 1e18, 1e18);
    }

    function test_realActions_passTheirAssertions() public {
        handler.addLiquidity(0, 0, 1e21, 3e21);
        handler.swapExactIn(1, 0, 1e18);
        handler.swapExactOut(2, 1, 1e18);
        handler.swapSupportingFeeOnTransfer(0, 2 + (1 << 16), 1e18);
        handler.donate(0, 1e18, 1e18);
        handler.roundTrip(1, 0, 1e18, false); // pair 0 holds a donation: executed, but not a recorded round trip
        handler.skim(0, 2);
        handler.flashSwap(1, 1e18, 0);
        handler.setProtocolFee(true);
        handler.warp(1 days);
        handler.sync(2);
        handler.removeLiquidity(0, 0, 5000);
        handler.removeLiquiditySupportingFeeOnTransfer(1, 1, 10_000);
        assertEq(handler.swapsExecuted(), 5);
        assertEq(handler.exactOutExecuted(), 1);
        assertEq(handler.burnsExecuted(), 2);
        assertEq(handler.roundTrips(), 0);
        handler.roundTrip(1, 1, 1e18, true);
        assertEq(handler.roundTrips(), 1);
    }

    // ------------------------------------------------------------------------------------------------------
    // Non-vacuity guard used by afterInvariant
    // ------------------------------------------------------------------------------------------------------

    function test_notVacuous_flagsARunInWhichEverySwapReverted() public {
        _mockSwapRevert(handler, abi.encodeWithSelector(IAMMPair.InsufficientOutputAmount.selector));
        for (uint256 i; i < 7; ++i) {
            handler.swapExactIn(i, 0, 1e18);
        }
        assertTrue(handler.checkNotVacuous(8), "7 failed attempts are below the threshold");
        handler.swapExactIn(0, 0, 1e18);
        assertFalse(handler.checkNotVacuous(8), "8 failed attempts and no success");
    }

    function test_notVacuous_flagsARunInWhichEveryBurnReverted() public {
        vm.mockCallRevert(
            address(handler.router()),
            abi.encodeWithSelector(AMMRouter.removeLiquidity.selector),
            abi.encodeWithSelector(IAMMPair.InsufficientLiquidityBurned.selector, 0, 0)
        );
        for (uint256 i; i < 8; ++i) {
            handler.removeLiquidity(i, i, 5000);
        }
        assertEq(handler.burnAttempts(), 8);
        assertFalse(handler.checkNotVacuous(8));
    }
}
