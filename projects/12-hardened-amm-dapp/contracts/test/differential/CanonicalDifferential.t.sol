// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {AMMPair} from "../../src/AMMPair.sol";
import {AMMRouter} from "../../src/AMMRouter.sol";
import {CanonicalV2} from "../utils/CanonicalV2.sol";
import {DualPairHarness} from "./DualPairHarness.sol";

/// @notice The oracle itself: the npm artifact is the genuine mainnet UniswapV2Pair bytecode.
contract CanonicalOracleTest is Test, CanonicalV2 {
    function test_canonicalPairBytecodeHashesToMainnetInitCodeHash() public view {
        assertEq(keccak256(_canonicalBytecode("UniswapV2Pair")), CANONICAL_PAIR_INIT_CODE_HASH);
    }

    function test_canonicalFactoryCreatesPairsAtTheMainnetDerivedAddress() public {
        DualPairHarness h = new DualPairHarness();
        address expected = vm.computeCreate2Address(
            keccak256(abi.encodePacked(address(h.token0()), address(h.token1()))),
            CANONICAL_PAIR_INIT_CODE_HASH,
            address(h.canonicalFactory())
        );
        assertEq(address(h.canonical()), expected);
    }
}

/// @notice Stateless differential properties: each test drives both pairs with the same fuzzed operation(s)
///         and the harness asserts identical outcome (both succeed or both revert), identical return data and
///         identical reserves, TWAP accumulators, kLast, LP supply, LP balances and token balances.
contract CanonicalDifferentialTest is Test {
    DualPairHarness internal h;
    AMMRouter internal quoter; // pure quote functions only

    function setUp() public {
        vm.warp(1_750_000_000);
        h = new DualPairHarness();
        quoter = new AMMRouter(address(h.hardenedFactory()));
    }

    function _seed(uint256 a0, uint256 a1) internal {
        assertTrue(h.mint(a0, a1, 0), "seed mint");
    }

    function testFuzz_diff_firstMint(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 0, type(uint112).max);
        amount1 = bound(amount1, 0, type(uint112).max);
        h.mint(amount0, amount1, 0); // may legitimately revert on both (e.g. sqrt(k) <= 1000)
    }

    function testFuzz_diff_mintThenBurn(uint256 a0, uint256 a1, uint256 b0, uint256 b1, uint256 burnBps) public {
        _seed(bound(a0, 1e6, 1e30), bound(a1, 1e6, 1e30));
        h.mint(bound(b0, 0, 1e30), bound(b1, 0, 1e30), 1);
        uint256 lp = h.lpBalance(1);
        h.burn(1, lp * bound(burnBps, 0, 10_000) / 10_000);
    }

    /// @dev The quote is exactly the canonical k-check boundary: `out` passes on both, `out + 1` fails on both.
    function testFuzz_diff_getAmountOutIsTheExactKBoundary(uint256 r0, uint256 r1, uint256 amountIn, bool zeroForOne)
        public
    {
        _seed(bound(r0, 1e4, 1e32), bound(r1, 1e4, 1e32));
        (uint112 reserve0, uint112 reserve1) = h.reserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        // Smallest input that quotes a non-zero output, so the property is never vacuous.
        amountIn = bound(amountIn, quoter.getAmountIn(1, reserveIn, reserveOut), reserveIn);
        uint256 out = quoter.getAmountOut(amountIn, reserveIn, reserveOut);
        assertGt(out, 0);
        uint256 snapshot = vm.snapshotState();
        bool tooMuch = zeroForOne ? h.swap(amountIn, 0, 0, out + 1, 0) : h.swap(0, amountIn, out + 1, 0, 0);
        assertFalse(tooMuch, "one wei above the quote must violate k on both pairs");
        vm.revertToState(snapshot);
        bool exact = zeroForOne ? h.swap(amountIn, 0, 0, out, 0) : h.swap(0, amountIn, out, 0, 0);
        assertTrue(exact, "the quote must be accepted by both pairs");
    }

    /// @dev getAmountIn always buys at least the requested output on the canonical pair (rounded in its favour).
    function testFuzz_diff_getAmountInIsSufficient(uint256 r0, uint256 r1, uint256 amountOut) public {
        _seed(bound(r0, 1e4, 1e31), bound(r1, 1e4, 1e31));
        (uint112 reserve0, uint112 reserve1) = h.reserves();
        // Up to 99 % of the reserve: the input stays below ~101x reserve0, inside the 112-bit reserve range.
        amountOut = bound(amountOut, 1, uint256(reserve1) * 99 / 100);
        uint256 amountIn = quoter.getAmountIn(amountOut, reserve0, reserve1);
        assertTrue(h.swap(amountIn, 0, 0, amountOut, 0), "getAmountIn must be enough for both pairs");
    }

    /// @dev Arbitrary (mostly invalid) swaps: revert behaviour must match exactly.
    function testFuzz_diff_rawSwap(uint256 in0, uint256 in1, uint256 out0, uint256 out1) public {
        _seed(1e21, 3e21);
        h.swap(bound(in0, 0, 1e22), bound(in1, 0, 1e22), bound(out0, 0, 2e21), bound(out1, 0, 4e21), 2);
    }

    function testFuzz_diff_donateSkimSync(uint256 d0, uint256 d1, bool syncFirst) public {
        _seed(1e21, 3e21);
        h.donate(bound(d0, 0, 1e24), bound(d1, 0, 1e24));
        if (syncFirst) {
            h.sync();
            h.skim(1);
        } else {
            h.skim(1);
            h.sync();
        }
    }

    /// @dev TWAP accumulators stay bit-identical across the 2^32 timestamp wrap (year 2106).
    function testFuzz_diff_twapAcrossTimestampWrap(uint256 before, uint256 afterWrap, uint256 amountIn) public {
        uint256 wrap = uint256(type(uint32).max) + 1;
        vm.warp(wrap - bound(before, 1, 1 days));
        _seed(5e20, 7e20);
        vm.warp(wrap + bound(afterWrap, 0, 1 days));
        (uint112 r0, uint112 r1) = h.reserves();
        amountIn = bound(amountIn, 1e9, 1e20);
        assertTrue(h.swap(amountIn, 0, 0, quoter.getAmountOut(amountIn, r0, r1), 0));
        vm.warp(block.timestamp + 17);
        h.sync();
        assertGt(h.hardened().price0CumulativeLast(), 0);
    }

    /// @dev The protocol fee (1/6 of sqrt(k) growth) mints the same LP amount on both pairs.
    function testFuzz_diff_protocolFee(uint256 a0, uint256 a1, uint256 swaps, uint256 size) public {
        h.setProtocolFee(true);
        _seed(bound(a0, 1e18, 1e27), bound(a1, 1e18, 1e27));
        swaps = bound(swaps, 1, 8);
        for (uint256 i; i < swaps; ++i) {
            (uint112 r0, uint112 r1) = h.reserves();
            uint256 amountIn = bound(size, 1e12, r0 / 2);
            h.swap(amountIn, 0, 0, quoter.getAmountOut(amountIn, r0, r1), 1);
            (r0, r1) = h.reserves();
            h.swap(0, amountIn, quoter.getAmountOut(amountIn, r1, r0), 0, 2);
        }
        h.burn(0, h.lpBalance(0) / 3); // realises the protocol fee
        h.setProtocolFee(false);
        h.mint(1e18, 1e18, 1); // resets kLast on both
        assertEq(h.hardened().kLast(), 0);
    }

    /// @dev A long random sequence, generated from one seed, over every operation type.
    function testFuzz_diff_randomSequence(uint256 seed) public {
        _seed(1e21 + seed % 1e21, 2e21 + (seed >> 64) % 1e21);
        for (uint256 i; i < 40; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 9;
            uint256 x = (r >> 8) % 1e22;
            uint256 y = (r >> 96) % 1e22;
            if (op == 0) {
                h.mint(x, y, r >> 200);
            } else if (op == 1) {
                h.burn(r >> 200, h.lpBalance(r >> 200) * ((r >> 40) % 10_001) / 10_000);
            } else if (op == 2 || op == 3) {
                (uint112 r0, uint112 r1) = h.reserves();
                uint256 amountIn = x % (uint256(op == 2 ? r0 : r1) + 1) + 1;
                uint256 out = quoter.getAmountOut(amountIn, op == 2 ? r0 : r1, op == 2 ? r1 : r0);
                uint256 adjusted = out + (r >> 160) % 3; // quote + {0, 1, 2}
                adjusted = adjusted == 0 ? 0 : adjusted - 1; // quote - 1, quote or quote + 1 (floored at 0)
                if (op == 2) h.swap(amountIn, 0, 0, adjusted, r >> 200);
                else h.swap(0, amountIn, adjusted, 0, r >> 200);
            } else if (op == 4) {
                h.donate(x % 1e20, y % 1e20);
            } else if (op == 5) {
                h.skim(r >> 200);
            } else if (op == 6) {
                h.sync();
            } else if (op == 7) {
                vm.warp(block.timestamp + (r >> 100) % 2 days);
            } else {
                h.setProtocolFee((r >> 50) % 2 == 0);
            }
        }
        h.assertSameState("final");
    }

    function test_diff_hardenedPairIsTheContractUnderTest() public view {
        assertEq(AMMPair(address(h.hardened())).symbol(), "HAMM-LP");
    }
}
