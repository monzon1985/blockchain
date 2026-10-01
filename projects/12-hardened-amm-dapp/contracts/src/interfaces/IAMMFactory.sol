// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-core IUniswapV2Factory.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

/// @title IAMMFactory
/// @notice Deploys one constant-product pair per unordered token pair and holds the protocol-fee recipient.
interface IAMMFactory {
    /// @notice Emitted once per pair. Same signature as Uniswap v2 so existing indexers keep working.
    /// @param token0 The lower-sorted token of the pair.
    /// @param token1 The higher-sorted token of the pair.
    /// @param pair The CREATE2 address of the new pair.
    /// @param pairCount The number of pairs after this one was created (1-based index).
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);

    /// @notice Emitted when the owner changes the protocol-fee recipient.
    /// @param previousFeeTo The recipient before the change (zero means the fee was off).
    /// @param newFeeTo The recipient after the change (zero switches the fee off).
    event FeeToUpdated(address indexed previousFeeTo, address indexed newFeeTo);

    /// @notice Both sides of the requested pair are the same token.
    /// @param token The duplicated token address.
    error IdenticalAddresses(address token);

    /// @notice One side of the requested pair is the zero address.
    error ZeroAddress();

    /// @notice The pair already exists.
    /// @param pair The existing pair address.
    error PairExists(address pair);

    /// @notice A token of the requested pair has no code, so no ERC-20 transfer to or from it can be verified.
    /// @param token The address without code.
    error TokenHasNoCode(address token);

    /// @notice Protocol-fee recipient. Zero means the protocol fee is switched off.
    /// @return The current recipient of the 1/6 share of LP fee growth.
    function feeTo() external view returns (address);

    /// @notice keccak256 of the pair creation code. Routers use it to derive pair addresses without a call.
    /// @return The init-code hash every pair is deployed with.
    // slither-disable-next-line naming-convention -- Uniswap-style name for a constant-like value
    function PAIR_INIT_CODE_HASH() external view returns (bytes32);

    /// @notice Pair address for a token pair, in either order; zero if it does not exist.
    /// @param tokenA One token of the pair.
    /// @param tokenB The other token of the pair.
    /// @return pair The pair address or zero.
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /// @notice Pair address by creation index.
    /// @param index Zero-based creation index.
    /// @return pair The pair created at `index`.
    function allPairs(uint256 index) external view returns (address pair);

    /// @notice Number of pairs created so far.
    /// @return The length of `allPairs`.
    function allPairsLength() external view returns (uint256);

    /// @notice Token pair of the pair currently being constructed. Only non-zero inside `createPair`.
    /// @dev Read by the pair constructor so that `token0`/`token1` can be immutables while the init code
    ///      (and therefore the CREATE2 address) stays independent of the tokens.
    /// @return token0 The lower-sorted token of the pair under construction.
    /// @return token1 The higher-sorted token of the pair under construction.
    function parameters() external view returns (address token0, address token1);

    /// @notice Deploys the pair for `tokenA`/`tokenB` with CREATE2 (salt = keccak256(token0, token1)).
    /// @param tokenA One token of the pair.
    /// @param tokenB The other token of the pair.
    /// @return pair The new pair address.
    function createPair(address tokenA, address tokenB) external returns (address pair);

    /// @notice Sets the protocol-fee recipient. Owner only.
    /// @param newFeeTo The new recipient; zero switches the protocol fee off.
    function setFeeTo(address newFeeTo) external;
}
