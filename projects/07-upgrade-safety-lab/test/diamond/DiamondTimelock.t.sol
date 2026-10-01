// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {UpgradeGovernance} from "../../script/UpgradeGovernance.sol";
import {RegistryDiamond} from "../../src/diamond/RegistryDiamond.sol";
import {AdminFacet} from "../../src/diamond/facets/AdminFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {PlanFacet} from "../../src/diamond/facets/PlanFacet.sol";
import {IDiamondCut} from "../../src/diamond/interfaces/IDiamond.sol";
import {LibOwnership} from "../../src/diamond/libraries/LibOwnership.sol";
import {ISubscriptionRegistry} from "../../src/interfaces/IRegistry.sol";
import {LabBase} from "../utils/LabBase.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

contract ReplacementAdminFacet {
    function version() external pure returns (string memory) {
        return "diamond-1.1.0";
    }
}

/// @notice The diamond has no AccessManaged code of its own; instead an AccessManager becomes its owner and is then
///         configured like the UUPS lineage's manager (`UpgradeGovernance`). The diamond's paths to new code are
///         `diamondCut` and handing ownership to someone else (`transferOwnership`), so both are UPGRADER functions:
///         delayed and cancellable by the guardian. Plan administration can go to an operator role with no delay.
abstract contract DiamondTimelockFixture is LabBase {
    uint64 internal constant OPERATOR_ROLE = 4;

    RegistryDiamond internal diamond;
    AccessManager internal manager;
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    address internal replacement;
    bytes internal cutCall;

    function _admin() internal view virtual returns (address);

    function setUp() public {
        vm.warp(1_700_000_000);
        (diamond,) = _deployDiamond(owner, _newToken(), treasury);
        address admin = _admin();
        manager = new AccessManager(admin);

        vm.startPrank(admin);
        bytes4[] memory opsSel = new bytes4[](1);
        opsSel[0] = PlanFacet.createPlan.selector;
        manager.setTargetFunctionRole(address(diamond), opsSel, OPERATOR_ROLE);
        manager.grantRole(OPERATOR_ROLE, operator, 0);
        vm.stopPrank();

        // Two-step hand-over of the diamond to the manager, accepted while ADMIN has no delay yet.
        vm.prank(owner);
        ISubscriptionRegistry(address(diamond)).transferOwnership(address(manager));
        vm.prank(admin);
        manager.execute(address(diamond), abi.encodeCall(ISubscriptionRegistry.acceptOwnership, ()));
        assertEq(ISubscriptionRegistry(address(diamond)).owner(), address(manager));

        // The same governance as the UUPS proxy; it delays ADMIN last.
        vm.startPrank(admin);
        UpgradeGovernance.configure(manager, address(diamond), _pathsToNewCode(), upgrader, guardian, admin);
        vm.stopPrank();

        replacement = address(new ReplacementAdminFacet());
        cutCall = abi.encodeCall(IDiamondCut.diamondCut, (_versionCut(), address(0), ""));
    }

    function _pathsToNewCode() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = DiamondCutFacet.diamondCut.selector;
        s[1] = OwnershipFacet.transferOwnership.selector;
    }

    function _versionCut() internal view returns (IDiamondCut.FacetCut[] memory cuts) {
        bytes4[] memory versionSel = new bytes4[](1);
        versionSel[0] = AdminFacet.version.selector;
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(replacement, IDiamondCut.FacetCutAction.Replace, versionSel);
    }

    function _expectNotScheduled(address caller, address target, bytes memory data) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotScheduled.selector, manager.hashOperation(caller, target, data)
            )
        );
    }
}

