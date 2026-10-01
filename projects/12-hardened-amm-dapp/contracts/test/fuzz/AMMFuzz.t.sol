// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {AMMPair} from "../../src/AMMPair.sol";
import {IAMMPair} from "../../src/interfaces/IAMMPair.sol";
import {AMMLibrary} from "../../src/libraries/AMMLibrary.sol";
import {AMMTestBase} from "../utils/AMMTestBase.sol";

/// @notice Stateless properties of the pair math and the router, over fuzzed pool shapes and trade sizes.
contract AMMFuzzTest is AMMTestBase {
    /// @dev The first mint is floor(sqrt(a * b)) - MINIMUM_LIQUIDITY: the square root is correctly rounded down.
    function testFuzz_firstMint_isFloorSqrtMinusMinimumLiquidity(uint256 a, uint256 b) public {
        a = bound(a, 1001, 1e33);
        b = bound(b, 1001, 1e33);
        AMMPair pair = AMMPair(factory.createPair(address(tokenA), address(tokenB)));
        tokenA.mint(address(pair), a);
        tokenB.mint(address(pair), b);
        uint256 product = a * b;
        try pair.mint(alice) returns (uint256 liquidity) {
            uint256 root = liquidity + 1000;
            assertLe(root * root, product, "root rounded down");
            assertGt((root + 1) * (root + 1), product, "root is the largest integer below sqrt");
        } catch (bytes memory reason) {
            // Only possible when floor(sqrt(a * b)) <= 1000.
            assertEq(reason, abi.encodeWithSelector(IAMMPair.InsufficientLiquidityMinted.selector, 0));
            assertLe(product, 1001 * 1001 - 1);
        }
    }

    /// @dev getAmountOut is the exact k boundary of this pair: the quote passes, one more wei fails.
    function testFuzz_getAmountOut_isTheLargestOutputThePairAccepts(
        uint256 r0,
        uint256 r1,
        uint256 amountIn,
        bool zeroForOne
    ) public {
        tokenA.mint(address(this), 1e32);
        tokenB.mint(address(this), 1e32);
        _addLiquidity(address(this), address(tokenA), address(tokenB), bound(r0, 1e6, 1e32), bound(r1, 1e6, 1e32));
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        amountIn = bound(amountIn, router.getAmountIn(1, reserveIn, reserveOut), reserveIn * 10);
        uint256 out = router.getAmountOut(amountIn, reserveIn, reserveOut);
        address tokenIn = zeroForOne ? pair.token0() : pair.token1();
        tokenA.mint(address(this), amountIn); // enough of either token
        tokenB.mint(address(this), amountIn);

        (uint256 o0, uint256 o1) = zeroForOne ? (uint256(0), out + 1) : (out + 1, uint256(0));
        uint256 snapshot = vm.snapshotState();
        _pay(tokenIn, address(pair), amountIn);
        vm.expectRevert(); // K, or InsufficientLiquidity when out + 1 == reserveOut
        pair.swap(o0, o1, bob, "");
        vm.revertToState(snapshot);

        (o0, o1) = zeroForOne ? (uint256(0), out) : (out, uint256(0));
        _pay(tokenIn, address(pair), amountIn);
        pair.swap(o0, o1, bob, "");
    }

    function _pay(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "pay");
    }

    /// @dev getAmountIn is sufficient and, fed back into getAmountOut, yields at least the requested output.
    function testFuzz_getAmountIn_roundTripsThroughGetAmountOut(uint256 reserveIn, uint256 reserveOut, uint256 out)
        public
        view
    {
        reserveIn = bound(reserveIn, 1e3, 1e33);
        reserveOut = bound(reserveOut, 1e3, 1e33);
        // Up to 99 % of the reserve keeps amountIn * 997 * reserveOut inside 256 bits (v2 math reverts beyond).
        out = bound(out, 1, reserveOut * 99 / 100);
        uint256 amountIn = router.getAmountIn(out, reserveIn, reserveOut);
        assertGe(router.getAmountOut(amountIn, reserveIn, reserveOut), out);
        // Tight up to the unconditional "+1" of Uniswap v2's rounding: two wei less can never buy `out`.
        if (amountIn > 2) assertLt(router.getAmountOut(amountIn - 2, reserveIn, reserveOut), out);
    }

    /// @dev An exact-input swap followed by the reverse swap of its whole output never returns more than the input.
    function testFuzz_roundTripSwap_neverProfits(uint256 r0, uint256 r1, uint256 amountIn) public {
        _addLiquidity(address(this), address(tokenA), address(tokenB), bound(r0, 1e9, 1e30), bound(r1, 1e9, 1e30));
        (uint256 ra, uint256 rb) = _reserves(address(tokenA), address(tokenB));
        amountIn = bound(amountIn, router.getAmountIn(1, ra, rb), ra * 5); // always quotes >= 1 wei out
        tokenA.mint(alice, amountIn);
        vm.startPrank(alice);
        uint256[] memory out =
            router.swapExactTokensForTokens(amountIn, 0, _path(address(tokenA), address(tokenB)), alice, deadline);
        // Swapping a dust output back can quote zero and revert: then nothing comes back, which trivially holds.
        try router.swapExactTokensForTokens(
            out[1], 0, _path(address(tokenB), address(tokenA)), alice, deadline
        ) returns (
            uint256[] memory back
        ) {
            assertLe(back[1], amountIn);
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(AMMLibrary.InsufficientOutputAmount.selector));
        }
        vm.stopPrank();
    }

    /// @dev Adding then immediately removing liquidity never returns more than was deposited.
    function testFuzz_addRemove_neverReturnsMoreThanDeposited(uint256 r0, uint256 r1, uint256 a, uint256 b) public {
        _addLiquidity(address(this), address(tokenA), address(tokenB), bound(r0, 1e9, 1e29), bound(r1, 1e9, 1e29));
        (uint256 ra, uint256 rb) = _reserves(address(tokenA), address(tokenB));
        // At least 0.1 % of each reserve, so the deposit always mints LP (supply >= 1e9 here).
        a = bound(a, ra / 1e3 + 1, 1e30);
        b = bound(b, rb / 1e3 + 1, 1e30);
        vm.startPrank(alice);
        (uint256 depositedA, uint256 depositedB, uint256 liquidity) =
            router.addLiquidity(address(tokenA), address(tokenB), a, b, 0, 0, alice, deadline);
        _pair(address(tokenA), address(tokenB)).approve(address(router), liquidity);
        (uint256 gotA, uint256 gotB) =
            router.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, 0, alice, deadline);
        vm.stopPrank();
        assertLe(gotA, depositedA);
        assertLe(gotB, depositedB);
    }

    /// @dev Multi-hop exact-in equals chaining the single-hop quotes, and the router delivers exactly that.
    function testFuzz_multiHop_equalsChainedSingleHops(uint256 amountIn, uint256 ab, uint256 bc) public {
        _addLiquidity(address(this), address(tokenA), address(tokenB), 1e24, bound(ab, 1e20, 1e28));
        _addLiquidity(address(this), address(tokenB), address(tokenC), 1e24, bound(bc, 1e20, 1e28));
        amountIn = bound(amountIn, 1e15, 1e24); // large enough that both hops quote a non-zero output
        (uint256 rab, uint256 rba) = _reserves(address(tokenA), address(tokenB));
        (uint256 rbc, uint256 rcb) = _reserves(address(tokenB), address(tokenC));
        uint256 hop1 = router.getAmountOut(amountIn, rab, rba);
        uint256 hop2 = router.getAmountOut(hop1, rbc, rcb);
        assertGt(hop2, 0);
        uint256 before = tokenC.balanceOf(bob);
        vm.prank(alice);
        router.swapExactTokensForTokens(
            amountIn, hop2, _path(address(tokenA), address(tokenB), address(tokenC)), bob, deadline
        );
        assertEq(tokenC.balanceOf(bob) - before, hop2);
    }

    /// @dev Exact-out delivers exactly the requested output and charges exactly getAmountsIn.
    function testFuzz_exactOut_deliversExactlyTheRequestedOutput(uint256 out, uint256 r0, uint256 r1) public {
        _addLiquidity(address(this), address(tokenA), address(tokenB), bound(r0, 1e12, 1e30), bound(r1, 1e12, 1e30));
        (, uint256 rb) = _reserves(address(tokenA), address(tokenB));
        out = bound(out, 1, rb * 9 / 10);
        address[] memory path = _path(address(tokenA), address(tokenB));
        uint256 expectedIn = router.getAmountsIn(out, path)[0];
        tokenA.mint(alice, expectedIn);
        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 beforeB = tokenB.balanceOf(bob);
        vm.prank(alice);
        router.swapTokensForExactTokens(out, expectedIn, path, bob, deadline);
        assertEq(tokenB.balanceOf(bob) - beforeB, out);
        assertEq(beforeA - tokenA.balanceOf(alice), expectedIn);
    }
}
