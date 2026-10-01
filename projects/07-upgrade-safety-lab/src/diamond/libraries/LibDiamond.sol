// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IDiamondCut, IERC8109Introspection} from "../interfaces/IDiamond.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @dev ERC-7201 base slot of the selector table, computed by the `erc7201` builtin.
uint256 constant DIAMOND_STORAGE_LOCATION = erc7201("upgradelab.storage.Diamond");

/// @title LibDiamond
/// @notice Selector table and cut logic of the registry diamond (ERC-2535 semantics, ERC-8109 events).
/// @dev Invariants maintained by every function below:
///      - `selectors` holds each registered selector exactly once;
///      - `facetAndPosition[s].position` is the index of `s` in `selectors`;
///      - a selector whose facet is the diamond itself is immutable (never replaced or removed).
library LibDiamond {
    /// @notice Where a selector is served and where it sits in the enumeration array.
    /// @param facet Facet address (the diamond itself for immutable functions).
    /// @param position Index in `DiamondStorage.selectors`.
    struct FacetAndPosition {
        address facet;
        uint96 position;
    }

    /// @notice The diamond's routing table.
    /// @param facetAndPosition Facet and array position per selector.
    /// @param selectors Every registered selector (enumeration for the loupe).
    /// @param supportedInterfaces ERC-165 interface ids the diamond reports as supported.
    /// @custom:storage-location erc7201:upgradelab.storage.Diamond
    struct DiamondStorage {
        mapping(bytes4 selector => FacetAndPosition) facetAndPosition;
        bytes4[] selectors;
        mapping(bytes4 interfaceId => bool) supportedInterfaces;
    }

    /// @notice A cut step carried no selectors.
    /// @param facet The facet of the empty step.
    error EmptySelectorList(address facet);

    /// @notice The facet has no code or is the diamond itself.
    /// @param facet The rejected facet.
    error InvalidFacet(address facet);

    /// @notice Add of a selector that is already registered (a duplicate or a 4-byte collision).
    /// @param selector The clashing selector.
    /// @param existingFacet The facet that already serves it.
    error SelectorAlreadyExists(bytes4 selector, address existingFacet);

    /// @notice Replace or Remove of a selector that is not registered.
    /// @param selector The unknown selector.
    error SelectorNotFound(bytes4 selector);

    /// @notice Replace with the facet that already serves the selector.
    /// @param selector The selector.
    /// @param facet The unchanged facet.
    error ReplaceWithSameFacet(bytes4 selector, address facet);

    /// @notice Replace or Remove of a function compiled into the diamond itself.
    /// @param selector The immutable selector.
    error ImmutableFunction(bytes4 selector);

    /// @notice A Remove step named a facet; ERC-2535 requires the zero address.
    /// @param facet The non-zero facet address.
    error RemoveFacetAddressMustBeZero(address facet);

    /// @notice `_init` is zero but `_calldata` is not empty.
    /// @param dataLength Length of the orphaned calldata.
    error InitCalldataWithoutInit(uint256 dataLength);

    /// @notice `_init` has no code.
    /// @param init The rejected initialization contract.
    error InitHasNoCode(address init);

    /// @notice Returns a storage pointer to the routing table.
    /// @return $ The ERC-7201 namespace `upgradelab.storage.Diamond`.
    function diamondStorage() internal pure returns (DiamondStorage storage $) {
        uint256 location = DIAMOND_STORAGE_LOCATION;
        // Only assigns the slot of a storage pointer; no memory or storage is touched.
        assembly {
            $.slot := location
        }
    }

    // Cuts are atomic: validation must revert on the first offending selector, inside the loop that applies
    // the step, so the error carries that selector.
    // forge-lint: disable-start(require-revert-in-loop)

    /// @notice Registers functions implemented by the diamond contract itself (ERC-8109 immutable functions).
    /// @param selectors Selectors of the diamond's own external functions.
    function addImmutableFunctions(bytes4[] memory selectors) internal {
        DiamondStorage storage $ = diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address existing = $.facetAndPosition[selector].facet;
            if (existing != address(0)) revert SelectorAlreadyExists(selector, existing);
            _register($, selector, address(this));
        }
    }

    /// @notice Applies an ERC-2535 cut and runs the optional initializer.
    /// @param cuts Steps to apply, in order.
    /// @param init Contract to delegatecall afterwards, or zero.
    /// @param data Calldata for `init`.
    function diamondCut(IDiamondCut.FacetCut[] memory cuts, address init, bytes memory data) internal {
        for (uint256 i; i < cuts.length; ++i) {
            IDiamondCut.FacetCut memory cut = cuts[i];
            if (cut.functionSelectors.length == 0) revert EmptySelectorList(cut.facetAddress);
            if (cut.action == IDiamondCut.FacetCutAction.Add) {
                _add(cut.facetAddress, cut.functionSelectors);
            } else if (cut.action == IDiamondCut.FacetCutAction.Replace) {
                _replace(cut.facetAddress, cut.functionSelectors);
            } else {
                _remove(cut.facetAddress, cut.functionSelectors);
            }
        }
        emit IDiamondCut.DiamondCut(cuts, init, data);
        _initialize(init, data);
    }

    /// @dev Add: every selector must be new.
    function _add(address facet, bytes4[] memory selectors) private {
        _requireFacet(facet);
        DiamondStorage storage $ = diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address existing = $.facetAndPosition[selector].facet;
            if (existing != address(0)) revert SelectorAlreadyExists(selector, existing);
            _register($, selector, facet);
        }
    }

    /// @dev Replace: every selector must exist, be mutable, and move to a different facet.
    function _replace(address facet, bytes4[] memory selectors) private {
        _requireFacet(facet);
        DiamondStorage storage $ = diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address oldFacet = $.facetAndPosition[selector].facet;
            if (oldFacet == address(0)) revert SelectorNotFound(selector);
            if (oldFacet == address(this)) revert ImmutableFunction(selector);
            if (oldFacet == facet) revert ReplaceWithSameFacet(selector, facet);
            $.facetAndPosition[selector].facet = facet;
            emit IERC8109Introspection.DiamondFunctionReplaced(selector, oldFacet, facet);
        }
    }

    /// @dev Remove: facet must be zero; every selector must exist and be mutable. Swap-and-pop keeps the
    ///      enumeration array dense.
    function _remove(address facet, bytes4[] memory selectors) private {
        if (facet != address(0)) revert RemoveFacetAddressMustBeZero(facet);
        DiamondStorage storage $ = diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            FacetAndPosition memory info = $.facetAndPosition[selector];
            if (info.facet == address(0)) revert SelectorNotFound(selector);
            if (info.facet == address(this)) revert ImmutableFunction(selector);

            uint256 lastIndex = $.selectors.length - 1;
            if (info.position != lastIndex) {
                bytes4 lastSelector = $.selectors[lastIndex];
                $.selectors[info.position] = lastSelector;
                $.facetAndPosition[lastSelector].position = info.position;
            }
            $.selectors.pop();
            delete $.facetAndPosition[selector];
            emit IERC8109Introspection.DiamondFunctionRemoved(selector, info.facet);
        }
    }

    /// @dev Appends a selector to the table and emits the ERC-8109 event.
    function _register(DiamondStorage storage $, bytes4 selector, address facet) private {
        // A diamond cannot hold 2^96 selectors (each costs a storage write), so the position always fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        $.facetAndPosition[selector] = FacetAndPosition({facet: facet, position: uint96($.selectors.length)});
        $.selectors.push(selector);
        emit IERC8109Introspection.DiamondFunctionAdded(selector, facet);
    }

    /// @dev Rejects facets without code and the diamond itself (which would make the fallback recurse).
    function _requireFacet(address facet) private view {
        if (facet == address(this) || facet.code.length == 0) revert InvalidFacet(facet);
    }

    // forge-lint: disable-end(require-revert-in-loop)

    // slither-disable-start unused-return
    /// @dev Delegatecalls the initializer, bubbling its revert reason (OpenZeppelin `Address`).
    function _initialize(address init, bytes memory data) private {
        if (init == address(0)) {
            if (data.length != 0) revert InitCalldataWithoutInit(data.length);
            return;
        }
        if (init.code.length == 0) revert InitHasNoCode(init);
        emit IERC8109Introspection.DiamondDelegateCall(init, data);
        // The initializer's return data carries no meaning for a cut; failures revert inside Address.
        Address.functionDelegateCall(init, data);
    }
    // slither-disable-end unused-return
}
