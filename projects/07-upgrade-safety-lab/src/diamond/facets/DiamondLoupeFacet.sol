// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IDiamondLoupe} from "../interfaces/IDiamond.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title DiamondLoupeFacet
/// @notice The ERC-2535 loupe functions that ERC-8109 dropped (`facets`, `facetFunctionSelectors`,
///         `facetAddresses`) plus ERC-165. `facetAddress` is an immutable function of the diamond itself.
/// @dev These views are O(n^2) in the number of selectors; they are meant for off-chain callers.
contract DiamondLoupeFacet is IERC165 {
    /// @notice Every facet with its selectors, in first-registration order.
    /// @return facets_ The facets (the diamond itself appears for its immutable functions).
    function facets() external view returns (IDiamondLoupe.Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage $ = LibDiamond.diamondStorage();
        uint256 selectorCount = $.selectors.length;
        address[] memory addresses = new address[](selectorCount);
        uint256[] memory counts = new uint256[](selectorCount);
        bytes4[][] memory grouped = new bytes4[][](selectorCount);
        uint256 facetCount = 0;

        for (uint256 i; i < selectorCount; ++i) {
            bytes4 selector = $.selectors[i];
            address facet = $.facetAndPosition[selector].facet;
            uint256 index = _indexOf(addresses, facetCount, facet);
            if (index == facetCount) {
                addresses[facetCount] = facet;
                grouped[facetCount] = new bytes4[](selectorCount);
                ++facetCount;
            }
            grouped[index][counts[index]++] = selector;
        }

        facets_ = new IDiamondLoupe.Facet[](facetCount);
        for (uint256 i; i < facetCount; ++i) {
            bytes4[] memory selectors = grouped[i];
            uint256 count = counts[i];
            // Shrinks the over-allocated array in place: `count` never exceeds the allocated length.
            assembly ("memory-safe") {
                mstore(selectors, count)
            }
            facets_[i] = IDiamondLoupe.Facet({facetAddress: addresses[i], functionSelectors: selectors});
        }
    }

    /// @notice Selectors served by a facet.
    /// @param _facet The facet.
    /// @return facetFunctionSelectors_ Its selectors, in registration order.
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_) {
        LibDiamond.DiamondStorage storage $ = LibDiamond.diamondStorage();
        uint256 selectorCount = $.selectors.length;
        facetFunctionSelectors_ = new bytes4[](selectorCount);
        uint256 count = 0;
        for (uint256 i; i < selectorCount; ++i) {
            bytes4 selector = $.selectors[i];
            if ($.facetAndPosition[selector].facet == _facet) facetFunctionSelectors_[count++] = selector;
        }
        // Shrinks the over-allocated array in place: `count` never exceeds the allocated length.
        assembly ("memory-safe") {
            mstore(facetFunctionSelectors_, count)
        }
    }

    /// @notice Every facet address, in first-registration order.
    /// @return facetAddresses_ The facets.
    function facetAddresses() external view returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage $ = LibDiamond.diamondStorage();
        uint256 selectorCount = $.selectors.length;
        facetAddresses_ = new address[](selectorCount);
        uint256 count = 0;
        for (uint256 i; i < selectorCount; ++i) {
            address facet = $.facetAndPosition[$.selectors[i]].facet;
            if (_indexOf(facetAddresses_, count, facet) == count) facetAddresses_[count++] = facet;
        }
        // Shrinks the over-allocated array in place: `count` never exceeds the allocated length.
        assembly ("memory-safe") {
            mstore(facetAddresses_, count)
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return LibDiamond.diamondStorage().supportedInterfaces[interfaceId];
    }

    /// @dev Linear search over the first `length` entries; returns `length` when absent.
    function _indexOf(address[] memory list, uint256 length, address item) private pure returns (uint256) {
        for (uint256 i; i < length; ++i) {
            if (list[i] == item) return i;
        }
        return length;
    }
}
