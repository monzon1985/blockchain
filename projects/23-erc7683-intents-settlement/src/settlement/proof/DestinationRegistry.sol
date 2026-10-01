// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";

import {ISettlementModule} from "../../interfaces/ISettlementModule.sol";

/// @title DestinationRegistry
/// @notice Write-once map of destination chain id to the DestinationSettler whose storage a proof-based module reads.
/// @dev Write-once matters: re-pointing a chain to another contract after orders were opened would let the admin
///      "prove" fills against storage it controls. Once set, the admin has no further power over the module.
abstract contract DestinationRegistry is ISettlementModule, AccessManaged {
    /// @dev DestinationSettler by chain id.
    mapping(uint256 chainId => address settler) internal _destinationSettlers;

    /// @notice Emitted when a destination settler is registered.
    /// @param chainId The destination chain.
    /// @param settler The DestinationSettler on that chain.
    event DestinationSettlerSet(uint256 indexed chainId, address indexed settler);

    /// @notice The chain already has a settler.
    /// @param chainId The destination chain.
    error DestinationSettlerAlreadySet(uint256 chainId);
    /// @notice The settler address is zero.
    error ZeroDestinationSettler();
    /// @notice The chain has no settler.
    /// @param chainId The destination chain.
    error UnknownDestinationChain(uint256 chainId);

    /// @param authority AccessManager governing `setDestinationSettler`.
    constructor(address authority) AccessManaged(authority) {}

    /// @notice Registers, once, the DestinationSettler of `chainId`.
    /// @param chainId The destination chain.
    /// @param settler The DestinationSettler on that chain.
    function setDestinationSettler(uint256 chainId, address settler) external restricted {
        require(settler != address(0), ZeroDestinationSettler());
        require(_destinationSettlers[chainId] == address(0), DestinationSettlerAlreadySet(chainId));
        _destinationSettlers[chainId] = settler;
        // The only prior external call is AccessManager.canCall, made by the `restricted` modifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit DestinationSettlerSet(chainId, settler);
    }

    /// @inheritdoc ISettlementModule
    function destinationSettler(uint256 chainId) external view returns (address) {
        return _destinationSettlers[chainId];
    }

    /// @dev Registered settler of `chainId`; reverts if none.
    function _settlerOf(uint256 chainId) internal view returns (address settler) {
        settler = _destinationSettlers[chainId];
        require(settler != address(0), UnknownDestinationChain(chainId));
    }
}
