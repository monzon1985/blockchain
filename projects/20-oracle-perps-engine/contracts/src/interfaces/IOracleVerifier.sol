// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IOracleVerifier
/// @notice Verifies EIP-712 price reports signed by a small, rotatable signer set and aggregates them into a median.
/// @dev A report is data, not an authorisation: it has no nonce. Replay across chains, verifying contracts and
///      markets is prevented by the EIP-712 domain and the signed `marketId`; replay across time is bounded by
///      `maxReportAge` and by the caller-supplied `requestTimestamp` (reports must be strictly newer than the
///      order or request they settle).
interface IOracleVerifier {
    /// @notice One signer's observation of a market price, plus the signature over its EIP-712 digest.
    /// @param signer Address that signed the report; must be a member of the active signer set.
    /// @param price Price of one index token in USD, 18 decimals (WAD).
    /// @param timestamp Unix time (seconds) at which the signer observed `price`.
    /// @param signature ECDSA (65-byte) or ERC-1271 signature over `reportDigest(marketId, price, timestamp)`.
    struct SignedPriceReport {
        address signer;
        uint256 price;
        uint64 timestamp;
        bytes signature;
    }

    /// @notice Emitted when the signer set or quorum changes.
    /// @param signers The new signer set, in storage order.
    /// @param minSigners The new quorum (minimum number of distinct signed reports per verification).
    event SignerSetUpdated(address[] signers, uint8 minSigners);

    /// @notice Emitted when the freshness or dispersion limits change.
    /// @param maxReportAge New maximum age of a report relative to `block.timestamp`, in seconds.
    /// @param maxSpreadBps New maximum (max - min) / median dispersion across the reports, in basis points.
    event ReportLimitsUpdated(uint32 maxReportAge, uint16 maxSpreadBps);

    /// @notice Fewer reports than the quorum were supplied.
    /// @param provided Number of reports supplied.
    /// @param required Current quorum.
    error NotEnoughReports(uint256 provided, uint256 required);

    /// @notice More reports than signers exist were supplied (at least one must be a duplicate or unknown).
    /// @param provided Number of reports supplied.
    /// @param maxAllowed Size of the signer set.
    error TooManyReports(uint256 provided, uint256 maxAllowed);

    /// @notice A report was signed by an address outside the active signer set.
    /// @param signer The offending address.
    error UnknownSigner(address signer);

    /// @notice Two reports in the same batch claim the same signer.
    /// @param signer The signer that appeared twice.
    error DuplicateSigner(address signer);

    /// @notice The signature does not match the claimed signer for the reconstructed digest.
    /// @param signer The claimed signer.
    error InvalidSignature(address signer);

    /// @notice A report carries a zero price.
    /// @param signer The signer of the zero-price report.
    error ZeroPrice(address signer);

    /// @notice A report is timestamped after the current block.
    /// @param signer The signer of the report.
    /// @param timestamp The report timestamp.
    /// @param blockTimestamp The current block timestamp.
    error ReportFromFuture(address signer, uint256 timestamp, uint256 blockTimestamp);

    /// @notice A report is older than `maxReportAge`.
    /// @param signer The signer of the report.
    /// @param timestamp The report timestamp.
    /// @param oldestAllowed The oldest timestamp still accepted.
    error StaleReport(address signer, uint256 timestamp, uint256 oldestAllowed);

    /// @notice A report is not strictly newer than the request it is meant to settle (latency-arbitrage guard).
    /// @param signer The signer of the report.
    /// @param timestamp The report timestamp.
    /// @param requestTimestamp The creation timestamp of the order or request being settled.
    error ReportPredatesRequest(address signer, uint256 timestamp, uint256 requestTimestamp);

    /// @notice The reports disagree by more than `maxSpreadBps` of the median.
    /// @param minPrice Lowest reported price.
    /// @param maxPrice Highest reported price.
    /// @param medianPrice Median of the reports.
    /// @param maxSpreadBps Current dispersion limit.
    error SpreadTooWide(uint256 minPrice, uint256 maxPrice, uint256 medianPrice, uint16 maxSpreadBps);

    /// @notice The proposed signer set is empty or larger than `MAX_SIGNERS`.
    /// @param size Proposed number of signers.
    error InvalidSignerSetSize(uint256 size);

    /// @notice The proposed quorum is below 2 or above the signer-set size.
    /// @param minSigners Proposed quorum.
    /// @param size Proposed number of signers.
    error InvalidQuorum(uint8 minSigners, uint256 size);

    /// @notice The proposed signer set contains the zero address or a duplicate.
    /// @param signer The offending entry.
    error InvalidSignerEntry(address signer);

    /// @notice The proposed freshness or dispersion limit is outside its safe bounds.
    /// @param maxReportAge Proposed maximum age in seconds.
    /// @param maxSpreadBps Proposed dispersion limit in basis points.
    error InvalidReportLimits(uint32 maxReportAge, uint16 maxSpreadBps);

    /// @notice Verifies a batch of signed reports and returns their median.
    /// @param marketId Market the reports must be signed for.
    /// @param reports Signed reports from distinct members of the signer set.
    /// @param requestTimestamp Every report must be strictly newer than this timestamp (0 disables the check).
    /// @return medianPrice Median of the report prices (mean of the two middle values for an even count).
    /// @return oldestTimestamp Timestamp of the oldest report in the batch.
    function verifyReports(bytes32 marketId, SignedPriceReport[] calldata reports, uint256 requestTimestamp)
        external
        view
        returns (uint256 medianPrice, uint256 oldestTimestamp);

    /// @notice EIP-712 digest a signer must sign for a report.
    /// @param marketId Market identifier.
    /// @param price Price, 18 decimals.
    /// @param timestamp Observation time in seconds.
    /// @return The typed-data digest `keccak256("\x19\x01" || domainSeparator || structHash)`.
    function reportDigest(bytes32 marketId, uint256 price, uint64 timestamp) external view returns (bytes32);

    /// @notice Current signer set, in storage order.
    /// @return The signer addresses.
    function signers() external view returns (address[] memory);

    /// @notice Current quorum.
    /// @return Minimum number of distinct signed reports per verification.
    function minSigners() external view returns (uint8);

    /// @notice Current maximum report age in seconds.
    /// @return The age limit.
    function maxReportAge() external view returns (uint32);

    /// @notice Current dispersion limit in basis points of the median.
    /// @return The spread limit.
    function maxSpreadBps() external view returns (uint16);
}
