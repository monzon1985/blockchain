// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PerpsDeployment} from "../../script/PerpsDeployment.sol";
import {LPVault} from "../../src/LPVault.sol";
import {OracleVerifier} from "../../src/OracleVerifier.sol";
import {OrderBook} from "../../src/OrderBook.sol";
import {PerpsMarket} from "../../src/PerpsMarket.sol";
import {IOracleVerifier} from "../../src/interfaces/IOracleVerifier.sol";
import {IOrderBook} from "../../src/interfaces/IOrderBook.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {MockUSD} from "../mocks/MockUSD.sol";

/// @notice Deploys the full system through `PerpsDeployment` and provides signing and order-flow helpers.
abstract contract PerpsTestBase is Test {
    bytes32 internal constant MARKET_ID = keccak256("ETH-USD");
    uint256 internal constant PRICE0 = 3000e18;
    uint256 internal constant START_TS = 1_700_000_000;

    uint256 internal constant SIGNER1_PK = 0xA11CE;
    uint256 internal constant SIGNER2_PK = 0xB0B;
    uint256 internal constant SIGNER3_PK = 0xCA401;

    address internal signer1;
    address internal signer2;
    address internal signer3;

    address internal keeper = makeAddr("keeper");
    address internal riskAdmin = makeAddr("riskAdmin");
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal lp = makeAddr("lp");

    MockUSD internal usd;
    PerpsDeployment.System internal sys;
    PerpsMarket internal market;
    OrderBook internal orderBook;
    LPVault internal vault;
    OracleVerifier internal oracle;

    function setUp() public virtual {
        vm.warp(START_TS);
        signer1 = vm.addr(SIGNER1_PK);
        signer2 = vm.addr(SIGNER2_PK);
        signer3 = vm.addr(SIGNER3_PK);
        usd = new MockUSD(18);
        sys = PerpsDeployment.deploy(IERC20(address(usd)), _config(_riskParams()));
        market = sys.market;
        orderBook = sys.orderBook;
        vault = sys.vault;
        oracle = sys.oracle;
    }

    /// @dev Risk parameters of the deployed market; suites override this to isolate mechanics.
    function _riskParams() internal pure virtual returns (IPerpsMarket.RiskParams memory) {
        return PerpsDeployment.defaultRiskParams();
    }

    /// @dev Default parameters with funding and borrow fees switched off, for exact fee/impact arithmetic.
    function _staticRiskParams() internal pure returns (IPerpsMarket.RiskParams memory p) {
        p = PerpsDeployment.defaultRiskParams();
        p.borrowFactor = 0;
        p.maxFundingVelocity = 0;
    }

    function _config(IPerpsMarket.RiskParams memory params) internal view returns (PerpsDeployment.Config memory cfg) {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        address[] memory keepers = new address[](1);
        keepers[0] = keeper;
        cfg = PerpsDeployment.Config({
            admin: address(this),
            governor: address(this),
            signers: signers,
            minSigners: 2,
            maxReportAge: 60,
            maxSpreadBps: 50,
            keepers: keepers,
            riskAdmin: riskAdmin,
            oracleAdmin: oracleAdmin,
            guardian: guardian,
            marketId: MARKET_ID,
            params: params
        });
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Oracle helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Signs a report. The digest is rebuilt locally (no external call), so helpers can be used right after
    ///      `vm.prank` / `vm.expectRevert`; `test_reportDigest_matchesEip712` pins it to the contract's digest.
    function _sign(uint256 pk, bytes32 marketId, uint256 price, uint64 ts)
        internal
        view
        returns (IOracleVerifier.SignedPriceReport memory r)
    {
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(pk, _digest(address(oracle), marketId, price, ts));
        r = IOracleVerifier.SignedPriceReport({
            signer: vm.addr(pk), price: price, timestamp: ts, signature: abi.encodePacked(rr, s, v)
        });
    }

    function _digest(address verifier, bytes32 marketId, uint256 price, uint64 ts) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PerpsOracle"),
                keccak256("1"),
                block.chainid,
                verifier
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(keccak256("PriceReport(bytes32 marketId,uint256 price,uint64 timestamp)"), marketId, price, ts)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @dev Three reports at `price`, timestamped at the current block.
    function _reports(uint256 price) internal view returns (IOracleVerifier.SignedPriceReport[] memory reports) {
        return _reportsAt(price, uint64(block.timestamp));
    }

    function _reportsAt(uint256 price, uint64 ts)
        internal
        view
        returns (IOracleVerifier.SignedPriceReport[] memory reports)
    {
        reports = new IOracleVerifier.SignedPriceReport[](3);
        reports[0] = _sign(SIGNER1_PK, MARKET_ID, price, ts);
        reports[1] = _sign(SIGNER2_PK, MARKET_ID, price, ts);
        reports[2] = _sign(SIGNER3_PK, MARKET_ID, price, ts);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Flow helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _fund(address who, uint256 amount) internal {
        usd.mint(who, amount);
        vm.startPrank(who);
        usd.approve(address(orderBook), type(uint256).max);
        usd.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _minFee() internal view returns (uint256 fee) {
        (fee,,) = market.requestConfig();
    }

    /// @dev Requests and settles a deposit one second later at `price`.
    function _deposit(address who, uint256 assets, uint256 price) internal returns (uint256 shares) {
        _fund(who, assets + _minFee());
        uint256 fee = _minFee();
        vm.prank(who);
        uint256 id = vault.requestDeposit(assets, 0, fee);
        uint256 before = vault.balanceOf(who);
        skip(1);
        vm.prank(keeper);
        vault.executeRequest(id, _reports(price));
        shares = vault.balanceOf(who) - before;
    }

    function _acceptable(bool isLong, bool increase) internal pure returns (uint256) {
        return isLong == increase ? type(uint128).max : 0;
    }

    function _createOrder(
        address who,
        IOrderBook.OrderType orderType,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 trigger
    ) internal returns (uint256 id) {
        bool increase = orderType == IOrderBook.OrderType.MarketIncrease
            || orderType == IOrderBook.OrderType.LimitIncrease;
        uint256 fee = _minFee();
        _fund(who, (increase ? collateral : 0) + fee);
        vm.prank(who);
        id = orderBook.createOrder(orderType, isLong, size, collateral, trigger, _acceptable(isLong, increase), fee);
    }

    /// @dev Advances one second and settles `id` at `price` as the keeper.
    function _execute(uint256 id, uint256 price) internal {
        skip(1);
        vm.prank(keeper);
        orderBook.executeOrder(id, _reports(price));
    }

    function _open(address who, bool isLong, uint256 size, uint256 collateral, uint256 price) internal {
        uint256 id = _createOrder(who, IOrderBook.OrderType.MarketIncrease, isLong, size, collateral, 0);
        _execute(id, price);
    }

    function _close(address who, bool isLong, uint256 price) internal {
        uint256 id = _createOrder(who, IOrderBook.OrderType.MarketDecrease, isLong, type(uint128).max, 0, 0);
        _execute(id, price);
    }

    /// @dev Selector of the revert reason carried by the first `OrderCancelled` / `LpRequestCancelled` log recorded
    ///      since `vm.recordLogs()`.
    function _cancelReasonSelector() internal view returns (bytes4) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 orderTopic = IOrderBook.OrderCancelled.selector;
        bytes32 lpTopic = keccak256("LpRequestCancelled(uint256,address,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == orderTopic || logs[i].topics[0] == lpTopic) {
                return bytes4(abi.decode(logs[i].data, (bytes)));
            }
        }
        revert("no cancellation log");
    }

    /// @dev Impact-pool balance the next accrual hands to the LPs, `dt` seconds after the previous accrual.
    function _impactDistribution(uint256 dt) internal view returns (uint256) {
        uint256 period = market.IMPACT_POOL_DISTRIBUTION_PERIOD();
        uint256 impactPool = market.impactPoolAmount();
        return dt >= period ? impactPool : impactPool * dt / period;
    }

    /// @dev `poolAmount` as the next settlement will see it (after it accrues and distributes the impact pool).
    function _poolAfterAccrual() internal view returns (uint256) {
        return market.poolAmount() + _impactDistribution(block.timestamp - market.lastAccrualAt());
    }

    /// @dev Token conservation across the three custody contracts.
    function _assertConservation() internal view {
        assertEq(
            usd.balanceOf(address(market)),
            market.poolAmount() + market.impactPoolAmount() + market.totalCollateral(),
            "market buckets"
        );
        assertEq(usd.balanceOf(address(orderBook)), orderBook.totalEscrow(), "order book escrow");
        assertEq(usd.balanceOf(address(vault)), vault.escrowedAssets(), "vault escrow");
        assertEq(vault.balanceOf(address(vault)), vault.escrowedShares(), "vault escrowed shares");
    }
}
