// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {OracleVerifier} from "../../src/OracleVerifier.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {MockERC1271Signer} from "../mocks/MockERC1271Signer.sol";
import {PerpsTestBase} from "../utils/PerpsTestBase.sol";

contract OracleVerifierTest is PerpsTestBase {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _verify(IOracleVerifier.SignedPriceReport[] memory reports, uint256 requestTs)
        internal
        view
        returns (uint256 median, uint256 oldest)
    {
        return oracle.verifyReports(MARKET_ID, reports, requestTs);
    }

    function _pair(uint256 pkA, uint256 priceA, uint256 pkB, uint256 priceB)
        internal
        view
        returns (IOracleVerifier.SignedPriceReport[] memory reports)
    {
        reports = new IOracleVerifier.SignedPriceReport[](2);
        reports[0] = _sign(pkA, MARKET_ID, priceA, uint64(block.timestamp));
        reports[1] = _sign(pkB, MARKET_ID, priceB, uint64(block.timestamp));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Happy paths
    // ---------------------------------------------------------------------------------------------------------------

    function test_constructor_setsConfig() public view {
        address[] memory s = oracle.signers();
        assertEq(s.length, 3);
        assertEq(s[0], signer1);
        assertEq(oracle.minSigners(), 2);
        assertEq(oracle.maxReportAge(), 60);
        assertEq(oracle.maxSpreadBps(), 50);
        assertTrue(oracle.isSigner(signer2));
        assertFalse(oracle.isSigner(alice));
    }

    function test_verify_threeReports_returnsMiddleValue() public view {
        IOracleVerifier.SignedPriceReport[] memory r = new IOracleVerifier.SignedPriceReport[](3);
        r[0] = _sign(SIGNER1_PK, MARKET_ID, 3003e18, uint64(block.timestamp));
        r[1] = _sign(SIGNER2_PK, MARKET_ID, 2999e18, uint64(block.timestamp - 5));
        r[2] = _sign(SIGNER3_PK, MARKET_ID, 3001e18, uint64(block.timestamp - 2));
        (uint256 median, uint256 oldest) = _verify(r, 0);
        assertEq(median, 3001e18);
        assertEq(oldest, block.timestamp - 5);
    }

    function test_verify_twoReports_returnsMean() public view {
        (uint256 median,) = _verify(_pair(SIGNER1_PK, 3000e18, SIGNER3_PK, 3010e18), 0);
        assertEq(median, 3005e18);
    }

    function test_verify_acceptsErc1271Signer() public {
        uint256 ownerPk = 0xD00D;
        MockERC1271Signer wallet = new MockERC1271Signer(vm.addr(ownerPk));
        address[] memory set = new address[](3);
        set[0] = signer1;
        set[1] = signer2;
        set[2] = address(wallet);
        _rotate(set, 2);

        IOracleVerifier.SignedPriceReport[] memory r = new IOracleVerifier.SignedPriceReport[](2);
        r[0] = _sign(SIGNER1_PK, MARKET_ID, PRICE0, uint64(block.timestamp));
        r[1] = _sign(ownerPk, MARKET_ID, PRICE0, uint64(block.timestamp));
        r[1].signer = address(wallet);
        (uint256 median,) = _verify(r, 0);
        assertEq(median, PRICE0);

        // A signature from anyone else is rejected by the wallet.
        r[1] = _sign(SIGNER3_PK, MARKET_ID, PRICE0, uint64(block.timestamp));
        r[1].signer = address(wallet);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignature.selector, address(wallet)));
        _verify(r, 0);
    }

    function test_reportDigest_matchesEip712() public view {
        bytes32 typeHash = keccak256("PriceReport(bytes32 marketId,uint256 price,uint64 timestamp)");
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PerpsOracle"),
                keccak256("1"),
                block.chainid,
                address(oracle)
            )
        );
        assertEq(oracle.domainSeparator(), domain);
        bytes32 expected = keccak256(
            abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(typeHash, MARKET_ID, PRICE0, uint64(123))))
        );
        assertEq(oracle.reportDigest(MARKET_ID, PRICE0, 123), expected);
        assertEq(oracle.PRICE_REPORT_TYPEHASH(), typeHash);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Batch-shape failures
    // ---------------------------------------------------------------------------------------------------------------

    function test_revert_tooFewReports() public {
        IOracleVerifier.SignedPriceReport[] memory r = new IOracleVerifier.SignedPriceReport[](1);
        r[0] = _sign(SIGNER1_PK, MARKET_ID, PRICE0, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.NotEnoughReports.selector, 1, 2));
        _verify(r, 0);
    }

    function test_revert_tooManyReports() public {
        IOracleVerifier.SignedPriceReport[] memory r = new IOracleVerifier.SignedPriceReport[](4);
        IOracleVerifier.SignedPriceReport[] memory three = _reports(PRICE0);
        r[0] = three[0];
        r[1] = three[1];
        r[2] = three[2];
        r[3] = three[0];
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.TooManyReports.selector, 4, 3));
        _verify(r, 0);
    }

    function test_revert_duplicateSigner() public {
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, PRICE0, SIGNER1_PK, PRICE0 + 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.DuplicateSigner.selector, signer1));
        _verify(r, 0);
    }

    function test_revert_unknownSigner() public {
        uint256 rogue = 0xBAD;
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, PRICE0, rogue, PRICE0);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnknownSigner.selector, vm.addr(rogue)));
        _verify(r, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Signature failures and replay
    // ---------------------------------------------------------------------------------------------------------------

    function test_revert_signatureByWrongKey() public {
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, PRICE0, SIGNER2_PK, PRICE0);
        r[1].signer = signer3; // claims signer3 but was signed by signer2
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignature.selector, signer3));
        _verify(r, 0);
    }

    function test_revert_tamperedPrice() public {
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, PRICE0, SIGNER2_PK, PRICE0);
        r[1].price = PRICE0 + 1;
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignature.selector, signer2));
        _verify(r, 0);
    }

    function test_revert_replayAcrossMarkets() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignature.selector, signer1));
        oracle.verifyReports(keccak256("BTC-USD"), r, 0);
    }

    function test_revert_replayAcrossChains() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignature.selector, signer1));
        _verify(r, 0);
    }

    function test_revert_replayAcrossVerifierDeployments() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        OracleVerifier other =
            new OracleVerifier(address(sys.manager), oracle.signers(), 2, oracle.maxReportAge(), oracle.maxSpreadBps());
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignature.selector, signer1));
        other.verifyReports(MARKET_ID, r, 0);
    }

    function test_revert_replayOfReportOlderThanRequest() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        // A request created in the same second as the reports cannot be settled with them.
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.ReportPredatesRequest.selector, signer1, block.timestamp, block.timestamp
            )
        );
        _verify(r, block.timestamp);
    }

    function test_revert_highSMalleableSignature() public {
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, PRICE0, SIGNER2_PK, PRICE0);
        bytes memory sig = r[1].signature;
        bytes32 rr;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            // sig layout: [len][r][s][v]; reading the fixed-size words of a 65-byte signature
            rr := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        bytes32 flippedS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        r[1].signature = abi.encodePacked(rr, flippedS, flippedV);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignature.selector, signer2));
        _verify(r, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Freshness and dispersion
    // ---------------------------------------------------------------------------------------------------------------

    function test_revert_zeroPrice() public {
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, 0, SIGNER2_PK, PRICE0);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.ZeroPrice.selector, signer1));
        _verify(r, 0);
    }

    function test_revert_reportFromFuture() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reportsAt(PRICE0, uint64(block.timestamp + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.ReportFromFuture.selector, signer1, block.timestamp + 1, block.timestamp
            )
        );
        _verify(r, 0);
    }

    function test_revert_staleReport() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        skip(61);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleVerifier.StaleReport.selector, signer1, block.timestamp - 61, block.timestamp - 60
            )
        );
        _verify(r, 0);
    }

    function test_verify_acceptsReportExactlyAtMaxAge() public {
        IOracleVerifier.SignedPriceReport[] memory r = _reports(PRICE0);
        skip(60);
        (uint256 median,) = _verify(r, 0);
        assertEq(median, PRICE0);
    }

    function test_revert_spreadTooWide() public {
        // 3000 vs 3015.1: 50.3 bps of the 3007.55 mean median.
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, 3000e18, SIGNER2_PK, 3015.1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IOracleVerifier.SpreadTooWide.selector, 3000e18, 3015.1e18, 3007.55e18, 50)
        );
        _verify(r, 0);
    }

    function test_verify_spreadAtLimitAccepted() public view {
        // 3000 vs 3015: exactly 49.87 bps of the 3007.5 median.
        (uint256 median,) = _verify(_pair(SIGNER1_PK, 3000e18, SIGNER2_PK, 3015e18), 0);
        assertEq(median, 3007.5e18);
    }

    function test_compromisedSigner_boundedByMedian() public view {
        // One signer reports a wildly wrong price: the honest pair still settles, and the outlier cannot be included.
        IOracleVerifier.SignedPriceReport[] memory honest = _pair(SIGNER1_PK, 3000e18, SIGNER2_PK, 3001e18);
        (uint256 median,) = _verify(honest, 0);
        assertEq(median, 3000.5e18);
    }

    function test_revert_compromisedSignerOutlierIncluded() public {
        IOracleVerifier.SignedPriceReport[] memory r = new IOracleVerifier.SignedPriceReport[](3);
        r[0] = _sign(SIGNER1_PK, MARKET_ID, 3000e18, uint64(block.timestamp));
        r[1] = _sign(SIGNER2_PK, MARKET_ID, 3001e18, uint64(block.timestamp));
        r[2] = _sign(SIGNER3_PK, MARKET_ID, 6000e18, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.SpreadTooWide.selector, 3000e18, 6000e18, 3001e18, 50));
        _verify(r, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Governance: timelocked rotation
    // ---------------------------------------------------------------------------------------------------------------

    function _rotate(address[] memory set, uint8 quorum) internal {
        bytes memory data = abi.encodeCall(OracleVerifier.setSigners, (set, quorum));
        vm.prank(oracleAdmin);
        sys.manager.schedule(address(oracle), data, 0);
        skip(1 days);
        vm.prank(oracleAdmin);
        sys.manager.execute(address(oracle), data);
    }

    function test_rotation_requiresScheduleAndDelay() public {
        address[] memory set = new address[](3);
        set[0] = signer1;
        set[1] = signer2;
        set[2] = alice;

        vm.prank(oracleAdmin);
        vm.expectRevert(); // not scheduled
        oracle.setSigners(set, 2);

        bytes memory data = abi.encodeCall(OracleVerifier.setSigners, (set, 2));
        vm.prank(oracleAdmin);
        (bytes32 opId,) = sys.manager.schedule(address(oracle), data, 0);

        skip(1 days - 1);
        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, opId));
        sys.manager.execute(address(oracle), data);

        skip(1);
        vm.expectEmit(address(oracle));
        emit IOracleVerifier.SignerSetUpdated(set, 2);
        vm.prank(oracleAdmin);
        oracle.setSigners(set, 2);
        assertTrue(oracle.isSigner(alice));
        assertFalse(oracle.isSigner(signer3));
    }

    function test_rotation_removedSignerReportsRejected() public {
        address[] memory set = new address[](2);
        set[0] = signer1;
        set[1] = signer2;
        _rotate(set, 2);
        IOracleVerifier.SignedPriceReport[] memory r = _pair(SIGNER1_PK, PRICE0, SIGNER3_PK, PRICE0);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.UnknownSigner.selector, signer3));
        _verify(r, 0);
    }

    function test_revert_setSigners_unauthorized() public {
        address[] memory set = new address[](2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        oracle.setSigners(set, 2);
    }

    function test_revert_setReportLimits_unauthorized() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        oracle.setReportLimits(30, 25);
    }

    function test_setReportLimits_throughTimelock() public {
        bytes memory data = abi.encodeCall(OracleVerifier.setReportLimits, (30, 25));
        vm.prank(oracleAdmin);
        sys.manager.schedule(address(oracle), data, 0);
        skip(1 days);
        vm.expectEmit(address(oracle));
        emit IOracleVerifier.ReportLimitsUpdated(30, 25);
        vm.prank(oracleAdmin);
        sys.manager.execute(address(oracle), data);
        assertEq(oracle.maxReportAge(), 30);
        assertEq(oracle.maxSpreadBps(), 25);
    }

    function test_revert_constructor_invalidSignerSets() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignerSetSize.selector, 0));
        new OracleVerifier(address(sys.manager), empty, 2, 60, 50);

        address[] memory tooMany = new address[](17);
        for (uint256 i; i < 17; ++i) {
            tooMany[i] = address(uint160(i + 1));
        }
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignerSetSize.selector, 17));
        new OracleVerifier(address(sys.manager), tooMany, 2, 60, 50);

        address[] memory three = oracle.signers();
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidQuorum.selector, 1, 3));
        new OracleVerifier(address(sys.manager), three, 1, 60, 50);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidQuorum.selector, 4, 3));
        new OracleVerifier(address(sys.manager), three, 4, 60, 50);

        three[2] = address(0);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignerEntry.selector, address(0)));
        new OracleVerifier(address(sys.manager), three, 2, 60, 50);
        three[2] = three[0];
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidSignerEntry.selector, three[0]));
        new OracleVerifier(address(sys.manager), three, 2, 60, 50);
    }

    function test_revert_constructor_invalidReportLimits() public {
        address[] memory three = oracle.signers();
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidReportLimits.selector, 0, 50));
        new OracleVerifier(address(sys.manager), three, 2, 0, 50);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidReportLimits.selector, 601, 50));
        new OracleVerifier(address(sys.manager), three, 2, 601, 50);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidReportLimits.selector, 60, 0));
        new OracleVerifier(address(sys.manager), three, 2, 60, 0);
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.InvalidReportLimits.selector, 60, 501));
        new OracleVerifier(address(sys.manager), three, 2, 60, 501);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The median is order-independent and lies between the extreme reports.
    function testFuzz_median_isOrderIndependentAndBounded(uint256 base, uint16 d1, uint16 d2, uint16 d3, uint8 perm)
        public
        view
    {
        base = bound(base, 1e18, 1e30);
        uint256[3] memory p = [
            base + (base * bound(d1, 0, 40)) / 10_000,
            base + (base * bound(d2, 0, 40)) / 10_000,
            base + (base * bound(d3, 0, 40)) / 10_000
        ];
        uint256[3] memory pks = [SIGNER1_PK, SIGNER2_PK, SIGNER3_PK];
        uint256 rot = bound(perm, 0, 2);
        IOracleVerifier.SignedPriceReport[] memory r = new IOracleVerifier.SignedPriceReport[](3);
        IOracleVerifier.SignedPriceReport[] memory rotated = new IOracleVerifier.SignedPriceReport[](3);
        for (uint256 i; i < 3; ++i) {
            r[i] = _sign(pks[i], MARKET_ID, p[i], uint64(block.timestamp));
        }
        for (uint256 i; i < 3; ++i) {
            rotated[i] = r[(i + rot) % 3];
        }
        (uint256 m1,) = _verify(r, 0);
        (uint256 m2,) = _verify(rotated, 0);
        assertEq(m1, m2);
        uint256 lo = p[0] < p[1] ? (p[0] < p[2] ? p[0] : p[2]) : (p[1] < p[2] ? p[1] : p[2]);
        uint256 hi = p[0] > p[1] ? (p[0] > p[2] ? p[0] : p[2]) : (p[1] > p[2] ? p[1] : p[2]);
        assertGe(m1, lo);
        assertLe(m1, hi);
        assertTrue(m1 == p[0] || m1 == p[1] || m1 == p[2]);
    }

    /// @dev Any report not strictly newer than the request is rejected, whatever its age.
    function testFuzz_revert_reportNotNewerThanRequest(uint256 age, uint256 requestLead) public {
        age = bound(age, 0, 60);
        requestLead = bound(requestLead, 0, 1000);
        uint64 ts = uint64(block.timestamp - age);
        IOracleVerifier.SignedPriceReport[] memory r = _reportsAt(PRICE0, ts);
        uint256 requestTs = uint256(ts) + requestLead;
        vm.expectRevert(abi.encodeWithSelector(IOracleVerifier.ReportPredatesRequest.selector, signer1, ts, requestTs));
        _verify(r, requestTs);
    }
}
