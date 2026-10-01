// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {ERC20} from "solady/tokens/ERC20.sol";

import {AMMPair} from "../../src/AMMPair.sol";
import {IAMMRouter} from "../../src/interfaces/IAMMRouter.sol";
import {AMMLibrary} from "../../src/libraries/AMMLibrary.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AMMTestBase} from "../utils/AMMTestBase.sol";

contract AMMRouterTest is AMMTestBase {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address internal lp;
    uint256 internal lpKey;

    function setUp() public override {
        super.setUp();
        (lp, lpKey) = makeAddrAndKey("permit-lp");
        tokenA.mint(lp, USER_FUNDS);
        tokenB.mint(lp, USER_FUNDS);
        vm.startPrank(lp);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _seedAB() internal {
        _addLiquidity(address(this), address(tokenA), address(tokenB), 100 ether, 200 ether);
    }

    function _seedABC() internal {
        _seedAB();
        _addLiquidity(address(this), address(tokenB), address(tokenC), 200 ether, 50 ether);
    }

    function _assertRouterHoldsNothing() internal view {
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
        assertEq(tokenC.balanceOf(address(router)), 0);
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_cachesFactoryAndInitCodeHash() public view {
        assertEq(router.factory(), address(factory));
        assertEq(router.pairInitCodeHash(), factory.PAIR_INIT_CODE_HASH());
    }

    function test_router_rejectsEther() public {
        (bool ok,) = address(router).call{value: 1}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ addLiquidity

    function test_addLiquidity_createsPairAndDepositsDesiredAmounts() public {
        vm.prank(alice);
        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            router.addLiquidity(address(tokenA), address(tokenB), 1 ether, 4 ether, 0, 0, alice, deadline);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        assertTrue(address(pair) != address(0));
        assertEq(amountA, 1 ether);
        assertEq(amountB, 4 ether);
        assertEq(liquidity, 2 ether - 1000);
        assertEq(pair.balanceOf(alice), liquidity);
        _assertRouterHoldsNothing();
    }

    function test_addLiquidity_usesOptimalBWhenAIsTheBindingSide() public {
        _seedAB(); // 1 A : 2 B
        vm.prank(alice);
        (uint256 amountA, uint256 amountB,) =
            router.addLiquidity(address(tokenA), address(tokenB), 1 ether, 5 ether, 0, 2 ether, alice, deadline);
        assertEq(amountA, 1 ether);
        assertEq(amountB, 2 ether);
    }

    function test_addLiquidity_usesOptimalAWhenBIsTheBindingSide() public {
        _seedAB();
        vm.prank(alice);
        (uint256 amountA, uint256 amountB,) =
            router.addLiquidity(address(tokenA), address(tokenB), 5 ether, 2 ether, 1 ether, 0, alice, deadline);
        assertEq(amountA, 1 ether);
        assertEq(amountB, 2 ether);
    }

    function test_addLiquidity_revertsBelowMinB() public {
        _seedAB();
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientBAmount.selector, 2 ether, 2 ether + 1));
        vm.prank(alice);
        router.addLiquidity(address(tokenA), address(tokenB), 1 ether, 5 ether, 0, 2 ether + 1, alice, deadline);
    }

    function test_addLiquidity_revertsBelowMinA() public {
        _seedAB();
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientAAmount.selector, 1 ether, 1 ether + 1));
        vm.prank(alice);
        router.addLiquidity(address(tokenA), address(tokenB), 5 ether, 2 ether, 1 ether + 1, 0, alice, deadline);
    }

    function test_addLiquidity_revertsAfterDeadline() public {
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.Expired.selector, block.timestamp - 1, block.timestamp));
        router.addLiquidity(address(tokenA), address(tokenB), 1, 1, 0, 0, alice, block.timestamp - 1);
    }

    function test_addLiquidity_revertsForZeroRecipient() public {
        vm.expectRevert(IAMMRouter.InvalidRecipient.selector);
        router.addLiquidity(address(tokenA), address(tokenB), 1, 1, 0, 0, address(0), deadline);
    }

    // ------------------------------------------------------------------ removeLiquidity

    function test_removeLiquidity_ordersAmountsLikeTheArguments() public {
        uint256 liquidity = _addLiquidity(alice, address(tokenA), address(tokenB), 10 ether, 40 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        vm.startPrank(alice);
        pair.approve(address(router), liquidity);
        // Pass the tokens in reverse order: amounts must follow the arguments, not token0/token1.
        (uint256 amountB, uint256 amountA) =
            router.removeLiquidity(address(tokenB), address(tokenA), liquidity, 0, 0, bob, deadline);
        vm.stopPrank();
        // ts = 20e18, liquidity = 20e18 - 1000: amounts = liquidity * reserve / ts.
        assertEq(amountA, liquidity * 10 ether / 20 ether);
        assertEq(amountB, liquidity * 40 ether / 20 ether);
        assertEq(tokenA.balanceOf(bob), USER_FUNDS + amountA);
        _assertRouterHoldsNothing();
    }

    function test_removeLiquidity_revertsBelowMins() public {
        uint256 liquidity = _addLiquidity(alice, address(tokenA), address(tokenB), 10 ether, 40 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        uint256 outA = liquidity * 10 ether / 20 ether;
        uint256 outB = liquidity * 40 ether / 20 ether;
        vm.startPrank(alice);
        pair.approve(address(router), liquidity);
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientAAmount.selector, outA, outA + 1));
        router.removeLiquidity(address(tokenA), address(tokenB), liquidity, outA + 1, 0, alice, deadline);
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientBAmount.selector, outB, outB + 1));
        router.removeLiquidity(address(tokenA), address(tokenB), liquidity, 0, outB + 1, alice, deadline);
        vm.stopPrank();
    }

    function test_removeLiquidity_revertsAfterDeadlineAndForZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.Expired.selector, block.timestamp - 1, block.timestamp));
        router.removeLiquidity(address(tokenA), address(tokenB), 1, 0, 0, alice, block.timestamp - 1);
        vm.expectRevert(IAMMRouter.InvalidRecipient.selector);
        router.removeLiquidity(address(tokenA), address(tokenB), 1, 0, 0, address(0), deadline);
    }

    function test_removeLiquiditySupportingFeeOnTransfer_equalsPlainRemovalForStandardTokens() public {
        uint256 liquidity = _addLiquidity(alice, address(tokenA), address(tokenB), 10 ether, 40 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        uint256 outA = liquidity * 10 ether / 20 ether;
        uint256 outB = liquidity * 40 ether / 20 ether;
        vm.startPrank(alice);
        pair.approve(address(router), liquidity);
        (uint256 amountA, uint256 amountB) = router.removeLiquiditySupportingFeeOnTransferTokens(
            address(tokenA), address(tokenB), liquidity, outA, outB, bob, deadline
        );
        vm.stopPrank();
        assertEq(amountA, outA);
        assertEq(amountB, outB);
        assertEq(tokenB.balanceOf(bob), USER_FUNDS + outB);
    }

    function test_removeLiquiditySupportingFeeOnTransfer_reverts() public {
        uint256 liquidity = _addLiquidity(alice, address(tokenA), address(tokenB), 10 ether, 40 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        uint256 outA = liquidity * 10 ether / 20 ether;
        uint256 outB = liquidity * 40 ether / 20 ether;
        vm.startPrank(alice);
        pair.approve(address(router), liquidity);
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientAAmount.selector, outA, outA + 1));
        router.removeLiquiditySupportingFeeOnTransferTokens(
            address(tokenA), address(tokenB), liquidity, outA + 1, 0, alice, deadline
        );
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientBAmount.selector, outB, outB + 1));
        router.removeLiquiditySupportingFeeOnTransferTokens(
            address(tokenA), address(tokenB), liquidity, 0, outB + 1, alice, deadline
        );
        vm.expectRevert(IAMMRouter.InvalidRecipient.selector);
        router.removeLiquiditySupportingFeeOnTransferTokens(
            address(tokenA), address(tokenB), liquidity, 0, 0, address(0), deadline
        );
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.Expired.selector, block.timestamp - 1, block.timestamp));
        router.removeLiquiditySupportingFeeOnTransferTokens(
            address(tokenA), address(tokenB), liquidity, 0, 0, alice, block.timestamp - 1
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ removeLiquidityWithPermit

    function _signPermit(AMMPair pair, uint256 value, uint256 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, lp, address(router), value, nonce, deadline));
        (v, r, s) = vm.sign(lpKey, keccak256(abi.encodePacked("\x19\x01", pair.DOMAIN_SEPARATOR(), structHash)));
    }

    function test_removeLiquidityWithPermit_exactAmount() public {
        uint256 liquidity = _addLiquidity(lp, address(tokenA), address(tokenB), 10 ether, 10 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pair, liquidity, 0);
        vm.prank(lp);
        (uint256 amountA, uint256 amountB) = router.removeLiquidityWithPermit(
            address(tokenA), address(tokenB), liquidity, 0, 0, lp, deadline, false, v, r, s
        );
        assertEq(amountA, liquidity);
        assertEq(amountB, liquidity);
        assertEq(pair.balanceOf(lp), 0);
        assertEq(pair.allowance(lp, address(router)), 0, "exact permit fully consumed");
        assertEq(pair.nonces(lp), 1);
    }

    function test_removeLiquidityWithPermit_approveMax() public {
        uint256 liquidity = _addLiquidity(lp, address(tokenA), address(tokenB), 10 ether, 10 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pair, type(uint256).max, 0);
        vm.prank(lp);
        router.removeLiquidityWithPermit(
            address(tokenA), address(tokenB), liquidity / 2, 0, 0, lp, deadline, true, v, r, s
        );
        assertEq(pair.allowance(lp, address(router)), type(uint256).max);
    }

    /// @dev Permit griefing: an observer submits the user's permit first. The removal must still succeed.
    function test_removeLiquidityWithPermit_survivesFrontRunPermit() public {
        uint256 liquidity = _addLiquidity(lp, address(tokenA), address(tokenB), 10 ether, 10 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pair, liquidity, 0);

        vm.prank(bob); // front-runner
        pair.permit(lp, address(router), liquidity, deadline, v, r, s);

        vm.prank(lp);
        router.removeLiquidityWithPermit(
            address(tokenA), address(tokenB), liquidity, 0, 0, lp, deadline, false, v, r, s
        );
        assertEq(pair.balanceOf(lp), 0);
    }

    function test_removeLiquidityWithPermit_revertsOnBadSignatureWithoutAllowance() public {
        uint256 liquidity = _addLiquidity(lp, address(tokenA), address(tokenB), 10 ether, 10 ether);
        AMMPair pair = _pair(address(tokenA), address(tokenB));
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pair, liquidity - 1, 0); // signs a different value
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.PermitFailed.selector, 0, liquidity));
        vm.prank(lp);
        router.removeLiquidityWithPermit(
            address(tokenA), address(tokenB), liquidity, 0, 0, lp, deadline, false, v, r, s
        );
    }

    function test_removeLiquidityWithPermit_revertsAfterDeadline() public {
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.Expired.selector, block.timestamp - 1, block.timestamp));
        router.removeLiquidityWithPermit(
            address(tokenA), address(tokenB), 1, 0, 0, lp, block.timestamp - 1, false, 0, bytes32(0), bytes32(0)
        );
    }

    // ------------------------------------------------------------------ exact-input swaps

    function test_swapExactTokensForTokens_singleHop() public {
        _seedAB();
        uint256 expected = router.getAmountOut(1 ether, 100 ether, 200 ether);
        vm.prank(alice);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(1 ether, expected, _path(address(tokenA), address(tokenB)), bob, deadline);
        assertEq(amounts.length, 2);
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], expected);
        assertEq(tokenB.balanceOf(bob), USER_FUNDS + expected);
        _assertRouterHoldsNothing();
    }

    function test_swapExactTokensForTokens_multiHopEqualsChainedQuotes() public {
        _seedABC();
        uint256 hop1 = router.getAmountOut(1 ether, 100 ether, 200 ether);
        uint256 hop2 = router.getAmountOut(hop1, 200 ether, 50 ether);
        address[] memory path = _path(address(tokenA), address(tokenB), address(tokenC));
        uint256[] memory quoted = router.getAmountsOut(1 ether, path);
        assertEq(quoted[1], hop1);
        assertEq(quoted[2], hop2);

        vm.prank(alice);
        uint256[] memory amounts = router.swapExactTokensForTokens(1 ether, hop2, path, bob, deadline);
        assertEq(amounts[2], hop2);
        assertEq(tokenC.balanceOf(bob), USER_FUNDS + hop2);
        assertEq(tokenB.balanceOf(bob), USER_FUNDS, "intermediate token never reaches the recipient");
        _assertRouterHoldsNothing();
    }

    function test_swapExactTokensForTokens_reverseDirection() public {
        _seedAB();
        uint256 expected = router.getAmountOut(1 ether, 200 ether, 100 ether);
        vm.prank(alice);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(tokenB), address(tokenA)), bob, deadline);
        assertEq(tokenA.balanceOf(bob), USER_FUNDS + expected);
    }

    function test_swapExactTokensForTokens_revertsBelowMinimumOutput() public {
        _seedAB();
        uint256 expected = router.getAmountOut(1 ether, 100 ether, 200 ether);
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientOutputAmount.selector, expected, expected + 1));
        vm.prank(alice);
        router.swapExactTokensForTokens(1 ether, expected + 1, _path(address(tokenA), address(tokenB)), bob, deadline);
    }

    function test_swapExactTokensForTokens_revertsAfterDeadline() public {
        _seedAB();
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.Expired.selector, block.timestamp - 1, block.timestamp));
        router.swapExactTokensForTokens(1, 0, _path(address(tokenA), address(tokenB)), bob, block.timestamp - 1);
    }

    function test_swapExactTokensForTokens_revertsOnInvalidPaths() public {
        _seedAB();
        address[] memory shortPath = new address[](1);
        shortPath[0] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InvalidPath.selector, 1));
        router.swapExactTokensForTokens(1 ether, 0, shortPath, bob, deadline);

        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.PairNotFound.selector, address(tokenA), address(tokenC)));
        router.swapExactTokensForTokens(1 ether, 0, _path(address(tokenA), address(tokenC)), bob, deadline);

        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.IdenticalAddresses.selector, address(tokenA)));
        router.swapExactTokensForTokens(1 ether, 0, _path(address(tokenA), address(tokenA)), bob, deadline);

        vm.expectRevert(AMMLibrary.ZeroAddress.selector);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(0), address(tokenA)), bob, deadline);

        vm.expectRevert(IAMMRouter.InvalidRecipient.selector);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(tokenA), address(tokenB)), address(0), deadline);
    }

    // ------------------------------------------------------------------ exact-output swaps

    function test_swapTokensForExactTokens_singleHop() public {
        _seedAB();
        uint256 amountIn = router.getAmountIn(3 ether, 100 ether, 200 ether);
        vm.prank(alice);
        uint256[] memory amounts =
            router.swapTokensForExactTokens(3 ether, amountIn, _path(address(tokenA), address(tokenB)), bob, deadline);
        assertEq(amounts[0], amountIn);
        assertEq(tokenB.balanceOf(bob), USER_FUNDS + 3 ether);
        assertEq(tokenA.balanceOf(alice), USER_FUNDS - amountIn);
    }

    function test_swapTokensForExactTokens_multiHop() public {
        _seedABC();
        address[] memory path = _path(address(tokenA), address(tokenB), address(tokenC));
        uint256 hop2In = router.getAmountIn(1 ether, 200 ether, 50 ether);
        uint256 hop1In = router.getAmountIn(hop2In, 100 ether, 200 ether);
        uint256[] memory quoted = router.getAmountsIn(1 ether, path);
        assertEq(quoted[0], hop1In);
        assertEq(quoted[1], hop2In);
        vm.prank(alice);
        router.swapTokensForExactTokens(1 ether, hop1In, path, bob, deadline);
        assertEq(tokenC.balanceOf(bob), USER_FUNDS + 1 ether);
        _assertRouterHoldsNothing();
    }

    function test_swapTokensForExactTokens_revertsAboveMaximumInput() public {
        _seedAB();
        uint256 amountIn = router.getAmountIn(3 ether, 100 ether, 200 ether);
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.ExcessiveInputAmount.selector, amountIn, amountIn - 1));
        vm.prank(alice);
        router.swapTokensForExactTokens(3 ether, amountIn - 1, _path(address(tokenA), address(tokenB)), bob, deadline);
    }

    function test_swapTokensForExactTokens_revertsAfterDeadlineAndForZeroRecipient() public {
        _seedAB();
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.Expired.selector, block.timestamp - 1, block.timestamp));
        router.swapTokensForExactTokens(1, 1, _path(address(tokenA), address(tokenB)), bob, block.timestamp - 1);
        vm.expectRevert(IAMMRouter.InvalidRecipient.selector);
        router.swapTokensForExactTokens(1, 1, _path(address(tokenA), address(tokenB)), address(0), deadline);
        address[] memory shortPath = new address[](1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InvalidPath.selector, 1));
        router.swapTokensForExactTokens(1, 1, shortPath, bob, deadline);
    }

    function test_swapTokensForExactTokens_revertsWhenOutputReachesReserve() public {
        _seedAB();
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InsufficientLiquidity.selector, 100 ether, 200 ether));
        router.swapTokensForExactTokens(
            200 ether, type(uint256).max, _path(address(tokenA), address(tokenB)), bob, deadline
        );
    }

    // ------------------------------------------------------------------ fee-on-transfer entry point (standard tokens)

    function test_swapSupportingFeeOnTransfer_matchesExactInForStandardTokens() public {
        _seedABC();
        address[] memory path = _path(address(tokenA), address(tokenB), address(tokenC));
        uint256[] memory quoted = router.getAmountsOut(1 ether, path);
        vm.prank(alice);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, quoted[2], path, bob, deadline);
        assertEq(tokenC.balanceOf(bob), USER_FUNDS + quoted[2]);
        _assertRouterHoldsNothing();
    }

    function test_swapSupportingFeeOnTransfer_reverts() public {
        _seedAB();
        address[] memory path = _path(address(tokenA), address(tokenB));
        uint256 quoted = router.getAmountOut(1 ether, 100 ether, 200 ether);
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientOutputAmount.selector, quoted, quoted + 1));
        vm.prank(alice);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, quoted + 1, path, bob, deadline);

        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.Expired.selector, block.timestamp - 1, block.timestamp));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1, 0, path, bob, block.timestamp - 1);

        vm.expectRevert(IAMMRouter.InvalidRecipient.selector);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1, 0, path, address(0), deadline);

        address[] memory shortPath = new address[](1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InvalidPath.selector, 1));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1, 0, shortPath, bob, deadline);
    }

    function test_swapSupportingFeeOnTransfer_revertsWhenAHopPairIsMissing() public {
        _seedAB();
        // A -> B exists, B -> C does not: the input is paid to the A/B pair, then the second hop fails.
        address[] memory path = _path(address(tokenA), address(tokenB), address(tokenC));
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.PairNotFound.selector, address(tokenB), address(tokenC)));
        vm.prank(alice);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 0, path, bob, deadline);
    }

    function test_swapSupportingFeeOnTransfer_revertsWhenTheFirstPairIsMissing() public {
        address[] memory path = _path(address(tokenA), address(tokenC));
        // The input transfer to the code-less CREATE2 address succeeds; the hop check then reverts everything.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.PairNotFound.selector, address(tokenA), address(tokenC)));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 0, path, bob, deadline);
    }

    // ------------------------------------------------------------------ quote helpers

    function test_quoteHelpers_matchTheV2Formulas() public view {
        assertEq(router.quote(1 ether, 100 ether, 200 ether), 2 ether);
        assertEq(router.getAmountOut(1000, 1_000_000, 1_000_000), 996); // 997000 * 1e6 / (1e9 + 997000)
        assertEq(router.getAmountIn(996, 1_000_000, 1_000_000), 1000); // 1e6 * 996 * 1000 / (999004 * 997) + 1
    }

    function test_quoteHelpers_revertOnDegenerateInputs() public {
        vm.expectRevert(AMMLibrary.InsufficientAmount.selector);
        router.quote(0, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InsufficientLiquidity.selector, 0, 1));
        router.quote(1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InsufficientLiquidity.selector, 1, 0));
        router.quote(1, 1, 0);

        vm.expectRevert(AMMLibrary.InsufficientInputAmount.selector);
        router.getAmountOut(0, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InsufficientLiquidity.selector, 0, 1));
        router.getAmountOut(1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InsufficientLiquidity.selector, 1, 0));
        router.getAmountOut(1, 1, 0);

        vm.expectRevert(AMMLibrary.InsufficientOutputAmount.selector);
        router.getAmountIn(0, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InsufficientLiquidity.selector, 0, 2));
        router.getAmountIn(1, 0, 2);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InsufficientLiquidity.selector, 1, 1));
        router.getAmountIn(1, 1, 1);

        address[] memory shortPath = new address[](1);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InvalidPath.selector, 1));
        router.getAmountsOut(1, shortPath);
        vm.expectRevert(abi.encodeWithSelector(AMMLibrary.InvalidPath.selector, 1));
        router.getAmountsIn(1, shortPath);
    }

    // ------------------------------------------------------------------ token plumbing

    function test_safeTransferFrom_bubblesTheTokenRevert() public {
        _seedAB();
        MockERC20 unapproved = new MockERC20("Unapproved", "UN", 18);
        unapproved.mint(alice, 10 ether);
        _addLiquidityRaw(address(unapproved));
        vm.prank(alice); // alice never approved the router for `unapproved`
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(unapproved), address(tokenA)), bob, deadline);
    }

    function _addLiquidityRaw(address token) internal {
        MockERC20(token).mint(address(this), 10 ether);
        MockERC20(token).approve(address(router), type(uint256).max);
        router.addLiquidity(token, address(tokenA), 10 ether, 10 ether, 0, 0, address(this), deadline);
    }

    function test_router_isStatelessAcrossManyOperations() public {
        _seedABC();
        address[] memory path = _path(address(tokenA), address(tokenB), address(tokenC));
        for (uint256 i; i < 5; ++i) {
            vm.prank(alice);
            router.swapExactTokensForTokens(0.1 ether, 0, path, alice, deadline);
            vm.prank(bob);
            router.swapTokensForExactTokens(0.01 ether, type(uint256).max, path, bob, deadline);
        }
        _assertRouterHoldsNothing();
        assertEq(_pair(address(tokenA), address(tokenB)).balanceOf(address(router)), 0);
        assertEq(_pair(address(tokenB), address(tokenC)).balanceOf(address(router)), 0);
    }
}
