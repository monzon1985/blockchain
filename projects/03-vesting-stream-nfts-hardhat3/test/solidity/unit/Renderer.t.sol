// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibString} from "solady/src/utils/LibString.sol";

import {RawSymbolToken} from "../../../contracts/mocks/RawSymbolToken.sol";
import {CreateParams, Milestone, Shape} from "../../../contracts/types/StreamTypes.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice On-chain rendering: SSTORE2 fragments, hostile token metadata, and "rendering never reverts" fuzzing.
/// Byte-exact output and XML well-formedness are checked by the node:test golden-file suite.
contract RendererTest is BaseTest {
    RawSymbolToken internal raw;

    function setUp() public override {
        super.setUp();
        raw = new RawSymbolToken(bytes("RAW"), 18);
        raw.mint(sender, type(uint256).max / 2);
        vm.prank(sender);
        raw.approve(address(vesting), type(uint256).max);
    }

    function test_fragmentsLiveInSstore2DataContracts() public view {
        bytes memory head = renderer.HEAD_POINTER().code;
        bytes memory frame = renderer.FRAME_POINTER().code;
        // SSTORE2 prefixes the data with a STOP opcode so the data contract can never be executed.
        assertEq(uint8(head[0]), 0x00);
        assertEq(uint8(frame[0]), 0x00);
        assertTrue(LibString.startsWith(string(head), string(abi.encodePacked(bytes1(0), "<svg xmlns="))));
        assertGt(head.length, 1000);
    }

    function test_tokenUriIsBase64Json() public {
        uint256 id = _createDefaultLinear();
        string memory uri = vesting.tokenURI(id);
        assertTrue(LibString.startsWith(uri, "data:application/json;base64,"));
    }

    function test_svgOf_isACompleteSvgDocument() public {
        uint256 id = _createDefaultSegmented();
        vm.warp(T0 + 5 * MONTH);
        string memory svg = renderer.svgOf(vesting, id);
        assertTrue(LibString.startsWith(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(LibString.endsWith(svg, "</svg>"));
        assertTrue(LibString.contains(svg, "PIECEWISE LINEAR | 3 SEGMENTS | CANCELABLE"));
        assertTrue(LibString.contains(svg, ">1,500 MOCK</text>")); // 1,000 + 3,000 * 1/6 streamed at month 5
        assertTrue(LibString.contains(svg, ">4,000 MOCK</text>"));
    }

    function test_hostileSymbolIsEscapedInSvg() public {
        raw.setSymbol(bytes("<script>alert(1)</script>"), RawSymbolToken.SymbolMode.AbiString);
        uint256 id = _createRaw();
        string memory svg = renderer.svgOf(vesting, id);
        assertFalse(LibString.contains(svg, "<script"));
        assertTrue(LibString.contains(svg, "&lt;script&gt;alert..."));
    }

    function test_revertingSymbolRendersUnknown() public {
        raw.setSymbol("", RawSymbolToken.SymbolMode.Revert);
        assertTrue(LibString.contains(renderer.svgOf(vesting, _createRaw()), " UNKNOWN</text>"));
    }

    function test_gasBurningSymbolIsCappedAndRendersUnknown() public {
        raw.setSymbol("", RawSymbolToken.SymbolMode.BurnGas);
        uint256 id = _createRaw();
        uint256 before = gasleft();
        string memory svg = renderer.svgOf(vesting, id);
        uint256 used = before - gasleft();
        assertTrue(LibString.contains(svg, " UNKNOWN</text>"));
        assertLt(used, 2_000_000);
    }

    function test_emptyReturnDataRendersUnknown() public {
        raw.setSymbol("", RawSymbolToken.SymbolMode.Empty);
        assertTrue(LibString.contains(renderer.svgOf(vesting, _createRaw()), " UNKNOWN</text>"));
    }

    function test_bytes32SymbolIsDecoded() public {
        raw.setSymbol(bytes("MKR"), RawSymbolToken.SymbolMode.Bytes32);
        assertTrue(LibString.contains(renderer.svgOf(vesting, _createRaw()), " MKR</text>"));
    }

    /// Dust (a non-zero amount below 0.0001 tokens) is displayed as `<0.0001`, which must reach the SVG escaped.
    /// 10,000 tokens over four years stream about 0.00008 tokens per second.
    function test_dustAmountsAreXmlEscaped() public {
        uint40 end = T0 + 4 * 365 days;
        uint256 id = _create(_linear(alice, uint128(10_000 * E18), T0, 0, end));
        vm.warp(T0 + 1); // streamed = 79,274,479,959,411 base units
        string memory svg = renderer.svgOf(vesting, id);
        assertTrue(LibString.contains(svg, '<text x="236" y="180" class="v">&lt;0.0001 MOCK</text>')); // STREAMED
        assertTrue(LibString.contains(svg, 'WITHDRAWABLE</text><text x="236" y="276" class="v">&lt;0.0001 MOCK</text>'));
        assertFalse(LibString.contains(svg, "<0.0001"));
        _assertMarkupWellFormed(svg);

        // A cancel one second before the end leaves a dust refund, displayed for the rest of the NFT's life.
        vm.warp(end - 1);
        vm.prank(sender);
        vesting.cancel(id);
        vm.warp(end + 3650 days);
        svg = renderer.svgOf(vesting, id);
        assertTrue(LibString.contains(svg, 'class="k">REFUNDED</text><text x="236" y="276" class="v">&lt;0.0001 MOCK'));
        assertFalse(LibString.contains(svg, "<0.0001"));
        _assertMarkupWellFormed(svg);
    }

    function test_revertingDecimalsFallBackToBaseUnits() public {
        raw.setDecimals(0, true);
        uint256 id = _createRaw(); // deposit 1e18 base units
        assertTrue(LibString.contains(renderer.svgOf(vesting, id), ">1,000,000,000,000,000,000 RAW</text>"));
    }

    /// Rendering never reverts and always produces well-formed markup, whatever the shape, schedule, amounts,
    /// decimals, time and cancel state; a revert would blank the NFT on every marketplace, and broken markup would
    /// show a broken image. Small deposits and large decimals make dust (`<0.0001`) rows frequent.
    function testFuzz_renderingNeverReverts(
        uint8 shapeSeed,
        uint8 count,
        uint128 deposit,
        uint40 duration,
        uint8 decimals,
        uint40 renderOffset,
        bool cancel
    ) public {
        raw.setDecimals(decimals, false);
        Shape shape = Shape(bound(shapeSeed, 0, 2));
        deposit = uint128(bound(deposit, 1, type(uint128).max / 64));
        duration = uint40(bound(duration, 2, 20 * 365 days));
        CreateParams memory p;
        if (shape == Shape.LinearCliff) {
            p = _linear(alice, deposit, T0, count % 2 == 0 ? 0 : T0 + duration / 2, T0 + duration);
        } else {
            uint256 n = bound(count, 1, shape == Shape.Tranched ? 32 : 16);
            Milestone[] memory m = _even(n, deposit / uint128(n) + 1, T0, uint40(duration / n + 1));
            p = _withMilestones(alice, shape, T0, m);
        }
        vm.prank(sender);
        uint256 id = vesting.create(IERC20(address(raw)), p);

        vm.warp(uint256(T0) + bound(renderOffset, 0, uint256(duration) * 2));
        if (cancel && vesting.refundableAmountOf(id) > 0) {
            vm.prank(sender);
            vesting.cancel(id);
            vm.warp(block.timestamp + 1 days);
        }
        string memory svg = renderer.svgOf(vesting, id);
        assertTrue(LibString.endsWith(svg, "</svg>"));
        _assertMarkupWellFormed(svg);
        assertTrue(LibString.startsWith(vesting.tokenURI(id), "data:application/json;base64,"));
    }

    /// The markup checker used by the fuzz test rejects the documents an unescaped amount or symbol would produce.
    function test_markupCheckerRejectsUnescapedText() public {
        _assertMarkupWellFormed('<svg><text x="1">&lt;0.0001 A&amp;B &quot;&#39;&gt;</text></svg>');
        string[5] memory broken = [
            string('<svg><text x="1"><0.0001 MOCK</text></svg>'), // unescaped dust amount
            "<svg><text>A&B</text></svg>", // bare ampersand
            "<svg><text>a > b</text></svg>", // '>' in text (the renderer escapes every '>')
            '<svg><text x="<">1</text></svg>', // '<' inside a tag
            "<svg><text>1</text></svg" // unterminated tag
        ];
        for (uint256 i; i < broken.length; ++i) {
            (bool ok,) = address(this).call(abi.encodeCall(this.assertMarkupWellFormedExternal, (broken[i])));
            assertFalse(ok, broken[i]);
        }
    }

    function assertMarkupWellFormedExternal(string calldata svg) external pure {
        _assertMarkupWellFormed(svg);
    }

    function _createRaw() internal returns (uint256) {
        vm.prank(sender);
        return vesting.create(IERC20(address(raw)), _linear(alice, 1e18, T0, 0, T0 + MONTH));
    }

    /// @dev Lexical XML check, cheap enough for the fuzzer (the node:test suites run a full XML validator on top):
    /// every `<` opens a tag (it is followed by a letter or `/`), tags do not nest, every `>` closes a tag (the
    /// renderer escapes `>` in text, and its static CSS contains none), and every `&` starts one of the references
    /// Solady's `escapeHTML` emits.
    function _assertMarkupWellFormed(string memory svg) internal pure {
        bytes memory b = bytes(svg);
        bool inTag;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "<") {
                require(!inTag, "'<' inside a tag");
                require(i + 1 < b.length && (_isLetter(b[i + 1]) || b[i + 1] == "/"), "'<' does not open a tag");
                inTag = true;
            } else if (c == ">") {
                require(inTag, "'>' outside a tag");
                inTag = false;
            } else if (c == "&") {
                require(_startsWithReference(b, i), "'&' does not start an entity reference");
            }
        }
        require(!inTag, "unterminated tag");
    }

    function _isLetter(bytes1 c) private pure returns (bool) {
        return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
    }

    function _startsWithReference(bytes memory b, uint256 at) private pure returns (bool) {
        string[5] memory references = [string("&amp;"), "&lt;", "&gt;", "&quot;", "&#39;"];
        for (uint256 r; r < references.length; ++r) {
            bytes memory ref = bytes(references[r]);
            if (at + ref.length > b.length) continue;
            bool matches = true;
            for (uint256 k; k < ref.length && matches; ++k) {
                matches = b[at + k] == ref[k];
            }
            if (matches) return true;
        }
        return false;
    }
}
