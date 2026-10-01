// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-core IUniswapV2Pair.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

/// @title IAMMPair
/// @notice Constant-product (x * y = k) pair with a 0.30 % LP fee, an optional 0.05 % protocol fee and
///         Uniswap-v2-compatible TWAP accumulators. Events keep the Uniswap v2 signatures.
interface IAMMPair {
    /// @notice Liquidity was added.
    /// @param sender The caller of `mint` (usually the router).
    /// @param amount0 Token0 deposited (balance above reserve).
    /// @param amount1 Token1 deposited (balance above reserve).
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);

    /// @notice Liquidity was removed.
    /// @param sender The caller of `burn` (usually the router).
    /// @param amount0 Token0 paid out.
    /// @param amount1 Token1 paid out.
    /// @param to Recipient of both tokens.
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    /// @notice A swap (or flash swap) settled.
    /// @param sender The caller of `swap`.
    /// @param amount0In Token0 received by the pair.
    /// @param amount1In Token1 received by the pair.
    /// @param amount0Out Token0 sent by the pair.
    /// @param amount1Out Token1 sent by the pair.
    /// @param to Recipient of the output tokens.
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice Reserves were written. Emitted by every mint, burn, swap and sync.
    /// @param reserve0 New token0 reserve.
    /// @param reserve1 New token1 reserve.
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @notice First deposit is too small to lock MINIMUM_LIQUIDITY and still mint a positive amount.
    /// @param liquidity The liquidity the deposit would have minted (0 or negative is clamped to 0).
    error InsufficientLiquidityMinted(uint256 liquidity);

    /// @notice A burn would pay out zero of at least one token.
    /// @param amount0 Token0 the burn would pay.
    /// @param amount1 Token1 the burn would pay.
    error InsufficientLiquidityBurned(uint256 amount0, uint256 amount1);

    /// @notice A swap requested no output.
    error InsufficientOutputAmount();

    /// @notice A swap requested at least the full reserve of a token.
    /// @param amount0Out Requested token0 output.
    /// @param amount1Out Requested token1 output.
    /// @param reserve0 Token0 reserve.
    /// @param reserve1 Token1 reserve.
    error InsufficientLiquidity(uint256 amount0Out, uint256 amount1Out, uint112 reserve0, uint112 reserve1);

    /// @notice The swap recipient is one of the pair tokens (which would corrupt accounting).
    /// @param to The rejected recipient.
    error InvalidTo(address to);

    /// @notice The pair received no input for a swap.
    error InsufficientInputAmount();

    /// @notice The fee-adjusted constant-product check failed.
    /// @param balanceProduct balance0Adjusted * balance1Adjusted (scaled by 1000^2).
    /// @param reserveProduct reserve0 * reserve1 * 1000^2.
    error K(uint256 balanceProduct, uint256 reserveProduct);

    /// @notice A balance does not fit the 112-bit reserve slots.
    /// @param balance0 Token0 balance.
    /// @param balance1 Token1 balance.
    error Overflow(uint256 balance0, uint256 balance1);

    /// @notice A flash-swap recipient has no code to run the callback.
    /// @param to The recipient without code.
    error CallbackTargetNotContract(address to);

    /// @notice A flash-swap callback did not return the IAMMCallee magic value.
    /// @param returned The value the callee returned.
    error InvalidCallbackReturn(bytes32 returned);

    /// @notice Lock-free liquidity locked forever at address(0) on the first mint (first-depositor defence).
    /// @return Always 1000.
    // slither-disable-next-line naming-convention -- Uniswap v2 ABI name
    function MINIMUM_LIQUIDITY() external view returns (uint256);

    /// @notice The factory that deployed this pair.
    /// @return The factory address.
    function factory() external view returns (address);

    /// @notice Lower-sorted token.
    /// @return The token0 address.
    function token0() external view returns (address);

    /// @notice Higher-sorted token.
    /// @return The token1 address.
    function token1() external view returns (address);

    /// @notice Reserves and the (mod 2^32) timestamp of their last update.
    /// @dev Reverts with `ReentrancyGuardReentrantCall()` while a state-changing function is executing, so
    ///      that integrators cannot price anything off reserves that are mid-update (read-only reentrancy).
    /// @return reserve0 Token0 reserve.
    /// @return reserve1 Token1 reserve.
    /// @return blockTimestampLast Block timestamp (mod 2^32) of the last reserve update.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice True while a state-changing function of this pair is on the call stack.
    /// @dev Integrators that read `totalSupply`, `balanceOf` or the price accumulators must check this first.
    /// @return locked Whether the transient reentrancy lock is held.
    function isLocked() external view returns (bool locked);

    /// @notice Time-weighted sum of reserve1/reserve0 as UQ112x112. Wraps modulo 2^256 by design.
    /// @return The token0 price accumulator.
    function price0CumulativeLast() external view returns (uint256);

    /// @notice Time-weighted sum of reserve0/reserve1 as UQ112x112. Wraps modulo 2^256 by design.
    /// @return The token1 price accumulator.
    function price1CumulativeLast() external view returns (uint256);

    /// @notice reserve0 * reserve1 as of the last liquidity event while the protocol fee was on.
    /// @return The k checkpoint used to compute the protocol fee.
    function kLast() external view returns (uint256);

    /// @notice Mints LP tokens for the tokens transferred to the pair since the last update.
    /// @param to Recipient of the LP tokens.
    /// @return liquidity LP tokens minted.
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burns the LP tokens held by the pair and pays out the pro-rata share of both tokens.
    /// @param to Recipient of the tokens.
    /// @return amount0 Token0 paid out.
    /// @return amount1 Token1 paid out.
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Sends the requested outputs, optionally runs a flash-swap callback, then enforces k.
    /// @param amount0Out Token0 to send.
    /// @param amount1Out Token1 to send.
    /// @param to Recipient of the outputs (and callback target when `data` is non-empty).
    /// @param data Empty for a plain swap; non-empty triggers `IAMMCallee.ammSwapCall` on `to`.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice Sends balances in excess of reserves to `to`.
    /// @param to Recipient of the surplus.
    function skim(address to) external;

    /// @notice Writes the current balances into the reserves.
    function sync() external;
}
