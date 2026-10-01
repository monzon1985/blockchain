// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-periphery UniswapV2Router02.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAMMFactory} from "./interfaces/IAMMFactory.sol";
import {IAMMPair} from "./interfaces/IAMMPair.sol";
import {IAMMRouter} from "./interfaces/IAMMRouter.sol";
import {AMMLibrary} from "./libraries/AMMLibrary.sol";

/// @title AMMRouter
/// @notice Stateless periphery for AMMPair: liquidity, exact-in / exact-out multi-hop swaps and fee-on-transfer
///         swaps, each bounded by a deadline and a slippage limit.
/// @dev Holds no state and never custodies tokens (users pay pairs directly), so it has no reentrancy guard:
///      a reentrant call can only spend the reentering caller's own approvals. It has no payable entry point.
contract AMMRouter is IAMMRouter {
    using SafeERC20 for IERC20;

    /// @inheritdoc IAMMRouter
    address public immutable factory;

    /// @inheritdoc IAMMRouter
    bytes32 public immutable pairInitCodeHash;

    /// @dev Rejects transactions mined after `deadline` (stale transactions are a free option for MEV).
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, Expired(deadline, block.timestamp));
        _;
    }

    /// @param factory_ The factory to route through; its init-code hash is cached.
    // slither-disable-start missing-zero-check
    // forge-lint: disable-next-line(missing-zero-check) -- a zero factory reverts on the PAIR_INIT_CODE_HASH call
    constructor(address factory_) {
        factory = factory_;
        pairInitCodeHash = IAMMFactory(factory_).PAIR_INIT_CODE_HASH();
    }

    // slither-disable-end missing-zero-check

    // ------------------------------------------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAMMRouter
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(to != address(0), InvalidRecipient());
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        liquidity = _depositAndMint(tokenA, tokenB, amountA, amountB, to);
    }

    /// @inheritdoc IAMMRouter
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        require(to != address(0), InvalidRecipient());
        (amountA, amountB) = _burnLiquidity(tokenA, tokenB, liquidity, to);
        require(amountA >= amountAMin, InsufficientAAmount(amountA, amountAMin));
        require(amountB >= amountBMin, InsufficientBAmount(amountB, amountBMin));
    }

    /// @inheritdoc IAMMRouter
    // slither-disable-next-line reentrancy-balance -- the balance delta of `to` is the measurement itself; a reentrant `to` only misreports its own output
    function removeLiquiditySupportingFeeOnTransferTokens(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        require(to != address(0), InvalidRecipient());
        uint256 balanceABefore = IERC20(tokenA).balanceOf(to);
        uint256 balanceBBefore = IERC20(tokenB).balanceOf(to);
        _burnLiquidity(tokenA, tokenB, liquidity, to);
        // Slippage is enforced on what the recipient actually received, after any transfer fee.
        amountA = IERC20(tokenA).balanceOf(to) - balanceABefore;
        amountB = IERC20(tokenB).balanceOf(to) - balanceBBefore;
        require(amountA >= amountAMin, InsufficientAAmount(amountA, amountAMin));
        require(amountB >= amountBMin, InsufficientBAmount(amountB, amountBMin));
    }

    /// @inheritdoc IAMMRouter
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        _permit(tokenA, tokenB, approveMax ? type(uint256).max : liquidity, liquidity, deadline, v, r, s);
        return removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    // ------------------------------------------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAMMRouter
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(to != address(0), InvalidRecipient());
        amounts = AMMLibrary.getAmountsOut(factory, pairInitCodeHash, amountIn, path);
        uint256 amountOut = amounts[amounts.length - 1];
        require(amountOut >= amountOutMin, InsufficientOutputAmount(amountOut, amountOutMin));
        IERC20(path[0])
            .safeTransferFrom(msg.sender, AMMLibrary.pairFor(factory, pairInitCodeHash, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @inheritdoc IAMMRouter
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(to != address(0), InvalidRecipient());
        amounts = AMMLibrary.getAmountsIn(factory, pairInitCodeHash, amountOut, path);
        require(amounts[0] <= amountInMax, ExcessiveInputAmount(amounts[0], amountInMax));
        IERC20(path[0])
            .safeTransferFrom(msg.sender, AMMLibrary.pairFor(factory, pairInitCodeHash, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @inheritdoc IAMMRouter
    // slither-disable-next-line reentrancy-balance -- the balance delta of `to` is the measurement itself; a reentrant `to` only misreports its own output
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) {
        require(to != address(0), InvalidRecipient());
        require(path.length >= 2, AMMLibrary.InvalidPath(path.length));
        IERC20(path[0])
            .safeTransferFrom(msg.sender, AMMLibrary.pairFor(factory, pairInitCodeHash, path[0], path[1]), amountIn);
        IERC20 tokenOut = IERC20(path[path.length - 1]);
        uint256 balanceBefore = tokenOut.balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        // Slippage is enforced on what the recipient actually received, after every transfer fee.
        uint256 received = tokenOut.balanceOf(to) - balanceBefore;
        require(received >= amountOutMin, InsufficientOutputAmount(received, amountOutMin));
    }

    // ------------------------------------------------------------------------------------------------------
    // Quotes
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAMMRouter
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB) {
        return AMMLibrary.quote(amountA, reserveA, reserveB);
    }

    /// @inheritdoc IAMMRouter
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut)
    {
        return AMMLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @inheritdoc IAMMRouter
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn)
    {
        return AMMLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    /// @inheritdoc IAMMRouter
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        return AMMLibrary.getAmountsOut(factory, pairInitCodeHash, amountIn, path);
    }

    /// @inheritdoc IAMMRouter
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts) {
        return AMMLibrary.getAmountsIn(factory, pairInitCodeHash, amountOut, path);
    }

    // ------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------

    /// @dev Optimal deposit at the current ratio; creates the pair if it does not exist yet.
    // slither-disable-next-line unused-return -- the pair address is re-derived with CREATE2
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) private returns (uint256 amountA, uint256 amountB) {
        if (IAMMFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            // The pair address is re-derived with CREATE2 below; the return value is not needed.
            // forge-lint: disable-next-line(unused-return)
            IAMMFactory(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = AMMLibrary.getReserves(factory, pairInitCodeHash, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = AMMLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, InsufficientBAmount(amountBOptimal, amountBMin));
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = AMMLibrary.quote(amountBDesired, reserveB, reserveA);
                // amountAOptimal <= amountADesired always holds here (the ratio argument of Uniswap v2's assert);
                // the check below still bounds it from both sides.
                require(
                    amountAOptimal <= amountADesired && amountAOptimal >= amountAMin,
                    InsufficientAAmount(amountAOptimal, amountAMin)
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /// @dev Pulls `liquidity` LP tokens from the caller into the pair and burns them to `to`; returns the amounts
    ///      the pair paid, ordered like the arguments.
    // slither-disable-next-line unused-return -- only token0 of sortTokens is needed
    function _burnLiquidity(address tokenA, address tokenB, uint256 liquidity, address to)
        private
        returns (uint256 amountA, uint256 amountB)
    {
        address pair = AMMLibrary.pairFor(factory, pairInitCodeHash, tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IAMMPair(pair).burn(to);
        (address token0,) = AMMLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
    }

    /// @dev Pays both amounts from the caller straight into the pair, then mints LP tokens to `to`.
    function _depositAndMint(address tokenA, address tokenB, uint256 amountA, uint256 amountB, address to)
        private
        returns (uint256 liquidity)
    {
        address pair = AMMLibrary.pairFor(factory, pairInitCodeHash, tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IAMMPair(pair).mint(to);
    }

    /// @dev Applies an EIP-2612 permit for the router on the pair's LP token. A permit seen in the mempool can be
    ///      submitted by anyone first, which consumes the nonce and makes a bare `permit` call revert; that case is
    ///      accepted as long as the allowance it granted already covers `liquidity`.
    function _permit(
        address tokenA,
        address tokenB,
        uint256 value,
        uint256 liquidity,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        address pair = AMMLibrary.pairFor(factory, pairInitCodeHash, tokenA, tokenB);
        try IERC20Permit(pair).permit(msg.sender, address(this), value, deadline, v, r, s) {}
        catch {
            uint256 allowance = IERC20(pair).allowance(msg.sender, address(this));
            require(allowance >= liquidity, PermitFailed(allowance, liquidity));
        }
    }

    /// @dev Executes the hops of a quoted path; every intermediate output goes straight to the next pair.
    // slither-disable-next-line calls-loop,unused-return -- one pair call per hop, all-or-nothing; only token0 of sortTokens is needed
    function _swap(uint256[] memory amounts, address[] calldata path, address to) private {
        uint256 lastHop = path.length - 2;
        for (uint256 i; i <= lastHop; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = AMMLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, 0);
            address recipient = i < lastHop ? AMMLibrary.pairFor(factory, pairInitCodeHash, output, path[i + 2]) : to;
            IAMMPair(AMMLibrary.pairFor(factory, pairInitCodeHash, input, output))
                .swap(amount0Out, amount1Out, recipient, new bytes(0));
        }
    }

    /// @dev Like `_swap`, but prices every hop on the input the pair actually received.
    function _swapSupportingFeeOnTransferTokens(address[] calldata path, address to) private {
        uint256 lastHop = path.length - 2;
        for (uint256 i; i <= lastHop; ++i) {
            address recipient =
                i < lastHop ? AMMLibrary.pairFor(factory, pairInitCodeHash, path[i + 1], path[i + 2]) : to;
            _swapHopSupportingFeeOnTransfer(path[i], path[i + 1], recipient);
        }
    }

    /// @dev One fee-on-transfer hop: the input is the pair's balance above its reserve, not a precomputed amount.
    // slither-disable-next-line calls-loop,unused-return -- called once per hop; the TWAP timestamp and token1 are not needed
    function _swapHopSupportingFeeOnTransfer(address input, address output, address recipient) private {
        (address token0,) = AMMLibrary.sortTokens(input, output);
        IAMMPair pair = IAMMPair(AMMLibrary.pairFor(factory, pairInitCodeHash, input, output));
        require(address(pair).code.length != 0, AMMLibrary.PairNotFound(input, output));
        // forge-lint: disable-next-line(unused-return) -- the TWAP timestamp is irrelevant for pricing a hop
        (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
        (uint256 reserveInput, uint256 reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 amountInput = IERC20(input).balanceOf(address(pair)) - reserveInput;
        uint256 amountOutput = AMMLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
        (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOutput) : (amountOutput, 0);
        pair.swap(amount0Out, amount1Out, recipient, new bytes(0));
    }
}
