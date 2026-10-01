// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {AMMPair} from "../../src/AMMPair.sol";
import {IAMMPair} from "../../src/interfaces/IAMMPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AMMTestBase} from "../utils/AMMTestBase.sol";

contract AMMPairTest is AMMTestBase {
    AMMPair internal pair;
    MockERC20 internal token0;
    MockERC20 internal token1;

    function setUp() public override {
        super.setUp();
        pair = AMMPair(factory.createPair(address(tokenA), address(tokenB)));
        token0 = MockERC20(pair.token0());
        token1 = MockERC20(pair.token1());
    }

    // ------------------------------------------------------------------ helpers

    function _deposit(uint256 amount0, uint256 amount1) internal returns (uint256 liquidity) {
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        liquidity = pair.mint(address(this));
    }

    function _reservesOf() internal view returns (uint112 r0, uint112 r1) {
        (r0, r1,) = pair.getReserves();
    }

    // ------------------------------------------------------------------ metadata

    function test_metadata() public view {
        assertEq(pair.name(), "Hardened AMM LP");
        assertEq(pair.symbol(), "HAMM-LP");
        assertEq(pair.decimals(), 18);
        assertEq(pair.MINIMUM_LIQUIDITY(), 1000);
        assertEq(pair.CALLBACK_SUCCESS(), keccak256("IAMMCallee.ammSwapCall"));
        assertFalse(pair.isLocked());
    }

    function test_domainSeparator_isEip712WithPairAddress() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Hardened AMM LP"),
                keccak256("1"),
                block.chainid,
                address(pair)
            )
        );
        assertEq(pair.DOMAIN_SEPARATOR(), expected);
    }

    function test_permit2_hasNoImplicitAllowance() public {
        _deposit(10 ether, 10 ether);
        assertEq(pair.allowance(address(this), 0x000000000022D473030F116dDEE9F6B43aC78BA3), 0);
    }

    // ------------------------------------------------------------------ mint

    function test_mint_first_locksMinimumLiquidityAndMintsFloorSqrt() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 4 ether;
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);

        vm.expectEmit(address(pair));
        emit IAMMPair.Sync(uint112(amount0), uint112(amount1));
        vm.expectEmit(address(pair));
        emit IAMMPair.Mint(address(this), amount0, amount1);
        uint256 liquidity = pair.mint(alice);

        assertEq(liquidity, 2 ether - 1000);
        assertEq(pair.balanceOf(alice), 2 ether - 1000);
        assertEq(pair.balanceOf(address(0)), 1000);
        assertEq(pair.totalSupply(), 2 ether);
        (uint112 r0, uint112 r1) = _reservesOf();
        assertEq(r0, amount0);
        assertEq(r1, amount1);
    }

    function test_mint_first_revertsWhenRootKDoesNotExceedMinimumLiquidity() public {
        token0.transfer(address(pair), 1000);
        token1.transfer(address(pair), 1000); // sqrt = 1000 exactly: nothing left for the depositor
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InsufficientLiquidityMinted.selector, 0));
        pair.mint(address(this));
    }

    function test_mint_subsequent_isProportionalAndTakesTheMinimumSide() public {
        _deposit(10 ether, 40 ether);
        uint256 supply = pair.totalSupply();
        // Over-supply token1: the pair only credits the token0 ratio, the excess is donated.
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 10 ether);
        uint256 liquidity = pair.mint(alice);
        assertEq(liquidity, 1 ether * supply / 10 ether);
    }

    function test_mint_revertsWhenDepositMintsZero() public {
        _deposit(10 ether, 10 ether);
        token0.transfer(address(pair), 1 ether); // token1 side contributes nothing
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InsufficientLiquidityMinted.selector, 0));
        pair.mint(address(this));
    }

    // ------------------------------------------------------------------ burn

    function test_burn_paysProRataAndEmits() public {
        uint256 liquidity = _deposit(3 ether, 3 ether);
        pair.transfer(address(pair), liquidity);

        uint256 expected = 3 ether - 1000;
        vm.expectEmit(address(pair));
        emit IAMMPair.Sync(1000, 1000);
        vm.expectEmit(address(pair));
        emit IAMMPair.Burn(address(this), expected, expected, bob);
        (uint256 amount0, uint256 amount1) = pair.burn(bob);

        assertEq(amount0, expected);
        assertEq(amount1, expected);
        assertEq(token0.balanceOf(bob), USER_FUNDS + expected);
        assertEq(pair.totalSupply(), 1000);
        (uint112 r0, uint112 r1) = _reservesOf();
        assertEq(r0, 1000);
        assertEq(r1, 1000);
    }

    function test_burn_revertsWhenNothingToBurn() public {
        _deposit(3 ether, 3 ether);
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InsufficientLiquidityBurned.selector, 0, 0));
        pair.burn(address(this));
    }

    // ------------------------------------------------------------------ swap

    function test_swap_token0ForToken1_atExactQuote() public {
        _deposit(5 ether, 10 ether);
        uint256 amountIn = 1 ether;
        uint256 expectedOut = router.getAmountOut(amountIn, 5 ether, 10 ether);
        token0.transfer(address(pair), amountIn);

        vm.expectEmit(address(pair));
        emit IAMMPair.Swap(address(this), amountIn, 0, 0, expectedOut, bob);
        pair.swap(0, expectedOut, bob, "");

        assertEq(token1.balanceOf(bob), USER_FUNDS + expectedOut);
        (uint112 r0, uint112 r1) = _reservesOf();
        assertEq(r0, 6 ether);
        assertEq(r1, 10 ether - expectedOut);
    }

    function test_swap_token1ForToken0_atExactQuote() public {
        _deposit(5 ether, 10 ether);
        uint256 amountIn = 1 ether;
        uint256 expectedOut = router.getAmountOut(amountIn, 10 ether, 5 ether);
        token1.transfer(address(pair), amountIn);
        pair.swap(expectedOut, 0, bob, "");
        assertEq(token0.balanceOf(bob), USER_FUNDS + expectedOut);
    }

    function test_swap_revertsOnePastTheQuoteWithK() public {
        _deposit(5 ether, 10 ether);
        uint256 amountIn = 1 ether;
        uint256 out = router.getAmountOut(amountIn, 5 ether, 10 ether) + 1;
        token0.transfer(address(pair), amountIn);
        uint256 balanceProduct = (6 ether * 1000 - amountIn * 3) * ((10 ether - out) * 1000);
        uint256 reserveProduct = uint256(5 ether) * 10 ether * 1_000_000;
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.K.selector, balanceProduct, reserveProduct));
        pair.swap(0, out, bob, "");
    }

    function test_swap_revertsOnZeroOutput() public {
        _deposit(5 ether, 10 ether);
        vm.expectRevert(IAMMPair.InsufficientOutputAmount.selector);
        pair.swap(0, 0, bob, "");
    }

    function test_swap_revertsWhenOutputReachesReserve() public {
        _deposit(5 ether, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InsufficientLiquidity.selector, 5 ether, 0, 5 ether, 10 ether));
        pair.swap(5 ether, 0, bob, "");
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InsufficientLiquidity.selector, 0, 10 ether, 5 ether, 10 ether));
        pair.swap(0, 10 ether, bob, "");
    }

    function test_swap_revertsWhenRecipientIsAPairToken() public {
        _deposit(5 ether, 10 ether);
        token0.transfer(address(pair), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InvalidTo.selector, address(token0)));
        pair.swap(0, 1, address(token0), "");
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.InvalidTo.selector, address(token1)));
        pair.swap(0, 1, address(token1), "");
    }

    function test_swap_revertsWithoutInput() public {
        _deposit(5 ether, 10 ether);
        vm.expectRevert(IAMMPair.InsufficientInputAmount.selector);
        pair.swap(0, 1 ether, bob, "");
    }

    // ------------------------------------------------------------------ skim / sync / overflow

    function test_skim_sendsOnlyTheSurplus() public {
        _deposit(5 ether, 10 ether);
        token0.transfer(address(pair), 3);
        token1.transfer(address(pair), 7);
        pair.skim(bob);
        assertEq(token0.balanceOf(bob), USER_FUNDS + 3);
        assertEq(token1.balanceOf(bob), USER_FUNDS + 7);
        assertEq(token0.balanceOf(address(pair)), 5 ether);
    }

    function test_sync_absorbsDonations() public {
        _deposit(5 ether, 10 ether);
        token0.transfer(address(pair), 1 ether);
        vm.expectEmit(address(pair));
        emit IAMMPair.Sync(6 ether, 10 ether);
        pair.sync();
        (uint112 r0,) = _reservesOf();
        assertEq(r0, 6 ether);
    }

    function test_update_revertsWhenABalanceExceeds112Bits() public {
        _deposit(5 ether, 10 ether);
        uint256 huge = uint256(type(uint112).max) + 1;
        token0.mint(address(pair), huge);
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.Overflow.selector, huge + 5 ether, 10 ether));
        pair.sync();
    }

    // ------------------------------------------------------------------ TWAP

    function test_twap_accumulatesUq112x112PriceTimesElapsed() public {
        _deposit(5 ether, 10 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 60);
        pair.sync();
        assertEq(pair.price0CumulativeLast(), (uint256(10 ether) << 112) / 5 ether * 60);
        assertEq(pair.price1CumulativeLast(), (uint256(5 ether) << 112) / 10 ether * 60);
        (,, uint32 last) = pair.getReserves();
        assertEq(last, uint32(start + 60));

        // Same block: no further accrual.
        pair.sync();
        assertEq(pair.price0CumulativeLast(), (uint256(10 ether) << 112) / 5 ether * 60);
    }

    function test_twap_elapsedTimeSurvivesThe2106TimestampWrap() public {
        vm.warp(type(uint32).max - 9); // 10 s before the 32-bit wrap
        _deposit(5 ether, 10 ether);
        vm.warp(uint256(type(uint32).max) + 11); // 20 s later; the truncated timestamp is now 10
        pair.sync();
        assertEq(pair.price0CumulativeLast(), (uint256(10 ether) << 112) / 5 ether * 20);
        (,, uint32 last) = pair.getReserves();
        assertEq(last, 10);
    }

    function test_twap_accumulatorWrapsModulo2pow256WithoutReverting() public {
        _deposit(5 ether, 10 ether);
        // price0CumulativeLast lives in slot 1 (see `forge inspect AMMPair storageLayout`).
        vm.store(address(pair), bytes32(uint256(1)), bytes32(type(uint256).max));
        vm.warp(block.timestamp + 1);
        pair.sync();
        uint256 increment = (uint256(10 ether) << 112) / 5 ether;
        unchecked {
            assertEq(pair.price0CumulativeLast(), type(uint256).max + increment);
        }
    }

    // ------------------------------------------------------------------ protocol fee

    function test_protocolFee_mintsOneSixthOfRootKGrowthToFeeTo() public {
        vm.prank(owner);
        factory.setFeeTo(feeRecipient);
        _deposit(100 ether, 100 ether);
        assertEq(pair.kLast(), 100 ether * uint256(100 ether), "kLast checkpointed on mint");

        // Trade back and forth to accrue LP fees.
        for (uint256 i; i < 10; ++i) {
            (uint112 r0, uint112 r1) = _reservesOf();
            uint256 out = router.getAmountOut(10 ether, r0, r1);
            token0.transfer(address(pair), 10 ether);
            pair.swap(0, out, address(this), "");
            (r0, r1) = _reservesOf();
            out = router.getAmountOut(10 ether, r1, r0);
            token1.transfer(address(pair), 10 ether);
            pair.swap(out, 0, address(this), "");
        }

        (uint112 rr0, uint112 rr1) = _reservesOf();
        uint256 rootK = FixedPointMathLib.sqrt(uint256(rr0) * rr1);
        uint256 rootKLast = FixedPointMathLib.sqrt(pair.kLast());
        uint256 expectedFee = pair.totalSupply() * (rootK - rootKLast) / (rootK * 5 + rootKLast);
        assertGt(expectedFee, 0);

        uint256 liquidity = pair.balanceOf(address(this));
        pair.transfer(address(pair), liquidity / 2);
        pair.burn(address(this));
        assertEq(pair.balanceOf(feeRecipient), expectedFee);
    }

    function test_protocolFee_switchedOffResetsKLast() public {
        vm.prank(owner);
        factory.setFeeTo(feeRecipient);
        _deposit(100 ether, 100 ether);
        assertGt(pair.kLast(), 0);
        vm.prank(owner);
        factory.setFeeTo(address(0));
        _deposit(1 ether, 1 ether);
        assertEq(pair.kLast(), 0);
        assertEq(pair.balanceOf(feeRecipient), 0);
    }

    // ------------------------------------------------------------------ LP token (Solady ERC-20 + EIP-2612)

    function test_permit_setsAllowanceFromSignature() public {
        (address signer, uint256 key) = makeAddrAndKey("lp");
        token0.transfer(address(pair), 1 ether);
        token1.transfer(address(pair), 1 ether);
        pair.mint(signer);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                bob,
                123,
                0,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", pair.DOMAIN_SEPARATOR(), structHash)));
        pair.permit(signer, bob, 123, deadline, v, r, s);
        assertEq(pair.allowance(signer, bob), 123);
        assertEq(pair.nonces(signer), 1);

        vm.expectRevert(ERC20.InvalidPermit.selector); // replay
        pair.permit(signer, bob, 123, deadline, v, r, s);
    }
}
