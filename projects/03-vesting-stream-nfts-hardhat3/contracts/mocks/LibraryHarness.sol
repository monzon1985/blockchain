// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DecimalFormat} from "../libraries/DecimalFormat.sol";
import {SafeText} from "../libraries/SafeText.sol";
import {StreamMath} from "../libraries/StreamMath.sol";
import {Milestone} from "../types/StreamTypes.sol";

/// @notice Test-only wrapper exposing the internal libraries to the TypeScript differential tests.
contract LibraryHarness {
    function formatUnits(uint256 amount, uint8 decimals) external pure returns (string memory) {
        return DecimalFormat.formatUnits(amount, decimals);
    }

    function formatBps(uint256 bps) external pure returns (string memory) {
        return DecimalFormat.formatBps(bps);
    }

    function sanitize(string calldata raw) external pure returns (string memory) {
        return SafeText.sanitize(raw);
    }

    function xml(string calldata raw) external pure returns (string memory) {
        return SafeText.xml(raw);
    }

    function json(string calldata raw) external pure returns (string memory) {
        return SafeText.json(raw);
    }

    function linear(uint128 deposit, uint40 start, uint40 cliff, uint40 end, uint40 t) external pure returns (uint128) {
        return StreamMath.linear(deposit, start, cliff, end, t);
    }

    function segmented(Milestone[] calldata segments, uint40 start, uint40 t) external pure returns (uint128) {
        return StreamMath.segmented(segments, start, t);
    }

    function tranched(Milestone[] calldata tranches, uint40 t) external pure returns (uint128) {
        return StreamMath.tranched(tranches, t);
    }
}
