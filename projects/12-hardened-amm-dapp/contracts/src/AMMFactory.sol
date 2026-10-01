// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-core UniswapV2Factory.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {AMMPair} from "./AMMPair.sol";
import {IAMMFactory} from "./interfaces/IAMMFactory.sol";

/// @title AMMFactory
/// @notice Permissionless pair deployment; the owner (two-step transfer) can only redirect the protocol fee.
/// @dev A compromised owner can at most divert the protocol fee (1/6 of LP fee growth, i.e. 0.05 % of volume)
///      to an address of its choice. It cannot pause, upgrade, move reserves or touch LP principal.
// slither-disable-next-line too-many-digits -- flags type(AMMPair).creationCode, not a literal
contract AMMFactory is IAMMFactory, Ownable2Step {
    /// @inheritdoc IAMMFactory
    // slither-disable-next-line naming-convention -- Uniswap-style name for a constant-like immutable
    bytes32 public immutable PAIR_INIT_CODE_HASH = keccak256(type(AMMPair).creationCode);

    /// @inheritdoc IAMMFactory
    address public feeTo;

    /// @inheritdoc IAMMFactory
    mapping(address tokenA => mapping(address tokenB => address pair)) public getPair;

    /// @inheritdoc IAMMFactory
    address[] public allPairs;

    /// @notice Token0 of the pair under construction; transient, so it is zero outside `createPair`.
    // slither-disable-next-line write-after-write -- set before and cleared after the CREATE2 on purpose
    address private transient _pendingToken0;

    /// @notice Token1 of the pair under construction; transient, so it is zero outside `createPair`.
    // slither-disable-next-line write-after-write -- set before and cleared after the CREATE2 on purpose
    address private transient _pendingToken1;

    /// @param initialOwner Account allowed to set the protocol-fee recipient.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IAMMFactory
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @inheritdoc IAMMFactory
    function parameters() external view returns (address token0, address token1) {
        return (_pendingToken0, _pendingToken1);
    }

    /// @inheritdoc IAMMFactory
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, IdenticalAddresses(tokenA));
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), ZeroAddress());
        address existing = getPair[token0][token1];
        require(existing == address(0), PairExists(existing));
        // A pair for an address without code could be created ahead of a counterfactual token deployment.
        require(token0.code.length != 0, TokenHasNoCode(token0));
        require(token1.code.length != 0, TokenHasNoCode(token1));

        _pendingToken0 = token0;
        _pendingToken1 = token1;
        pair = address(new AMMPair{salt: keccak256(abi.encodePacked(token0, token1))}());
        _pendingToken0 = address(0);
        _pendingToken1 = address(0);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate the reverse direction as well
        allPairs.push(pair);
        // forge-lint: disable-next-line(reentrancy-events) -- the only call is the constructor of our own pair
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @inheritdoc IAMMFactory
    /// @dev Zero is a valid value: it switches the protocol fee off.
    // slither-disable-start missing-zero-check
    // forge-lint: disable-next-line(missing-zero-check)
    function setFeeTo(address newFeeTo) external onlyOwner {
        emit FeeToUpdated(feeTo, newFeeTo);
        feeTo = newFeeTo;
    }
    // slither-disable-end missing-zero-check
}
