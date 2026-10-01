// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-periphery IUniswapV2Router02.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

/// @title IAMMRouter
/// @notice Stateless user entry point: liquidity management and multi-hop swaps with deadline and slippage
///         bounds. Never holds tokens between calls: every transfer goes user -> pair or pair -> recipient.
interface IAMMRouter {
    /// @notice The transaction was mined after its deadline.
    /// @param deadline The user-supplied deadline.
    /// @param timestamp The block timestamp at execution.
    error Expired(uint256 deadline, uint256 timestamp);

    /// @notice The final output of an exact-input swap is below the user's minimum.
    /// @param amountOut The output the swap would deliver.
    /// @param amountOutMin The user's minimum.
    error InsufficientOutputAmount(uint256 amountOut, uint256 amountOutMin);

    /// @notice The input required by an exact-output swap exceeds the user's maximum.
    /// @param amountIn The input the swap requires.
    /// @param amountInMax The user's maximum.
    error ExcessiveInputAmount(uint256 amountIn, uint256 amountInMax);

    /// @notice Token A deposited or withdrawn is below the user's minimum.
    /// @param amountA The amount of token A.
    /// @param amountAMin The user's minimum.
    error InsufficientAAmount(uint256 amountA, uint256 amountAMin);

    /// @notice Token B deposited or withdrawn is below the user's minimum.
    /// @param amountB The amount of token B.
    /// @param amountBMin The user's minimum.
    error InsufficientBAmount(uint256 amountB, uint256 amountBMin);

    /// @notice The recipient is the zero address.
    error InvalidRecipient();

    /// @notice The permit call failed and the router's allowance is still below the requested liquidity.
    /// @param allowance The router's current LP allowance from the caller.
    /// @param liquidity The liquidity to remove.
    error PermitFailed(uint256 allowance, uint256 liquidity);

    /// @notice The factory this router routes through.
    /// @return The factory address.
    function factory() external view returns (address);

    /// @notice Pair init-code hash cached from the factory at construction.
    /// @return The hash used to derive pair addresses.
    function pairInitCodeHash() external view returns (bytes32);

    /// @notice Deposits both tokens at the current ratio (creating the pair on first use) and mints LP tokens.
    /// @param tokenA One token.
    /// @param tokenB The other token.
    /// @param amountADesired Upper bound of token A to deposit.
    /// @param amountBDesired Upper bound of token B to deposit.
    /// @param amountAMin Lower bound of token A to deposit (slippage protection).
    /// @param amountBMin Lower bound of token B to deposit (slippage protection).
    /// @param to Recipient of the LP tokens.
    /// @param deadline Last valid block timestamp.
    /// @return amountA Token A deposited.
    /// @return amountB Token B deposited.
    /// @return liquidity LP tokens minted.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Burns LP tokens (pulled from the caller with `transferFrom`) and pays out both tokens.
    /// @param tokenA One token.
    /// @param tokenB The other token.
    /// @param liquidity LP tokens to burn.
    /// @param amountAMin Minimum token A to receive.
    /// @param amountBMin Minimum token B to receive.
    /// @param to Recipient of both tokens.
    /// @param deadline Last valid block timestamp.
    /// @return amountA Token A received.
    /// @return amountB Token B received.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    /// @notice `removeLiquidity` for fee-on-transfer tokens: the minimums are checked against what `to` actually
    ///         received (balance deltas), not against what the pair sent.
    /// @param tokenA One token.
    /// @param tokenB The other token.
    /// @param liquidity LP tokens to burn.
    /// @param amountAMin Minimum token A credited to `to`.
    /// @param amountBMin Minimum token B credited to `to`.
    /// @param to Recipient of both tokens.
    /// @param deadline Last valid block timestamp.
    /// @return amountA Token A credited to `to`.
    /// @return amountB Token B credited to `to`.
    function removeLiquiditySupportingFeeOnTransferTokens(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    /// @notice `removeLiquidity` authorised by an EIP-2612 signature instead of a prior `approve`.
    /// @dev Tolerates a front-run permit: if `permit` reverts but the allowance is already sufficient
    ///      (someone submitted the same signature first), the removal proceeds.
    /// @param tokenA One token.
    /// @param tokenB The other token.
    /// @param liquidity LP tokens to burn.
    /// @param amountAMin Minimum token A to receive.
    /// @param amountBMin Minimum token B to receive.
    /// @param to Recipient of both tokens.
    /// @param deadline Last valid block timestamp; also the permit deadline.
    /// @param approveMax Whether the signature approves type(uint256).max instead of `liquidity`.
    /// @param v Signature v.
    /// @param r Signature r.
    /// @param s Signature s.
    /// @return amountA Token A received.
    /// @return amountB Token B received.
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
    ) external returns (uint256 amountA, uint256 amountB);

    /// @notice Swaps an exact input along `path`, reverting if the final output is below `amountOutMin`.
    /// @param amountIn Exact input.
    /// @param amountOutMin Minimum final output.
    /// @param path Token path (at least two tokens, each adjacent pair must exist).
    /// @param to Recipient of the final output.
    /// @param deadline Last valid block timestamp.
    /// @return amounts Input and the output of every hop.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Swaps for an exact output along `path`, reverting if the required input exceeds `amountInMax`.
    /// @param amountOut Exact final output.
    /// @param amountInMax Maximum input.
    /// @param path Token path (at least two tokens, each adjacent pair must exist).
    /// @param to Recipient of the final output.
    /// @param deadline Last valid block timestamp.
    /// @return amounts Required input and the output of every hop.
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Exact-input swap for tokens that take a fee on transfer: each hop prices the amount the pair
    ///         actually received, and the minimum is checked against what `to` actually received.
    /// @param amountIn Amount pulled from the caller (before any transfer fee).
    /// @param amountOutMin Minimum final amount credited to `to`.
    /// @param path Token path (at least two tokens, each adjacent pair must exist).
    /// @param to Recipient of the final output.
    /// @param deadline Last valid block timestamp.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    /// @notice amountA * reserveB / reserveA (no fee).
    /// @param amountA Amount of token A.
    /// @param reserveA Reserve of token A.
    /// @param reserveB Reserve of token B.
    /// @return amountB Equivalent amount of token B.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB);

    /// @notice Single-hop exact-input quote after the 0.30 % fee.
    /// @param amountIn Exact input.
    /// @param reserveIn Input reserve.
    /// @param reserveOut Output reserve.
    /// @return amountOut Output, rounded down.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);

    /// @notice Single-hop exact-output quote after the 0.30 % fee.
    /// @param amountOut Exact output.
    /// @param reserveIn Input reserve.
    /// @param reserveOut Output reserve.
    /// @return amountIn Input, rounded up.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn);

    /// @notice Multi-hop exact-input quote against current reserves.
    /// @param amountIn Exact input.
    /// @param path Token path.
    /// @return amounts Input and the output of every hop.
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    /// @notice Multi-hop exact-output quote against current reserves.
    /// @param amountOut Exact final output.
    /// @param path Token path.
    /// @return amounts Required input and the output of every hop.
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}
