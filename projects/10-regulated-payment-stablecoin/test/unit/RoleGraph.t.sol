// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Roles} from "../../src/access/Roles.sol";
import {TestPaymentDollarV1} from "../../src/TestPaymentDollarV1.sol";
import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";
import {ReserveGate} from "../../src/modules/ReserveGate.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";
import {RoleGraph} from "../../script/RoleGraph.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice The post-deployment role-graph verification (`script/RoleGraph.sol`, run by `VerifyRoles.s.sol`) accepts
///         the production wiring and reports every kind of drift an operator could introduce, including changes
///         that are still pending and an unexpected implementation behind the proxy.
contract RoleGraphTest is StablecoinTestBase {
    RoleGraph.Log[] internal history;
    address internal implementationV2;

    function setUp() public override {
        vm.recordLogs();
        super.setUp();
        _collect();
    }

    function _collect() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        RoleGraph.Log[] memory converted = RoleGraph.fromRecorded(logs);
        for (uint256 i; i < converted.length; ++i) {
            history.push(converted[i]);
        }
    }

    function _verify(bool v2) internal returns (string[] memory) {
        _collect();
        return RoleGraph.verify(manager, token, _config(), v2 ? implementationV2 : implementationV1, v2, history);
    }

    function _assertProblem(string[] memory problems, string memory expected) internal pure {
        for (uint256 i; i < problems.length; ++i) {
            if (keccak256(bytes(problems[i])) == keccak256(bytes(expected))) return;
        }
        revert(string.concat("missing problem: ", expected));
    }

    function _hex(address account) internal pure returns (string memory) {
        return Strings.toHexString(account);
    }

    function _sel(bytes4 selector) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint32(selector)), 4);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Accepted wiring
    // ------------------------------------------------------------------------------------------------------------

    function test_productionWiringVerifies() public {
        string[] memory problems = _verify(false);
        assertEq(problems.length, 0);
        assertEq(RoleGraph.expectedMembers(_config()).length, 9);
    }

    function test_v2WiringVerifiesOnlyInV2Mode() public {
        (, implementationV2) = _upgradeToV2();
        assertEq(_verify(true).length, 0);
        string[] memory asV1 = _verify(false);
        _assertProblem(asV1, "unexpected selector mapping 0xb62b3a34");
        _assertProblem(asV1, "proxy implementation is not the recorded implementation");
    }

    /// Regression: a deployer that is also governance used to keep ADMIN with no execution delay, and the verifier
    /// accepted it. The wiring now re-grants that ADMIN membership with the 2-day delay, the verifier expects the
    /// delay in every configuration, and the key can no longer act without a schedule.
    function test_governanceEqualsDeployer_adminKeepsDelay() public {
        StablecoinDeployment.Config memory cfg = _config();
        cfg.governance = address(this);
        StablecoinDeployment.Deployment memory d = StablecoinDeployment.deploy(cfg);
        _collect();

        (bool isAdmin, uint32 delay) = d.manager.hasRole(Roles.ADMIN, address(this));
        assertTrue(isAdmin);
        assertEq(delay, Roles.GOVERNANCE_DELAY);
        assertEq(RoleGraph.expectedMembers(cfg)[0].delay, Roles.GOVERNANCE_DELAY);
        assertEq(RoleGraph.verify(d.manager, d.token, cfg, d.implementation, false, history).length, 0);

        // The one-transaction takeover of the original report is refused at every step.
        address evil = makeAddr("evilAttestor");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotScheduled.selector,
                d.manager
                    .hashOperation(
                        address(this), address(d.token), abi.encodeCall(ReserveGate.setReserveAttestor, (evil))
                    )
            )
        );
        d.token.setReserveAttestor(evil);
        bytes memory grant = abi.encodeCall(AccessManager.grantRole, (Roles.UPGRADER, address(this), 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerNotScheduled.selector,
                d.manager.hashOperation(address(this), address(d.manager), grant)
            )
        );
        d.manager.grantRole(Roles.UPGRADER, address(this), 0);
        address v2 = address(new TestPaymentDollarV2());
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        d.token.upgradeToAndCall(v2, "");
    }

    function test_rejectsZeroGovernanceDelay() public {
        StablecoinDeployment.Config memory cfg = _config();
        cfg.governanceDelay = 0;
        vm.expectRevert(StablecoinDeployment.GovernanceDelayRequired.selector);
        this.deployExternally(cfg);
    }

    /// @dev External wrapper so `expectRevert` can observe a revert raised inside the library call.
    function deployExternally(StablecoinDeployment.Config memory cfg) external {
        StablecoinDeployment.deploy(cfg);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Drift that has taken effect
    // ------------------------------------------------------------------------------------------------------------

    function test_detectsExtraMinter() public {
        address rogue = makeAddr("rogue");
        _governance(address(manager), abi.encodeCall(AccessManager.grantRole, (Roles.MINTER, rogue, 0)));
        string[] memory problems = _verify(false);
        assertEq(problems.length, 1);
        _assertProblem(problems, string.concat("unexpected member: role 2 / ", _hex(rogue)));
    }

    function test_detectsDeployerRegainingAdmin() public {
        _governance(address(manager), abi.encodeCall(AccessManager.grantRole, (Roles.ADMIN, address(this), 0)));
        _assertProblem(_verify(false), string.concat("unexpected member: role 0 / ", _hex(address(this))));
    }

    function test_detectsMissingMemberAndWrongDelay() public {
        _governance(address(manager), abi.encodeCall(AccessManager.revokeRole, (Roles.PAUSER, pauser)));
        // Re-granting an existing member with a shorter delay takes effect after the setback (the old delay); the
        // verifier reports it as pending first, then as a wrong delay once it applies.
        _governance(address(manager), abi.encodeCall(AccessManager.grantRole, (Roles.UPGRADER, upgrader, 0)));
        string[] memory pending = _verify(false);
        _assertProblem(pending, string.concat("missing member: role 3 / ", _hex(pauser)));
        _assertProblem(pending, string.concat("pending execution delay change: role 7 / ", _hex(upgrader)));
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        string[] memory applied = _verify(false);
        _assertProblem(applied, string.concat("wrong execution delay: role 7 / ", _hex(upgrader)));
    }

    function test_detectsRewiredSelector() public {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = token.mint.selector;
        _governance(
            address(manager), abi.encodeCall(AccessManager.setTargetFunctionRole, (address(token), sel, Roles.PAUSER))
        );
        string[] memory problems = _verify(false);
        _assertProblem(problems, "selector mint is not mapped to its role");
        _assertProblem(problems, string.concat("unexpected selector mapping ", _sel(token.mint.selector)));
        assertEq(_sel(token.mint.selector), "0x40c10f19");
    }

    function test_detectsGovernanceSelectorOpened() public {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = token.setReserveAttestor.selector;
        _governance(
            address(manager), abi.encodeCall(AccessManager.setTargetFunctionRole, (address(token), sel, Roles.MINTER))
        );
        string[] memory problems = _verify(false);
        _assertProblem(problems, "a governance selector is no longer ADMIN-only");
    }

    function test_detectsGuardianAdminAndGrantDelayChanges() public {
        _governance(address(manager), abi.encodeCall(AccessManager.setRoleGuardian, (Roles.UPGRADER, Roles.MINTER)));
        _governance(address(manager), abi.encodeCall(AccessManager.setRoleAdmin, (Roles.MINTER, Roles.MASTER_MINTER)));
        _governance(address(manager), abi.encodeCall(AccessManager.setGrantDelay, (Roles.BRIDGE, 1 days)));
        vm.warp(block.timestamp + 5 days); // grant-delay increases apply after AccessManager's minimum setback
        string[] memory problems = _verify(false);
        _assertProblem(problems, "role 7 has an unexpected guardian");
        _assertProblem(problems, "role 2 has a non-ADMIN admin");
        _assertProblem(problems, "role 6 has a grant delay");
    }

    function test_detectsClosedTargetAndAuthorityAndAttestor() public {
        _governance(address(manager), abi.encodeCall(AccessManager.setTargetClosed, (address(token), true)));
        string[] memory problems = _verify(false);
        _assertProblem(problems, "token target is closed");

        AccessManager other = new AccessManager(address(this));
        _governance(address(manager), abi.encodeCall(AccessManager.updateAuthority, (address(token), address(other))));
        _assertProblem(_verify(false), "token authority is not the manager");

        // `other` is now the authority and this contract its undelayed admin: swap the attestor directly.
        token.setReserveAttestor(makeAddr("otherAttestor"));
        _assertProblem(_verify(false), "unexpected reserve attestor");
    }

    /// Regression: the mode used to be taken from the token's own `version()`, so any implementation answering "1"
    /// passed. The verifier now compares the ERC-1967 slot with the recorded implementation.
    function test_detectsUnexpectedImplementation() public {
        address impostor = address(new TestPaymentDollarV1()); // same code, same answers, not the recorded one
        bytes memory upgradeCall = abi.encodeCall(token.upgradeToAndCall, (impostor, ""));
        vm.prank(upgrader);
        manager.schedule(address(token), upgradeCall, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        vm.prank(upgrader);
        manager.execute(address(token), upgradeCall);

        assertEq(token.implementationVersion(), "1");
        assertEq(RoleGraph.implementationOf(address(token)), impostor);
        string[] memory problems = _verify(false);
        assertEq(problems.length, 1);
        _assertProblem(problems, "proxy implementation is not the recorded implementation");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Drift that is still pending
    // ------------------------------------------------------------------------------------------------------------

    /// Regression: a scheduled but not yet executed `grantRole(ADMIN, attacker, 0)` used to verify clean.
    function test_detectsPendingScheduledOperations() public {
        address attacker = makeAddr("attacker");
        bytes memory grantAdmin = abi.encodeCall(AccessManager.grantRole, (Roles.ADMIN, attacker, 0));
        bytes memory moveAuthority =
            abi.encodeCall(AccessManager.updateAuthority, (address(token), address(new AccessManager(attacker))));
        bytes memory upgrade = StablecoinDeployment.v2UpgradeCalldata(address(new TestPaymentDollarV2()));
        vm.prank(governance);
        manager.schedule(address(manager), grantAdmin, 0);
        vm.prank(governance);
        manager.schedule(address(manager), moveAuthority, 0);
        vm.prank(upgrader);
        manager.schedule(address(token), upgrade, 0);

        string[] memory problems = _verify(false);
        assertEq(problems.length, 3);
        string memory onManager = string.concat(" on ", _hex(address(manager)), " scheduled by ", _hex(governance));
        _assertProblem(
            problems, string.concat("pending operation: ", _sel(AccessManager.grantRole.selector), onManager)
        );
        _assertProblem(
            problems, string.concat("pending operation: ", _sel(AccessManager.updateAuthority.selector), onManager)
        );
        _assertProblem(
            problems,
            string.concat(
                "pending operation: ",
                _sel(token.upgradeToAndCall.selector),
                " on ",
                _hex(address(token)),
                " scheduled by ",
                _hex(upgrader)
            )
        );

        // Cancelled, or expired without execution: no longer pending.
        vm.prank(governance);
        manager.cancel(governance, address(manager), grantAdmin);
        vm.prank(pauser);
        manager.cancel(upgrader, address(token), upgrade);
        assertEq(_verify(false).length, 1);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY + manager.expiration() + 1);
        assertEq(_verify(false).length, 0);
    }

    /// A schedule that is executed and then scheduled again is reported once, for its latest nonce only.
    function test_pendingOperation_onlyLatestScheduleCounts() public {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = TestPaymentDollarV2.setTransferCapFlag.selector;
        bytes memory rewire =
            abi.encodeCall(AccessManager.setTargetFunctionRole, (address(token), sel, Roles.COMPLIANCE_OFFICER));
        _governance(address(manager), rewire);
        // Executed: v1 does not know that selector, so it shows up as an unexpected mapping, not as pending.
        string[] memory afterExecute = _verify(false);
        assertEq(afterExecute.length, 1);
        _assertProblem(afterExecute, "unexpected selector mapping 0xb62b3a34");

        vm.prank(governance);
        manager.schedule(address(manager), rewire, 0);
        string[] memory pending = _verify(false);
        assertEq(pending.length, 2);
        _assertProblem(
            pending,
            string.concat(
                "pending operation: ",
                _sel(AccessManager.setTargetFunctionRole.selector),
                " on ",
                _hex(address(manager)),
                " scheduled by ",
                _hex(governance)
            )
        );
    }

    /// A governance-delay reduction for ADMIN itself is visible while it waits for its setback.
    function test_detectsPendingAdminDelayReduction() public {
        _governance(address(manager), abi.encodeCall(AccessManager.grantRole, (Roles.ADMIN, governance, 0)));
        string[] memory pending = _verify(false);
        assertEq(pending.length, 1);
        _assertProblem(pending, string.concat("pending execution delay change: role 0 / ", _hex(governance)));
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        _assertProblem(_verify(false), string.concat("wrong execution delay: role 0 / ", _hex(governance)));
    }

    /// A member granted under a grant delay is not yet a member (`hasRole` is false) but is already reported.
    function test_detectsPendingMember() public {
        address rogue = makeAddr("rogue");
        _governance(address(manager), abi.encodeCall(AccessManager.setGrantDelay, (Roles.MINTER, 1 days)));
        vm.warp(block.timestamp + 5 days); // the grant-delay increase applies after the minimum setback
        _governance(address(manager), abi.encodeCall(AccessManager.grantRole, (Roles.MINTER, rogue, 0)));
        (bool isMember,) = manager.hasRole(Roles.MINTER, rogue);
        assertFalse(isMember);
        string[] memory problems = _verify(false);
        _assertProblem(problems, string.concat("pending member: role 2 / ", _hex(rogue)));
        _assertProblem(problems, "role 2 has a grant delay");
    }
}
