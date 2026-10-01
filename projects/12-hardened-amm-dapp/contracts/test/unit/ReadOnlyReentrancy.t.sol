// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Test} from "forge-std/Test.sol";

import {AMMFactory} from "../../src/AMMFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {HookToken, ILPPricedPair, LPOracleVictim, ReadOnlyReentrancyAttacker} from "../mocks/ReadOnlyReentrancy.sol";
import {CanonicalV2, IUniswapV2Factory, IUniswapV2Pair} from "../utils/CanonicalV2.sol";

/// @notice The classic read-only reentrancy (Curve/Balancer class): during `burn`, the LP supply has already
///         dropped but the reserves are not updated yet. A hook token hands control to the burner, who asks a
///         naive oracle for the LP price. The canonical pair answers with an inflated price; the hardened pair
///         refuses to answer because `getReserves()` is guarded by the transient lock.
contract ReadOnlyReentrancyTest is Test, CanonicalV2 {
    HookToken internal hook;
    MockERC20 internal other;
    LPOracleVictim internal oracle;

    function setUp() public {
        vm.warp(1_750_000_000);
        hook = new HookToken();
        other = new MockERC20("Other", "OTH", 18);
        oracle = new LPOracleVictim();
    }

    /// @dev Seeds the pair with 100/100 held by the attacker, then burns 90 % of the supply from the attacker.
    function _attack(IUniswapV2Pair pair) internal returns (ReadOnlyReentrancyAttacker attacker, uint256 fairValue) {
        attacker = new ReadOnlyReentrancyAttacker(oracle);
        hook.mint(address(pair), 100 ether);
        other.mint(address(pair), 100 ether);
        pair.mint(address(attacker));
        fairValue = oracle.lpValueInToken0(ILPPricedPair(address(pair)));

        uint256 liquidity = pair.balanceOf(address(attacker)) * 9 / 10;
        attacker.arm(ILPPricedPair(address(pair)));
        vm.prank(address(attacker));
        pair.transfer(address(pair), liquidity);
        pair.burn(address(attacker)); // pays HookToken to the attacker -> hook -> oracle read
        assertTrue(attacker.attempted(), "the hook ran during burn");
    }

    function test_canonicalPair_leaksAnInflatedLpPriceDuringBurn() public {
        IUniswapV2Factory canonicalFactory = _deployCanonicalFactory(address(this));
        IUniswapV2Pair pair = IUniswapV2Pair(canonicalFactory.createPair(address(hook), address(other)));
        (ReadOnlyReentrancyAttacker attacker, uint256 fairValue) = _attack(pair);

        assertTrue(attacker.readSucceeded(), "canonical getReserves answers mid-burn");
        // Stale reserves over a supply that already dropped by 90 %: the LP looks ~10x more valuable.
        assertGt(attacker.observedLpValue(), fairValue * 9);
    }

    function test_hardenedPair_refusesToPriceDuringBurn() public {
        AMMFactory factory = new AMMFactory(address(this));
        IUniswapV2Pair pair = IUniswapV2Pair(factory.createPair(address(hook), address(other)));
        (ReadOnlyReentrancyAttacker attacker,) = _attack(pair);

        assertFalse(attacker.readSucceeded(), "hardened getReserves reverts mid-burn");
        assertEq(
            attacker.revertData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        // After the transaction the price is readable again and consistent.
        (uint112 r0,,) = pair.getReserves();
        assertEq(oracle.lpValueInToken0(ILPPricedPair(address(pair))), 2 * uint256(r0) * 1e18 / pair.totalSupply());
    }
}
