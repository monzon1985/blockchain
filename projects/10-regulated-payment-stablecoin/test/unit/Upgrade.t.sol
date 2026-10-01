// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC3009Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC3009Upgradeable.sol";

import {Roles} from "../../src/access/Roles.sol";
import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @dev Exposes the namespace constants of both versions so the test can recompute them.
contract NamespaceProbe is TestPaymentDollarV2 {
    function slots() external pure returns (bytes32, bytes32, bytes32, bytes32) {
        return (
            COMPLIANCE_STORAGE_LOCATION,
            RESERVES_STORAGE_LOCATION,
            MINTING_STORAGE_LOCATION,
            TRANSFER_CAPS_STORAGE_LOCATION
        );
    }
}

/// @dev Not UUPS: an upgrade to it must be refused.
contract NotUUPS {
    function hello() external pure returns (uint256) {
        return 1;
    }
}

/// @notice v1 -> v2 through the real 2-day schedule, with sentinels on everything the upgrade must preserve, plus
///         the v2 feature (rolling outflow cap for flagged accounts).
contract UpgradeTest is StablecoinTestBase {
    TestPaymentDollarV2 internal v2;

    // Sentinel state captured before the upgrade.
    uint256 internal supplyBefore;
    bytes32 internal domainBefore;
    bytes internal pendingAuthSig;
    bytes32 internal constant PENDING_NONCE = keccak256("signed-before-upgrade");
    bytes32 internal constant USED_NONCE = keccak256("used-before-upgrade");

    function _populate() internal {
        _mint(alice, 1000e6);
        _mint(bob, 2000e6);
        vm.prank(minter2);
        token.mint(carol, 3000e6);
        vm.prank(bridge);
        token.crosschainMint(address(wallet), 400e6);

        vm.prank(alice);
        token.approve(bob, 123e6);
        uint256 deadline = block.timestamp + 30 days;
        token.permit(alice, carol, 77e6, deadline, _signPermit(aliceKey, alice, carol, 77e6, deadline));
        token.permit(bob, carol, 1e6, deadline, _signPermit(bobKey, bob, carol, 1e6, deadline));

        bytes memory used =
            _signTransferAuth(aliceKey, alice, bob, 5e6, block.timestamp - 1, block.timestamp + 30 days, USED_NONCE);
        token.transferWithAuthorization(
            alice, bob, 5e6, block.timestamp - 1, block.timestamp + 30 days, USED_NONCE, used
        );
        pendingAuthSig =
            _signTransferAuth(bobKey, bob, alice, 9e6, block.timestamp - 1, block.timestamp + 30 days, PENDING_NONCE);

        vm.prank(blocklister);
        token.blocklist(makeAddr("sanctioned"));
        vm.prank(compliance);
        token.freeze(carol, ORDER_REF);

        supplyBefore = token.totalSupply();
        domainBefore = token.DOMAIN_SEPARATOR();
    }

    function test_upgrade_preservesEverySentinel() public {
        _populate();
        (uint256 reservesBefore, uint64 asOfBefore,, uint256 supplyAtBefore) = token.latestReserveAttestation();
        uint256 minterWindowBefore = token.minterWindowAvailable(minter);
        (uint256 bridgeMintBefore,) = token.bridgeAvailable(bridge);

        address implV2;
        (v2, implV2) = _upgradeToV2();

        assertEq(v2.implementationVersion(), "2");
        assertEq(v2.version(), "1"); // EIP-712 domain version, unchanged by the upgrade
        assertEq(address(uint160(uint256(vm.load(address(token), ERC1967Utils.IMPLEMENTATION_SLOT)))), implV2);
        // ERC-20 state.
        assertEq(v2.totalSupply(), supplyBefore);
        assertEq(v2.balanceOf(alice), 995e6);
        assertEq(v2.balanceOf(bob), 2005e6);
        assertEq(v2.balanceOf(carol), 3000e6);
        assertEq(v2.balanceOf(address(wallet)), 400e6);
        assertEq(v2.allowance(alice, bob), 123e6);
        assertEq(v2.allowance(alice, carol), 77e6);
        assertEq(v2.allowance(bob, carol), 1e6);
        assertEq(v2.name(), "Test Payment Dollar");
        assertEq(v2.symbol(), "tPD");
        // Signature state: permit nonces, used 3009 nonces, and the unchanged EIP-712 domain.
        assertEq(v2.nonces(alice), 1);
        assertEq(v2.nonces(bob), 1);
        assertTrue(v2.authorizationState(alice, USED_NONCE));
        assertFalse(v2.authorizationState(bob, PENDING_NONCE));
        assertEq(v2.DOMAIN_SEPARATOR(), domainBefore);
        // Issuer controls.
        assertTrue(v2.isBlocklisted(makeAddr("sanctioned")));
        assertTrue(v2.isFrozen(carol));
        assertTrue(v2.isMinter(minter));
        assertEq(v2.minterAllowance(minter), MINTER_ALLOWANCE - 1000e6 - 2000e6);
        assertEq(v2.minterDailyLimit(minter), MINTER_DAILY);
        assertEq(v2.minterLimitCeiling(), MINTER_CEILING);
        assertEq(v2.reserveAttestor(), attestor);
        (uint256 reservesAfter, uint64 asOfAfter,, uint256 supplyAtAfter) = v2.latestReserveAttestation();
        assertEq(reservesAfter, reservesBefore);
        assertEq(asOfAfter, asOfBefore);
        assertEq(supplyAtAfter, supplyAtBefore);
        assertEq(v2.authority(), address(manager));
        // The upgrade warped 2 days, so the rolling windows have fully refilled; the limits themselves persist.
        assertEq(minterWindowBefore, MINTER_DAILY - 1000e6 - 2000e6);
        assertEq(v2.minterWindowAvailable(minter), MINTER_DAILY);
        assertEq(bridgeMintBefore, BRIDGE_MINT_LIMIT - 400e6);
        (uint256 bridgeMintAfter,) = v2.bridgeAvailable(bridge);
        assertEq(bridgeMintAfter, BRIDGE_MINT_LIMIT);
        // v2 initialised with its documented default.
        assertEq(v2.flaggedDailyCap(), v2.DEFAULT_FLAGGED_DAILY_CAP());

        // An authorization signed before the upgrade still executes after it, and a used one stays used.
        v2.transferWithAuthorization(
            bob, alice, 9e6, START_TIME - 1, START_TIME + 30 days, PENDING_NONCE, pendingAuthSig
        );
        assertEq(v2.balanceOf(alice), 1004e6);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009UsedAuthorization.selector, bob, PENDING_NONCE)
        );
        v2.transferWithAuthorization(
            bob, alice, 9e6, START_TIME - 1, START_TIME + 30 days, PENDING_NONCE, pendingAuthSig
        );
    }

    /// Integrators that build the EIP-712 domain from `name()` and `version()` (the USDC convention) keep producing
    /// valid signatures after the upgrade: `version()` is the domain version, the logic version is separate.
    function test_upgrade_versionGetterMatchesEip712Domain() public {
        _mint(alice, 10e6);
        (v2,) = _upgradeToV2();
        (, string memory domainName, string memory domainVersion, uint256 chainId, address verifying,,) =
            v2.eip712Domain();
        assertEq(v2.name(), domainName);
        assertEq(v2.version(), domainVersion);
        assertEq(v2.implementationVersion(), "2");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 domain = _domainSeparatorFor(v2.name(), v2.version(), chainId, verifying);
        assertEq(domain, v2.DOMAIN_SEPARATOR());
        bytes memory sig =
            _sign(aliceKey, _digest(domain, _permitStructHash(alice, bob, 5e6, v2.nonces(alice), deadline)));
        v2.permit(alice, bob, 5e6, deadline, sig);
        assertEq(v2.allowance(alice, bob), 5e6);
    }

    function test_upgrade_namespacesFollowErc7201() public {
        (bytes32 compliance_, bytes32 reserves_, bytes32 minting_, bytes32 caps_) = new NamespaceProbe().slots();
        assertEq(compliance_, _erc7201("tpd.storage.Compliance"));
        assertEq(reserves_, _erc7201("tpd.storage.Reserves"));
        assertEq(minting_, _erc7201("tpd.storage.Minting"));
        assertEq(caps_, _erc7201("tpd.storage.TransferCaps"));
    }

    function test_upgrade_v2ImplementationCannotBeInitialized() public {
        TestPaymentDollarV2 impl = new TestPaymentDollarV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initializeV2();
    }

    function test_upgrade_initializeV2RunsOnce() public {
        (v2,) = _upgradeToV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initializeV2();
    }

    function test_upgrade_rejectsNonUupsImplementation() public {
        address bad = address(new NotUUPS());
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (bad, ""));
        vm.prank(upgrader);
        manager.schedule(address(token), data, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, bad));
        manager.execute(address(token), data);
    }

    function test_upgrade_notThroughImplementation() public {
        address impl2 = address(new TestPaymentDollarV2());
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        TestPaymentDollarV2(implementationV1).upgradeToAndCall(impl2, "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // v2 feature: rolling outflow cap for flagged accounts
    // ------------------------------------------------------------------------------------------------------------

    function _v2WithFlaggedAlice() internal {
        (v2,) = _upgradeToV2();
        _attest(INITIAL_RESERVES);
        _mint(alice, 50_000e6);
        vm.expectEmit(true, false, false, true);
        emit TestPaymentDollarV2.TransferCapFlagSet(alice, true);
        vm.prank(compliance);
        v2.setTransferCapFlag(alice, true);
    }

    function test_v2_flaggedTransfersCapped() public {
        _v2WithFlaggedAlice();
        uint256 cap = v2.DEFAULT_FLAGGED_DAILY_CAP();
        assertTrue(v2.isTransferCapFlagged(alice));
        vm.prank(alice);
        v2.transfer(bob, cap - 1);
        assertEq(v2.flaggedOutflowAvailable(alice), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestPaymentDollarV2.FlaggedTransferCapExceeded.selector, alice, 1, 2));
        v2.transfer(bob, 2);
        // Inflows are not capped.
        vm.prank(bob);
        v2.transfer(alice, 5e6);
        // The window rolls.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        v2.transfer(bob, cap);
    }

    function test_v2_capCoversEveryOutflowPath() public {
        _v2WithFlaggedAlice();
        uint256 cap = v2.DEFAULT_FLAGGED_DAILY_CAP();
        vm.prank(alice);
        v2.approve(carol, type(uint256).max);
        vm.prank(carol);
        v2.transferFrom(alice, carol, cap / 2);
        bytes memory sig = _signTransferAuth(
            aliceKey, alice, bob, cap / 4, block.timestamp - 1, block.timestamp + 1 hours, bytes32(0)
        );
        v2.transferWithAuthorization(
            alice, bob, cap / 4, block.timestamp - 1, block.timestamp + 1 hours, bytes32(0), sig
        );
        vm.prank(bridge);
        v2.crosschainBurn(alice, cap / 4);
        assertEq(v2.flaggedOutflowAvailable(alice), 0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(TestPaymentDollarV2.FlaggedTransferCapExceeded.selector, alice, 0, 1));
        v2.transferFrom(alice, carol, 1);
    }

    function test_v2_lawfulOrdersBypassCap() public {
        _v2WithFlaggedAlice();
        vm.prank(compliance);
        v2.freeze(alice, ORDER_REF);
        vm.prank(compliance);
        v2.seize(alice, custody, 20_000e6, ORDER_REF);
        vm.prank(compliance);
        v2.burnFrozen(alice, ORDER_REF);
        assertEq(v2.balanceOf(alice), 0);
        assertEq(v2.balanceOf(custody), 20_000e6);
    }

    function test_v2_unflagRemovesCap() public {
        _v2WithFlaggedAlice();
        vm.prank(compliance);
        v2.setTransferCapFlag(alice, false);
        vm.prank(alice);
        v2.transfer(bob, 50_000e6);
    }

    function test_v2_flagReverts() public {
        (v2,) = _upgradeToV2();
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        v2.setTransferCapFlag(address(0), true);
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(TestPaymentDollarV2.TransferCapFlagUnchanged.selector, alice, false));
        v2.setTransferCapFlag(alice, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        v2.setTransferCapFlag(alice, true);
    }

    function test_v2_setFlaggedDailyCapThroughGovernance() public {
        (v2,) = _upgradeToV2();
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, compliance));
        v2.setFlaggedDailyCap(1);
        _governance(address(token), abi.encodeCall(TestPaymentDollarV2.setFlaggedDailyCap, (42e6)));
        assertEq(v2.flaggedDailyCap(), 42e6);
    }

    function test_v2_keepsV1ChokePoint() public {
        (v2,) = _upgradeToV2();
        vm.prank(pauser);
        v2.pause();
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        v2.transfer(bob, 0);
    }

    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }
}
