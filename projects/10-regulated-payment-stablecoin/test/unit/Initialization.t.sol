// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC7802} from "@openzeppelin/contracts/interfaces/draft-IERC7802.sol";

import {TestPaymentDollarV1} from "../../src/TestPaymentDollarV1.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

contract InitializationTest is StablecoinTestBase {
    function test_metadata() public view {
        assertEq(token.name(), "Test Payment Dollar");
        assertEq(token.symbol(), "tPD");
        assertEq(token.decimals(), 6);
        assertEq(token.version(), "1");
        assertEq(token.implementationVersion(), "1");
        assertEq(token.authority(), address(manager));
        assertEq(token.reserveAttestor(), attestor);
        assertEq(token.minterLimitCeiling(), MINTER_CEILING);
        (uint256 mintLimit, uint256 burnLimit) = token.bridgeLimits();
        assertEq(mintLimit, BRIDGE_MINT_LIMIT);
        assertEq(burnLimit, BRIDGE_BURN_LIMIT);
        assertEq(token.RATE_LIMIT_WINDOW(), 24 hours);
        assertEq(token.MAX_ATTESTATION_AGE(), 26 hours);
        assertFalse(token.paused());
    }

    function test_eip712Domain_matchesIndependentComputation() public view {
        assertEq(token.DOMAIN_SEPARATOR(), _domainSeparator());
        (, string memory name, string memory ver, uint256 chainId, address verifying,,) = token.eip712Domain();
        assertEq(name, "Test Payment Dollar");
        assertEq(ver, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(token));
    }

    function test_proxyPointsAtImplementation() public view {
        bytes32 slot = vm.load(address(token), ERC1967Utils.IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(slot))), implementationV1);
    }

    function test_supportsInterface() public view {
        assertTrue(token.supportsInterface(type(IERC7802).interfaceId));
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertFalse(token.supportsInterface(0xdeadbeef));
    }

    function test_initialize_revertsOnProxyReinitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(_params(address(manager), attestor));
    }

    function test_initialize_revertsOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TestPaymentDollarV1(implementationV1).initialize(_params(address(manager), attestor));
    }

    function test_initialize_revertsOnZeroAttestor() public {
        address impl = address(new TestPaymentDollarV1());
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        new ERC1967Proxy(impl, abi.encodeCall(TestPaymentDollarV1.initialize, (_params(address(manager), address(0)))));
    }

    /// An authority without code (zero address or EOA) would make every restricted selector, upgrades included,
    /// permanently unauthorisable: initialize refuses it.
    function test_initialize_revertsOnAuthorityWithoutCode() public {
        address impl = address(new TestPaymentDollarV1());
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        new ERC1967Proxy(impl, abi.encodeCall(TestPaymentDollarV1.initialize, (_params(address(0), attestor))));

        address eoa = makeAddr("notAnAccessManager");
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, eoa));
        new ERC1967Proxy(impl, abi.encodeCall(TestPaymentDollarV1.initialize, (_params(eoa, attestor))));
    }

    function test_initialize_emitsConfigurationEvents() public {
        address impl = address(new TestPaymentDollarV1());
        vm.expectEmit(true, true, false, false);
        emit ReserveAttestorSet(address(0), attestor);
        vm.expectEmit(false, false, false, true);
        emit MinterLimitCeilingSet(MINTER_CEILING);
        vm.expectEmit(false, false, false, true);
        emit BridgeLimitsSet(BRIDGE_MINT_LIMIT, BRIDGE_BURN_LIMIT);
        new ERC1967Proxy(impl, abi.encodeCall(TestPaymentDollarV1.initialize, (_params(address(manager), attestor))));
    }

    function test_proxiableUUID_onlyOnImplementation() public {
        assertEq(TestPaymentDollarV1(implementationV1).proxiableUUID(), ERC1967Utils.IMPLEMENTATION_SLOT);
        vm.expectRevert();
        token.proxiableUUID();
    }

    function _params(address authority, address attestor_)
        internal
        pure
        returns (TestPaymentDollarV1.InitParams memory)
    {
        return TestPaymentDollarV1.InitParams({
            authority: authority,
            attestor: attestor_,
            minterLimitCeiling: MINTER_CEILING,
            bridgeMintLimit: BRIDGE_MINT_LIMIT,
            bridgeBurnLimit: BRIDGE_BURN_LIMIT
        });
    }
}
