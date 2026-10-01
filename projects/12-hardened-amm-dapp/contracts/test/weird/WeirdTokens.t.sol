// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";

import {AMMFactory} from "../../src/AMMFactory.sol";
import {AMMPair} from "../../src/AMMPair.sol";
import {AMMRouter} from "../../src/AMMRouter.sol";
import {IAMMPair} from "../../src/interfaces/IAMMPair.sol";
import {IAMMRouter} from "../../src/interfaces/IAMMRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferToken, NoReturnToken, RebasingToken, ReturnsFalseToken} from "../mocks/WeirdTokens.sol";

/// @notice The weird-token matrix: fee-on-transfer, rebasing (both directions), USDT-style missing return
///         values, tokens that return false, and 6 / 18 / 24 decimals. Each test states the observed behaviour,
///         including the cases where the AMM deliberately refuses to operate.
contract WeirdTokensTest is Test {
    AMMFactory internal factory;
    AMMRouter internal router;
    MockERC20 internal usd; // well-behaved counterpart
    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    uint256 internal deadline;

    function setUp() public {
        vm.warp(1_750_000_000);
        deadline = block.timestamp + 1 hours;
        factory = new AMMFactory(address(this));
        router = new AMMRouter(address(factory));
        usd = new MockERC20("Standard", "STD", 18);
        usd.mint(user, 1e30);
        vm.prank(user);
        usd.approve(address(router), type(uint256).max);
    }

    function _fund(address token) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", user, 1e30));
        require(ok);
        vm.prank(user);
        (ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max));
        require(ok);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _seed(address token, uint256 amountToken, uint256 amountUsd) internal returns (AMMPair pair) {
        _fund(token);
        vm.prank(user);
        router.addLiquidity(token, address(usd), amountToken, amountUsd, 0, 0, user, deadline);
        pair = AMMPair(factory.getPair(token, address(usd)));
    }

    function _reserveOf(AMMPair pair, address token) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return pair.token0() == token ? r0 : r1;
    }

    // ------------------------------------------------------------------ fee-on-transfer (1 %)

    function test_feeOnTransfer_mintCreditsOnlyWhatArrived() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(18, 100);
        AMMPair pair = _seed(address(fot), 100 ether, 100 ether);
        assertEq(_reserveOf(pair, address(fot)), 99 ether, "pair measured the post-fee balance");
    }

    function test_feeOnTransfer_standardSwapRevertsWithK() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(18, 100);
        _seed(address(fot), 100 ether, 100 ether);
        vm.expectPartialRevert(IAMMPair.K.selector); // quoted on 1 ether, the pair received 0.99 ether
        vm.prank(user);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(fot), address(usd)), recipient, deadline);
    }

    function test_feeOnTransfer_supportingSwap_asInput() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(18, 100);
        AMMPair pair = _seed(address(fot), 100 ether, 100 ether);
        uint256 expected =
            router.getAmountOut(0.99 ether, _reserveOf(pair, address(fot)), _reserveOf(pair, address(usd)));
        vm.prank(user);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, expected, _path(address(fot), address(usd)), recipient, deadline
        );
        assertEq(usd.balanceOf(recipient), expected);
    }

    function test_feeOnTransfer_supportingSwap_asOutput_checksWhatTheRecipientGot() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(18, 100);
        AMMPair pair = _seed(address(fot), 100 ether, 100 ether);
        uint256 pairOut = router.getAmountOut(1 ether, _reserveOf(pair, address(usd)), _reserveOf(pair, address(fot)));
        uint256 received = pairOut - pairOut / 100;
        // Asking for the pre-fee amount must fail: slippage is enforced on the post-fee delivery.
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientOutputAmount.selector, received, pairOut));
        vm.prank(user);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, pairOut, _path(address(usd), address(fot)), recipient, deadline
        );
        vm.prank(user);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, received, _path(address(usd), address(fot)), recipient, deadline
        );
        assertEq(fot.balanceOf(recipient), received);
    }

    function test_feeOnTransfer_supportingSwap_multiHopThroughTheToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(18, 100);
        _seed(address(fot), 100 ether, 100 ether);
        MockERC20 third = new MockERC20("Third", "THD", 18);
        _fund(address(third));
        vm.prank(user);
        router.addLiquidity(address(fot), address(third), 100 ether, 100 ether, 0, 0, user, deadline);
        address[] memory path = new address[](3);
        (path[0], path[1], path[2]) = (address(usd), address(fot), address(third));
        vm.prank(user);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1 ether, 1, path, recipient, deadline);
        assertGt(third.balanceOf(recipient), 0);
        assertEq(fot.balanceOf(address(router)), 0);
    }

    function test_feeOnTransfer_removeLiquidity_plainChecksPairAmountsSupportingChecksDelivery() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(18, 100);
        AMMPair pair = _seed(address(fot), 100 ether, 100 ether);
        uint256 liquidity = pair.balanceOf(user) / 2;
        uint256 pairPays = liquidity * _reserveOf(pair, address(fot)) / pair.totalSupply();
        uint256 delivered = pairPays - pairPays / 100;

        vm.startPrank(user);
        pair.approve(address(router), type(uint256).max);
        uint256 snapshot = vm.snapshotState();
        // The plain entry point accepts a minimum equal to what the pair sent, although `recipient` got 1 % less.
        (uint256 reported,) =
            router.removeLiquidity(address(fot), address(usd), liquidity, pairPays, 0, recipient, deadline);
        assertEq(reported, pairPays);
        assertEq(fot.balanceOf(recipient), delivered);
        vm.revertToState(snapshot);

        // The supporting entry point enforces the minimum on the delivered amount.
        vm.expectRevert(abi.encodeWithSelector(IAMMRouter.InsufficientAAmount.selector, delivered, pairPays));
        router.removeLiquiditySupportingFeeOnTransferTokens(
            address(fot), address(usd), liquidity, pairPays, 0, recipient, deadline
        );
        (uint256 got,) = router.removeLiquiditySupportingFeeOnTransferTokens(
            address(fot), address(usd), liquidity, delivered, 0, recipient, deadline
        );
        vm.stopPrank();
        assertEq(got, delivered);
    }

    // ------------------------------------------------------------------ rebasing

    function test_rebasing_positiveRebase_surplusIsSkimmableUntilSynced() public {
        RebasingToken reb = new RebasingToken(18);
        AMMPair pair = _seed(address(reb), 100 ether, 100 ether);
        reb.rebase(1.1e18); // +10 %
        assertEq(reb.balanceOf(address(pair)), 110 ether);
        assertEq(_reserveOf(pair, address(reb)), 100 ether, "reserves lag the rebase");

        uint256 snapshot = vm.snapshotState();
        pair.skim(recipient); // anyone can take the rebase yield before a sync
        assertApproxEqAbs(reb.balanceOf(recipient), 10 ether, 1);
        vm.revertToState(snapshot);

        pair.sync(); // or it is credited to the LPs
        assertEq(_reserveOf(pair, address(reb)), 110 ether);
    }

    function test_rebasing_negativeRebase_blocksMintSkimAndSwapsUntilSync() public {
        RebasingToken reb = new RebasingToken(18);
        AMMPair pair = _seed(address(reb), 100 ether, 100 ether);
        reb.rebase(0.9e18); // -10 %: balance 90 < reserve 100
        assertLt(reb.balanceOf(address(pair)), _reserveOf(pair, address(reb)));

        vm.expectRevert(stdError.arithmeticError); // balance - reserve underflows, as in the canonical pair
        pair.mint(user);
        vm.expectRevert(stdError.arithmeticError);
        pair.skim(user);
        // The shrunken balance plus a 1-token deposit is still below the stale reserve: the pair sees no input.
        vm.expectRevert(IAMMPair.InsufficientInputAmount.selector);
        vm.prank(user);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(reb), address(usd)), recipient, deadline);

        pair.sync(); // realigns reserves; k drops, the documented exception for negative rebases
        assertEq(_reserveOf(pair, address(reb)), reb.balanceOf(address(pair)));
        vm.prank(user);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(reb), address(usd)), recipient, deadline);
    }

    function test_rebasing_burnPaysFromBalances() public {
        RebasingToken reb = new RebasingToken(18);
        AMMPair pair = _seed(address(reb), 100 ether, 100 ether);
        reb.rebase(0.5e18);
        uint256 liquidity = pair.balanceOf(user);
        vm.startPrank(user);
        pair.approve(address(router), liquidity);
        (uint256 amountReb,) = router.removeLiquidity(address(reb), address(usd), liquidity, 0, 0, user, deadline);
        vm.stopPrank();
        assertApproxEqRel(amountReb, 50 ether, 1e12, "the loss is shared pro rata");
    }

    // ------------------------------------------------------------------ missing / false return values

    function test_usdtStyleNoReturnValue_fullLifecycle() public {
        NoReturnToken usdt = new NoReturnToken(6);
        AMMPair pair = _seed(address(usdt), 1_000_000e6, 1_000_000 ether);
        vm.startPrank(user);
        router.swapExactTokensForTokens(1000e6, 1, _path(address(usdt), address(usd)), user, deadline);
        router.swapExactTokensForTokens(1000 ether, 1, _path(address(usd), address(usdt)), user, deadline);
        uint256 liquidity = pair.balanceOf(user);
        pair.approve(address(router), liquidity);
        router.removeLiquidity(address(usdt), address(usd), liquidity, 0, 0, user, deadline);
        vm.stopPrank();
        assertEq(pair.balanceOf(user), 0);
        assertEq(usdt.balanceOf(address(router)), 0);
    }

    function test_returnsFalse_isRejectedOnPullAndOnPush() public {
        ReturnsFalseToken token = new ReturnsFalseToken();
        _seed(address(token), 100 ether, 100 ether);
        token.setFailing(true);

        // Pull (router.transferFrom user -> pair) returns false.
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(user);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(token), address(usd)), recipient, deadline);

        // Push (pair.transfer -> recipient) returns false.
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(user);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(usd), address(token)), recipient, deadline);
    }

    // ------------------------------------------------------------------ decimals 6 / 18 / 24

    function testFuzz_decimalsMatrix_lifecycle(uint8 decimalsSeedA, uint8 decimalsSeedB, uint256 units, uint256 trade)
        public
    {
        uint8[3] memory options = [6, 18, 24];
        uint8 decA = options[decimalsSeedA % 3];
        uint8 decB = options[decimalsSeedB % 3];
        MockERC20 a = new MockERC20("A", "A", decA);
        MockERC20 b = new MockERC20("B", "B", decB);
        _fund(address(a));
        _fund(address(b));
        units = bound(units, 1, 1_000_000_000); // 1 to 1e9 whole tokens per side
        uint256 amountA = units * 10 ** decA;
        uint256 amountB = units * 10 ** decB;
        a.mint(user, amountA * 2); // deposit + a trade of up to the whole deposit
        b.mint(user, amountB);

        vm.startPrank(user);
        (,, uint256 liquidity) = router.addLiquidity(address(a), address(b), amountA, amountB, 0, 0, user, deadline);
        AMMPair pair = AMMPair(factory.getPair(address(a), address(b)));
        uint256 amountIn = bound(trade, 1, amountA);
        uint256[] memory quoted = router.getAmountsOut(amountIn, _path(address(a), address(b)));
        if (quoted[1] > 0) {
            router.swapExactTokensForTokens(amountIn, quoted[1], _path(address(a), address(b)), user, deadline);
        }
        pair.approve(address(router), liquidity);
        router.removeLiquidity(address(a), address(b), liquidity, 0, 0, user, deadline);
        vm.stopPrank();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0), IERC20(pair.token0()).balanceOf(address(pair)));
        assertEq(uint256(r1), IERC20(pair.token1()).balanceOf(address(pair)));
        assertEq(pair.totalSupply(), 1000, "only the locked liquidity remains");
    }

    function test_decimals24_hitsThe112BitReserveCeiling() public {
        MockERC20 big = new MockERC20("Big", "BIG", 24);
        _fund(address(big));
        // uint112 max ~ 5.19e33 raw units = ~5.19e9 whole tokens at 24 decimals.
        uint256 tooMuch = 6e9 * 1e24;
        big.mint(user, tooMuch);
        (uint256 balance0, uint256 balance1) =
            address(big) < address(usd) ? (tooMuch, uint256(1 ether)) : (uint256(1 ether), tooMuch);
        vm.expectRevert(abi.encodeWithSelector(IAMMPair.Overflow.selector, balance0, balance1));
        vm.prank(user);
        router.addLiquidity(address(big), address(usd), tooMuch, 1 ether, 0, 0, user, deadline);
    }
}
