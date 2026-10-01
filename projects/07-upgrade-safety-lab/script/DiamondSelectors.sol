// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AdminFacet} from "../src/diamond/facets/AdminFacet.sol";
import {DiamondCutFacet} from "../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/diamond/facets/OwnershipFacet.sol";
import {PlanFacet} from "../src/diamond/facets/PlanFacet.sol";
import {SubscriptionFacet} from "../src/diamond/facets/SubscriptionFacet.sol";
import {IDiamondCut} from "../src/diamond/interfaces/IDiamond.sol";

/// @title DiamondSelectors
/// @notice The registry diamond's routing table: which selector is cut to which facet. There is exactly one copy:
///         the deployment script (`DeployDiamond.s.sol`) and every test (`LabBase`) build their cuts from it, and
///         the layout gate (`scripts/check-layouts.mjs`) reads this library's AST to build the selector-clash set
///         and the API-parity check. A facet function that is not listed here is not routed, whatever its ABI says.
library DiamondSelectors {
    /// @notice Selectors routed to `DiamondCutFacet`.
    /// @return s The selectors.
    function cutSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    /// @notice Selectors routed to `DiamondLoupeFacet`.
    /// @return s The selectors.
    function loupeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.supportsInterface.selector;
    }

    /// @notice Selectors routed to `OwnershipFacet`.
    /// @return s The selectors.
    function ownershipSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = OwnershipFacet.owner.selector;
        s[1] = OwnershipFacet.pendingOwner.selector;
        s[2] = OwnershipFacet.transferOwnership.selector;
        s[3] = OwnershipFacet.acceptOwnership.selector;
        s[4] = OwnershipFacet.renounceOwnership.selector;
    }

    /// @notice Selectors routed to `PlanFacet`.
    /// @return s The selectors.
    function planSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = PlanFacet.createPlan.selector;
        s[1] = PlanFacet.setPlanActive.selector;
        s[2] = PlanFacet.setPlanPrice.selector;
        s[3] = PlanFacet.planCount.selector;
        s[4] = PlanFacet.plan.selector;
        s[5] = PlanFacet.planPrice.selector;
    }

    /// @notice Selectors routed to `SubscriptionFacet`.
    /// @return s The selectors.
    function subscriptionSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = SubscriptionFacet.subscribe.selector;
        s[1] = SubscriptionFacet.subscribeWithMaxPrice.selector;
        s[2] = SubscriptionFacet.cancel.selector;
        s[3] = SubscriptionFacet.subscriptionOf.selector;
        s[4] = SubscriptionFacet.isActive.selector;
        s[5] = SubscriptionFacet.renewalsOf.selector;
        s[6] = SubscriptionFacet.totalSubscriptions.selector;
    }

    /// @notice Selectors routed to `AdminFacet`.
    /// @return s The selectors.
    function adminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = AdminFacet.setGracePeriod.selector;
        s[1] = AdminFacet.pause.selector;
        s[2] = AdminFacet.unpause.selector;
        s[3] = AdminFacet.setTreasury.selector;
        s[4] = AdminFacet.gracePeriod.selector;
        s[5] = AdminFacet.paused.selector;
        s[6] = AdminFacet.paymentToken.selector;
        s[7] = AdminFacet.treasury.selector;
        s[8] = AdminFacet.totalRevenue.selector;
        s[9] = AdminFacet.version.selector;
    }

    /// @notice The six `Add` steps of the initial cut, in deployment order.
    /// @param cut DiamondCutFacet address.
    /// @param loupe DiamondLoupeFacet address.
    /// @param ownership OwnershipFacet address.
    /// @param plan PlanFacet address.
    /// @param subscription SubscriptionFacet address.
    /// @param admin AdminFacet address.
    /// @return cuts The cut steps.
    function facetCuts(address cut, address loupe, address ownership, address plan, address subscription, address admin)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](6);
        cuts[0] = IDiamondCut.FacetCut(cut, IDiamondCut.FacetCutAction.Add, cutSelectors());
        cuts[1] = IDiamondCut.FacetCut(loupe, IDiamondCut.FacetCutAction.Add, loupeSelectors());
        cuts[2] = IDiamondCut.FacetCut(ownership, IDiamondCut.FacetCutAction.Add, ownershipSelectors());
        cuts[3] = IDiamondCut.FacetCut(plan, IDiamondCut.FacetCutAction.Add, planSelectors());
        cuts[4] = IDiamondCut.FacetCut(subscription, IDiamondCut.FacetCutAction.Add, subscriptionSelectors());
        cuts[5] = IDiamondCut.FacetCut(admin, IDiamondCut.FacetCutAction.Add, adminSelectors());
    }
}