contract DiamondTimelockTest is DiamondTimelockFixture {
    function _admin() internal view override returns (address) {
        return governance;
    }

    function test_cutIsDelayedThenExecuted() public {
        vm.prank(upgrader);
        (bytes32 id,) = manager.schedule(address(diamond), cutCall, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        vm.prank(upgrader);
        manager.execute(address(diamond), cutCall);

        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.prank(upgrader);
        manager.execute(address(diamond), cutCall);
        assertEq(ISubscriptionRegistry(address(diamond)).version(), "diamond-1.1.0");
    }

    function test_guardianCancelsACut() public {
        vm.prank(upgrader);
        (bytes32 id,) = manager.schedule(address(diamond), cutCall, 0);
        vm.prank(guardian);
        manager.cancel(upgrader, address(diamond), cutCall);
        vm.warp(vm.getBlockTimestamp() + UPGRADE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        vm.prank(upgrader);
        manager.execute(address(diamond), cutCall);
        assertEq(ISubscriptionRegistry(address(diamond)).version(), "diamond-1.0.0");
    }

    function test_nobodyCutsAroundTheManager() public {
        IDiamondCut.FacetCut[] memory cuts = _versionCut();
        vm.expectRevert(abi.encodeWithSelector(LibOwnership.OwnableUnauthorizedAccount.selector, upgrader));
        vm.prank(upgrader);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        // The former owner lost direct control of the diamond (the manager's ADMIN paths are tested below).
        vm.expectRevert(abi.encodeWithSelector(LibOwnership.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(new IDiamondCut.FacetCut[](0), address(0), "");
    }

    function test_operatorAdministersPlansWithoutDelay() public {
        vm.prank(operator);
        manager.execute(address(diamond), abi.encodeCall(ISubscriptionRegistry.createPlan, (30 days)));
        assertEq(ISubscriptionRegistry(address(diamond)).planCount(), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                operator,
                address(diamond),
                DiamondCutFacet.diamondCut.selector
            )
        );
        vm.prank(operator);
        manager.execute(address(diamond), cutCall);
    }

    function test_adminCannotGrantItselfAnUndelayedUpgraderRole() public {
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (UPGRADER_ROLE, governance, 0));
        _expectNotScheduled(governance, address(manager), grant);
        vm.prank(governance);
        manager.grantRole(UPGRADER_ROLE, governance, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                governance,
                address(diamond),
                DiamondCutFacet.diamondCut.selector
            )
        );
        vm.prank(governance);
        manager.execute(address(diamond), cutCall);
    }

    function test_handingTheDiamondToAnotherOwnerIsAnUpgradePath() public {
        bytes memory handOver = abi.encodeCall(ISubscriptionRegistry.transferOwnership, (stranger));
        // ADMIN cannot do it at all (it is an UPGRADER function)...
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                governance,
                address(diamond),
                OwnershipFacet.transferOwnership.selector
            )
        );
        vm.prank(governance);
        manager.execute(address(diamond), handOver);

        // ...and the UPGRADER only through the public window, which the guardian can close.
        vm.prank(upgrader);
        (bytes32 id,) = manager.schedule(address(diamond), handOver, 0);
        vm.prank(guardian);
        manager.cancel(upgrader, address(diamond), handOver);
        assertEq(manager.getSchedule(id), 0);
        assertEq(ISubscriptionRegistry(address(diamond)).pendingOwner(), address(0));
    }
}

/// @notice The review's proof of concept for the diamond: the account that is the manager's ADMIN grants itself
///         UPGRADER with no delay and cuts in the same block.
contract DiamondOwnerIsAdminTimelockTest is DiamondTimelockFixture {
    function _admin() internal view override returns (address) {
        return owner;
    }

    function test_adminCannotCutInstantly() public {
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (UPGRADER_ROLE, owner, 0));
        _expectNotScheduled(owner, address(manager), grant);
        vm.prank(owner);
        manager.grantRole(UPGRADER_ROLE, owner, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                owner,
                address(diamond),
                DiamondCutFacet.diamondCut.selector
            )
        );
        vm.prank(owner);
        manager.execute(address(diamond), cutCall);
        assertEq(ISubscriptionRegistry(address(diamond)).version(), "diamond-1.0.0");
    }
}
