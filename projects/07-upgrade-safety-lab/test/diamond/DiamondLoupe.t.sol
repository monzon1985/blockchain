// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryDiamond} from "../../src/diamond/RegistryDiamond.sol";
import {AdminFacet} from "../../src/diamond/facets/AdminFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {PlanFacet} from "../../src/diamond/facets/PlanFacet.sol";
import {IDiamondCut, IDiamondLoupe, IERC8109Introspection} from "../../src/diamond/interfaces/IDiamond.sol";
import {LabBase} from "../utils/LabBase.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Loupe (ERC-2535) and introspection (ERC-8109) views agree with each other after any cut sequence.
contract DiamondLoupeTest is LabBase {
    RegistryDiamond internal diamond;
    DiamondFacets internal f;

    // Diamond (2 immutable) + cut (1) + loupe (4) + ownership (5) + plan (6) + subscription (7) + admin (10).
    uint256 internal constant INITIAL_SELECTORS = 35;

    function setUp() public {
        (diamond, f) = _deployDiamond(owner, _newToken(), treasury);
    }

    function _loupe() internal view returns (DiamondLoupeFacet) {
        return DiamondLoupeFacet(address(diamond));
    }

    function test_initialTable() public view {
        IERC8109Introspection.FunctionFacetPair[] memory pairs = diamond.functionFacetPairs();
        assertEq(pairs.length, INITIAL_SELECTORS);

        IDiamondLoupe.Facet[] memory facets = _loupe().facets();
        assertEq(facets.length, 7);
        assertEq(facets[0].facetAddress, address(diamond), "immutable functions are served by the diamond");
        assertEq(facets[0].functionSelectors.length, 2);
        assertEq(facets[1].facetAddress, address(f.cut));
        assertEq(facets[6].facetAddress, address(f.admin));
        assertEq(facets[6].functionSelectors.length, 10);

        address[] memory addresses = _loupe().facetAddresses();
        assertEq(addresses.length, 7);
        assertEq(_loupe().facetFunctionSelectors(address(f.plan)).length, 6);
        assertEq(_loupe().facetFunctionSelectors(address(0xdead)).length, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(_loupe().supportsInterface(type(IERC165).interfaceId));
        assertTrue(_loupe().supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(_loupe().supportsInterface(type(IDiamondLoupe).interfaceId));
        assertEq(type(IDiamondCut).interfaceId, bytes4(0x1f931c1c));
        assertEq(type(IDiamondLoupe).interfaceId, bytes4(0x48e2b093));
        assertFalse(_loupe().supportsInterface(0xffffffff));
    }

    /// @notice Applies a random sequence of Add, Replace and Remove steps to the plan and admin selectors (each
    ///         selector moves between its original facet, a second deployment of the same facet, and "absent"),
    ///         then checks the table invariants: every selector routes where the model says, no duplicates,
    ///         `facetAddress` agrees with every pair, and the loupe's grouping covers exactly the pairs.
    function testFuzz_cutSequencesKeepTheTableConsistent(uint256 seed, uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 16));
        bytes4[] memory pool = _planAndAdminSelectors();
        address[2] memory planFacets = [address(f.plan), address(new PlanFacet())];
        address[2] memory adminFacets = [address(f.admin), address(new AdminFacet())];
        address[] memory routedTo = new address[](pool.length); // model: zero means removed
        for (uint256 i; i < pool.length; ++i) {
            routedTo[i] = i < 6 ? planFacets[0] : adminFacets[0];
        }

        for (uint256 r; r < rounds; ++r) {
            uint256 h = uint256(keccak256(abi.encode(seed, r)));
            uint256 idx = h % pool.length;
            address[2] memory pair = idx < 6 ? planFacets : adminFacets;
            bytes4[] memory one = new bytes4[](1);
            one[0] = pool[idx];
            IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
            if (routedTo[idx] == address(0)) {
                address to = pair[(h >> 8) % 2];
                cuts[0] = IDiamondCut.FacetCut(to, IDiamondCut.FacetCutAction.Add, one);
                routedTo[idx] = to;
            } else if ((h >> 8) % 2 == 0) {
                address to = routedTo[idx] == pair[0] ? pair[1] : pair[0];
                cuts[0] = IDiamondCut.FacetCut(to, IDiamondCut.FacetCutAction.Replace, one);
                routedTo[idx] = to;
            } else {
                cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
                routedTo[idx] = address(0);
            }
            vm.prank(owner);
            IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        }

        uint256 removedCount;
        for (uint256 i; i < pool.length; ++i) {
            assertEq(diamond.facetAddress(pool[i]), routedTo[i], "routed where the model says");
            if (routedTo[i] == address(0)) ++removedCount;
        }

        IERC8109Introspection.FunctionFacetPair[] memory pairs = diamond.functionFacetPairs();
        assertEq(pairs.length, INITIAL_SELECTORS - removedCount);
        for (uint256 i; i < pairs.length; ++i) {
            assertEq(diamond.facetAddress(pairs[i].selector), pairs[i].facet);
            for (uint256 j = i + 1; j < pairs.length; ++j) {
                assertTrue(pairs[i].selector != pairs[j].selector, "duplicate selector");
            }
        }

        uint256 grouped;
        IDiamondLoupe.Facet[] memory facets = _loupe().facets();
        for (uint256 i; i < facets.length; ++i) {
            grouped += facets[i].functionSelectors.length;
            assertTrue(facets[i].functionSelectors.length > 0, "no empty facet in the loupe");
            bytes4[] memory bySelectorQuery = _loupe().facetFunctionSelectors(facets[i].facetAddress);
            assertEq(bySelectorQuery.length, facets[i].functionSelectors.length);
            for (uint256 k; k < bySelectorQuery.length; ++k) {
                assertEq(diamond.facetAddress(bySelectorQuery[k]), facets[i].facetAddress);
            }
        }
        assertEq(grouped, pairs.length);
        assertEq(_loupe().facetAddresses().length, facets.length);
    }

    function _planAndAdminSelectors() internal pure returns (bytes4[] memory pool) {
        bytes4[] memory plan = _planSelectors();
        bytes4[] memory admin = _adminSelectors();
        pool = new bytes4[](plan.length + admin.length);
        for (uint256 i; i < plan.length; ++i) {
            pool[i] = plan[i];
        }
        for (uint256 i; i < admin.length; ++i) {
            pool[plan.length + i] = admin[i];
        }
    }
}
