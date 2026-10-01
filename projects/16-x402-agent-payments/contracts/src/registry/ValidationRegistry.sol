// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IdentityRegistry} from "./IdentityRegistry.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ValidationRegistry
/// @notice ERC-8004-style validation registry. An agent's owner asks a named validator to check a piece of work
///         (identified by `requestHash`, a commitment to the request, the response and the payment receipt); the
///         validator re-executes it and posts a 0..100 score. In this project the validator re-runs the
///         deterministic endpoint and scores the byte-level agreement of the outputs.
/// @dev Follows the ERC-8004 draft interface with one deviation: validations are keyed by `(agentId, requestHash)`,
///      so {validationResponse} and {getValidationStatus} take the agent id. With a global key, anyone could register
///      a free agent and front-run another agent's (deterministic) request hash, blocking its validation for good.
///      Additional rules: an agent cannot name its own owner as validator, and a request hash can be registered only
///      once per agent.
contract ValidationRegistry {
    /// @notice Stored validation.
    /// @param validator Address allowed to respond.
    /// @param lastUpdate Timestamp of the last response (0 = pending).
    /// @param response Last score (0..100).
    /// @param agentId Agent whose work is validated.
    /// @param responseHash Hash of the validator's report.
    /// @param tag Validator-chosen tag.
    struct Validation {
        address validator;
        uint64 lastUpdate;
        uint8 response;
        uint256 agentId;
        bytes32 responseHash;
        string tag;
    }

    /// @notice A request addressed to a validator.
    /// @param agentId Agent whose work is validated.
    /// @param requestHash Commitment to the request data.
    struct RequestRef {
        uint256 agentId;
        bytes32 requestHash;
    }

    /// @notice Highest allowed score.
    uint8 public constant MAX_RESPONSE = 100;

    /// @notice Identity registry used for ownership checks.
    IdentityRegistry public immutable IDENTITY;

    /// @dev Validations by agent and request hash.
    mapping(uint256 agentId => mapping(bytes32 requestHash => Validation)) private _validations;

    /// @dev Request hashes per agent.
    mapping(uint256 agentId => bytes32[]) private _agentValidations;

    /// @dev Requests per validator.
    mapping(address validator => RequestRef[]) private _validatorRequests;

    /// @notice Emitted when an agent owner requests validation.
    /// @param validatorAddress Designated validator.
    /// @param agentId Agent id.
    /// @param requestURI Where the validator finds the request data.
    /// @param requestHash Commitment to the request data.
    event ValidationRequest(
        address indexed validatorAddress, uint256 indexed agentId, string requestURI, bytes32 indexed requestHash
    );

    /// @notice Emitted on every validator response.
    /// @param validatorAddress Validator.
    /// @param agentId Agent id.
    /// @param requestHash Request.
    /// @param response Score (0..100).
    /// @param responseURI Validator report.
    /// @param responseHash Report hash.
    /// @param tag Validator tag.
    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseURI,
        bytes32 responseHash,
        string tag
    );

    /// @notice Caller is not the owner or an operator of the agent.
    /// @param caller The caller.
    /// @param agentId Agent id.
    error NotAgentOperator(address caller, uint256 agentId);

    /// @notice Validator is zero or the agent's owner.
    /// @param validator The validator.
    error InvalidValidator(address validator);

    /// @notice Request hash is zero or already registered for this agent.
    /// @param agentId Agent id.
    /// @param requestHash The hash.
    error InvalidRequestHash(uint256 agentId, bytes32 requestHash);

    /// @notice Unknown request.
    /// @param agentId Agent id.
    /// @param requestHash The hash.
    error UnknownRequest(uint256 agentId, bytes32 requestHash);

    /// @notice Caller is not the designated validator.
    /// @param caller The caller.
    /// @param validator The designated validator.
    error NotValidator(address caller, address validator);

    /// @notice Score above {MAX_RESPONSE}.
    /// @param response The score.
    error ResponseOutOfRange(uint8 response);

    /// @param identity Identity registry.
    constructor(IdentityRegistry identity) {
        IDENTITY = identity;
    }

    /// @notice Requests validation of a piece of the agent's work.
    /// @param validatorAddress Designated validator.
    /// @param agentId Agent id (caller must be owner or operator).
    /// @param requestURI Location of the request data.
    /// @param requestHash Commitment to the request data (unique per agent).
    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external {
        require(IDENTITY.isOwnerOrOperator(agentId, msg.sender), NotAgentOperator(msg.sender, agentId));
        require(
            validatorAddress != address(0) && validatorAddress != IDENTITY.ownerOf(agentId),
            InvalidValidator(validatorAddress)
        );
        require(
            requestHash != bytes32(0) && _validations[agentId][requestHash].validator == address(0),
            InvalidRequestHash(agentId, requestHash)
        );
        _validations[agentId][requestHash] = Validation({
            validator: validatorAddress, lastUpdate: 0, response: 0, agentId: agentId, responseHash: 0, tag: ""
        });
        _agentValidations[agentId].push(requestHash);
        _validatorRequests[validatorAddress].push(RequestRef({agentId: agentId, requestHash: requestHash}));
        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
    }

    /// @notice Posts (or updates) the validator's score.
    /// @param agentId Agent whose request is answered.
    /// @param requestHash Request.
    /// @param response Score 0..100.
    /// @param responseURI Validator report.
    /// @param responseHash Report hash.
    /// @param tag Validator tag.
    function validationResponse(
        uint256 agentId,
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external {
        Validation storage v = _validations[agentId][requestHash];
        require(v.validator != address(0), UnknownRequest(agentId, requestHash));
        require(msg.sender == v.validator, NotValidator(msg.sender, v.validator));
        require(response <= MAX_RESPONSE, ResponseOutOfRange(response));
        v.response = response;
        v.responseHash = responseHash;
        v.tag = tag;
        v.lastUpdate = SafeCast.toUint64(block.timestamp);
        emit ValidationResponse(v.validator, v.agentId, requestHash, response, responseURI, responseHash, tag);
    }

    /// @notice Status of a validation.
    /// @param agentId Agent id.
    /// @param requestHash Request.
    /// @return validatorAddress Designated validator.
    /// @return requestAgentId Agent id (equal to `agentId`; kept for the ERC-8004 return shape).
    /// @return response Last score.
    /// @return responseHash Last report hash.
    /// @return tag Last tag.
    /// @return lastUpdate Timestamp of the last response (0 = pending).
    function getValidationStatus(uint256 agentId, bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 requestAgentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        )
    {
        Validation storage v = _validations[agentId][requestHash];
        require(v.validator != address(0), UnknownRequest(agentId, requestHash));
        return (v.validator, v.agentId, v.response, v.responseHash, v.tag, v.lastUpdate);
    }

    /// @notice Average score of answered validations of an agent.
    /// @param agentId Agent id.
    /// @param validatorAddresses Validators to include (empty = all).
    /// @param tag Tag filter (empty = any).
    /// @return count Number of answered validations included.
    /// @return averageResponse Integer average score (0 when `count == 0`).
    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        returns (uint64 count, uint8 averageResponse)
    {
        bytes32[] storage hashes = _agentValidations[agentId];
        bytes32 tagHash = keccak256(bytes(tag));
        bool filterTag = bytes(tag).length != 0;
        uint256 sum = 0;
        for (uint256 i = 0; i < hashes.length; ++i) {
            Validation storage v = _validations[agentId][hashes[i]];
            if (v.lastUpdate == 0) continue;
            if (filterTag && keccak256(bytes(v.tag)) != tagHash) continue;
            if (validatorAddresses.length != 0 && !_contains(validatorAddresses, v.validator)) continue;
            sum += v.response;
            ++count;
        }
        // The average of values <= 100 is <= 100, so the cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        averageResponse = count == 0 ? 0 : uint8(sum / count);
    }

    /// @notice All request hashes of an agent.
    /// @param agentId Agent id.
    /// @return The hashes.
    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory) {
        return _agentValidations[agentId];
    }

    /// @notice All requests addressed to a validator, as (agent id, request hash) pairs.
    /// @param validatorAddress Validator.
    /// @return The requests.
    function getValidatorRequests(address validatorAddress) external view returns (RequestRef[] memory) {
        return _validatorRequests[validatorAddress];
    }

    function _contains(address[] calldata list, address item) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == item) return true;
        }
        return false;
    }
}
