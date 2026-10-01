// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DiamondInit} from "../src/diamond/DiamondInit.sol";
import {RegistryDiamond} from "../src/diamond/RegistryDiamond.sol";
import {AdminFacet} from "../src/diamond/facets/AdminFacet.sol";
import {DiamondCutFacet} from "../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/diamond/facets/OwnershipFacet.sol";
import {PlanFacet} from "../src/diamond/facets/PlanFacet.sol";
import {SubscriptionFacet} from "../src/diamond/facets/SubscriptionFacet.sol";
import {DiamondSelectors} from "./DiamondSelectors.sol";
import {LabScript} from "./LabScript.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Step 4: deploys the diamond variant of the same registry (six facets routed by `DiamondSelectors`, one
///         initializer), paying in the demo token deployed by step 3b.
contract DeployDiamond is LabScript {
    function run() external {
        address deployer = msg.sender;
        IERC20 token = IERC20(_address("v3", "paymentToken"));

        vm.startBroadcast();
        DiamondInit init = new DiamondInit();
        RegistryDiamond diamond = new RegistryDiamond(
            deployer,
            DiamondSelectors.facetCuts(
                address(new DiamondCutFacet()),
                address(new DiamondLoupeFacet()),
                address(new OwnershipFacet()),
                address(new PlanFacet()),
                address(new SubscriptionFacet()),
                address(new AdminFacet())
            ),
            address(init),
            abi.encodeCall(DiamondInit.init, (token, deployer))
        );
        vm.stopBroadcast();

        string memory json = vm.serializeAddress("diamond", "diamond", address(diamond));
        vm.writeJson(json, _file("diamond"));
    }
}
