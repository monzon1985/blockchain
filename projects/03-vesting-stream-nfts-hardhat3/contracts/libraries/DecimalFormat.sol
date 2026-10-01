// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LibString} from "solady/src/utils/LibString.sol";

/// @title DecimalFormat
/// @notice Human-readable token amounts and percentages for the NFT art.
/// @dev Every conversion truncates (rounds toward zero): the art never shows more than the contract holds.
library DecimalFormat {
    /// @notice Number of fractional digits shown for token amounts.
    uint256 internal constant FRACTION_DIGITS = 4;

    /// @notice Formats `amount` base units of a token with `decimals` decimals, e.g. `1,234.5678`.
    /// @dev The fraction is truncated to four digits and trailing zeros are removed. A non-zero amount that
    /// truncates to zero is shown as `<0.0001` rather than `0`; that `<` must be escaped wherever the result is
    /// embedded in XML (`StreamRenderer._row` does). `decimals` comes from an untrusted token and may be
    /// anything in 0..255; values above 77 (where `10 ** decimals` overflows) are handled without overflow.
    /// @param amount Amount in base units.
    /// @param decimals Token decimals.
    /// @return Formatted amount.
    function formatUnits(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        uint256 whole = 0;
        uint256 fraction = 0; // floor(amount * 10^4 / 10^decimals) mod 10^4
        if (decimals == 0) {
            whole = amount;
        } else {
            uint256 remainder = amount;
            // 10^77 is the largest power of ten below 2^256. Above that, `amount < 2^256 < 10^decimals`, so the
            // whole part is zero and the remainder is the amount itself.
            if (decimals <= 77) {
                uint256 unit = 10 ** decimals;
                whole = amount / unit;
                remainder = amount % unit;
            }
            if (decimals < FRACTION_DIGITS) {
                fraction = remainder * 10 ** (FRACTION_DIGITS - decimals);
            } else if (decimals - FRACTION_DIGITS <= 77) {
                fraction = remainder / 10 ** (decimals - FRACTION_DIGITS);
            }
        }

        if (whole == 0 && fraction == 0) return amount == 0 ? "0" : "<0.0001";
        string memory integer = groupThousands(whole);
        if (fraction == 0) return integer;
        return string.concat(integer, ".", _fraction(fraction));
    }

    /// @notice Formats a basis-point value as a percentage with two decimals, e.g. `6342` -> `63.42%`.
    /// @param bps Value in basis points (10_000 = 100 %).
    /// @return Formatted percentage.
    function formatBps(uint256 bps) internal pure returns (string memory) {
        uint256 cents = bps % 100;
        return string.concat(LibString.toString(bps / 100), cents < 10 ? ".0" : ".", LibString.toString(cents), "%");
    }

    /// @notice Decimal representation of `value` with a comma every three digits.
    /// @param value Integer to format.
    /// @return out Grouped decimal string, e.g. `1,234,567`.
    function groupThousands(uint256 value) internal pure returns (string memory out) {
        bytes memory digits = bytes(LibString.toString(value));
        uint256 length = digits.length;
        uint256 commas = (length - 1) / 3;
        bytes memory grouped = new bytes(length + commas);
        uint256 j = grouped.length;
        for (uint256 i = length; i > 0; --i) {
            // `(length - i)` digits have been written so far; insert a comma before every complete group of three.
            if ((length - i) > 0 && (length - i) % 3 == 0) grouped[--j] = ",";
            grouped[--j] = digits[i - 1];
        }
        out = string(grouped);
    }

    /// @dev Renders a 1..9999 fraction as four digits with trailing zeros stripped (`500` -> `05`).
    function _fraction(uint256 fraction) private pure returns (string memory) {
        bytes memory buffer = new bytes(FRACTION_DIGITS);
        uint256 length = FRACTION_DIGITS;
        for (uint256 i = FRACTION_DIGITS; i > 0; --i) {
            buffer[i - 1] = bytes1(uint8(48 + (fraction % 10)));
            fraction /= 10;
        }
        while (length > 1 && buffer[length - 1] == "0") --length;
        bytes memory trimmed = new bytes(length);
        for (uint256 i; i < length; ++i) {
            trimmed[i] = buffer[i];
        }
        return string(trimmed);
    }
}
