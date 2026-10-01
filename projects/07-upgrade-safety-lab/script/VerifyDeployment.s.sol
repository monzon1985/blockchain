// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RegistryDiamond} from "../src/diamond/RegistryDiamond.sol";
import {DiamondLoupeFacet} from "../src/diamond/facets/DiamondLoupeFacet.sol";
import {IDiamondCut, IDiamondLoupe, IERC8109Introspection} from "../src/diamond/interfaces/IDiamond.sol";
import {SubscriptionRegistryV2} from "../src/uups/v2/SubscriptionRegistryV2.sol";
import {SubscriptionRegistryV3} from "../src/uups/v3/SubscriptionRegistryV3.sol";
import {LabScript} from "./LabScript.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @notice Read-only verification against the live chain after each step (no transaction is sent):
///         `forge script script/VerifyDeployment.s.sol --rpc-url $RPC --sig "run(string)" <stage>`, with the stage
///         one of v1, bridge, v2, v3-scheduled, v3, diamond.
contract VerifyDeployment is LabScript {
    error AuthorityMismatch(address expected, address actual);
    error PaymentTokenMismatch(address expected, address actual);
    error UnknownStage(string stage);
    error DiamondCheckFailed(string what);

    function run(string calldata stage) external view {
        bytes32 s = keccak256(bytes(stage));
        address proxy = _address("v1", "proxy");
        if (s == keccak256("v1")) {
            _verify(proxy, _address("v1", "implementation"), "1.0.0", false);
        } else if (s == keccak256("bridge")) {
            // Maintenance mode between the two migration steps: owner and version 2 in the OZ 5.x namespaces.
            _verify(proxy, _address("bridge", "implementation"), "1.5.0-bridge", true);
            _verifyNamespaces(proxy, 2);
        } else if (s == keccak256("v2")) {
            _verify(proxy, _address("v2", "implementation"), "2.0.0", true);
            _verifyNamespaces(proxy, 3);
            address manager = _address("v2", "manager");
            address authority = SubscriptionRegistryV2(proxy).authority();
            if (authority != manager) revert AuthorityMismatch(manager, authority);
            _verifyGovernance(AccessManager(manager), proxy, _address("v1", "owner"));
        } else if (s == keccak256("v3-scheduled")) {
            // Still V2 while the upgrade waits out its delay.
            _verify(proxy, _address("v2", "implementation"), "2.0.0", true);
            AccessManager manager = AccessManager(_address("v2", "manager"));
            bytes32 id = vm.parseJsonBytes32(_json("v3-schedule"), ".operationId");
            if (manager.getSchedule(id) == 0) revert DiamondCheckFailed("upgrade not scheduled");
        } else if (s == keccak256("v3")) {
            _verify(proxy, _address("v3", "implementation"), "3.0.0", true);
            _verifyNamespaces(proxy, 4);
            address token = _address("v3", "paymentToken");
            address actual = SubscriptionRegistryV3(proxy).paymentToken();
            if (actual != token) revert PaymentTokenMismatch(token, actual);
        } else if (s == keccak256("diamond")) {
            _verifyDiamond(RegistryDiamond(payable(_address("diamond", "diamond"))));
        } else {
            revert UnknownStage(stage);
        }
    }

    function _verifyDiamond(RegistryDiamond diamond) internal view {
        IERC8109Introspection.FunctionFacetPair[] memory pairs = diamond.functionFacetPairs();
        if (pairs.length != 35) revert DiamondCheckFailed("expected 35 selectors");
        for (uint256 i; i < pairs.length; ++i) {
            if (diamond.facetAddress(pairs[i].selector) != pairs[i].facet) revert DiamondCheckFailed("pair mismatch");
        }
        DiamondLoupeFacet loupe = DiamondLoupeFacet(address(diamond));
        if (loupe.facets().length != 7) revert DiamondCheckFailed("expected 7 facets (6 + the diamond)");
        if (!loupe.supportsInterface(type(IDiamondCut).interfaceId)) revert DiamondCheckFailed("IDiamondCut");
        if (!loupe.supportsInterface(type(IDiamondLoupe).interfaceId)) revert DiamondCheckFailed("IDiamondLoupe");
        (bool ok, bytes memory ret) = address(diamond).staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || abi.decode(ret, (address)) != _address("v1", "owner")) revert DiamondCheckFailed("owner");
    }
}
