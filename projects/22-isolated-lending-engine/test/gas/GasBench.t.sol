// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {AdaptiveCurveIrm} from "../../src/irm/AdaptiveCurveIrm.sol";
import {FlashLiquidator} from "../../src/periphery/FlashLiquidator.sol";
import {ISwapVenue} from "../../src/periphery/ISwapVenue.sol";
import {MockSwapVenue} from "../mocks/MockSwapVenue.sol";
import {FlashBorrower} from "../unit/FlashLoanReentrancy.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @notice Deterministic gas benchmarks of the hot paths, snapshotted in `.gas-snapshot` and checked in CI with
///         `forge snapshot --check --match-contract GasBench`. Each test measures one call in a warm market
///         (non-zero totals, one day of interest pending where accrual applies). `GasBench` runs them on a market
///         with the constant-rate mock IRM, `GasBenchAdaptiveIrm` on a market with the `AdaptiveCurveIrm` that
///         deployments use, whose accrual also runs `expWad` twice, Simpson's rule and a storage write.
abstract contract GasBenchBase is BaseTest {
    FlashLiquidator internal flash;
    MockSwapVenue internal venue;
    FlashBorrower internal flashBorrower;

    function setUp() public virtual override {
        super.setUp();
        _useMarket();
        _supply(supplier, 1000e18);
        _supplyCollateral(borrower, 100e18);
        _borrow(borrower, 60e18);
        loanToken.mint(borrower, 100e18);
        loanToken.mint(liquidator, 1000e18);
        collateralToken.mint(borrower, 100e18);
        loanToken.mint(supplier, 100e18);

        flash = new FlashLiquidator(engine, liquidator);
        venue = new MockSwapVenue(oracle, address(collateralToken), address(loanToken), 30);
        loanToken.mint(address(venue), 1_000_000e18);
        flashBorrower = new FlashBorrower(engine);
        skip(1 days);
    }

    /// @dev Selects the market the benches run on (and its interest rate model).
    function _useMarket() internal virtual;

    function test_gas_supply() public {
        vm.prank(supplier);
        engine.supply(marketParams, 10e18, 0, supplier, "");
    }

    function test_gas_withdraw() public {
        vm.prank(supplier);
        engine.withdraw(marketParams, 10e18, 0, supplier, supplier);
    }

    function test_gas_supplyCollateral() public {
        vm.prank(borrower);
        engine.supplyCollateral(marketParams, 10e18, borrower, "");
    }

    function test_gas_withdrawCollateral() public {
        vm.prank(borrower);
        engine.withdrawCollateral(marketParams, 10e18, borrower, borrower);
    }

    function test_gas_borrow() public {
        vm.prank(borrower);
        engine.borrow(marketParams, 5e18, 0, borrower, borrower);
    }

    function test_gas_repay() public {
        vm.prank(borrower);
        engine.repay(marketParams, 5e18, 0, borrower, "");
    }

    function test_gas_liquidatePartial() public {
        oracle.setPrice(0.66e36); // health ~0.946: partial liquidation in the solvent region
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, 10e18, 0, "");
    }

    function test_gas_liquidateCloseoutCappedAtEquity() public {
        oracle.setPrice(0.61e36); // collateral worth 61 covers the ~60 debt but not the 5 % bonus
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, type(uint256).max, 0, "");
    }

    function test_gas_liquidateCloseoutWithBadDebt() public {
        oracle.setPrice(0.5e36);
        vm.prank(liquidator);
        engine.liquidate(marketParams, borrower, type(uint256).max, 0, "");
    }

    function test_gas_flashLiquidation() public {
        oracle.setPrice(0.66e36);
        FlashLiquidator.Order memory order = FlashLiquidator.Order({
            marketParams: marketParams,
            borrower: borrower,
            seizedAssets: 10e18,
            repaidShares: 0,
            venue: ISwapVenue(address(venue)),
            minAmountOut: 0
        });
        vm.prank(liquidator);
        flash.liquidate(order, 10e18, 0);
    }

    function test_gas_flashLoan() public {
        flashBorrower.borrow(address(loanToken), 500e18, FlashBorrower.Mode.Repay);
    }

    function test_gas_accrueInterest() public {
        engine.accrueInterest(marketParams);
    }

    function test_gas_createMarket() public {
        MarketParams memory params = marketParams;
        params.collateralToken = address(0xC0FFEE);
        engine.createMarket(params);
    }

    function test_gas_healthFactorView() public view {
        engine.healthFactor(marketParams, borrower);
    }
}

/// @notice The benches on the fixture's market: constant 5 % APR mock IRM (a view function returning a number), so
///         the figures isolate the engine's own cost. Also holds the reentrancy-guard baselines.
contract GasBench is GasBenchBase {
    NoGuardHarness internal noGuard;
    TransientMarketLockHarness internal transientLock;
    TransientGuardHarness internal transientGuard;
    StorageGuardHarness internal storageGuard;

    function setUp() public override {
        super.setUp();
        noGuard = new NoGuardHarness();
        transientLock = new TransientMarketLockHarness();
        transientGuard = new TransientGuardHarness();
        storageGuard = new StorageGuardHarness();
    }

    function _useMarket() internal override {
        irm.setRate(uint256(0.05e18) / 365 days);
    }

    // --- Baseline: the per-market transient lock vs. OpenZeppelin's guards vs. no guard -----------------------

    function test_gas_baseline_noGuard() public {
        noGuard.touch(bytes32(uint256(1)));
    }

    function test_gas_baseline_transientMarketLock() public {
        transientLock.touch(bytes32(uint256(1)));
    }

    function test_gas_baseline_transientReentrancyGuard() public {
        transientGuard.touch(bytes32(uint256(1)));
    }

    function test_gas_baseline_storageReentrancyGuard() public {
        storageGuard.touch(bytes32(uint256(1)));
    }
}

/// @notice The same benches on a market that uses the deployed `AdaptiveCurveIrm`.
contract GasBenchAdaptiveIrm is GasBenchBase {
    function _useMarket() internal override {
        AdaptiveCurveIrm adaptive = new AdaptiveCurveIrm(address(engine));
        vm.prank(owner);
        engine.enableIrm(address(adaptive));
        marketParams.irm = address(adaptive);
        id = engine.createMarket(marketParams);
    }
}

/// @dev Same warm storage write in every harness; only the guard differs.
contract NoGuardHarness {
    uint256 internal counter = 1;

    function touch(bytes32) external {
        ++counter;
    }
}

/// @dev The engine's lock: one transient slot per market id (tload + 2 tstore).
contract TransientMarketLockHarness {
    using SlotDerivation for bytes32;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    bytes32 private constant MARKET_LOCK_SLOT = 0xca540b57ea7c54395033237ab4809e5314fe1685f5699a4b3ae741259b361300;
    uint256 internal counter = 1;

    error Locked();

    function touch(bytes32 id) external {
        TransientSlot.BooleanSlot slot = MARKET_LOCK_SLOT.deriveMapping(id).asBoolean();
        require(!slot.tload(), Locked());
        slot.tstore(true);
        ++counter;
        slot.tstore(false);
    }
}

/// @dev OpenZeppelin's transient guard (one global lock): the alternative the design table weighs.
contract TransientGuardHarness is ReentrancyGuardTransient {
    uint256 internal counter = 1;

    function touch(bytes32) external nonReentrant {
        ++counter;
    }
}

/// @dev OpenZeppelin's storage-based guard (one global lock), for reference.
contract StorageGuardHarness is ReentrancyGuard {
    uint256 internal counter = 1;

    function touch(bytes32) external nonReentrant {
        ++counter;
    }
}
