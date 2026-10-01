// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {AllocatorVault} from "../src/AllocatorVault.sol";
import {VaultRoles} from "../src/access/VaultRoles.sol";

/// @notice Deploys an AccessManager and an AllocatorVault, wires the curator / allocator / guardian selectors, grants
///         the roles, hands the manager's admin role to `ADMIN` and renounces the deployer's own admin role.
/// @dev Keystore-based: no private key is read from the environment.
///      forge script script/DeployAllocatorVault.s.sol --rpc-url <url> --account <keystore-name> --broadcast
///      Inputs (see .env.example): ASSET, ADMIN, CURATOR, ALLOCATOR, GUARDIAN, FEE_RECIPIENT, and optionally
///      VAULT_NAME, VAULT_SYMBOL, PERFORMANCE_FEE, MANAGEMENT_FEE, PRICE_GROWTH_LIMIT (WAD values).
///      The role addresses are checked before anything is broadcast: a zero ADMIN would leave the AccessManager with
///      no administrator once the deployer renounces (no role could ever be re-granted), a zero CURATOR, ALLOCATOR or
///      GUARDIAN would leave the vault without that role, and a guardian equal to the curator could not veto it.
contract DeployAllocatorVault is Script {
    /// @notice Everything the deployment needs.
    struct Config {
        address asset;
        address admin;
        address curator;
        address allocator;
        address guardian;
        address feeRecipient;
        string name;
        string symbol;
        uint256 performanceFee;
        uint256 managementFee;
        uint256 priceGrowthLimit;
    }

    /// @notice A role address is zero (`.env.example` ships zeros as placeholders).
    /// @param role The role's environment variable.
    error ZeroRoleAddress(string role);

    /// @notice The guardian must be independent from the curator, whose timelocked changes it vetoes.
    /// @param account The address given for both roles.
    error GuardianIsCurator(address account);

    /// @notice Reads the configuration from the environment and deploys.
    function run() external returns (AccessManager manager, AllocatorVault vault) {
        return deploy(
            Config({
                asset: vm.envAddress("ASSET"),
                admin: vm.envAddress("ADMIN"),
                curator: vm.envAddress("CURATOR"),
                allocator: vm.envAddress("ALLOCATOR"),
                guardian: vm.envAddress("GUARDIAN"),
                feeRecipient: vm.envAddress("FEE_RECIPIENT"),
                name: vm.envOr("VAULT_NAME", string("Curated Allocator Vault")),
                symbol: vm.envOr("VAULT_SYMBOL", string("cAV")),
                performanceFee: vm.envOr("PERFORMANCE_FEE", uint256(0.1e18)),
                managementFee: vm.envOr("MANAGEMENT_FEE", uint256(0)),
                priceGrowthLimit: vm.envOr("PRICE_GROWTH_LIMIT", uint256(0.25e18))
            })
        );
    }

    /// @notice Validates `cfg` and deploys (the vault's constructor checks the asset, fees and growth limit).
    function deploy(Config memory cfg) public returns (AccessManager manager, AllocatorVault vault) {
        _requireRole(cfg.admin, "ADMIN");
        _requireRole(cfg.curator, "CURATOR");
        _requireRole(cfg.allocator, "ALLOCATOR");
        _requireRole(cfg.guardian, "GUARDIAN");
        if (cfg.guardian == cfg.curator) revert GuardianIsCurator(cfg.guardian);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers(); // the broadcasting account (keystore or --sender)
        manager = new AccessManager(deployer);
        vault = new AllocatorVault(
            AllocatorVault.InitParams({
                asset: IERC20(cfg.asset),
                name: cfg.name,
                symbol: cfg.symbol,
                authority: address(manager),
                feeRecipient: cfg.feeRecipient,
                performanceFee: cfg.performanceFee,
                managementFee: cfg.managementFee,
                maxSharePriceGrowthPerYear: cfg.priceGrowthLimit
            })
        );

        VaultRoles.configure(manager, address(vault));
        manager.grantRole(VaultRoles.CURATOR, cfg.curator, 0);
        manager.grantRole(VaultRoles.ALLOCATOR, cfg.allocator, 0);
        manager.grantRole(VaultRoles.GUARDIAN, cfg.guardian, 0);
        if (cfg.admin != deployer) {
            manager.grantRole(manager.ADMIN_ROLE(), cfg.admin, 0);
            manager.renounceRole(manager.ADMIN_ROLE(), deployer);
        }
        vm.stopBroadcast();

        console2.log("AccessManager:", address(manager));
        console2.log("AllocatorVault:", address(vault));
    }

    function _requireRole(address account, string memory role) internal pure {
        if (account == address(0)) revert ZeroRoleAddress(role);
    }
}
