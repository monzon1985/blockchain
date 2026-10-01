// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";

import {
    IFlashLoanCallback,
    ILiquidateCallback,
    IRepayCallback,
    ISupplyCallback,
    ISupplyCollateralCallback
} from "../../src/interfaces/ILendingCallbacks.sol";
import {ILendingEngine, Id, MarketParams} from "../../src/interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../../src/libraries/MarketParamsLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract FlashLoanTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _supply(supplier, 1000e18);
    }

    function test_flashLoan() public {
        FlashBorrower fb = new FlashBorrower(engine);
        vm.expectEmit(address(engine));
        emit ILendingEngine.FlashLoan(address(fb), address(loanToken), 500e18);
        fb.borrow(address(loanToken), 500e18, FlashBorrower.Mode.Repay);
        assertEq(fb.balanceSeen(), 500e18);
        assertEq(loanToken.balanceOf(address(engine)), 1000e18);
    }

    function test_flashLoan_revertsWhenNotRepaid() public {
        FlashBorrower fb = new FlashBorrower(engine);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(engine), 0, 500e18)
        );
        fb.borrow(address(loanToken), 500e18, FlashBorrower.Mode.NoApproval);
    }

    function test_flashLoan_revertsOnZeroAmount() public {
        vm.expectRevert(ILendingEngine.ZeroAmount.selector);
        engine.flashLoan(address(loanToken), 0, "");
    }

    function test_flashLoan_revertsAboveBalance() public {
        FlashBorrower fb = new FlashBorrower(engine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(engine), 1000e18, 1000e18 + 1
            )
        );
        fb.borrow(address(loanToken), 1000e18 + 1, FlashBorrower.Mode.Repay);
    }

    function test_flashLoan_callbackCanUseMarkets() public {
        // Flash loans are not market-bound: the callback can supply into the market and withdraw again.
        FlashBorrower fb = new FlashBorrower(engine);
        fb.setMarket(marketParams);
        fb.borrow(address(loanToken), 100e18, FlashBorrower.Mode.SupplyAndWithdraw);
        assertEq(loanToken.balanceOf(address(engine)), 1000e18);
        assertEq(engine.position(id, address(fb)).supplyShares, 0);
    }
}

contract FlashBorrower is IFlashLoanCallback {
    enum Mode {
        Repay,
        NoApproval,
        SupplyAndWithdraw
    }

    ILendingEngine internal immutable ENGINE;
    MarketParams internal params;
    uint256 public balanceSeen;

    constructor(ILendingEngine engine) {
        ENGINE = engine;
    }

    function setMarket(MarketParams memory marketParams) external {
        params = marketParams;
    }

    function borrow(address token, uint256 assets, Mode mode) external {
        ENGINE.flashLoan(token, assets, abi.encode(token, mode));
    }

    function onFlashLoan(uint256 assets, bytes calldata data) external {
        (address token, Mode mode) = abi.decode(data, (address, Mode));
        balanceSeen = MockERC20(token).balanceOf(address(this));
        if (mode == Mode.SupplyAndWithdraw) {
            MockERC20(token).approve(address(ENGINE), assets);
            (, uint256 shares) = ENGINE.supply(params, assets, 0, address(this), "");
            ENGINE.withdraw(params, 0, shares, address(this), address(this));
        }
        if (mode != Mode.NoApproval) MockERC20(token).approve(address(ENGINE), assets);
    }
}

