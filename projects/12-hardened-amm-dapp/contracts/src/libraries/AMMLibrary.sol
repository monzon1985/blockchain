// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-periphery UniswapV2Library.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

import {IAMMPair} from "../interfaces/IAMMPair.sol";

/// @title AMMLibrary
/// @notice Pure quoting math (bit-for-bit the Uniswap v2 formulas) and CREATE2 pair derivation.
/// @dev The TypeScript quote library in `web/src/lib/quote.ts` mirrors these functions and is
///      differential-tested against the deployed router.
library AMMLibrary {
    /// @notice Both tokens are the same.
    /// @param token The duplicated token.
    error IdenticalAddresses(address token);

    /// @notice A token is the zero address.
    error ZeroAddress();

    /// @notice An amount that must be positive is zero.
    error InsufficientAmount();

    /// @notice The input amount of a swap quote is zero.
    error InsufficientInputAmount();

    /// @notice The output amount of a swap quote is zero.
    error InsufficientOutputAmount();

    /// @notice A reserve is empty, or the requested output is not strictly below the output reserve.
    /// @param reserveIn Reserve of the input token.
    /// @param reserveOut Reserve of the output token.
    error InsufficientLiquidity(uint256 reserveIn, uint256 reserveOut);

    /// @notice A swap path has fewer than two tokens.
    /// @param length The path length.
    error InvalidPath(uint256 length);

    /// @notice No pair is deployed for the two tokens.
    /// @param tokenA One token of the missing pair.
    /// @param tokenB The other token of the missing pair.
    error PairNotFound(address tokenA, address tokenB);

    /// @notice Sorts two token addresses.
    /// @param tokenA One token.
    /// @param tokenB The other token.
    /// @return token0 The lower address.
    /// @return token1 The higher address.
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, IdenticalAddresses(tokenA));
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), ZeroAddress());
    }

    /// @notice CREATE2 address of the pair for two tokens, without an external call.
    /// @param factory The factory that deploys pairs.
    /// @param initCodeHash keccak256 of the pair creation code.
    /// @param tokenA One token.
    /// @param tokenB The other token.
    /// @return pair The deterministic pair address (may have no code if the pair does not exist).
    function pairFor(address factory, bytes32 initCodeHash, address tokenA, address tokenB)
        internal
        pure
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(token0, token1)), initCodeHash)
                    )
                )
            )
        );
    }

    /// @notice Reserves of the pair for `tokenA`/`tokenB`, ordered as the arguments.
    /// @param factory The factory that deploys pairs.
    /// @param initCodeHash keccak256 of the pair creation code.
    /// @param tokenA The token whose reserve is returned first.
    /// @param tokenB The token whose reserve is returned second.
    /// @return reserveA Reserve of `tokenA`.
    /// @return reserveB Reserve of `tokenB`.
    // slither-disable-next-line unused-return -- the TWAP timestamp is irrelevant for quoting
    function getReserves(address factory, bytes32 initCodeHash, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = pairFor(factory, initCodeHash, tokenA, tokenB);
        // Explicit error instead of an empty revert when the pair was never created.
        require(pair.code.length != 0, PairNotFound(tokenA, tokenB));
        // forge-lint: disable-next-line(unused-return) -- the TWAP timestamp is irrelevant for quoting
        (uint256 reserve0, uint256 reserve1,) = IAMMPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice Amount of B with the same value as `amountA` at the current reserve ratio (no fee).
    /// @param amountA Amount of token A.
    /// @param reserveA Reserve of token A.
    /// @param reserveB Reserve of token B.
    /// @return amountB amountA * reserveB / reserveA, rounded down.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, InsufficientAmount());
        require(reserveA > 0 && reserveB > 0, InsufficientLiquidity(reserveA, reserveB));
        amountB = amountA * reserveB / reserveA;
    }

    /// @notice Maximum output for an exact input after the 0.30 % fee.
    /// @param amountIn Exact input amount.
    /// @param reserveIn Reserve of the input token.
    /// @param reserveOut Reserve of the output token.
    /// @return amountOut Output amount, rounded down (the largest amount the pair's k check accepts).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, InsufficientInputAmount());
        require(reserveIn > 0 && reserveOut > 0, InsufficientLiquidity(reserveIn, reserveOut));
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Input required for an exact output after the 0.30 % fee.
    /// @param amountOut Exact output amount; must be below `reserveOut`.
    /// @param reserveIn Reserve of the input token.
    /// @param reserveOut Reserve of the output token.
    /// @return amountIn Input amount, rounded up (floor + 1, exactly as Uniswap v2).
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, InsufficientOutputAmount());
        require(reserveIn > 0 && reserveOut > amountOut, InsufficientLiquidity(reserveIn, reserveOut));
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = numerator / denominator + 1;
    }

    /// @notice Chained `getAmountOut` over a path.
    /// @param factory The factory that deploys pairs.
    /// @param initCodeHash keccak256 of the pair creation code.
    /// @param amountIn Exact input for the first hop.
    /// @param path Token path, at least two tokens.
    /// @return amounts amounts[0] = amountIn, amounts[i] = output of hop i.
    function getAmountsOut(address factory, bytes32 initCodeHash, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, InvalidPath(path.length));
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ++i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, initCodeHash, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @notice Chained `getAmountIn` over a path, computed from the last hop backwards.
    /// @param factory The factory that deploys pairs.
    /// @param initCodeHash keccak256 of the pair creation code.
    /// @param amountOut Exact output of the last hop.
    /// @param path Token path, at least two tokens.
    /// @return amounts amounts[last] = amountOut, amounts[i] = input required at hop i.
    function getAmountsIn(address factory, bytes32 initCodeHash, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, InvalidPath(path.length));
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; --i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, initCodeHash, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
