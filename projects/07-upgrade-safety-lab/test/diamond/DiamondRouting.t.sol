// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryDiamond} from "../../src/diamond/RegistryDiamond.sol";
import {ISubscriptionRegistry} from "../../src/interfaces/IRegistry.sol";
import {LabBase} from "../utils/LabBase.sol";

/// @notice The routing table that is actually cut (`DiamondSelectors`, shared by the deployment script and every
///         test) serves the whole shared API. The layout gate checks the same thing statically against the facet
///         ABIs; this test checks the deployed table.
contract DiamondRoutingTest is LabBase {
    /// @dev Every function of `ISubscriptionRegistry`. `test_apiListIsExactlyTheInterface` ties this list to the
    ///      compiler's own view of the interface, so it cannot silently miss or invent a function.
    function _api() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](28);
        s[0] = ISubscriptionRegistry.createPlan.selector;
        s[1] = ISubscriptionRegistry.setPlanActive.selector;
        s[2] = ISubscriptionRegistry.setPlanPrice.selector;
        s[3] = ISubscriptionRegistry.subscribe.selector;
        s[4] = ISubscriptionRegistry.subscribeWithMaxPrice.selector;
        s[5] = ISubscriptionRegistry.cancel.selector;
        s[6] = ISubscriptionRegistry.setGracePeriod.selector;
        s[7] = ISubscriptionRegistry.setTreasury.selector;
        s[8] = ISubscriptionRegistry.pause.selector;
        s[9] = ISubscriptionRegistry.unpause.selector;
        s[10] = ISubscriptionRegistry.transferOwnership.selector;
        s[11] = ISubscriptionRegistry.acceptOwnership.selector;
        s[12] = ISubscriptionRegistry.renounceOwnership.selector;
        s[13] = ISubscriptionRegistry.owner.selector;
        s[14] = ISubscriptionRegistry.pendingOwner.selector;
        s[15] = ISubscriptionRegistry.planCount.selector;
        s[16] = ISubscriptionRegistry.plan.selector;
        s[17] = ISubscriptionRegistry.planPrice.selector;
        s[18] = ISubscriptionRegistry.subscriptionOf.selector;
        s[19] = ISubscriptionRegistry.isActive.selector;
        s[20] = ISubscriptionRegistry.renewalsOf.selector;
        s[21] = ISubscriptionRegistry.totalSubscriptions.selector;
        s[22] = ISubscriptionRegistry.gracePeriod.selector;
        s[23] = ISubscriptionRegistry.paused.selector;
        s[24] = ISubscriptionRegistry.paymentToken.selector;
        s[25] = ISubscriptionRegistry.treasury.selector;
        s[26] = ISubscriptionRegistry.totalRevenue.selector;
        s[27] = ISubscriptionRegistry.version.selector;
    }

    /// @notice ERC-165 interface ids are the XOR of every function selector the interface declares (the inherited
    ///         event and error interfaces declare none), so equality proves the list above is exact.
    function test_apiListIsExactlyTheInterface() public pure {
        bytes4[] memory api = _api();
        bytes4 folded;
        for (uint256 i; i < api.length; ++i) {
            folded ^= api[i];
            for (uint256 j = i + 1; j < api.length; ++j) {
                assertTrue(api[i] != api[j], "duplicate");
            }
        }
        assertEq(folded, type(ISubscriptionRegistry).interfaceId);
    }

    function test_deployedRoutingTableServesEveryApiFunction() public {
        (RegistryDiamond diamond, DiamondFacets memory f) = _deployDiamond(owner, _newToken(), treasury);
        bytes4[] memory api = _api();
        for (uint256 i; i < api.length; ++i) {
            address facet = diamond.facetAddress(api[i]);
            assertTrue(facet != address(0), "routed");
            assertTrue(facet != address(diamond), "served by a facet, not an immutable function");
        }
        // Spot checks that the shared table routes to the facet that implements the function.
        assertEq(diamond.facetAddress(ISubscriptionRegistry.subscribeWithMaxPrice.selector), address(f.subscription));
        assertEq(diamond.facetAddress(ISubscriptionRegistry.owner.selector), address(f.ownership));
        assertEq(diamond.facetAddress(ISubscriptionRegistry.version.selector), address(f.admin));
    }
}
