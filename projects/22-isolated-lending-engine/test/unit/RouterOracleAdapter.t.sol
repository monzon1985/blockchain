// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {LendingEngine} from "../../src/LendingEngine.sol";
import {Id, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {RouterOracleAdapter} from "../../src/oracles/RouterOracleAdapter.sol";
import {FixedRateIrm} from "../mocks/FixedRateIrm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/// @notice Oracle-failure matrix for the adapter: every router status on either leg of either source.
contract RouterOracleAdapterTest is Test {
    MockPriceOracle internal primary;
    MockPriceOracle internal secondary;
    MockERC20 internal weth; // 18 decimals, collateral
    MockERC20 internal usdc; // 6 decimals, loan
    RouterOracleAdapter internal adapter;

    uint256 internal constant WETH_USD = 2000e18;
    uint256 internal constant WETH_USD_SECONDARY = 1990e18;
    uint256 internal constant USDC_USD = 1e18;
    // 1 wei of WETH in USDC base units, 1e36-scaled: 2000 * 10^(36 + 6 - 18).
    uint256 internal constant PRIMARY_PRICE = 2000e24;
    uint256 internal constant SECONDARY_PRICE = 1990e24;

    function setUp() public {
        primary = new MockPriceOracle();
        secondary = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        adapter = new RouterOracleAdapter(primary, secondary, address(weth), address(usdc));
        primary.setQuote(address(weth), WETH_USD, IPriceOracle.Status.OK);
        primary.setQuote(address(usdc), USDC_USD, IPriceOracle.Status.OK);
        secondary.setQuote(address(weth), WETH_USD_SECONDARY, IPriceOracle.Status.OK);
        secondary.setQuote(address(usdc), USDC_USD, IPriceOracle.Status.OK);
    }

    function _assertQuote(uint256 expectedPrice, RouterOracleAdapter.Source expectedSource) internal view {
        (uint256 value, RouterOracleAdapter.Source source) = adapter.quote();
        assertEq(value, expectedPrice);
        assertEq(uint256(source), uint256(expectedSource));
        assertEq(adapter.price(), expectedPrice);
    }

    function test_constructor_scaleFactor() public view {
        assertEq(adapter.SCALE_FACTOR(), 1e24);
        assertEq(address(adapter.PRIMARY()), address(primary));
        assertEq(address(adapter.SECONDARY()), address(secondary));
        assertEq(adapter.COLLATERAL_TOKEN(), address(weth));
        assertEq(adapter.LOAN_TOKEN(), address(usdc));
    }

    function test_primaryOk() public view {
        _assertQuote(PRIMARY_PRICE, RouterOracleAdapter.Source.Primary);
        // 1 WETH is worth 2000 USDC.
        assertEq(1e18 * adapter.price() / 1e36, 2000e6);
    }

    /// @notice Every non-OK, non-sequencer status on either primary leg falls through to the secondary.
    function test_failedPrimaryLegFallsBackToSecondary() public {
        IPriceOracle.Status[6] memory failures = [
            IPriceOracle.Status.STALE,
            IPriceOracle.Status.ZERO,
            IPriceOracle.Status.NEGATIVE,
            IPriceOracle.Status.OUT_OF_BOUNDS,
            IPriceOracle.Status.DEVIATION,
            IPriceOracle.Status.FALLBACK_USED
        ];
        for (uint256 i; i < failures.length; ++i) {
            primary.setQuote(address(weth), WETH_USD, failures[i]);
            _assertQuote(SECONDARY_PRICE, RouterOracleAdapter.Source.Secondary);
            primary.setQuote(address(weth), WETH_USD, IPriceOracle.Status.OK);

            primary.setQuote(address(usdc), USDC_USD, failures[i]);
            _assertQuote(SECONDARY_PRICE, RouterOracleAdapter.Source.Secondary);
            primary.setQuote(address(usdc), USDC_USD, IPriceOracle.Status.OK);
        }
    }

    function test_zeroPriceWithOkStatusIsRejected() public {
        primary.setQuote(address(weth), 0, IPriceOracle.Status.OK);
        _assertQuote(SECONDARY_PRICE, RouterOracleAdapter.Source.Secondary);
        primary.setQuote(address(weth), WETH_USD, IPriceOracle.Status.OK);
        primary.setQuote(address(usdc), 0, IPriceOracle.Status.OK);
        _assertQuote(SECONDARY_PRICE, RouterOracleAdapter.Source.Secondary);
    }

    function test_primaryTwapUsedOnlyWhenSecondaryFails() public {
        primary.setQuote(address(weth), WETH_USD, IPriceOracle.Status.FALLBACK_USED);
        secondary.setQuote(address(weth), WETH_USD_SECONDARY, IPriceOracle.Status.STALE);
        _assertQuote(PRIMARY_PRICE, RouterOracleAdapter.Source.PrimaryFallback);
    }

    function test_zeroTwapIsRejected() public {
        primary.setQuote(address(weth), 0, IPriceOracle.Status.FALLBACK_USED);
        secondary.setQuote(address(weth), WETH_USD_SECONDARY, IPriceOracle.Status.STALE);
        vm.expectRevert(
            abi.encodeWithSelector(
                RouterOracleAdapter.PriceUnavailable.selector,
                IPriceOracle.Status.FALLBACK_USED,
                IPriceOracle.Status.OK,
                IPriceOracle.Status.STALE,
                IPriceOracle.Status.OK
            )
        );
        adapter.price();
    }

    function test_bothSourcesDownReverts() public {
        primary.setQuote(address(weth), WETH_USD, IPriceOracle.Status.STALE);
        secondary.setQuote(address(usdc), USDC_USD, IPriceOracle.Status.DEVIATION);
        vm.expectRevert(
            abi.encodeWithSelector(
                RouterOracleAdapter.PriceUnavailable.selector,
                IPriceOracle.Status.STALE,
                IPriceOracle.Status.OK,
                IPriceOracle.Status.OK,
                IPriceOracle.Status.DEVIATION
            )
        );
        adapter.price();
    }

    function test_sequencerStatusesHaltWithoutFallback() public {
        IPriceOracle.Status[2] memory sequencer = [IPriceOracle.Status.SEQUENCER_DOWN, IPriceOracle.Status.GRACE_PERIOD];
        for (uint256 i; i < 2; ++i) {
            primary.setQuote(address(weth), WETH_USD, sequencer[i]);
            vm.expectRevert(abi.encodeWithSelector(RouterOracleAdapter.SequencerUnavailable.selector, sequencer[i]));
            adapter.price();
            primary.setQuote(address(weth), WETH_USD, IPriceOracle.Status.OK);

            primary.setQuote(address(usdc), USDC_USD, sequencer[i]);
            vm.expectRevert(abi.encodeWithSelector(RouterOracleAdapter.SequencerUnavailable.selector, sequencer[i]));
            adapter.price();
            primary.setQuote(address(usdc), USDC_USD, IPriceOracle.Status.OK);
        }
    }

    function test_secondarySequencerStatusHaltsWhenConsulted() public {
        primary.setQuote(address(weth), WETH_USD, IPriceOracle.Status.STALE);
        secondary.setQuote(address(weth), WETH_USD_SECONDARY, IPriceOracle.Status.GRACE_PERIOD);
        vm.expectRevert(
            abi.encodeWithSelector(RouterOracleAdapter.SequencerUnavailable.selector, IPriceOracle.Status.GRACE_PERIOD)
        );
        adapter.price();

        secondary.setQuote(address(weth), WETH_USD_SECONDARY, IPriceOracle.Status.OK);
        secondary.setQuote(address(usdc), USDC_USD, IPriceOracle.Status.SEQUENCER_DOWN);
        vm.expectRevert(
            abi.encodeWithSelector(
                RouterOracleAdapter.SequencerUnavailable.selector, IPriceOracle.Status.SEQUENCER_DOWN
            )
        );
        adapter.price();
    }

    function test_secondaryIgnoredWhilePrimaryHealthy() public {
        secondary.setQuote(address(weth), 0, IPriceOracle.Status.SEQUENCER_DOWN);
        _assertQuote(PRIMARY_PRICE, RouterOracleAdapter.Source.Primary);
    }

    function test_roundingNeverOvervaluesCollateral(uint256 collateralUsd, uint256 loanUsd) public {
        collateralUsd = bound(collateralUsd, 1, 1e30);
        loanUsd = bound(loanUsd, 1, 1e30);
        primary.setQuote(address(weth), collateralUsd, IPriceOracle.Status.OK);
        primary.setQuote(address(usdc), loanUsd, IPriceOracle.Status.OK);
        primary.setRoundingSpread(true); // Debt-intent quotes come back one wei higher
        uint256 value = adapter.price();
        // value <= collateralUsd * 1e24 / loanUsd (the loan leg was rounded up, the quotient rounds down)
        assertLe(value * loanUsd, collateralUsd * 1e24);
    }

    function test_decimalsCombinations() public {
        MockERC20 wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        RouterOracleAdapter a = new RouterOracleAdapter(primary, secondary, address(wbtc), address(dai));
        assertEq(a.SCALE_FACTOR(), 1e46);
        primary.setQuote(address(wbtc), 60_000e18, IPriceOracle.Status.OK);
        primary.setQuote(address(dai), 1e18, IPriceOracle.Status.OK);
        // 1 WBTC (1e8 base units) is worth 60_000 DAI (6e22 base units).
        assertEq(1e8 * a.price() / 1e36, 60_000e18);
    }

    function test_constructor_reverts() public {
        vm.expectRevert(RouterOracleAdapter.ZeroAddress.selector);
        new RouterOracleAdapter(IPriceOracle(address(0)), secondary, address(weth), address(usdc));
        vm.expectRevert(RouterOracleAdapter.ZeroAddress.selector);
        new RouterOracleAdapter(primary, IPriceOracle(address(0)), address(weth), address(usdc));
        vm.expectRevert(RouterOracleAdapter.ZeroAddress.selector);
        new RouterOracleAdapter(primary, secondary, address(0), address(usdc));
        vm.expectRevert(RouterOracleAdapter.ZeroAddress.selector);
        new RouterOracleAdapter(primary, secondary, address(weth), address(0));

        MockERC20 weird = new MockERC20("Weird", "WRD", 60);
        MockERC20 none = new MockERC20("None", "NON", 0);
        vm.expectRevert(abi.encodeWithSelector(RouterOracleAdapter.InvalidDecimals.selector, 60, 6));
        new RouterOracleAdapter(primary, secondary, address(weird), address(usdc));
        vm.expectRevert(abi.encodeWithSelector(RouterOracleAdapter.InvalidDecimals.selector, 0, 60));
        new RouterOracleAdapter(primary, secondary, address(none), address(weird));
    }
}

/// @notice End to end: a crash while the primary feed is stale is still liquidated through the secondary.
contract AdapterLiquidationTest is Test {
    LendingEngine internal engine;
    MockPriceOracle internal primary;
    MockPriceOracle internal secondary;
    MockERC20 internal weth;
    MockERC20 internal usdc;
    MarketParams internal params;
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        engine = new LendingEngine(address(this), address(this));
        FixedRateIrm irm = new FixedRateIrm(0);
        engine.enableIrm(address(irm));
        engine.enableLltv(0.86e18, 0.05e18, 2e18);
        primary = new MockPriceOracle();
        secondary = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        RouterOracleAdapter adapter = new RouterOracleAdapter(primary, secondary, address(weth), address(usdc));
        _setPrices(primary, 2000e18);
        _setPrices(secondary, 2000e18);
        params = MarketParams(address(usdc), address(weth), address(adapter), address(irm), 0.86e18);
        engine.createMarket(params);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(engine), type(uint256).max);
        engine.supply(params, 1_000_000e6, 0, address(this), "");

        weth.mint(borrower, 10e18);
        vm.startPrank(borrower);
        weth.approve(address(engine), type(uint256).max);
        engine.supplyCollateral(params, 10e18, borrower, "");
        engine.borrow(params, 16_000e6, 0, borrower, borrower); // 80 % LTV
        vm.stopPrank();
    }

    function _setPrices(MockPriceOracle source, uint256 wethUsd) internal {
        source.setQuote(address(weth), wethUsd, IPriceOracle.Status.OK);
        source.setQuote(address(usdc), 1e18, IPriceOracle.Status.OK);
    }

    function test_liquidationContinuesOnSecondaryWhenPrimaryStale() public {
        // Primary froze at 2000 and is now stale; the secondary sees the crash to 1800.
        primary.setQuote(address(weth), 2000e18, IPriceOracle.Status.STALE);
        _setPrices(secondary, 1800e18);

        assertLt(engine.healthFactor(params, borrower), 1e18);
        usdc.mint(liquidator, 20_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(engine), type(uint256).max);
        (uint256 seized,) = engine.liquidate(params, borrower, 1e18, 0, "");
        vm.stopPrank();
        assertEq(seized, 1e18);
        assertEq(weth.balanceOf(liquidator), 1e18);
    }

    function test_sequencerOutageFreezesLiquidations() public {
        primary.setQuote(address(weth), 1800e18, IPriceOracle.Status.GRACE_PERIOD);
        _setPrices(secondary, 1800e18);
        vm.expectRevert(
            abi.encodeWithSelector(RouterOracleAdapter.SequencerUnavailable.selector, IPriceOracle.Status.GRACE_PERIOD)
        );
        engine.liquidate(params, borrower, 1e18, 0, "");
    }
}
