// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {DecimalFormat} from "../../../contracts/libraries/DecimalFormat.sol";
import {MilestoneCodec} from "../../../contracts/libraries/MilestoneCodec.sol";
import {SafeText} from "../../../contracts/libraries/SafeText.sol";
import {Milestone} from "../../../contracts/types/StreamTypes.sol";

/// @notice MilestoneCodec round trips, SafeText escaping properties and DecimalFormat edge cases.
contract LibrariesTest is Test {
    /*//////////////////////////////////////////////////////////////
                             MILESTONE CODEC
    //////////////////////////////////////////////////////////////*/

    /// @dev External so that `MilestoneCodec.encode` receives calldata, as it does in production.
    function encodeExternal(Milestone[] calldata milestones) external pure returns (bytes memory) {
        return MilestoneCodec.encode(milestones);
    }

    function test_codec_packsTwentyOneBytesPerMilestone() public view {
        Milestone[] memory m = new Milestone[](2);
        m[0] = Milestone(type(uint128).max, type(uint40).max);
        m[1] = Milestone(1, 2);
        bytes memory packed = this.encodeExternal(m);
        assertEq(packed, abi.encodePacked(m[0].amount, m[0].timestamp, m[1].amount, m[1].timestamp));
    }

    function testFuzz_codec_roundTrip(bytes32 seed, uint8 count) public view {
        Milestone[] memory m = new Milestone[](bound(count, 0, 32));
        for (uint256 i; i < m.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            m[i] = Milestone(uint128(r), uint40(r >> 128));
        }
        bytes memory packed = this.encodeExternal(m);
        assertEq(packed.length, m.length * 21);
        Milestone[] memory decoded = MilestoneCodec.decode(packed);
        assertEq(decoded.length, m.length);
        for (uint256 i; i < m.length; ++i) {
            assertEq(decoded[i].amount, m[i].amount);
            assertEq(decoded[i].timestamp, m[i].timestamp);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                SAFE TEXT
    //////////////////////////////////////////////////////////////*/

    function test_sanitize_cases() public pure {
        assertEq(SafeText.sanitize(""), "UNKNOWN");
        assertEq(SafeText.sanitize("USDC"), "USDC");
        assertEq(SafeText.sanitize("ABCDEFGHIJKLMNOP"), "ABCDEFGHIJKLMNOP"); // 16 chars kept
        assertEq(SafeText.sanitize("ABCDEFGHIJKLMNOPQ"), "ABCDEFGHIJKLM..."); // 17 chars truncated
        assertEq(SafeText.sanitize("a\x00b\nc\x7f"), "a?b?c?");
        assertEq(SafeText.sanitize(unicode"€"), "???"); // multi-byte UTF-8 never gets cut in half
    }

    function test_xml_escapesMarkup() public pure {
        assertEq(SafeText.xml("<a b=\"x\">'&'</a>"), "&lt;a b=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
    }

    function test_json_escapesQuotesAndBackslashes() public pure {
        assertEq(SafeText.json("a\"b\\c"), "a\\\"b\\\\c");
    }

    /// Sanitized output is 1..16 printable ASCII characters, and short inputs map byte for byte.
    function testFuzz_sanitize_printableAsciiAndBounded(bytes memory raw) public pure {
        bytes memory clean = bytes(SafeText.sanitize(string(raw)));
        assertGe(clean.length, 1);
        assertLe(clean.length, 16);
        for (uint256 i; i < clean.length; ++i) {
            assertTrue(clean[i] >= 0x20 && clean[i] <= 0x7e, "non-printable byte");
        }
        if (raw.length != 0 && raw.length <= 16) {
            for (uint256 i; i < raw.length; ++i) {
                bytes1 expected = raw[i] >= 0x20 && raw[i] <= 0x7e ? raw[i] : bytes1("?");
                assertEq(clean[i], expected);
            }
        }
    }

    /// XML output has no raw markup characters, every '&' starts a known entity, and unescaping gives back the
    /// sanitized string.
    function testFuzz_xml_noRawMarkupAndRoundTrips(bytes memory raw) public pure {
        bytes memory out = bytes(SafeText.xml(string(raw)));
        bytes memory decoded = new bytes(out.length);
        uint256 n;
        for (uint256 i; i < out.length; ++i) {
            bytes1 c = out[i];
            assertTrue(c != "<" && c != ">" && c != '"' && c != "'", "raw markup character");
            if (c != "&") {
                decoded[n++] = c;
                continue;
            }
            (bytes1 ch, uint256 len) = _entity(out, i);
            assertTrue(len != 0, "unknown entity");
            decoded[n++] = ch;
            i += len - 1;
        }
        assembly ("memory-safe") {
            mstore(decoded, n)
        }
        assertEq(string(decoded), SafeText.sanitize(string(raw)));
    }

    /// JSON output never contains an unescaped quote or backslash and unescapes back to the sanitized string.
    function testFuzz_json_quotesAlwaysEscaped(bytes memory raw) public pure {
        bytes memory out = bytes(SafeText.json(string(raw)));
        bytes memory decoded = new bytes(out.length);
        uint256 n;
        for (uint256 i; i < out.length; ++i) {
            bytes1 c = out[i];
            assertTrue(c >= 0x20 && c != '"', "unescaped quote or control character");
            if (c == "\\") {
                bytes1 next = out[++i];
                assertTrue(next == '"' || next == "\\", "unexpected escape");
                decoded[n++] = next;
            } else {
                decoded[n++] = c;
            }
        }
        assembly ("memory-safe") {
            mstore(decoded, n)
        }
        assertEq(string(decoded), SafeText.sanitize(string(raw)));
    }

    /*//////////////////////////////////////////////////////////////
                             DECIMAL FORMAT
    //////////////////////////////////////////////////////////////*/

    function test_formatUnits_cases() public pure {
        assertEq(DecimalFormat.formatUnits(0, 18), "0");
        assertEq(DecimalFormat.formatUnits(1, 18), "<0.0001");
        assertEq(DecimalFormat.formatUnits(1e14, 18), "0.0001");
        assertEq(DecimalFormat.formatUnits(1_234_567_891_234_567_891_234, 18), "1,234.5678");
        assertEq(DecimalFormat.formatUnits(1000e6, 6), "1,000");
        assertEq(DecimalFormat.formatUnits(1.5e6, 6), "1.5");
        assertEq(DecimalFormat.formatUnits(1_050_000, 6), "1.05");
        assertEq(DecimalFormat.formatUnits(12_345, 2), "123.45");
        assertEq(DecimalFormat.formatUnits(7, 0), "7");
        assertEq(
            DecimalFormat.formatUnits(type(uint256).max, 0),
            "115,792,089,237,316,195,423,570,985,008,687,907,853,269,984,665,640,564,039,457,584,007,913,129,639,935"
        );
        assertEq(DecimalFormat.formatUnits(10 ** 77, 77), "1");
        assertEq(DecimalFormat.formatUnits(type(uint256).max, 78), "0.1157");
        assertEq(DecimalFormat.formatUnits(type(uint256).max, 81), "0.0001");
        assertEq(DecimalFormat.formatUnits(type(uint256).max, 82), "<0.0001");
        assertEq(DecimalFormat.formatUnits(1, 255), "<0.0001");
    }

    function test_groupThousands_boundaries() public pure {
        assertEq(DecimalFormat.groupThousands(0), "0");
        assertEq(DecimalFormat.groupThousands(999), "999");
        assertEq(DecimalFormat.groupThousands(1000), "1,000");
        assertEq(DecimalFormat.groupThousands(100_000), "100,000");
        assertEq(DecimalFormat.groupThousands(1_000_000), "1,000,000");
    }

    function test_formatBps_cases() public pure {
        assertEq(DecimalFormat.formatBps(0), "0.00%");
        assertEq(DecimalFormat.formatBps(5), "0.05%");
        assertEq(DecimalFormat.formatBps(6342), "63.42%");
        assertEq(DecimalFormat.formatBps(10_000), "100.00%");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Decodes the XML entity starting at `out[i]`; returns its character and length, or length 0 if unknown.
    function _entity(bytes memory out, uint256 i) internal pure returns (bytes1, uint256) {
        if (_startsWith(out, i, "&lt;")) return ("<", 4);
        if (_startsWith(out, i, "&gt;")) return (">", 4);
        if (_startsWith(out, i, "&amp;")) return ("&", 5);
        if (_startsWith(out, i, "&quot;")) return ('"', 6);
        if (_startsWith(out, i, "&#39;")) return ("'", 5);
        return (0, 0);
    }

    function _startsWith(bytes memory data, uint256 offset, bytes memory prefix) internal pure returns (bool) {
        if (offset + prefix.length > data.length) return false;
        for (uint256 j; j < prefix.length; ++j) {
            if (data[offset + j] != prefix[j]) return false;
        }
        return true;
    }
}
