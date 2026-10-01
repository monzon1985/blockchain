// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IDiamondCut, IERC8109Introspection} from "./interfaces/IDiamond.sol";
import {LibDiamond} from "./libraries/LibDiamond.sol";
import {LibOwnership} from "./libraries/LibOwnership.sol";

/// @title RegistryDiamond
/// @notice The subscription registry rebuilt as an ERC-2535 diamond. Functions are routed by selector to facets;
///         all state lives in ERC-7201 namespaces of this contract.
/// @dev The two ERC-8109 introspection functions are compiled into the diamond and registered as immutable
///      functions (facet = the diamond itself): no cut can ever blind off-chain tooling, while `diamondCut`
///      itself stays a removable facet function, so removing it freezes the diamond for good.
contract RegistryDiamond is IERC8109Introspection {
    /// @notice Sets the owner, registers the immutable introspection functions and applies the initial cut.
    /// @param initialOwner Owner allowed to cut the diamond and administer plans.
    /// @param cuts Initial facets (normally DiamondCutFacet, DiamondLoupeFacet, OwnershipFacet and the app facets).
    /// @param init Contract delegatecalled once after the cut (for example `DiamondInit`), or zero.
    /// @param initCalldata Calldata for `init`.
    constructor(address initialOwner, IDiamondCut.FacetCut[] memory cuts, address init, bytes memory initCalldata) {
        if (initialOwner == address(0)) revert LibOwnership.OwnableInvalidOwner(address(0));
        LibOwnership.setOwner(initialOwner);

        bytes4[] memory immutableSelectors = new bytes4[](2);
        immutableSelectors[0] = IERC8109Introspection.facetAddress.selector;
        immutableSelectors[1] = IERC8109Introspection.functionFacetPairs.selector;
        LibDiamond.addImmutableFunctions(immutableSelectors);

        LibDiamond.diamondCut(cuts, init, initCalldata);
    }

    /// @notice Routes every call without a compiled function to the facet registered for its selector.
    /// @dev Reverts with `FunctionNotFound(msg.sig)` for unknown selectors (ERC-8109), including plain ETH
    ///      transfers (selector 0x00000000).
    fallback() external payable {
        address facet = LibDiamond.diamondStorage().facetAndPosition[msg.sig].facet;
        if (facet == address(0)) revert FunctionNotFound(msg.sig);
        // Forwards calldata to the facet with delegatecall and returns or reverts with its returndata verbatim.
        // Memory from offset 0 is used as scratch space because this frame never returns to Solidity code.
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @notice Plain ETH transfers carry selector 0x00000000, which no facet serves.
    receive() external payable {
        revert FunctionNotFound(bytes4(0));
    }

    /// @inheritdoc IERC8109Introspection
    function facetAddress(bytes4 _functionSelector) external view returns (address) {
        return LibDiamond.diamondStorage().facetAndPosition[_functionSelector].facet;
    }

    /// @inheritdoc IERC8109Introspection
    function functionFacetPairs() external view returns (FunctionFacetPair[] memory pairs) {
        LibDiamond.DiamondStorage storage $ = LibDiamond.diamondStorage();
        uint256 count = $.selectors.length;
        pairs = new FunctionFacetPair[](count);
        for (uint256 i; i < count; ++i) {
            bytes4 selector = $.selectors[i];
            pairs[i] = FunctionFacetPair({selector: selector, facet: $.facetAndPosition[selector].facet});
        }
    }
}
