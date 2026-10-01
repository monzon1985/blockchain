// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ComplianceModuleBase} from "./ComplianceModuleBase.sol";
import {IComplianceModule, TransferContext, TransferKind} from "../../interfaces/ICompliance.sol";

/// @title TransferWindowModule
/// @notice Restricts peer-to-peer transfers to a trading window: selected UTC weekdays, between `openSecond`
///         (inclusive) and `closeSecond` (exclusive) seconds after UTC midnight.
/// @dev Only `TransferKind.Transfer` is gated. Issuance, redemption requests, forced transfers and recoveries
///      are operational flows with their own controls and are not tied to secondary-market hours.
contract TransferWindowModule is ComplianceModuleBase {
    /// @notice Seconds per day.
    uint32 public constant DAY = 86_400;
    /// @notice Weekday mask with all seven days (bit 0 = Monday ... bit 6 = Sunday).
    uint8 public constant ALL_DAYS = 0x7f;

    /// @notice Whether the window is enforced.
    bool public enabled;
    /// @notice Allowed weekdays, bit 0 = Monday ... bit 6 = Sunday.
    uint8 public weekdayMask;
    /// @notice Window start, seconds after UTC midnight (inclusive).
    uint32 public openSecond;
    /// @notice Window end, seconds after UTC midnight (exclusive).
    uint32 public closeSecond;

    /// @notice Emitted when the window configuration changes.
    /// @param enabled Whether enforced.
    /// @param weekdayMask Allowed weekdays.
    /// @param openSecond Start.
    /// @param closeSecond End.
    event TransferWindowSet(bool enabled, uint8 weekdayMask, uint32 openSecond, uint32 closeSecond);

    /// @notice Empty weekday mask, bits above Sunday, or an empty / out-of-day time range.
    error InvalidWindow(uint8 weekdayMask, uint32 openSecond, uint32 closeSecond);

    /// @param initialAuthority AccessManager.
    /// @param engine_ Compliance engine.
    constructor(address initialAuthority, address engine_) ComplianceModuleBase(initialAuthority, engine_) {}

    /// @notice Enables the window with the given schedule.
    /// @param mask Allowed weekdays (bit 0 = Monday).
    /// @param open Start second (inclusive).
    /// @param close End second (exclusive), at most 86 400.
    function setWindow(uint8 mask, uint32 open, uint32 close) external restricted {
        require(mask != 0 && mask <= ALL_DAYS && open < close && close <= DAY, InvalidWindow(mask, open, close));
        enabled = true;
        weekdayMask = mask;
        openSecond = open;
        closeSecond = close;
        emit TransferWindowSet(true, mask, open, close);
    }

    /// @notice Disables the window (transfers allowed at any time).
    function disableWindow() external restricted {
        enabled = false;
        emit TransferWindowSet(false, weekdayMask, openSecond, closeSecond);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "TransferWindow";
    }

    /// @notice Whether the window is open at `timestamp`.
    /// @param timestamp Unix time.
    /// @return True if a peer-to-peer transfer would be allowed.
    function isOpenAt(uint256 timestamp) public view returns (bool) {
        if (!enabled) return true;
        // 1970-01-01 was a Thursday; with Monday = 0 that is weekday 3. Calendar arithmetic, not randomness.
        // slither-disable-start weak-prng
        uint256 weekday = (timestamp / DAY + 3) % 7;
        uint256 second = timestamp % DAY;
        // slither-disable-end weak-prng
        return (weekdayMask >> weekday) & 1 == 1 && second >= openSecond && second < closeSecond;
    }

    /// @inheritdoc IComplianceModule
    function check(TransferContext calldata ctx) external view returns (bool) {
        return ctx.kind != TransferKind.Transfer || isOpenAt(block.timestamp);
    }
}
