// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {VolatilityMath} from "../../src/libraries/VolatilityMath.sol";

/// @notice Differential tests of VolatilityMath against exact reference values produced by sim/gen_vectors.py
/// (integer/rational arithmetic and mpmath at 120 digits). For round-down quantities each vector carries an analytic
/// error bound, so every check asserts the rounding DIRECTION and the MAGNITUDE of the error.
contract VolatilityMathDifferentialTest is Test {
    // Field order must be alphabetical: vm.parseJson encodes objects with sorted keys.
    struct DecayVector {
        uint256 alphaWad;
        uint256 floorExact;
        uint256 k;
        uint256 maxError;
    }

    struct EwmaVector {
        uint256 alphaWad;
        uint256 blocks;
        uint256 ewma;
        uint256 floorExact;
        uint256 maxError;
        uint256 sample;
    }

    struct FeeVector {
        uint256 ewma;
        uint256 expected;
        uint256 slope;
    }

    struct SurchargeRateVector {
        uint256 cap;
        uint256 ewma;
        uint256 expected;
        uint256 slope;
    }

    struct SurchargeAmountVector {
        uint256 amount;
        uint256 expected;
        uint256 rate;
    }

    struct ProRatedVector {
        uint256 amount;
        uint256 ceilExact;
        uint256 edge;
        uint256 full;
        bool inCurrency1;
        uint256 post;
        uint256 pre;
        uint256 rate;
    }

    struct SequenceVector {
        uint256 alphaWad;
        uint256[] blocks;
        uint256 floorExact;
        uint256 maxError;
        uint256[] samples;
        uint256 start;
    }

    string internal json;

    function setUp() public {
        json = vm.readFile("test/fixtures/vectors.json");
        assertEq(vm.parseJsonUint(json, ".version"), 2, "fixture version");
    }

    /// @notice (1 - a)^k never exceeds the exact value and stays within 2^bitlen(k) wei of it.
    function test_differential_decayFactor() public view {
        DecayVector[] memory vectors = abi.decode(vm.parseJson(json, ".decay"), (DecayVector[]));
        assertGt(vectors.length, 200, "vector count");
        uint256 exactHits;
        uint256 maxError;
        for (uint256 i; i < vectors.length; ++i) {
            DecayVector memory v = vectors[i];
            uint256 got = VolatilityMath.decayFactor(v.alphaWad, v.k);
            assertLe(got, v.floorExact, string.concat("decay above exact #", vm.toString(i)));
            assertLe(v.floorExact - got, v.maxError, string.concat("decay error too large #", vm.toString(i)));
            if (got == v.floorExact) ++exactHits;
            if (v.floorExact - got > maxError) maxError = v.floorExact - got;
        }
        console2.log("decay vectors / exact / max error (wei):", vectors.length, exactHits, maxError);
        // Sanity: the bound is loose, but the implementation is usually exact.
        assertGt(exactHits, vectors.length / 2, "most decay factors should be exact");
    }

    /// @notice A single EWMA update rounds down: equal to floor(exact) for one block, within the bound otherwise.
    function test_differential_ewmaUpdate() public view {
        EwmaVector[] memory vectors = abi.decode(vm.parseJson(json, ".ewma"), (EwmaVector[]));
        assertGt(vectors.length, 150, "vector count");
        uint256 exactHits;
        uint256 maxError;
        for (uint256 i; i < vectors.length; ++i) {
            EwmaVector memory v = vectors[i];
            uint256 got = VolatilityMath.updateEwma(v.ewma, v.sample, v.blocks, v.alphaWad);
            assertLe(got, v.floorExact, string.concat("ewma above exact #", vm.toString(i)));
            assertLe(v.floorExact - got, v.maxError, string.concat("ewma error too large #", vm.toString(i)));
            if (v.blocks == 1) assertEq(got, v.floorExact, "single-block update must be exact");
            if (got == v.floorExact) ++exactHits;
            if (v.floorExact - got > maxError) maxError = v.floorExact - got;
        }
        console2.log("ewma vectors / exact / max error (wei):", vectors.length, exactHits, maxError);
    }

    /// @notice LP fee: exact match (ceil, then clamp to [5, 100] bps).
    function test_differential_lpFee() public view {
        FeeVector[] memory vectors = abi.decode(vm.parseJson(json, ".fee"), (FeeVector[]));
        assertGt(vectors.length, 50, "vector count");
        for (uint256 i; i < vectors.length; ++i) {
            FeeVector memory v = vectors[i];
            assertEq(VolatilityMath.lpFee(v.ewma, v.slope), v.expected, string.concat("fee #", vm.toString(i)));
        }
    }

    /// @notice Surcharge rate: exact match (ceil, then cap).
    function test_differential_surchargeRate() public view {
        SurchargeRateVector[] memory vectors = abi.decode(vm.parseJson(json, ".surchargeRate"), (SurchargeRateVector[]));
        assertGt(vectors.length, 100, "vector count");
        for (uint256 i; i < vectors.length; ++i) {
            SurchargeRateVector memory v = vectors[i];
            assertEq(
                VolatilityMath.surchargeRate(v.ewma, v.slope, v.cap),
                v.expected,
                string.concat("surcharge rate #", vm.toString(i))
            );
        }
    }

    /// @notice Surcharge amount: exact match (ceil) and never more than the amount it is charged on.
    function test_differential_surchargeAmount() public view {
        SurchargeAmountVector[] memory vectors =
            abi.decode(vm.parseJson(json, ".surchargeAmount"), (SurchargeAmountVector[]));
        assertGt(vectors.length, 100, "vector count");
        for (uint256 i; i < vectors.length; ++i) {
            SurchargeAmountVector memory v = vectors[i];
            uint256 got = VolatilityMath.surchargeAmount(v.amount, v.rate);
            assertEq(got, v.expected, string.concat("surcharge amount #", vm.toString(i)));
            if (v.rate <= VolatilityMath.PIPS_DENOMINATOR) assertLe(got, v.amount, "surcharge exceeds amount");
        }
    }

    /// @notice Range-extension surcharge: never below the exact real value (ceil), never above the charge on the whole
    /// swap, and at most one unit above ceil(exact) (three roundings up, one scaled by pre / edge <= 1,000).
    function test_differential_proRatedSurcharge() public view {
        ProRatedVector[] memory vectors = abi.decode(vm.parseJson(json, ".proRatedSurcharge"), (ProRatedVector[]));
        assertGt(vectors.length, 250, "vector count");
        uint256 exactHits;
        uint256 capped;
        for (uint256 i; i < vectors.length; ++i) {
            ProRatedVector memory v = vectors[i];
            uint256 got = VolatilityMath.proRatedSurcharge(v.amount, v.rate, v.pre, v.post, v.edge, v.inCurrency1);
            assertEq(v.full, VolatilityMath.surchargeAmount(v.amount, v.rate), "whole-swap charge");
            assertGe(got, v.ceilExact, string.concat("pro-rated below exact #", vm.toString(i)));
            assertLe(got, v.full, string.concat("pro-rated above the whole-swap charge #", vm.toString(i)));
            assertLe(got, v.ceilExact + 1, string.concat("pro-rated error too large #", vm.toString(i)));
            if (got == v.ceilExact) ++exactHits;
            if (got == v.full && v.edge != v.pre) ++capped;
        }
        console2.log("pro-rated vectors / exact ceil / at the whole-swap charge:", vectors.length, exactHits, capped);
    }

    /// @notice 50-step sequences (the Bunni lesson): the accumulated rounding error is one-directional (never above
    /// the exact real-valued EWMA) and bounded by the sum of per-step bounds, i.e. it does not amplify.
    function test_differential_repeatedUpdates50() public view {
        SequenceVector[] memory vectors = abi.decode(vm.parseJson(json, ".sequences"), (SequenceVector[]));
        assertGt(vectors.length, 40, "vector count");
        uint256 maxDrift;
        uint256 maxBound;
        for (uint256 i; i < vectors.length; ++i) {
            SequenceVector memory v = vectors[i];
            assertEq(v.samples.length, 50, "sequence length");
            uint256 ewma = v.start;
            for (uint256 j; j < v.samples.length; ++j) {
                ewma = VolatilityMath.updateEwma(ewma, v.samples[j], v.blocks[j], v.alphaWad);
            }
            assertLe(ewma, v.floorExact, string.concat("sequence above exact #", vm.toString(i)));
            assertLe(v.floorExact - ewma, v.maxError, string.concat("sequence drift #", vm.toString(i)));
            if (v.floorExact - ewma > maxDrift) maxDrift = v.floorExact - ewma;
            if (v.maxError > maxBound) maxBound = v.maxError;
        }
        console2.log("50-step sequences / max drift (wei) / largest bound (wei):", vectors.length, maxDrift, maxBound);
    }
}
