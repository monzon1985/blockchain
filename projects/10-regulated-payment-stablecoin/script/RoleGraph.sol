// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Roles} from "../src/access/Roles.sol";
import {TestPaymentDollarV1} from "../src/TestPaymentDollarV1.sol";
import {StablecoinDeployment} from "./StablecoinDeployment.sol";

/**
 * @title RoleGraph
 * @notice Post-deployment verification of the AccessManager role graph of a Test Payment Dollar deployment: the
 *         proxy implementation, members, execution delays (current and pending), role admins, guardians, grant
 *         delays, every selector mapping ever set on the token, and every operation still scheduled on the manager.
 * @dev AccessManager cannot enumerate role members or schedules on-chain, so the candidate sets are rebuilt from the
 *      manager's own events (`RoleGranted`, `TargetFunctionRoleUpdated`, `OperationScheduled`); every candidate is
 *      then re-checked against the live state (`getAccess`, `getTargetFunctionRole`, `getSchedule`, `getNonce`).
 *      That catches missing wiring, anything extra (a forgotten deployer admin, an additional minter, a selector
 *      opened to the wrong role), changes that are still pending (a delay reduction waiting for its setback, a
 *      scheduled `grantRole` or `updateAuthority`) and an unexpected implementation behind the proxy. Used by
 *      `VerifyRoles.s.sol` (logs from `eth_getLogs`) and by `test/unit/RoleGraph.t.sol` (logs from `recordLogs`).
 */
