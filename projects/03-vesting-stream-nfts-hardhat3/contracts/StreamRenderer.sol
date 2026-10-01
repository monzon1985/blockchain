// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "solady/src/utils/Base64.sol";
import {DateTimeLib} from "solady/src/utils/DateTimeLib.sol";
import {DynamicBufferLib} from "solady/src/utils/DynamicBufferLib.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {MetadataReaderLib} from "solady/src/utils/MetadataReaderLib.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import {IStreamRenderer} from "./interfaces/IStreamRenderer.sol";
import {IVestingStreams} from "./interfaces/IVestingStreams.sol";
import {DecimalFormat} from "./libraries/DecimalFormat.sol";
import {SafeText} from "./libraries/SafeText.sol";
import {StreamMath} from "./libraries/StreamMath.sol";
import {Milestone, Shape, Status, Stream} from "./types/StreamTypes.sol";

/// @title StreamRenderer
/// @notice Renders a vesting stream as a fully on-chain SVG card (progress ring, amounts, schedule chart) wrapped in
/// Base64 JSON metadata.
/// @dev The static parts of the SVG (defs, styles, background, labels, chart frame) are written once at deployment
/// into two SSTORE2 data contracts, so they live in initcode rather than in this contract's runtime bytecode.
/// Everything derived from the ERC-20 (symbol, decimals) is untrusted: it is read with a gas cap through Solady's
/// `MetadataReaderLib`, reduced to printable ASCII and escaped for its context (XML or JSON). All geometry is integer
/// math rounded toward zero.
contract StreamRenderer is IStreamRenderer {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas forwarded to the token's `symbol()` and `decimals()` so a hostile token cannot exhaust the call.
    uint256 public constant TOKEN_QUERY_GAS = 50_000;

    /// @notice Maximum number of bytes read from `symbol()` before sanitization.
    uint256 internal constant SYMBOL_READ_LIMIT = 64;

    /// @notice Left edge of the schedule chart's plot area, in SVG pixels.
    uint256 internal constant PLOT_X = 48;

    /// @notice Width of the plot area: the x axis maps `[startTime, endTime]` onto `[PLOT_X, PLOT_X + PLOT_W]`.
    uint256 internal constant PLOT_W = 404;

    /// @notice y coordinate of the chart baseline (zero vested); SVG y grows downward.
    uint256 internal constant PLOT_BOTTOM = 400;

    /// @notice Height of the plot area: the full deposit is drawn at `PLOT_BOTTOM - PLOT_H`.
    uint256 internal constant PLOT_H = 80;

    /// @notice Width available to an amount row before the text is compressed with `textLength`.
    uint256 internal constant ROW_MAX_CHARS = 25;

    /// @notice Circumference of the outer (streamed) ring in hundredths of a pixel, rounded down: 2 * pi * 74.
    uint256 internal constant OUTER_RING_CIRCUMFERENCE = 46_495;

    /// @notice Circumference of the inner (withdrawn) ring in hundredths of a pixel, rounded down: 2 * pi * 56.
    uint256 internal constant INNER_RING_CIRCUMFERENCE = 35_185;

    /// @dev SVG prologue: root element, gradients, stylesheet, background and the title label.
    string internal constant SVG_HEAD = '<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500" '
        'viewBox="0 0 500 500"><defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#0b1020"/><stop offset="1" stop-color="#1a2244"/></linearGradient>'
        '<linearGradient id="arc" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7dd3fc"/>'
        '<stop offset="1" stop-color="#a78bfa"/></linearGradient><linearGradient id="area" x1="0" y1="0" x2="0" '
        'y2="1"><stop offset="0" stop-color="#7dd3fc" stop-opacity=".35"/><stop offset="1" stop-color="#7dd3fc" '
        'stop-opacity="0"/></linearGradient></defs><style>text{font-family:ui-monospace,SFMono-Regular,Menlo,'
        "Consolas,monospace;fill:#e2e8f0}.k{font-size:10px;fill:#94a3b8;letter-spacing:2px}.v{font-size:15px}"
        ".t{font-size:24px;font-weight:700}.p{font-size:22px;font-weight:700}.b{font-size:11px;font-weight:700;"
        "fill:#0b1020;letter-spacing:1px}.f{font-size:10px;fill:#64748b}.d{font-size:10px;fill:#94a3b8}</style>"
        '<rect width="500" height="500" rx="24" fill="url(#bg)"/><rect x="10" y="10" width="480" height="480" '
        'rx="18" fill="none" stroke="#fff" stroke-opacity=".08"/><text x="32" y="46" class="k">VESTING STREAM</text>';

    /// @dev Static body: ring tracks, row labels and the chart frame.
    string internal constant SVG_FRAME = '<circle cx="120" cy="190" r="74" fill="none" stroke="#fff" '
        'stroke-opacity=".08" stroke-width="12"/><circle cx="120" cy="190" r="56" fill="none" stroke="#fff" '
        'stroke-opacity=".06" stroke-width="6"/><text x="120" y="218" text-anchor="middle" class="k">VESTED</text>'
        '<text x="236" y="112" class="k">DEPOSITED</text><text x="236" y="160" class="k">STREAMED</text>'
        '<text x="236" y="208" class="k">WITHDRAWN</text><rect x="32" y="304" width="436" height="132" rx="10" '
        'fill="#fff" fill-opacity=".03" stroke="#fff" stroke-opacity=".08"/>';

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice SSTORE2 data contract holding {SVG_HEAD}.
    address public immutable HEAD_POINTER;

    /// @notice SSTORE2 data contract holding {SVG_FRAME}.
    address public immutable FRAME_POINTER;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Snapshot of everything the card needs, read once from the vesting contract and the token.
    struct Card {
        uint256 streamId;
        Stream stream;
        Milestone[] milestones;
        uint128 streamed;
        Status status;
        string rawSymbol;
        uint8 decimals;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        HEAD_POINTER = SSTORE2.write(bytes(SVG_HEAD));
        FRAME_POINTER = SSTORE2.write(bytes(SVG_FRAME));
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStreamRenderer
    function tokenURI(IVestingStreams streams, uint256 streamId) external view override returns (string memory) {
        Card memory card = _load(streams, streamId);
        return string.concat("data:application/json;base64,", Base64.encode(_json(card, _svg(card))));
    }

    /// @inheritdoc IStreamRenderer
    function svgOf(IVestingStreams streams, uint256 streamId) external view override returns (string memory) {
        return string(_svg(_load(streams, streamId)));
    }

    /*//////////////////////////////////////////////////////////////
                                LOADING
    //////////////////////////////////////////////////////////////*/

    /// @dev Reads the stream from `streams` and the symbol/decimals from the token (gas-capped, never reverts).
    function _load(IVestingStreams streams, uint256 streamId) internal view returns (Card memory card) {
        card.streamId = streamId;
        card.stream = streams.getStream(streamId);
        card.milestones = streams.getMilestones(streamId);
        card.streamed = streams.streamedAmountOf(streamId);
        card.status = streams.statusOf(streamId);
        address token = address(card.stream.token);
        card.rawSymbol = MetadataReaderLib.readSymbol(token, SYMBOL_READ_LIMIT, TOKEN_QUERY_GAS);
        card.decimals = MetadataReaderLib.readDecimals(token, TOKEN_QUERY_GAS);
    }

    // DynamicBufferLib's `p` appends in place and returns the same buffer for chaining; the return value is
    // intentionally unused throughout the rendering code below.
    // slither-disable-start unused-return

    /*//////////////////////////////////////////////////////////////
                                  SVG
    //////////////////////////////////////////////////////////////*/

    /// @dev Assembles the card: SSTORE2 head, header, SSTORE2 frame, ring, amount rows, chart, footer.
    function _svg(Card memory card) internal view returns (bytes memory) {
        // An empty buffer is the intended starting state.
        // slither-disable-next-line uninitialized-local
        DynamicBufferLib.DynamicBuffer memory svg;
        svg.reserve(6144);
        svg.p(SSTORE2.read(HEAD_POINTER));
        _header(svg, card);
        svg.p(SSTORE2.read(FRAME_POINTER));
        _ring(svg, card);
        _rows(svg, card);
        _chart(svg, card);
        _footer(svg, card);
        svg.p("</svg>");
        return svg.data;
    }

    /// @dev Stream id and the status pill.
    function _header(DynamicBufferLib.DynamicBuffer memory svg, Card memory card) internal pure {
        (string memory label, string memory color) = _statusStyle(card.status);
        svg.p(
            '<text x="32" y="78" class="t">#',
            bytes(LibString.toString(card.streamId)),
            '</text><rect x="340" y="32" width="128" height="26" rx="13" fill="',
            bytes(color),
            '"/><text x="404" y="49" text-anchor="middle" class="b">',
            bytes(label),
            "</text>"
        );
    }

    /// @dev Outer arc: streamed / deposit. Inner arc: withdrawn / deposit. Both in basis points, rounded down.
    /// Dash lengths are computed in user units from the circumference instead of relying on `pathLength`, which
    /// some SVG rasterizers ignore.
    function _ring(DynamicBufferLib.DynamicBuffer memory svg, Card memory card) internal pure {
        uint256 deposit = card.stream.depositAmount;
        uint256 streamedBps = (uint256(card.streamed) * 10_000) / deposit;
        uint256 withdrawnBps = (uint256(card.stream.withdrawnAmount) * 10_000) / deposit;
        svg.p(
            '<circle cx="120" cy="190" r="74" fill="none" stroke="url(#arc)" stroke-width="12" stroke-dasharray="',
            bytes(_dash(streamedBps, OUTER_RING_CIRCUMFERENCE)),
            ' 1000" transform="rotate(-90 120 190)"/><circle cx="120" cy="190" r="56" fill="none" stroke="#34d399" '
            'stroke-width="6" stroke-dasharray="',
            bytes(_dash(withdrawnBps, INNER_RING_CIRCUMFERENCE)),
            ' 1000" transform="rotate(-90 120 190)"/><text x="120" y="198" text-anchor="middle" class="p">',
            bytes(DecimalFormat.formatBps(streamedBps))
        );
        svg.p("</text>");
    }

    /// @dev `bps` of a circumference given in hundredths of a pixel, as a decimal with two digits, rounded down.
    function _dash(uint256 bps, uint256 circumference) internal pure returns (string memory) {
        uint256 hundredths = (bps * circumference) / 10_000;
        uint256 cents = hundredths % 100;
        return string.concat(LibString.toString(hundredths / 100), cents < 10 ? ".0" : ".", LibString.toString(cents));
    }

    /// @dev Deposited / streamed / withdrawn, then withdrawable (live) or refunded (canceled).
    function _rows(DynamicBufferLib.DynamicBuffer memory svg, Card memory card) internal pure {
        string memory symbol = SafeText.sanitize(card.rawSymbol);
        Stream memory stream = card.stream;
        uint8 decimals = card.decimals;
        _row(svg, "132", DecimalFormat.formatUnits(stream.depositAmount, decimals), symbol);
        _row(svg, "180", DecimalFormat.formatUnits(card.streamed, decimals), symbol);
        _row(svg, "228", DecimalFormat.formatUnits(stream.withdrawnAmount, decimals), symbol);
        if (stream.canceled) {
            svg.p('<text x="236" y="256" class="k">REFUNDED</text>');
            _row(svg, "276", DecimalFormat.formatUnits(stream.refundedAmount, decimals), symbol);
        } else {
            svg.p('<text x="236" y="256" class="k">WITHDRAWABLE</text>');
            _row(svg, "276", DecimalFormat.formatUnits(card.streamed - stream.withdrawnAmount, decimals), symbol);
        }
    }

    /// @dev One value row, `amount symbol`, with both parts XML-escaped: the (already sanitized) symbol can contain
    /// any printable ASCII, and `DecimalFormat.formatUnits` renders dust as `<0.0001`, which is markup in XML (the
    /// JSON keeps it as is, where it is a plain string). Rows longer than the column, measured in displayed characters
    /// rather than escaped bytes, are squeezed with `textLength`.
    function _row(
        DynamicBufferLib.DynamicBuffer memory svg,
        string memory y,
        string memory amount,
        string memory symbol
    ) internal pure {
        bool squeeze = bytes(amount).length + 1 + bytes(symbol).length > ROW_MAX_CHARS;
        svg.p(
            '<text x="236" y="',
            bytes(y),
            squeeze ? bytes('" class="v" textLength="232" lengthAdjust="spacingAndGlyphs">') : bytes('" class="v">'),
            bytes(LibString.escapeHTML(amount)),
            " ",
            bytes(LibString.escapeHTML(symbol)),
            "</text>"
        );
    }

    /// @dev Schedule curve with the area under it, the start/end dates and a marker at "now" (or at the
    /// cancellation point, with the frozen amount extended to the end).
    function _chart(DynamicBufferLib.DynamicBuffer memory svg, Card memory card) internal view {
        Stream memory stream = card.stream;
        bytes memory points = _curvePoints(card);
        svg.p('<polygon points="', points, bytes(_point(stream.endTime, 0, stream)));
        svg.p(bytes(_point(stream.startTime, 0, stream)), '" fill="url(#area)"/><polyline points="', points);
        svg.p('" fill="none" stroke="#7dd3fc" stroke-width="2" stroke-linejoin="round"/>');
        _marker(svg, card);
        svg.p('<text x="48" y="426" class="d">', bytes(_date(stream.startTime)));
        svg.p('</text><text x="452" y="426" text-anchor="end" class="d">', bytes(_date(stream.endTime)), "</text>");
    }

    /// @dev Dashed vertical line and dot at the current (or cancellation) time and the streamed amount.
    function _marker(DynamicBufferLib.DynamicBuffer memory svg, Card memory card) internal view {
        Stream memory stream = card.stream;
        uint256 markerTime = stream.canceled ? stream.canceledAt : block.timestamp;
        bytes memory x = bytes(LibString.toString(_xOf(markerTime, stream)));
        bytes memory y = bytes(LibString.toString(_yOf(card.streamed, stream.depositAmount)));
        svg.p('<line x1="', x, '" y1="320" x2="', x);
        svg.p('" y2="400" stroke="#f8fafc" stroke-opacity=".45" stroke-dasharray="3 3"/><circle cx="', x, '" cy="', y);
        svg.p('" r="4" fill="#f8fafc"/>');
        if (stream.canceled) {
            svg.p('<line x1="', x, '" y1="', y);
            svg.p('" x2="452" y2="', y, '" stroke="#fb7185" stroke-dasharray="4 3"/>');
        }
    }

    /// @dev Polyline vertices of the vesting curve, each followed by a space.
    function _curvePoints(Card memory card) internal pure returns (bytes memory) {
        // An empty buffer is the intended starting state.
        // slither-disable-next-line uninitialized-local
        DynamicBufferLib.DynamicBuffer memory buffer;
        Stream memory stream = card.stream;
        buffer.p(bytes(_point(stream.startTime, 0, stream)));
        if (stream.shape == Shape.LinearCliff) {
            if (stream.cliffTime != 0) {
                uint256 atCliff = StreamMath.linear(
                    stream.depositAmount, stream.startTime, stream.cliffTime, stream.endTime, stream.cliffTime
                );
                buffer.p(bytes(_point(stream.cliffTime, 0, stream)), bytes(_point(stream.cliffTime, atCliff, stream)));
            }
            buffer.p(bytes(_point(stream.endTime, stream.depositAmount, stream)));
        } else {
            uint256 cumulative = 0;
            bool stepped = stream.shape == Shape.Tranched;
            for (uint256 i; i < card.milestones.length; ++i) {
                Milestone memory milestone = card.milestones[i];
                // A tranche is a vertical jump: add the corner before it.
                if (stepped) buffer.p(bytes(_point(milestone.timestamp, cumulative, stream)));
                cumulative += milestone.amount;
                buffer.p(bytes(_point(milestone.timestamp, cumulative, stream)));
            }
        }
        return buffer.data;
    }

    /// @dev `"x,y "` for time `t` and vested amount `amount`.
    function _point(uint256 t, uint256 amount, Stream memory stream) internal pure returns (string memory) {
        return string.concat(
            LibString.toString(_xOf(t, stream)), ",", LibString.toString(_yOf(amount, stream.depositAmount)), " "
        );
    }

    /// @dev Maps a time onto the plot's x axis, clamped to `[startTime, endTime]`, rounded down.
    function _xOf(uint256 t, Stream memory stream) internal pure returns (uint256) {
        uint256 start = stream.startTime;
        uint256 end = stream.endTime;
        if (t <= start) return PLOT_X;
        if (t >= end) return PLOT_X + PLOT_W;
        return PLOT_X + ((t - start) * PLOT_W) / (end - start);
    }

    /// @dev Maps an amount onto the plot's y axis (SVG y grows downward), rounded toward the baseline.
    function _yOf(uint256 amount, uint256 deposit) internal pure returns (uint256) {
        return PLOT_BOTTOM - (amount * PLOT_H) / deposit;
    }

    /// @dev Shape description, milestone count, cancelability (or cancellation date) and the full token address.
    function _footer(DynamicBufferLib.DynamicBuffer memory svg, Card memory card) internal pure {
        Stream memory stream = card.stream;
        string memory detail;
        if (stream.shape == Shape.LinearCliff) {
            detail = stream.cliffTime != 0 ? "LINEAR WITH CLIFF" : "LINEAR";
        } else {
            detail = string.concat(
                stream.shape == Shape.Tranched ? "TRANCHED | " : "PIECEWISE LINEAR | ",
                LibString.toString(card.milestones.length),
                stream.shape == Shape.Tranched ? " TRANCHES" : " SEGMENTS"
            );
        }
        string memory cancelability = stream.canceled
            ? string.concat(" | CANCELED ", _date(stream.canceledAt))
            : stream.cancelable ? " | CANCELABLE" : " | NON-CANCELABLE";
        svg.p(
            '<text x="32" y="462" class="k">',
            bytes(detail),
            bytes(cancelability),
            '</text><text x="32" y="480" class="f">TOKEN ',
            bytes(LibString.toHexStringChecksummed(address(stream.token))),
            "</text>"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  JSON
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-721 metadata JSON with the SVG embedded as a Base64 data URI.
    function _json(Card memory card, bytes memory svg) internal pure returns (bytes memory) {
        Stream memory stream = card.stream;
        string memory symbol = SafeText.json(card.rawSymbol);
        string memory tokenAddress = LibString.toHexStringChecksummed(address(stream.token));
        // An empty buffer is the intended starting state.
        // slither-disable-next-line uninitialized-local
        DynamicBufferLib.DynamicBuffer memory json;
        json.p(
            '{"name":"Vesting Stream #',
            bytes(LibString.toString(card.streamId)),
            '","description":"',
            bytes(symbol),
            bytes(" vesting stream. The owner of this NFT can withdraw the vested tokens. Token address: "),
            bytes(tokenAddress),
            ". Token symbols are chosen by the token deployer and can impersonate other assets: always verify the "
            'token address.","image":"data:image/svg+xml;base64,'
        );
        json.p(
            bytes(Base64.encode(svg)),
            '","attributes":[{"trait_type":"Shape","value":"',
            bytes(_shapeName(stream)),
            '"},{"trait_type":"Status","value":"',
            bytes(_statusName(card.status)),
            '"},{"trait_type":"Token","value":"',
            bytes(symbol)
        );
        json.p(
            '"},{"trait_type":"Token address","value":"',
            bytes(tokenAddress),
            '"},{"trait_type":"Cancelable","value":"',
            stream.cancelable ? bytes("Yes") : bytes("No"),
            '"},{"trait_type":"Deposited","value":"',
            bytes(DecimalFormat.formatUnits(stream.depositAmount, card.decimals)),
            '"},{"display_type":"boost_percentage","trait_type":"Vested","value":'
        );
        json.p(bytes(LibString.toString((uint256(card.streamed) * 100) / stream.depositAmount)), "}]}");
        return json.data;
    }

    // slither-disable-end unused-return

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev `YYYY-MM-DD` (UTC) for a Unix timestamp.
    function _date(uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = DateTimeLib.timestampToDate(timestamp);
        return string.concat(
            LibString.toString(year),
            month < 10 ? "-0" : "-",
            LibString.toString(month),
            day < 10 ? "-0" : "-",
            LibString.toString(day)
        );
    }

    /// @dev Pill label and colour for each status.
    function _statusStyle(Status status) internal pure returns (string memory label, string memory color) {
        if (status == Status.Pending) return ("PENDING", "#fbbf24");
        if (status == Status.Streaming) return ("STREAMING", "#38bdf8");
        if (status == Status.Settled) return ("SETTLED", "#34d399");
        if (status == Status.Canceled) return ("CANCELED", "#fb7185");
        return ("DEPLETED", "#94a3b8");
    }

    /// @dev Human-readable status for the JSON attributes.
    function _statusName(Status status) internal pure returns (string memory) {
        if (status == Status.Pending) return "Pending";
        if (status == Status.Streaming) return "Streaming";
        if (status == Status.Settled) return "Settled";
        if (status == Status.Canceled) return "Canceled";
        return "Depleted";
    }

    /// @dev Human-readable shape for the JSON attributes.
    function _shapeName(Stream memory stream) internal pure returns (string memory) {
        if (stream.shape == Shape.LinearCliff) return stream.cliffTime != 0 ? "Linear with cliff" : "Linear";
        return stream.shape == Shape.Tranched ? "Tranched" : "Piecewise linear";
    }
}
