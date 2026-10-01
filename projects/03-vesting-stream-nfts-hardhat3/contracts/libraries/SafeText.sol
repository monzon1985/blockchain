// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LibString} from "solady/src/utils/LibString.sol";

/// @title SafeText
/// @notice Turns untrusted strings (ERC-20 symbols) into text that is safe inside XML and JSON.
/// @dev Two layers. First, {sanitize} reduces the input to printable ASCII (0x20-0x7E) and a bounded length:
/// control characters are illegal in XML 1.0 even when escaped, and cutting a multi-byte UTF-8 sequence would
/// produce invalid UTF-8. Second, the context-specific escapers from Solady are applied on top:
/// {xml} for SVG text nodes and attribute values, {json} for JSON string values.
library SafeText {
    /// @notice Maximum number of characters kept from an untrusted string.
    uint256 internal constant MAX_LENGTH = 16;

    /// @notice Replacement for any byte outside printable ASCII.
    bytes1 internal constant REPLACEMENT = "?";

    /// @notice Reduces `raw` to at most {MAX_LENGTH} printable ASCII characters.
    /// @dev Bytes outside 0x20-0x7E become `?`. Inputs longer than {MAX_LENGTH} keep their first 13 characters
    /// followed by `...`. An empty input becomes `UNKNOWN`, so a token that fails to answer `symbol()` never
    /// renders as a blank label.
    /// @param raw Untrusted input.
    /// @return clean Printable-ASCII string of length 1..16.
    function sanitize(string memory raw) internal pure returns (string memory clean) {
        bytes memory input = bytes(raw);
        uint256 length = input.length;
        if (length == 0) return "UNKNOWN";

        bool truncated = length > MAX_LENGTH;
        uint256 kept = truncated ? MAX_LENGTH - 3 : length;
        bytes memory out = new bytes(truncated ? MAX_LENGTH : length);
        for (uint256 i; i < kept; ++i) {
            bytes1 c = input[i];
            out[i] = (c >= 0x20 && c <= 0x7e) ? c : REPLACEMENT;
        }
        if (truncated) {
            out[kept] = ".";
            out[kept + 1] = ".";
            out[kept + 2] = ".";
        }
        clean = string(out);
    }

    /// @notice Sanitizes then escapes `raw` for use in XML text nodes and double- or single-quoted attributes.
    /// @param raw Untrusted input.
    /// @return XML-safe text where `& < > " '` are replaced by entity references.
    function xml(string memory raw) internal pure returns (string memory) {
        return LibString.escapeHTML(sanitize(raw));
    }

    /// @notice Sanitizes then escapes `raw` for use inside a JSON string literal.
    /// @param raw Untrusted input.
    /// @return JSON-safe text where `"` and `\` are backslash-escaped.
    function json(string memory raw) internal pure returns (string memory) {
        return LibString.escapeJSON(sanitize(raw));
    }
}
