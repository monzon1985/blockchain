// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ValidationRegistry} from "../../src/registry/ValidationRegistry.sol";
import {Fixture} from "../utils/Fixture.sol";

contract ValidationRegistryTest is Fixture {
    address internal agentOwner = makeAddr("agentOwner");
    address internal validator = makeAddr("validator");
    address internal validator2 = makeAddr("validator2");
    uint256 internal agentId;
    bytes32 internal constant REQ = keccak256("request");

    function setUp() public override {
        super.setUp();
        vm.prank(agentOwner);
        agentId = identity.register("data:,card");
    }

    function _request(bytes32 requestHash, address v) internal {
        vm.prank(agentOwner);
        validation.validationRequest(v, agentId, "data:,req", requestHash);
    }

    function test_RequestAndRespond() public {
        vm.expectEmit(address(validation));
        emit ValidationRegistry.ValidationRequest(validator, agentId, "data:,req", REQ);
        _request(REQ, validator);

        (address v, uint256 id, uint8 response,, string memory tag, uint256 lastUpdate) =
            validation.getValidationStatus(agentId, REQ);
        assertEq(v, validator);
        assertEq(id, agentId);
        assertEq(response, 0);
        assertEq(tag, "");
        assertEq(lastUpdate, 0, "pending");

        vm.expectEmit(address(validation));
        emit ValidationRegistry.ValidationResponse(
            validator, agentId, REQ, 100, "data:,report", keccak256("r"), "reexec"
        );
        vm.prank(validator);
        validation.validationResponse(agentId, REQ, 100, "data:,report", keccak256("r"), "reexec");
        (,, response,, tag, lastUpdate) = validation.getValidationStatus(agentId, REQ);
        assertEq(response, 100);
        assertEq(tag, "reexec");
        assertEq(lastUpdate, block.timestamp);

        // Responses can be updated.
        vm.prank(validator);
        validation.validationResponse(agentId, REQ, 40, "", bytes32(0), "reexec");
        (,, response,,,) = validation.getValidationStatus(agentId, REQ);
        assertEq(response, 40);

        assertEq(validation.getAgentValidations(agentId).length, 1);
        ValidationRegistry.RequestRef[] memory requests = validation.getValidatorRequests(validator);
        assertEq(requests.length, 1);
        assertEq(requests[0].agentId, agentId);
        assertEq(requests[0].requestHash, REQ);
    }

    function test_OperatorCanRequest() public {
        vm.prank(agentOwner);
        identity.approve(relayer, agentId);
        vm.prank(relayer);
        validation.validationRequest(validator, agentId, "", REQ);
        (address v,,,,,) = validation.getValidationStatus(agentId, REQ);
        assertEq(v, validator);
    }

    /// @notice Regression: request hashes are scoped per agent, so another agent registering the same (predictable)
    ///         hash first, with its own validator, cannot block this agent's validation.
    function test_RequestHashSquattingByAnotherAgentHasNoEffect() public {
        address attacker = makeAddr("attacker");
        address sock = makeAddr("sockValidator");
        vm.prank(attacker);
        uint256 attackerAgent = identity.register("data:,squatter");
        vm.prank(attacker);
        validation.validationRequest(sock, attackerAgent, "", REQ);

        _request(REQ, validator);
        (address v, uint256 id,,,,) = validation.getValidationStatus(agentId, REQ);
        assertEq(v, validator);
        assertEq(id, agentId);
        (v, id,,,,) = validation.getValidationStatus(attackerAgent, REQ);
        assertEq(v, sock);
        assertEq(id, attackerAgent);

        // Each validator can only answer the request that names it.
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.NotValidator.selector, sock, validator));
        vm.prank(sock);
        validation.validationResponse(agentId, REQ, 0, "", bytes32(0), "");
        vm.prank(validator);
        validation.validationResponse(agentId, REQ, 100, "", bytes32(0), "");
        (,, uint8 response,,,) = validation.getValidationStatus(agentId, REQ);
        assertEq(response, 100);
        (,, response,,,) = validation.getValidationStatus(attackerAgent, REQ);
        assertEq(response, 0);
    }

    function test_RevertWhen_RequestInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.NotAgentOperator.selector, relayer, agentId));
        vm.prank(relayer);
        validation.validationRequest(validator, agentId, "", REQ);

        vm.startPrank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.InvalidValidator.selector, address(0)));
        validation.validationRequest(address(0), agentId, "", REQ);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.InvalidValidator.selector, agentOwner));
        validation.validationRequest(agentOwner, agentId, "", REQ);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.InvalidRequestHash.selector, agentId, bytes32(0)));
        validation.validationRequest(validator, agentId, "", bytes32(0));
        validation.validationRequest(validator, agentId, "", REQ);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.InvalidRequestHash.selector, agentId, REQ));
        validation.validationRequest(validator2, agentId, "", REQ);
        vm.stopPrank();
    }

    function test_RevertWhen_ResponseInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.UnknownRequest.selector, agentId, REQ));
        validation.validationResponse(agentId, REQ, 1, "", bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.UnknownRequest.selector, agentId, REQ));
        validation.getValidationStatus(agentId, REQ);

        _request(REQ, validator);
        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.UnknownRequest.selector, agentId + 1, REQ));
        vm.prank(validator);
        validation.validationResponse(agentId + 1, REQ, 100, "", bytes32(0), "");

        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.NotValidator.selector, agentOwner, validator));
        vm.prank(agentOwner);
        validation.validationResponse(agentId, REQ, 100, "", bytes32(0), "");

        vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.ResponseOutOfRange.selector, 101));
        vm.prank(validator);
        validation.validationResponse(agentId, REQ, 101, "", bytes32(0), "");
    }

    function test_GetSummary() public {
        _request(keccak256("a"), validator);
        _request(keccak256("b"), validator);
        _request(keccak256("c"), validator2);
        _request(keccak256("pending"), validator2);
        vm.prank(validator);
        validation.validationResponse(agentId, keccak256("a"), 100, "", bytes32(0), "reexec");
        vm.prank(validator);
        validation.validationResponse(agentId, keccak256("b"), 50, "", bytes32(0), "manual");
        vm.prank(validator2);
        validation.validationResponse(agentId, keccak256("c"), 0, "", bytes32(0), "reexec");

        (uint64 count, uint8 avg) = validation.getSummary(agentId, new address[](0), "");
        assertEq(count, 3);
        assertEq(avg, 50);

        (count, avg) = validation.getSummary(agentId, new address[](0), "reexec");
        assertEq(count, 2);
        assertEq(avg, 50);

        address[] memory only = new address[](1);
        only[0] = validator;
        (count, avg) = validation.getSummary(agentId, only, "");
        assertEq(count, 2);
        assertEq(avg, 75);

        (count, avg) = validation.getSummary(999, new address[](0), "");
        assertEq(count, 0);
        assertEq(avg, 0);
    }

    /// @notice Any score in range is stored verbatim; anything above 100 is rejected.
    function testFuzz_ResponseRange(uint8 response) public {
        _request(REQ, validator);
        vm.prank(validator);
        if (response > 100) {
            vm.expectRevert(abi.encodeWithSelector(ValidationRegistry.ResponseOutOfRange.selector, response));
            validation.validationResponse(agentId, REQ, response, "", bytes32(0), "");
        } else {
            validation.validationResponse(agentId, REQ, response, "", bytes32(0), "");
            (,, uint8 stored,,,) = validation.getValidationStatus(agentId, REQ);
            assertEq(stored, response);
        }
    }
}
