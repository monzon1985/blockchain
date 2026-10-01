// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IDiamondCut} from "../interfaces/IDiamond.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibOwnership} from "../libraries/LibOwnership.sol";

/// @title DiamondCutFacet
/// @notice The ERC-2535 upgrade function. Owner-only; the owner can be an AccessManager (or any timelock) so that
///         cuts inherit its delay and cancellation (`DiamondTimelock.t.sol`). Removing this facet's selector
///         makes the diamond immutable.
contract DiamondCutFacet is IDiamondCut {
    /// @inheritdoc IDiamondCut
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external {
        LibOwnership.enforceIsOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }
}
