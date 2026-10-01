// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IOracleVerifier} from "./interfaces/IOracleVerifier.sol";

/// @title OracleVerifier
/// @notice Verifies EIP-712 `PriceReport` signatures from a small signer set and returns the median price.
/// @dev Security model: with `n` signers and a quorum of `minSigners >= 2`, a single compromised signer can only move
///      the median within the dispersion band (`maxSpreadBps`), because every included report must sit within that
///      band of the median. A report outside the band makes the batch revert, and the caller (a keeper) simply omits
///      it. Signer-set rotation is `restricted`: the deployment grants the oracle-admin role with an AccessManager
///      execution delay, which turns every rotation into a scheduled, publicly visible, timelocked operation.
contract OracleVerifier is IOracleVerifier, AccessManaged, EIP712 {
    /// @notice EIP-712 type hash of `PriceReport(bytes32 marketId,uint256 price,uint64 timestamp)`.
    bytes32 public constant PRICE_REPORT_TYPEHASH =
        keccak256("PriceReport(bytes32 marketId,uint256 price,uint64 timestamp)");

    /// @notice Upper bound on the signer-set size; keeps the duplicate bitmap in one word and the sort cheap.
    uint256 public constant MAX_SIGNERS = 16;

    /// @notice Hard ceiling for `maxReportAge` (10 minutes).
    uint32 public constant MAX_REPORT_AGE_LIMIT = 600;

    /// @notice Hard ceiling for `maxSpreadBps` (5%).
    uint16 public constant MAX_SPREAD_LIMIT_BPS = 500;

    /// @dev Signer addresses in storage order.
    address[] private _signers;

    /// @dev signer => (index in `_signers`) + 1; zero means "not a signer".
    mapping(address signer => uint256 indexPlusOne) private _signerSlot;

    /// @inheritdoc IOracleVerifier
    uint8 public minSigners;

    /// @inheritdoc IOracleVerifier
    uint32 public maxReportAge;

    /// @inheritdoc IOracleVerifier
    uint16 public maxSpreadBps;

    /// @param authority_ AccessManager that gates signer rotation and limit changes.
    /// @param initialSigners Initial signer set.
    /// @param initialMinSigners Initial quorum (>= 2).
    /// @param initialMaxReportAge Initial maximum report age in seconds.
    /// @param initialMaxSpreadBps Initial dispersion limit in basis points.
    constructor(
        address authority_,
        address[] memory initialSigners,
        uint8 initialMinSigners,
        uint32 initialMaxReportAge,
        uint16 initialMaxSpreadBps
    ) AccessManaged(authority_) EIP712("PerpsOracle", "1") {
        _setSigners(initialSigners, initialMinSigners);
        _setReportLimits(initialMaxReportAge, initialMaxSpreadBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin (timelocked through the AccessManager role delay)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Replaces the signer set and quorum.
    /// @dev Reports signed by removed signers stop verifying immediately after execution.
    /// @param newSigners The new signer set (1..MAX_SIGNERS distinct non-zero addresses).
    /// @param newMinSigners The new quorum (2..newSigners.length).
    function setSigners(address[] calldata newSigners, uint8 newMinSigners) external restricted {
        _setSigners(newSigners, newMinSigners);
    }

    /// @notice Updates the freshness and dispersion limits.
    /// @param newMaxReportAge New maximum report age (1..MAX_REPORT_AGE_LIMIT seconds).
    /// @param newMaxSpreadBps New dispersion limit (1..MAX_SPREAD_LIMIT_BPS basis points).
    function setReportLimits(uint32 newMaxReportAge, uint16 newMaxSpreadBps) external restricted {
        _setReportLimits(newMaxReportAge, newMaxSpreadBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Verification
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleVerifier
    function verifyReports(bytes32 marketId, SignedPriceReport[] calldata reports, uint256 requestTimestamp)
        external
        view
        returns (uint256 medianPrice, uint256 oldestTimestamp)
    {
        uint256 count = reports.length;
        uint256 quorum = minSigners;
        uint256 setSize = _signers.length;
        require(count >= quorum, NotEnoughReports(count, quorum));
        require(count <= setSize, TooManyReports(count, setSize));

        uint256[] memory prices = new uint256[](count);
        uint256 seen = 0; // bitmap of signer indices already used in this batch
        uint256 oldestAllowed = block.timestamp > maxReportAge ? block.timestamp - maxReportAge : 0;
        oldestTimestamp = type(uint256).max;

        for (uint256 i; i < count; ++i) {
            SignedPriceReport calldata r = reports[i];
            uint256 bit = _checkReport(marketId, r, oldestAllowed, requestTimestamp);
            require(seen & bit == 0, DuplicateSigner(r.signer));
            seen |= bit;
            if (r.timestamp < oldestTimestamp) oldestTimestamp = r.timestamp;
            _insertSorted(prices, i, r.price);
        }

        // count >= quorum >= 2, so both middle indices exist.
        uint256 mid = count / 2;
        medianPrice = count % 2 == 1 ? prices[mid] : (prices[mid - 1] + prices[mid]) / 2;

        uint256 lo = prices[0];
        uint256 hi = prices[count - 1];
        uint16 spreadLimit = maxSpreadBps;
        // The median is floored first by definition (it is the value the market uses); flooring can only make the
        // dispersion check stricter by at most one wei of the median.
        // slither-disable-next-line divide-before-multiply
        require(
            (hi - lo) * 10_000 <= uint256(spreadLimit) * medianPrice, SpreadTooWide(lo, hi, medianPrice, spreadLimit)
        );
    }

    /// @inheritdoc IOracleVerifier
    function reportDigest(bytes32 marketId, uint256 price, uint64 timestamp) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PRICE_REPORT_TYPEHASH, marketId, price, timestamp)));
    }

    /// @inheritdoc IOracleVerifier
    function signers() external view returns (address[] memory) {
        return _signers;
    }

    /// @notice Whether `account` is a member of the active signer set.
    /// @param account Address to check.
    /// @return True when `account` may sign reports.
    function isSigner(address account) external view returns (bool) {
        return _signerSlot[account] != 0;
    }

    /// @notice EIP-712 domain separator for this chain and contract.
    /// @return The domain separator used in `reportDigest`.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Validates one report (membership, price, freshness, ordering, signature) and returns its signer bit.
    function _checkReport(
        bytes32 marketId,
        SignedPriceReport calldata r,
        uint256 oldestAllowed,
        uint256 requestTimestamp
    ) private view returns (uint256 bit) {
        uint256 slot = _signerSlot[r.signer];
        require(slot != 0, UnknownSigner(r.signer));
        require(r.price != 0, ZeroPrice(r.signer));
        require(r.timestamp <= block.timestamp, ReportFromFuture(r.signer, r.timestamp, block.timestamp));
        require(r.timestamp >= oldestAllowed, StaleReport(r.signer, r.timestamp, oldestAllowed));
        require(r.timestamp > requestTimestamp, ReportPredatesRequest(r.signer, r.timestamp, requestTimestamp));
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(PRICE_REPORT_TYPEHASH, marketId, r.price, r.timestamp)));
        require(SignatureChecker.isValidSignatureNowCalldata(r.signer, digest, r.signature), InvalidSignature(r.signer));
        return 1 << (slot - 1);
    }

    /// @dev Insertion step: places `price` into the sorted prefix `prices[0..filled)`. `filled < MAX_SIGNERS`, so the
    ///      quadratic worst case is at most 120 comparisons.
    function _insertSorted(uint256[] memory prices, uint256 filled, uint256 price) private pure {
        uint256 j = filled;
        while (j > 0 && prices[j - 1] > price) {
            prices[j] = prices[j - 1];
            --j;
        }
        prices[j] = price;
    }

    function _setSigners(address[] memory newSigners, uint8 newMinSigners) private {
        uint256 size = newSigners.length;
        require(size != 0 && size <= MAX_SIGNERS, InvalidSignerSetSize(size));
        require(newMinSigners >= 2 && newMinSigners <= size, InvalidQuorum(newMinSigners, size));

        uint256 oldSize = _signers.length;
        for (uint256 i; i < oldSize; ++i) {
            delete _signerSlot[_signers[i]];
        }
        delete _signers;

        for (uint256 i; i < size; ++i) {
            address s = newSigners[i];
            require(s != address(0) && _signerSlot[s] == 0, InvalidSignerEntry(s));
            _signers.push(s);
            _signerSlot[s] = i + 1;
        }
        minSigners = newMinSigners;
        emit SignerSetUpdated(newSigners, newMinSigners);
    }

    function _setReportLimits(uint32 newMaxReportAge, uint16 newMaxSpreadBps) private {
        require(
            newMaxReportAge != 0 && newMaxReportAge <= MAX_REPORT_AGE_LIMIT && newMaxSpreadBps != 0
                && newMaxSpreadBps <= MAX_SPREAD_LIMIT_BPS,
            InvalidReportLimits(newMaxReportAge, newMaxSpreadBps)
        );
        maxReportAge = newMaxReportAge;
        maxSpreadBps = newMaxSpreadBps;
        emit ReportLimitsUpdated(newMaxReportAge, newMaxSpreadBps);
    }
}
