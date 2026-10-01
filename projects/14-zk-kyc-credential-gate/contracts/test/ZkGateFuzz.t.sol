// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixtureLoader} from "./base/FixtureLoader.sol";
import {ZkGateHarness} from "./base/ZkGateHarness.sol";
import {ZkGate} from "../src/ZkGate.sol";
import {PUBLIC_SIGNALS} from "../src/interfaces/IVerifiers.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @title ZkGateFuzzTest
/// @notice Fuzzes the gate's public-input validation against a real committed public-signal vector:
///         every perturbation of a checked slot is rejected with the precise error, and the only
///         unchecked slot (the nullifier) accepts any in-field value. Inputs are steered with
///         `bound` and deterministic remapping, never `vm.assume`.
contract ZkGateFuzzTest is FixtureLoader {
    uint256 internal constant FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    ZkGateHarness internal gate;
    uint256[PUBLIC_SIGNALS] internal base;
    uint256 internal expectedScope;
    address internal recipient;

    function setUp() public {
        GateFixture memory g = loadGate();
        useFixtureChain(g);
        MockVerifier mock = new MockVerifier();
        base = loadGroth16("valid_groth16.json").pub;
        recipient = g.recipient;
        deployCodeTo(
            "ZkGateHarness.sol:ZkGateHarness",
            abi.encode(fixtureConfig(g, address(mock), address(mock), address(this))),
            g.gateAddress
        );
        gate = ZkGateHarness(g.gateAddress);
        expectedScope = gate.appScope();
    }

    /// @dev Map `v` into [0, FIELD) \ {avoid} without rejecting the fuzz input.
    function _inFieldExcept(uint256 v, uint256 avoid) internal pure returns (uint256 out) {
        out = bound(v, 0, FIELD - 2);
        if (out >= avoid) out += 1; // skip exactly one value: a bijection onto the remaining set
    }

    function _validate(uint256[PUBLIC_SIGNALS] memory pub) internal {
        vm.prank(recipient);
        gate.exposedValidate(pub);
    }

    function test_BaselineValidates() public {
        _validate(base); // must not revert
    }

    function testFuzz_AnyInFieldNullifierPassesValidation(uint256 nf) public {
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[0] = bound(nf, 0, FIELD - 1);
        _validate(pub); // the nullifier is only range-checked; the verifier binds it
    }

    function testFuzz_OutOfFieldReverts(uint256 rawIdx, uint256 delta) public {
        uint256 idx = bound(rawIdx, 0, PUBLIC_SIGNALS - 1);
        uint256 value = FIELD + bound(delta, 0, type(uint256).max - FIELD);
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[idx] = value;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.PublicInputOutOfField.selector, idx, value));
        _validate(pub);
    }

    function testFuzz_WrongRecipientReverts(address caller) public {
        if (caller == recipient) caller = address(uint160(recipient) + 1);
        vm.expectRevert(abi.encodeWithSelector(ZkGate.RecipientMismatch.selector, base[21], uint256(uint160(caller))));
        vm.prank(caller);
        gate.exposedValidate(base);
    }

    function testFuzz_WrongCurrentDateReverts(uint256 date) public {
        date = _inFieldExcept(date, base[1]);
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[1] = date;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedCurrentDate.selector, date, base[1]));
        _validate(pub);
    }

    function testFuzz_UnknownIssuerRootReverts(uint256 root) public {
        root = _inFieldExcept(root, base[2]);
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[2] = root;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownIssuerRoot.selector, root));
        _validate(pub);
    }

    function testFuzz_UnknownRevocationRootReverts(uint256 root) public {
        root = _inFieldExcept(root, base[3]);
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[3] = root;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnknownRevocationRoot.selector, root));
        _validate(pub);
    }

    function testFuzz_SanctionedSlotMismatchReverts(uint256 rawSlot, uint256 value) public {
        uint256 slot = bound(rawSlot, 0, 15);
        uint256 expected = base[4 + slot];
        value = _inFieldExcept(value, expected);
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[4 + slot] = value;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.SanctionedListMismatch.selector, slot, value, expected));
        _validate(pub);
    }

    function testFuzz_WrongScopeReverts(uint256 scope) public {
        scope = _inFieldExcept(scope, expectedScope);
        uint256[PUBLIC_SIGNALS] memory pub = base;
        pub[20] = scope;
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedAppScope.selector, scope, expectedScope));
        _validate(pub);
    }

    function testFuzz_ScopeOfAnotherEpochReverts(uint256 secondsAhead) public {
        // Any time outside the fixture's epoch moves the expected scope.
        uint256 epochEnd = (gate.currentEpoch() + 1) * gate.epochDuration();
        vm.warp(bound(secondsAhead, epochEnd, epochEnd + 3650 days));
        uint256 scopeNow = gate.appScope();
        assertTrue(scopeNow != expectedScope);
        vm.expectRevert(abi.encodeWithSelector(ZkGate.UnexpectedAppScope.selector, base[20], scopeNow));
        _validate(base);
    }
}