/// @notice Every callback runs with its market locked; other markets stay open.
contract ReentrancyTest is BaseTest {
    using MarketParamsLib for MarketParams;

    MarketParams internal otherParams;
    Id internal otherId;
    Reentrant internal attacker;

    function setUp() public override {
        super.setUp();
        MockERC20 otherCollateral = new MockERC20("Other", "OTH", 18);
        otherParams = marketParams;
        otherParams.collateralToken = address(otherCollateral);
        otherParams.oracle = address(new MockOracle(1e36));
        otherId = engine.createMarket(otherParams);

        _supply(supplier, 1000e18);
        loanToken.mint(supplier, 1000e18);
        vm.prank(supplier);
        engine.supply(otherParams, 1000e18, 0, supplier, "");

        attacker = new Reentrant(engine, marketParams, otherParams);
        loanToken.mint(address(attacker), 1000e18);
        collateralToken.mint(address(attacker), 1000e18);
    }

    function test_supplyCallback_sameMarketLocked() public {
        attacker.arm(Reentrant.Target.SameMarket);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketLocked.selector, id));
        attacker.supply(1e18);
    }

    function test_supplyCallback_otherMarketOpen() public {
        attacker.arm(Reentrant.Target.OtherMarket);
        // The lock is probed inside the same transaction: after the call returns, transient storage is gone anyway.
        assertFalse(attacker.supplyThenProbeLock(1e18), "lock still held after supply returned");
        assertGt(engine.position(otherId, address(attacker)).supplyShares, 0);
    }

    function test_repayCallback_sameMarketLocked() public {
        attacker.openDebt(10e18);
        attacker.arm(Reentrant.Target.SameMarket);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketLocked.selector, id));
        attacker.repay(1e18);
    }

    function test_supplyCollateralCallback_sameMarketLocked() public {
        attacker.arm(Reentrant.Target.SameMarket);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketLocked.selector, id));
        attacker.supplyCollateral(1e18);
    }

    function test_liquidateCallback_sameMarketLocked() public {
        _supplyCollateral(borrower, 100e18);
        _borrow(borrower, 80e18);
        oracle.setPrice(0.9e36);
        attacker.arm(Reentrant.Target.SameMarket);
        vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketLocked.selector, id));
        attacker.liquidate(borrower, 1e18);
    }

    function test_liquidateCallback_otherMarketOpen() public {
        _supplyCollateral(borrower, 100e18);
        _borrow(borrower, 80e18);
        oracle.setPrice(0.9e36);
        attacker.arm(Reentrant.Target.OtherMarket);
        attacker.liquidate(borrower, 1e18);
        assertEq(collateralToken.balanceOf(address(attacker)), 1000e18 + 1e18);
    }

    function test_lockBlocksEveryEntryPoint() public {
        for (uint256 i; i < 8; ++i) {
            attacker.arm(Reentrant.Target.SameMarket);
            attacker.setReentryKind(i);
            vm.expectRevert(abi.encodeWithSelector(ILendingEngine.MarketLocked.selector, id));
            attacker.supply(1e18);
        }
    }
}

contract Reentrant is ISupplyCallback, IRepayCallback, ISupplyCollateralCallback, ILiquidateCallback {
    enum Target {
        None,
        SameMarket,
        OtherMarket
    }

    ILendingEngine internal immutable ENGINE;
    MarketParams internal params;
    MarketParams internal otherParams;
    Target internal target;
    uint256 internal reentryKind;

    constructor(ILendingEngine engine, MarketParams memory marketParams, MarketParams memory other) {
        ENGINE = engine;
        params = marketParams;
        otherParams = other;
        MockERC20(params.loanToken).approve(address(engine), type(uint256).max);
        MockERC20(params.collateralToken).approve(address(engine), type(uint256).max);
    }

    function arm(Target newTarget) external {
        target = newTarget;
    }

    function setReentryKind(uint256 kind) external {
        reentryKind = kind;
    }

    function openDebt(uint256 assets) external {
        Target saved = target;
        target = Target.None;
        ENGINE.supplyCollateral(params, assets * 2, address(this), "");
        ENGINE.borrow(params, assets, 0, address(this), address(this));
        target = saved;
    }

    function supply(uint256 assets) external {
        ENGINE.supply(params, assets, 0, address(this), hex"01");
    }

    /// @dev Supplies with the callback armed, then reports whether the market is still locked, in one transaction.
    function supplyThenProbeLock(uint256 assets) external returns (bool locked) {
        ENGINE.supply(params, assets, 0, address(this), hex"01");
        locked = ENGINE.isMarketLocked(MarketParamsLib.id(params));
    }

    function repay(uint256 assets) external {
        ENGINE.repay(params, assets, 0, address(this), hex"01");
    }

    function supplyCollateral(uint256 assets) external {
        ENGINE.supplyCollateral(params, assets, address(this), hex"01");
    }

    function liquidate(address borrower, uint256 seized) external {
        ENGINE.liquidate(params, borrower, seized, 0, hex"01");
    }

    function onSupply(uint256, bytes calldata) external {
        _reenter();
    }

    function onRepay(uint256, bytes calldata) external {
        _reenter();
    }

    function onSupplyCollateral(uint256, bytes calldata) external {
        _reenter();
    }

    function onLiquidate(uint256, bytes calldata) external {
        _reenter();
    }

    function _reenter() internal {
        if (target == Target.None) return;
        MarketParams memory p = target == Target.SameMarket ? params : otherParams;
        if (reentryKind == 0) ENGINE.supply(p, 1e18, 0, address(this), "");
        else if (reentryKind == 1) ENGINE.withdraw(p, 1, 0, address(this), address(this));
        else if (reentryKind == 2) ENGINE.borrow(p, 1, 0, address(this), address(this));
        else if (reentryKind == 3) ENGINE.repay(p, 1, 0, address(this), "");
        else if (reentryKind == 4) ENGINE.supplyCollateral(p, 1, address(this), "");
        else if (reentryKind == 5) ENGINE.withdrawCollateral(p, 1, address(this), address(this));
        else if (reentryKind == 6) ENGINE.liquidate(p, address(this), 1, 0, "");
        else ENGINE.accrueInterest(p);
    }
}

