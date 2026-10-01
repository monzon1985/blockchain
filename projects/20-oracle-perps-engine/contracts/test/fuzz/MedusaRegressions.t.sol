// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {PerpsMedusa} from "../medusa/PerpsMedusa.sol";

/// @notice Counterexamples found by Medusa, replayed call for call (block timestamps included) against the Medusa
///         harness, so they stay fixed.
contract MedusaRegressionTest is Test {
    /// @dev 8-call sequence (shrunk) that broke `property_I1_solvency` through the payout model: two shorts and a
    ///      long, then about 42 days of keeper inactivity. Funding owed to the long exceeded the per-settlement
    ///      payout bound, and the backstop, while cutting that credit, also set the long's small realised loss
    ///      to zero: the close paid 1,214 wei more than the model. Fixed by cutting only gains.
    function test_medusa_backstopKeepsTheLossOfAHaircutLoser() public {
        vm.warp(1);
        PerpsMedusa m = new PerpsMedusa();
        vm.warp(37);
        m.openPosition(
            4_999_999_999_999_999_678,
            false,
            115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_036_658_583_444_963_176_218_425,
            28_948_022_309_329_048_855_892_746_252_171_976_963_317_496_166_410_141_009_864_396_001_978_282_409_662
        );
        vm.warp(582_060);
        m.movePrice(
            197_409_287_538_272_678_602_948_820_425_756_349_447_496_610_418,
            25_010_301_826_267_891_510_730_915_972_693,
            44_601_490_396_998_746_283_072_005_500_557_456_011_740_241
        );
        vm.warp(582_061);
        m.lpRedeem(
            69_669_427_235_703_909_803_281_469_505_487_644_293_289_822_685_060_728_795_635_397_846_022_064_004_940,
            114_825_601_955_919_109_325_363_520_785_420_419_158_977_682_812_354_017_338_624_816_996_912_064_627_730
        );
        vm.warp(1_260_640);
        m.passTime(
            57_896_044_618_658_097_711_785_492_504_343_953_926_634_990_530_391_653_554_319_262_406_851_191_452_814
        );
        vm.warp(1_260_641);
        m.openPosition(
            3_097_056_684_271_948_836_762_778_040_210_870_836_853_942_316_606_368_954_257_617_459_633_335_644_276,
            false,
            9_192_764_933_242_437_891_976_451_136_182_178_819_279_227_009_584_946_536_702_368_118_993_542_995_608,
            22_988_149_351_077_951_032_597_462_544_685_348_551_360_536_482_891_204_030_769_110_433_086_520_034_359
        );
        vm.warp(1_333_271);
        m.openPosition(
            6_225_060_624_402_111_786_793_986_821_507_967_569_633_552_332_057_839_917_556_276_249_411_666_568_916,
            true,
            1_434_374_999_921_875_080,
            317_092_871_328_223_970_655_766_403_577_866_465_347_138_518_539_803_865_818_717_641_938_138_802_025
        );
        vm.warp(4_240_184);
        m.passTime(
            3_486_422_180_845_293_626_977_836_051_613_804_953_462_489_413_949_691_775_475_969_550_434_195_172_303
        );
        vm.warp(4_963_547);
        m.passTime(
            25_469_700_338_508_416_262_720_631_205_352_891_952_802_392_109_084_767_089_531_020_654_463_939_164_848
        );

        (bool ok, bytes memory detail) = m.checkSolvency();
        if (!ok) emit log_named_bytes("close-all failure", detail);
        assertTrue(ok, "every close pays what the model predicts");
        assertTrue(m.property_I4_feeConservationCounters());
        assertTrue(m.property_I5_feeConservationFlows());
    }
}
