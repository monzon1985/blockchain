// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {FeedReader} from "../../src/libraries/FeedReader.sol";
import {ObservationRing} from "../../src/libraries/ObservationRing.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";

/// @notice Exposes `ObservationRing` over one storage ring, so the library can be tested (and fuzzed) on its own.
contract ObservationRingHarness {
    using ObservationRing for ObservationRing.Ring;

    ObservationRing.Ring internal ring;

    function record(uint32 timestamp, uint192 answer, uint32 maxGap)
        external
        returns (uint8 index, uint224 cumulative, bool restarted)
    {
        return ring.record(timestamp, answer, maxGap);
    }

    function reset() external returns (bool) {
        return ring.reset();
    }

    function consult(uint32 currentTime, uint32 window) external view returns (bool available, uint256 delta) {
        return ring.consult(currentTime, window);
    }

    function newestAge(uint32 currentTime) external view returns (uint32) {
        return ring.newestAge(currentTime);
    }

    function header() external view returns (ObservationRing.Header memory) {
        return ring.header;
    }

    function observation(uint256 index) external view returns (ObservationRing.Observation memory) {
        return ring.observations[index];
    }
}

/// @notice Exposes `PriceMath`.
contract PriceMathHarness {
    function toWad(uint256 answer, uint8 decimals, IPriceOracle.Intent intent) external pure returns (uint256) {
        return PriceMath.toWad(answer, decimals, intent);
    }

    function averageToWad(uint256 sum, uint256 period, uint8 decimals, IPriceOracle.Intent intent)
        external
        pure
        returns (uint256)
    {
        return PriceMath.averageToWad(sum, period, decimals, intent);
    }

    function deviationBps(uint256 a, uint256 b) external pure returns (uint256) {
        return PriceMath.deviationBps(a, b);
    }
}

/// @notice Exposes `FeedReader`.
contract FeedReaderHarness {
    function latestRound(address feed) external view returns (bool ok, FeedReader.Round memory round) {
        return FeedReader.latestRound(feed);
    }
}

/// @notice A feed that returns far more data than asked for (a return bomb).
contract ReturnBombFeed {
    fallback() external {
        // Safety: deliberately returns 64 KiB of zeroes (memory expansion is paid by this contract).
        assembly ("memory-safe") {
            return(0, 0x10000)
        }
    }
}

/// @notice A feed that returns exactly one word too few.
contract FourWordFeed {
    fallback() external {
        // Safety: deliberately returns 128 bytes where 160 are expected.
        assembly ("memory-safe") {
            mstore(0x00, 1)
            mstore(0x20, 2000)
            return(0, 0x80)
        }
    }
}
