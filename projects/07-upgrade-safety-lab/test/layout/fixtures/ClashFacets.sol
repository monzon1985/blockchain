// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Selector-clash fixtures. `burn(uint256)` and `collate_propagate_storage(bytes16)` are a well-known
///         4-byte collision: both hash to 0x42966c68. The build-time detector (`layout-diff selectors`, driven by
///         `scripts/check-layouts.mjs`) must reject this facet set, and `diamondCut` must reject it at runtime.
contract ClashFacetA {
    /// @notice Stand-in token burn.
    function burn(uint256) external pure returns (string memory) {
        return "A.burn";
    }
}

/// @notice The colliding facet.
contract ClashFacetB {
    /// @notice Different signature, same selector as `ClashFacetA.burn(uint256)`.
    function collate_propagate_storage(bytes16) external pure returns (string memory) {
        return "B.collate_propagate_storage";
    }
}

/// @notice A facet that re-declares a function another facet already serves (a duplicate, not a collision).
contract DuplicateOwnerFacet {
    /// @notice Same signature as `OwnershipFacet.owner()`.
    function owner() external pure returns (address) {
        return address(0xdead);
    }
}