/// @notice Every entry point that takes a market lock releases it before returning.
/// @dev The check has to run inside the transaction that took the lock: EIP-1153 clears transient storage when a
///      transaction ends, and Foundry clears it between the test contract's top-level calls, so reading
///      `isMarketLocked` from the test after the call returns could never fail. `LockProbe` performs each operation
///      and, in the same call, reads the lock and runs a second operation on the same market.
contract LockReleaseTest is BaseTest {
    LockProbe internal probe;

    function setUp() public override {
        super.setUp();
        probe = new LockProbe(engine, marketParams, borrower);
        _supply(supplier, 1000e18);
        _supplyCollateral(borrower, 100e18);
        _borrow(borrower, 80e18);
        loanToken.mint(address(probe), 1000e18);
        collateralToken.mint(address(probe), 1000e18);
        // The probe also exercises `setFee`, which is owner-only.
        vm.prank(owner);
        engine.transferOwnership(address(probe));
        probe.acceptOwnership();
    }

    function test_everyLockingEntryPointReleasesItsLockWithinTheTransaction() public {
        string[9] memory names = [
            "supply",
            "withdraw",
            "supplyCollateral",
            "borrow",
            "repay",
            "withdrawCollateral",
            "accrueInterest",
            "setFee",
            "liquidate"
        ];
        for (uint256 op; op < names.length; ++op) {
            if (op == 8) oracle.setPrice(0.9e36); // makes `borrower` liquidatable; the probe's own debt stays tiny
            skip(1 hours); // every operation accrues, so the IRM call happens under the lock too
            (bool lockedAfter, bool secondCallSucceeded) = probe.run(op);
            assertFalse(lockedAfter, string.concat(names[op], ": market still locked after the call returned"));
            assertTrue(secondCallSucceeded, string.concat(names[op], ": second call on the market reverted"));
        }
    }
}

/// @notice Runs one locking operation, then probes the lock and re-enters the market within the same call.
contract LockProbe {
    using MarketParamsLib for MarketParams;

    ILendingEngine internal immutable ENGINE;
    MarketParams internal params;
    address internal immutable BORROWER;

    constructor(ILendingEngine engine, MarketParams memory marketParams, address borrower) {
        ENGINE = engine;
        params = marketParams;
        BORROWER = borrower;
        MockERC20(marketParams.loanToken).approve(address(engine), type(uint256).max);
        MockERC20(marketParams.collateralToken).approve(address(engine), type(uint256).max);
    }

    function acceptOwnership() external {
        (bool ok,) = address(ENGINE).call(abi.encodeWithSignature("acceptOwnership()"));
        require(ok, "acceptOwnership");
    }

    /// @return lockedAfter Whether the market was still locked once the operation returned.
    /// @return secondCallSucceeded Whether a second operation on the same market went through.
    function run(uint256 op) external returns (bool lockedAfter, bool secondCallSucceeded) {
        if (op == 0) ENGINE.supply(params, 10e18, 0, address(this), "");
        else if (op == 1) ENGINE.withdraw(params, 1e18, 0, address(this), address(this));
        else if (op == 2) ENGINE.supplyCollateral(params, 10e18, address(this), "");
        else if (op == 3) ENGINE.borrow(params, 1e18, 0, address(this), address(this));
        else if (op == 4) ENGINE.repay(params, 0.5e18, 0, address(this), "");
        else if (op == 5) ENGINE.withdrawCollateral(params, 1e18, address(this), address(this));
        else if (op == 6) ENGINE.accrueInterest(params);
        else if (op == 7) ENGINE.setFee(params, 0.01e18 * (ENGINE.market(params.id()).fee == 0 ? 1 : 2));
        else ENGINE.liquidate(params, BORROWER, 1e18, 0, "");
        lockedAfter = ENGINE.isMarketLocked(params.id());
        try ENGINE.accrueInterest(params) {
            secondCallSucceeded = true;
        } catch {}
    }
}