library RoleGraph {
    using Strings for uint256;
    using Strings for address;

    /// @notice A manager event in a source-independent shape.
    struct Log {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    /// @notice An expected (role, account, execution delay) membership.
    struct Member {
        uint64 roleId;
        address account;
        uint32 delay;
    }

    uint256 private constant MAX_PROBLEMS = 64;

    /// @dev forge-std cheatcode address, used to read the ERC-1967 implementation slot (works in scripts and tests).
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Converts `vm.getRecordedLogs()` output.
    /// @param logs Recorded logs.
    /// @return out The same logs in the source-independent shape.
    function fromRecorded(Vm.Log[] memory logs) internal pure returns (Log[] memory out) {
        out = new Log[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            out[i] = Log(logs[i].emitter, logs[i].topics, logs[i].data);
        }
    }

    /// @notice Converts `vm.eth_getLogs()` output.
    /// @param logs RPC logs.
    /// @return out The same logs in the source-independent shape.
    function fromRpc(Vm.EthGetLogs[] memory logs) internal pure returns (Log[] memory out) {
        out = new Log[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            out[i] = Log(logs[i].emitter, logs[i].topics, logs[i].data);
        }
    }

    /// @notice Every membership the configuration implies. ADMIN is always expected behind the governance delay,
    ///         whether or not governance is the deployer (see `StablecoinDeployment.wire`).
    /// @param cfg The deployment configuration.
    /// @return m The expected memberships.
    function expectedMembers(StablecoinDeployment.Config memory cfg) internal pure returns (Member[] memory m) {
        m = new Member[](7 + cfg.minters.length);
        m[0] = Member(Roles.ADMIN, cfg.governance, cfg.governanceDelay);
        m[1] = Member(Roles.MASTER_MINTER, cfg.masterMinter, 0);
        m[2] = Member(Roles.PAUSER, cfg.pauser, 0);
        m[3] = Member(Roles.BLOCKLISTER, cfg.blocklister, 0);
        m[4] = Member(Roles.COMPLIANCE_OFFICER, cfg.complianceOfficer, 0);
        m[5] = Member(Roles.BRIDGE, cfg.bridge, 0);
        m[6] = Member(Roles.UPGRADER, cfg.upgrader, cfg.governanceDelay);
        for (uint256 i; i < cfg.minters.length; ++i) {
            m[7 + i] = Member(Roles.MINTER, cfg.minters[i], 0);
        }
    }

    /// @notice The implementation the ERC-1967 proxy `proxy` currently delegates to.
    /// @param proxy The proxy address.
    /// @return The address stored in the ERC-1967 implementation slot.
    function implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(VM.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    /// @notice Checks the deployment against `cfg` and returns every discrepancy (empty when the graph is exact).
    /// @param manager The AccessManager.
    /// @param token The token proxy.
    /// @param cfg The configuration the deployment was made with.
    /// @param expectedImplementation The implementation the proxy must point at (the recorded v1 or v2 address).
    /// @param v2 Whether the v2 selector wiring is expected as well.
    /// @param logs All events emitted by `manager` since its deployment.
    /// @return problems One human-readable line per discrepancy.
    function verify(
        AccessManager manager,
        TestPaymentDollarV1 token,
        StablecoinDeployment.Config memory cfg,
        address expectedImplementation,
        bool v2,
        Log[] memory logs
    ) internal view returns (string[] memory problems) {
        problems = new string[](MAX_PROBLEMS);
        uint256 n;

        if (implementationOf(address(token)) != expectedImplementation) {
            n = _add(problems, n, "proxy implementation is not the recorded implementation");
        }
        if (token.authority() != address(manager)) n = _add(problems, n, "token authority is not the manager");
        if (manager.isTargetClosed(address(token))) n = _add(problems, n, "token target is closed");
        if (token.reserveAttestor() != cfg.attestor) n = _add(problems, n, "unexpected reserve attestor");

        n = _checkSelectors(manager, address(token), v2, logs, problems, n);
        n = _checkMembers(manager, cfg, logs, problems, n);
        n = _checkRoleSettings(manager, problems, n);
        n = _checkPendingOperations(manager, logs, problems, n);

        // Shrinks the fixed-size array to the number of problems found: rewriting the length word of a memory array
        // that was allocated with a larger length is safe (the tail is simply never read).
        assembly ("memory-safe") {
            mstore(problems, n)
        }
    }

    function _checkSelectors(
        AccessManager manager,
        address token,
        bool v2,
        Log[] memory logs,
        string[] memory problems,
        uint256 n
    ) private view returns (uint256) {
        StablecoinDeployment.SelectorRole[] memory table = _table(v2);
        for (uint256 i; i < table.length; ++i) {
            if (manager.getTargetFunctionRole(token, table[i].selector) != table[i].roleId) {
                n = _add(problems, n, string.concat("selector ", table[i].name, " is not mapped to its role"));
            }
        }
        bytes4[] memory adminOnly = StablecoinDeployment.v1AdminSelectors();
        for (uint256 i; i < adminOnly.length; ++i) {
            if (manager.getTargetFunctionRole(token, adminOnly[i]) != Roles.ADMIN) {
                n = _add(problems, n, "a governance selector is no longer ADMIN-only");
            }
        }
        // Any selector ever mapped on the token must either be in the table with its role, or be back to ADMIN.
        for (uint256 i; i < logs.length; ++i) {
            if (!_is(logs[i], manager, IAccessManager.TargetFunctionRoleUpdated.selector)) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != token) continue;
            bytes4 selector = abi.decode(logs[i].data, (bytes4));
            uint64 current = manager.getTargetFunctionRole(token, selector);
            if (current != Roles.ADMIN && !_inTable(table, selector, current)) {
                n = _add(problems, n, string.concat("unexpected selector mapping ", _hex4(selector)));
            }
        }
        return n;
    }

    function _checkMembers(
        AccessManager manager,
        StablecoinDeployment.Config memory cfg,
        Log[] memory logs,
        string[] memory problems,
        uint256 n
    ) private view returns (uint256) {
        Member[] memory expected = expectedMembers(cfg);
        for (uint256 i; i < expected.length; ++i) {
            Member memory e = expected[i];
            (bool isMember, uint32 delay) = manager.hasRole(e.roleId, e.account);
            if (!isMember) {
                n = _add(problems, n, _memberText("missing member", e.roleId, e.account));
            } else if (delay != e.delay) {
                n = _add(problems, n, _memberText("wrong execution delay", e.roleId, e.account));
            }
            // A scheduled delay change (for example a reduction waiting for its setback) is reported before it
            // takes effect, not after.
            (,, uint32 pendingDelay, uint48 effect) = manager.getAccess(e.roleId, e.account);
            if (effect != 0 && pendingDelay != e.delay) {
                n = _add(problems, n, _memberText("pending execution delay change", e.roleId, e.account));
            }
        }
        for (uint256 i; i < logs.length; ++i) {
            if (!_is(logs[i], manager, IAccessManager.RoleGranted.selector)) continue;
            uint64 roleId = uint64(uint256(logs[i].topics[1]));
            address account = address(uint160(uint256(logs[i].topics[2])));
            if (_isExpected(expected, roleId, account) || _grantedEarlier(manager, logs, i, roleId, account)) continue;
            (uint48 since,,,) = manager.getAccess(roleId, account);
            if (since == 0) continue; // revoked or renounced since
            // `since` in the future: granted, but a grant delay is still running.
            n = _add(
                problems,
                n,
                _memberText(since > block.timestamp ? "pending member" : "unexpected member", roleId, account)
            );
        }
        return n;
    }

    function _checkRoleSettings(AccessManager manager, string[] memory problems, uint256 n)
        private
        view
        returns (uint256)
    {
        for (uint64 roleId = Roles.MASTER_MINTER; roleId <= Roles.UPGRADER; ++roleId) {
            if (manager.getRoleAdmin(roleId) != Roles.ADMIN) {
                n = _add(problems, n, string.concat("role ", uint256(roleId).toString(), " has a non-ADMIN admin"));
            }
            uint64 expectedGuardian = roleId == Roles.UPGRADER ? Roles.PAUSER : Roles.ADMIN;
            if (manager.getRoleGuardian(roleId) != expectedGuardian) {
                n = _add(problems, n, string.concat("role ", uint256(roleId).toString(), " has an unexpected guardian"));
            }
            if (manager.getRoleGrantDelay(roleId) != 0) {
                n = _add(problems, n, string.concat("role ", uint256(roleId).toString(), " has a grant delay"));
            }
        }
        return n;
    }

    /// @dev Every operation still scheduled on the manager (any caller, any target) is reported: a pending
    ///      `grantRole(ADMIN, attacker)`, `updateAuthority` or upgrade is exactly what a verifier must surface while
    ///      it can still be cancelled. Only the latest schedule of an operation id counts (`getNonce`), and an
    ///      executed, cancelled or expired operation reads back as 0 from `getSchedule`.
    function _checkPendingOperations(AccessManager manager, Log[] memory logs, string[] memory problems, uint256 n)
        private
        view
        returns (uint256)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (!_is(logs[i], manager, IAccessManager.OperationScheduled.selector)) continue;
            bytes32 id = logs[i].topics[1];
            if (manager.getNonce(id) != uint32(uint256(logs[i].topics[2])) || manager.getSchedule(id) == 0) continue;
            (, address caller, address target, bytes memory data) =
                abi.decode(logs[i].data, (uint48, address, address, bytes));
            n = _add(
                problems,
                n,
                string.concat(
                    "pending operation: ",
                    data.length >= 4 ? _hex4(bytes4(data)) : "(no selector)",
                    " on ",
                    target.toHexString(),
                    " scheduled by ",
                    caller.toHexString()
                )
            );
        }
        return n;
    }

    function _table(bool v2) private pure returns (StablecoinDeployment.SelectorRole[] memory table) {
        StablecoinDeployment.SelectorRole[] memory v1 = StablecoinDeployment.v1SelectorRoles();
        if (!v2) return v1;
        StablecoinDeployment.SelectorRole[] memory extra = StablecoinDeployment.v2SelectorRoles();
        table = new StablecoinDeployment.SelectorRole[](v1.length + extra.length);
        for (uint256 i; i < v1.length; ++i) {
            table[i] = v1[i];
        }
        for (uint256 i; i < extra.length; ++i) {
            table[v1.length + i] = extra[i];
        }
    }

    function _inTable(StablecoinDeployment.SelectorRole[] memory table, bytes4 selector, uint64 roleId)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < table.length; ++i) {
            if (table[i].selector == selector && table[i].roleId == roleId) return true;
        }
        return false;
    }

    function _isExpected(Member[] memory expected, uint64 roleId, address account) private pure returns (bool) {
        for (uint256 i; i < expected.length; ++i) {
            if (expected[i].roleId == roleId && expected[i].account == account) return true;
        }
        return false;
    }

    /// @dev Whether a `RoleGranted` for the same (role, account) appears before index `end`, so that an account
    ///      granted twice (for example a delay update) is reported once.
    function _grantedEarlier(AccessManager manager, Log[] memory logs, uint256 end, uint64 roleId, address account)
        private
        pure
        returns (bool)
    {
        for (uint256 j; j < end; ++j) {
            if (!_is(logs[j], manager, IAccessManager.RoleGranted.selector)) continue;
            if (uint64(uint256(logs[j].topics[1])) == roleId && address(uint160(uint256(logs[j].topics[2]))) == account)
            {
                return true;
            }
        }
        return false;
    }

    function _is(Log memory log, AccessManager manager, bytes32 topic0) private pure returns (bool) {
        return log.emitter == address(manager) && log.topics.length > 0 && log.topics[0] == topic0;
    }

    function _hex4(bytes4 selector) private pure returns (string memory) {
        return uint256(uint32(selector)).toHexString(4);
    }

    function _memberText(string memory what, uint64 roleId, address account) private pure returns (string memory) {
        return string.concat(what, ": role ", uint256(roleId).toString(), " / ", account.toHexString());
    }

    function _add(string[] memory problems, uint256 n, string memory problem) private pure returns (uint256) {
        if (n < problems.length) problems[n] = problem;
        return n < problems.length ? n + 1 : n;
    }
}
