// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

import {DeployAllocatorVault} from "../../script/DeployAllocatorVault.s.sol";
import {AllocatorVault} from "../../src/AllocatorVault.sol";
import {VaultRoles} from "../../src/access/VaultRoles.sol";
import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Runs the production deployment script and checks the resulting role wiring and its input validation.
/// @dev Only the first test goes through the environment (`run()`): environment variables are process-wide, so the
///      validation tests call `deploy(Config)` directly instead of racing on them.
contract DeployScriptTest is Test {
    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    MockERC20 internal asset;
    DeployAllocatorVault internal script;

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD", 6);
        script = new DeployAllocatorVault();
    }

    function _config() internal view returns (DeployAllocatorVault.Config memory) {
        return DeployAllocatorVault.Config({
            asset: address(asset),
            admin: admin,
            curator: curator,
            allocator: allocator,
            guardian: guardian,
            feeRecipient: feeRecipient,
            name: "Curated Allocator Vault",
            symbol: "cAV",
            performanceFee: 0.1e18,
            managementFee: 0,
            priceGrowthLimit: 0.25e18
        });
    }

    function test_deployScript_wiresRolesAndHandsOverAdmin() public {
        vm.setEnv("ASSET", vm.toString(address(asset)));
        vm.setEnv("ADMIN", vm.toString(admin));
        vm.setEnv("CURATOR", vm.toString(curator));
        vm.setEnv("ALLOCATOR", vm.toString(allocator));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("FEE_RECIPIENT", vm.toString(feeRecipient));
        (AccessManager manager, AllocatorVault vault) = script.run();

        assertEq(vault.authority(), address(manager));
        assertEq(vault.asset(), address(asset));
        assertEq(vault.decimals(), 12);
        assertEq(vault.performanceFee(), 0.1e18);
        assertEq(vault.feeRecipient(), feeRecipient);

        (bool isAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), admin);
        assertTrue(isAdmin, "admin handed over");
        (bool deployerIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), DEFAULT_SENDER);
        assertFalse(deployerIsAdmin, "deployer renounced");
        (bool isCurator,) = manager.hasRole(VaultRoles.CURATOR, curator);
        (bool isAllocator,) = manager.hasRole(VaultRoles.ALLOCATOR, allocator);
        (bool isGuardian,) = manager.hasRole(VaultRoles.GUARDIAN, guardian);
        assertTrue(isCurator && isAllocator && isGuardian);

        _assertRole(manager, address(vault), VaultRoles.curatorSelectors(), VaultRoles.CURATOR);
        _assertRole(manager, address(vault), VaultRoles.allocatorSelectors(), VaultRoles.ALLOCATOR);
        _assertRole(manager, address(vault), VaultRoles.guardianSelectors(), VaultRoles.GUARDIAN);
        assertEq(manager.getTargetFunctionRole(address(vault), IAllocatorVault.accrue.selector), 0, "not restricted");
    }

    /// @dev `.env.example` ships zero addresses: forgetting ADMIN must not hand the AccessManager to address(0).
    function test_deployScript_revertsOnZeroAdmin() public {
        DeployAllocatorVault.Config memory cfg = _config();
        cfg.admin = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployAllocatorVault.ZeroRoleAddress.selector, "ADMIN"));
        script.deploy(cfg);
    }

    function test_deployScript_revertsOnZeroCuratorAllocatorOrGuardian() public {
        DeployAllocatorVault.Config memory cfg = _config();
        cfg.curator = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployAllocatorVault.ZeroRoleAddress.selector, "CURATOR"));
        script.deploy(cfg);

        cfg = _config();
        cfg.allocator = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployAllocatorVault.ZeroRoleAddress.selector, "ALLOCATOR"));
        script.deploy(cfg);

        cfg = _config();
        cfg.guardian = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployAllocatorVault.ZeroRoleAddress.selector, "GUARDIAN"));
        script.deploy(cfg);
    }

    function test_deployScript_revertsWhenGuardianIsCurator() public {
        DeployAllocatorVault.Config memory cfg = _config();
        cfg.guardian = curator;
        vm.expectRevert(abi.encodeWithSelector(DeployAllocatorVault.GuardianIsCurator.selector, curator));
        script.deploy(cfg);
    }

    function _assertRole(AccessManager manager, address vault, bytes4[] memory selectors, uint64 role) internal view {
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(manager.getTargetFunctionRole(vault, selectors[i]), role);
        }
    }
}
