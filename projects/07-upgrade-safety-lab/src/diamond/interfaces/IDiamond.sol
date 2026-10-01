// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IDiamondCut (ERC-2535)
/// @notice The ERC-2535 upgrade function, unchanged so existing diamond tooling can drive this diamond.
interface IDiamondCut {
    /// @notice What a cut does with its selectors: Add = 0, Replace = 1, Remove = 2.
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    /// @notice One step of a cut.
    /// @param facetAddress Facet implementing the selectors (must be zero for Remove).
    /// @param action Add, Replace or Remove.
    /// @param functionSelectors Selectors the step applies to.
    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice ERC-2535 event describing a whole cut; emitted alongside the ERC-8109 per-function events.
    /// @param _diamondCut The applied steps.
    /// @param _init Contract delegatecalled after the cut (zero when none).
    /// @param _calldata Calldata of that delegatecall.
    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);

    /// @notice Adds, replaces and removes functions, then optionally delegatecalls `_init` with `_calldata`.
    /// @param _diamondCut The steps to apply, in order.
    /// @param _init Contract to delegatecall after the cut, or zero.
    /// @param _calldata Calldata for `_init`.
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external;
}

/// @title IDiamondLoupe (ERC-2535)
/// @notice The ERC-2535 introspection functions. `facetAddress` is served by the diamond itself as an immutable
///         function (see `IERC8109Introspection`); the other three live in `DiamondLoupeFacet`.
interface IDiamondLoupe {
    /// @notice A facet and the selectors it serves.
    /// @param facetAddress The facet.
    /// @param functionSelectors Its selectors.
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice Every facet with its selectors (the diamond itself appears for its immutable functions).
    /// @return facets_ The facets.
    function facets() external view returns (Facet[] memory facets_);

    /// @notice Selectors served by a facet.
    /// @param _facet The facet.
    /// @return facetFunctionSelectors_ Its selectors.
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_);

    /// @notice Every facet address.
    /// @return facetAddresses_ The facets.
    function facetAddresses() external view returns (address[] memory facetAddresses_);

    /// @notice Facet that serves a selector, or zero.
    /// @param _functionSelector The selector.
    /// @return facetAddress_ The facet.
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}

/// @title ERC-8109 introspection and events
/// @notice The simplifications of ERC-8109 ("Diamonds, Simplified") adopted by this diamond: per-function events
///         instead of only the monolithic `DiamondCut`, and a single `functionFacetPairs` enumeration.
/// @dev ERC-8109 was withdrawn in favour of ERC-8153 while this lab was written; the adopted parts are the ones the
///      draft specified explicitly, and they remain compatible with ERC-2535 tooling.
interface IERC8109Introspection {
    /// @notice A selector and the facet that serves it.
    /// @param selector The function selector.
    /// @param facet The facet (the diamond itself for immutable functions).
    struct FunctionFacetPair {
        bytes4 selector;
        address facet;
    }

    /// @notice A function was added.
    /// @param _selector The selector.
    /// @param _facet The facet that now serves it.
    event DiamondFunctionAdded(bytes4 indexed _selector, address indexed _facet);

    /// @notice A function moved to another facet.
    /// @param _selector The selector.
    /// @param _oldFacet The facet that served it before.
    /// @param _newFacet The facet that serves it now.
    event DiamondFunctionReplaced(bytes4 indexed _selector, address indexed _oldFacet, address indexed _newFacet);

    /// @notice A function was removed.
    /// @param _selector The selector.
    /// @param _oldFacet The facet that served it.
    event DiamondFunctionRemoved(bytes4 indexed _selector, address indexed _oldFacet);

    /// @notice A cut delegatecalled an initialization contract.
    /// @param _delegate The delegatecalled contract.
    /// @param _delegateCalldata The calldata it received.
    event DiamondDelegateCall(address indexed _delegate, bytes _delegateCalldata);

    /// @notice No facet serves the selector (ERC-8109 fallback error).
    /// @param _selector The unknown selector.
    error FunctionNotFound(bytes4 _selector);

    /// @notice Facet that serves a selector, or zero.
    /// @param _functionSelector The selector.
    /// @return The facet.
    function facetAddress(bytes4 _functionSelector) external view returns (address);

    /// @notice Every registered selector with its facet, in registration order (removals swap-and-pop).
    /// @return pairs The pairs.
    function functionFacetPairs() external view returns (FunctionFacetPair[] memory pairs);
}
