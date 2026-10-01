// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LendingEngine} from "../../src/LendingEngine.sol";
import {IFlashLoanCallback} from "../../src/interfaces/ILendingCallbacks.sol";
import {ILendingEngine, Id, Market, MarketParams, Position} from "../../src/interfaces/ILendingEngine.sol";
import {AdaptiveCurveIrm} from "../../src/irm/AdaptiveCurveIrm.sol";
import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";
import {SharesMathLib} from "../../src/libraries/SharesMathLib.sol";
import {FixedRateIrm} from "../mocks/FixedRateIrm.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev Cheatcodes shared by Foundry and Medusa (both serve them at the same address).
interface IHevm {
    function warp(uint256 timestamp) external;
}

/// @notice A user contract; the system drives it so the harness needs no `prank` support.
/// @dev After every engine call, and still inside the same transaction, the actor checks that no market is left
///      locked. The check has to live here: Foundry 1.8 runs in isolation mode, where each call the handler makes
///      (depth 1) is its own transaction, so by the time the handler regains control EIP-1153 has already cleared the
///      transient lock. Under Medusa the whole handler call is one transaction and the handler checks again.
contract Actor is IFlashLoanCallback {
    /// @notice An engine call returned while `id` was still locked (raised by this harness, never by the engine).
    error LockLeaked(Id id);

    /// @dev Flash-loan callback actions.
    uint256 internal constant SUPPLY_THEN_WITHDRAW = 1;
    uint256 internal constant CLOSE_POSITION = 2;

    LendingEngine internal immutable ENGINE;
    Id[3] internal marketIds;

    constructor(LendingEngine engine, MockERC20[3] memory tokens, Id[3] memory ids) {
        ENGINE = engine;
        marketIds = ids;
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].approve(address(engine), type(uint256).max);
        }
    }

    function _requireUnlocked() internal view {
        for (uint256 i; i < marketIds.length; ++i) {
            if (ENGINE.isMarketLocked(marketIds[i])) revert LockLeaked(marketIds[i]);
        }
    }

    function supply(MarketParams memory p, uint256 assets, uint256 shares) external {
        ENGINE.supply(p, assets, shares, address(this), "");
        _requireUnlocked();
    }

    function withdraw(MarketParams memory p, uint256 assets, uint256 shares) external {
        ENGINE.withdraw(p, assets, shares, address(this), address(this));
        _requireUnlocked();
    }

    function supplyCollateral(MarketParams memory p, uint256 assets) external {
        ENGINE.supplyCollateral(p, assets, address(this), "");
        _requireUnlocked();
    }

    function withdrawCollateral(MarketParams memory p, uint256 assets) external {
        ENGINE.withdrawCollateral(p, assets, address(this), address(this));
        _requireUnlocked();
    }

    function borrow(MarketParams memory p, uint256 assets, uint256 shares) external {
        ENGINE.borrow(p, assets, shares, address(this), address(this));
        _requireUnlocked();
    }

    function repay(MarketParams memory p, uint256 assets, uint256 shares) external {
        ENGINE.repay(p, assets, shares, address(this), "");
        _requireUnlocked();
    }

    function accrue(MarketParams memory p) external {
        ENGINE.accrueInterest(p);
        _requireUnlocked();
    }

    function liquidate(MarketParams memory p, address borrower, uint256 seized, uint256 repaidShares)
        external
        returns (uint256 seizedAssets, uint256 repaidAssets)
    {
        (seizedAssets, repaidAssets) = ENGINE.liquidate(p, borrower, seized, repaidShares, "");
        _requireUnlocked();
    }

    function flashLoan(address token, uint256 assets, bytes memory data) external {
        ENGINE.flashLoan(token, assets, data);
        _requireUnlocked();
    }

    /// @dev Runs a market action with the flash-borrowed funds: supply them and withdraw the minted shares again (two
    ///      operations on one market inside one transaction), or close a liquidatable position (the keeper's path).
    function onFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(ENGINE), "not engine");
        if (data.length == 0) return;
        (uint256 action, MarketParams memory p, address borrower) = abi.decode(data, (uint256, MarketParams, address));
        if (action == SUPPLY_THEN_WITHDRAW) {
            (, uint256 shares) = ENGINE.supply(p, assets, 0, address(this), "");
            _requireUnlocked();
            ENGINE.withdraw(p, 0, shares, address(this), address(this));
        } else if (action == CLOSE_POSITION) {
            ENGINE.liquidate(p, borrower, 0, type(uint256).max, "");
        }
        _requireUnlocked();
    }
}

/// @notice Stateful fuzzing harness over three isolated markets that share tokens across roles:
///         M0 = L1 against C1 (adaptive IRM, 10 % fee), M1 = L1 against C2 (fixed 10 % APR, LLTV 94.5 %),
///         M2 = C1 against L1 (adaptive IRM, LLTV 62.5 %). Actions cover all eight asset/share conversions, price
///         shocks of -60 % to +30 %, time jumps, liquidations in every mode (partial, close by `type(uint256).max`,
///         close by the observed amounts) and flash loans whose callbacks act on the markets. Ghost variables record
///         every violation of a per-call property and what the campaign reached.
/// @dev Used as the Foundry invariant handler (`LendingInvariants.t.sol`) and, unchanged, as the Medusa target
///      (`test/medusa/LendingProperties.sol`). Every engine call is wrapped in try/catch: reverts are expected
///      behavior, and the properties are about the state that successful calls leave behind. A `MarketLocked` revert
///      is never expected (no action re-enters a market), so it is recorded as a lock violation.
///
///      Lock release is checked inside the transaction that took the lock (EIP-1153 clears transient storage when a
///      transaction ends, so a check in a later transaction could never fail): every actor reads `isMarketLocked`
///      for every market right after each engine call and reverts with `LockLeaked`, the flash-loan callback chains
///      two operations on one market, and under Medusa (where a whole handler call is one transaction) `_after`
///      checks again.
contract LendingSystem {
    using SharesMathLib for uint256;

    IHevm internal constant HEVM = IHevm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant N_MARKETS = 3;
    uint256 internal constant N_USERS = 4;
    /// @dev User that starts every campaign with a position at 99.99 % of its borrowing capacity in each market.
    uint256 internal constant THRESHOLD_USER = 3;

    LendingEngine public engine;
    MockERC20 public l1;
    MockERC20 public c1;
    MockERC20 public c2;
    MockOracle[3] public oracles;
    MarketParams[3] internal params;
    Id[3] public ids;
    Actor[4] public users;
    Actor public liquidator;
    address public feeRecipient;

    // Ghost state: violations (every one must stay zero).
    uint256 public healthViolations;
    uint256 public isolationViolations;
    uint256 public sharePriceViolations;
    uint256 public badDebtWithoutCloseout;
    uint256 public lockViolations;
    uint256 public supplierLossAboveWater;

    // Ghost state: what the campaign reached.
    uint256 public liquidations;
    uint256 public partialLiquidations;
    uint256 public fullRepayments;
    uint256 public closeoutsWithoutBadDebt;
    uint256 public badDebtEvents;
    uint256[3] public badDebtRealized;
    uint256 public flashCallbackActions;
    /// @notice Successful calls per conversion: supply, withdraw, borrow, repay, each by assets then by shares.
    uint256[8] public conversionCalls;

    constructor() {
        feeRecipient = address(0xFEE);
        engine = new LendingEngine(address(this), feeRecipient);
        l1 = new MockERC20("Loan1", "L1", 18);
        c1 = new MockERC20("Coll1", "C1", 18);
        c2 = new MockERC20("Coll2", "C2", 18);
        AdaptiveCurveIrm adaptive = new AdaptiveCurveIrm(address(engine));
        FixedRateIrm fixedRate = new FixedRateIrm(uint256(0.1e18) / 365 days);
        engine.enableIrm(address(adaptive));
        engine.enableIrm(address(fixedRate));
        engine.enableLltv(0.86e18, 0.05e18, 2e18);
        engine.enableLltv(0.945e18, 0.02e18, 4e18);
        engine.enableLltv(0.625e18, 0.15e18, 1e18);

        oracles[0] = new MockOracle(2e36); // 1 C1 = 2 L1
        oracles[1] = new MockOracle(0.5e36); // 1 C2 = 0.5 L1
        oracles[2] = new MockOracle(0.5e36); // 1 L1 = 0.5 C1
        params[0] = MarketParams(address(l1), address(c1), address(oracles[0]), address(adaptive), 0.86e18);
        params[1] = MarketParams(address(l1), address(c2), address(oracles[1]), address(fixedRate), 0.945e18);
        params[2] = MarketParams(address(c1), address(l1), address(oracles[2]), address(adaptive), 0.625e18);
        for (uint256 m; m < N_MARKETS; ++m) {
            ids[m] = engine.createMarket(params[m]);
        }
        engine.setFee(params[0], 0.1e18);

        MockERC20[3] memory tokens = [l1, c1, c2];
        for (uint256 u; u < N_USERS; ++u) {
            users[u] = new Actor(engine, tokens, ids);
        }
        liquidator = new Actor(engine, tokens, ids);

        // Threshold borrowers: the first accrual or downward tick makes them liquidatable, so every campaign starts
        // with liquidations near the threshold within reach rather than only after a crash.
        for (uint256 m; m < N_MARKETS; ++m) {
            uint256 collateral = 1000e18;
            uint256 assets = _capacity(m, collateral) * 9999 / 10_000;
            _mint(MockERC20(params[m].loanToken), address(users[2]), 2 * assets);
            users[2].supply(params[m], 2 * assets, 0);
            _mint(MockERC20(params[m].collateralToken), address(users[THRESHOLD_USER]), collateral);
            users[THRESHOLD_USER].supplyCollateral(params[m], collateral);
            users[THRESHOLD_USER].borrow(params[m], assets, 0);
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Like forge-std `bound`: in-range values pass through, others wrap into [lo, hi].
    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        if (x >= lo && x <= hi) return x;
        return lo + x % (hi - lo + 1);
    }

    function _capacity(uint256 m, uint256 collateral) internal view returns (uint256) {
        return collateral * oracles[m].currentPrice() / 1e36 * params[m].lltv / 1e18;
    }

    function _snapshot() internal view returns (Market[3] memory s) {
        for (uint256 m; m < N_MARKETS; ++m) {
            s[m] = engine.market(ids[m]);
        }
    }

    function _same(Market memory a, Market memory b) internal pure returns (bool) {
        return a.totalSupplyAssets == b.totalSupplyAssets && a.totalSupplyShares == b.totalSupplyShares
            && a.totalBorrowAssets == b.totalBorrowAssets && a.totalBorrowShares == b.totalBorrowShares
            && a.lastUpdate == b.lastUpdate && a.fee == b.fee;
    }

    /// @dev Records the per-call properties of an action on market `m` (N_MARKETS for none): other markets are
    ///      untouched, the supply share value did not drop without bad debt, and no market is still locked. The
    ///      lock check runs in the action's own transaction, before EIP-1153 clears transient storage.
    function _after(Market[3] memory before, uint256 m, bool badDebtAllowed) internal {
        Market[3] memory afterwards = _snapshot();
        for (uint256 k; k < N_MARKETS; ++k) {
            if (k != m && !_same(before[k], afterwards[k])) ++isolationViolations;
            if (engine.isMarketLocked(ids[k])) ++lockViolations;
        }
        if (m < N_MARKETS && !badDebtAllowed) {
            // Supply share value (TSA + 1) / (TSS + 1e6) never decreases without bad debt.
            uint256 lhs = (uint256(afterwards[m].totalSupplyAssets) + 1) * (uint256(before[m].totalSupplyShares) + 1e6);
            uint256 rhs = (uint256(before[m].totalSupplyAssets) + 1) * (uint256(afterwards[m].totalSupplyShares) + 1e6);
            if (lhs < rhs) ++sharePriceViolations;
        }
    }

    /// @dev No action re-enters a market, so a `MarketLocked` revert means an earlier operation leaked its lock, and
    ///      `LockLeaked` is the actors' own in-transaction check failing.
    function _noteRevert(bytes memory reason) internal {
        if (reason.length < 4) return;
        bytes4 selector = bytes4(reason);
        if (selector == ILendingEngine.MarketLocked.selector || selector == Actor.LockLeaked.selector) {
            ++lockViolations;
        }
    }

    function _mint(MockERC20 token, address to, uint256 amount) internal {
        token.mint(to, amount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------

    function supply(uint256 marketSeed, uint256 userSeed, uint256 amount, bool byShares) external {
        uint256 m = marketSeed % N_MARKETS;
        Actor user = users[userSeed % N_USERS];
        Market[3] memory before = _snapshot();
        if (byShares) {
            uint256 shares = _clamp(amount, 1, 1e30);
            (uint256 tsa, uint256 tss,,) = engine.expectedMarketBalances(params[m]);
            _mint(MockERC20(params[m].loanToken), address(user), shares.toAssetsUp(tsa, tss));
            try user.supply(params[m], 0, shares) {
                ++conversionCalls[1];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        } else {
            uint256 assets = _clamp(amount, 1, 1e24);
            _mint(MockERC20(params[m].loanToken), address(user), assets);
            try user.supply(params[m], assets, 0) {
                ++conversionCalls[0];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        }
        _after(before, m, false);
    }

    function withdraw(uint256 marketSeed, uint256 userSeed, uint256 fractionBps, bool byAssets) external {
        uint256 m = marketSeed % N_MARKETS;
        Actor user = users[userSeed % N_USERS];
        uint256 shares = engine.position(ids[m], address(user)).supplyShares * _clamp(fractionBps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        Market[3] memory before = _snapshot();
        if (byAssets) {
            (uint256 tsa, uint256 tss,,) = engine.expectedMarketBalances(params[m]);
            uint256 assets = shares.toAssetsDown(tsa, tss);
            if (assets == 0) return;
            try user.withdraw(params[m], assets, 0) {
                ++conversionCalls[2];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        } else {
            try user.withdraw(params[m], 0, shares) {
                ++conversionCalls[3];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        }
        _after(before, m, false);
    }

    function supplyCollateral(uint256 marketSeed, uint256 userSeed, uint256 assets) external {
        uint256 m = marketSeed % N_MARKETS;
        Actor user = users[userSeed % N_USERS];
        assets = _clamp(assets, 1, 1e24);
        _mint(MockERC20(params[m].collateralToken), address(user), assets);
        Market[3] memory before = _snapshot();
        try user.supplyCollateral(params[m], assets) {}
        catch (bytes memory reason) {
            _noteRevert(reason);
        }
        _after(before, m, false);
    }

    function withdrawCollateral(uint256 marketSeed, uint256 userSeed, uint256 fractionBps) external {
        uint256 m = marketSeed % N_MARKETS;
        Actor user = users[userSeed % N_USERS];
        uint256 assets = engine.position(ids[m], address(user)).collateral * _clamp(fractionBps, 1, 10_000) / 10_000;
        if (assets == 0) return;
        Market[3] memory before = _snapshot();
        try user.withdrawCollateral(params[m], assets) {}
        catch (bytes memory reason) {
            _noteRevert(reason);
        }
        _after(before, m, false);
    }

    function borrow(uint256 marketSeed, uint256 userSeed, uint256 fractionBps, bool byShares) external {
        uint256 m = marketSeed % N_MARKETS;
        Actor user = users[userSeed % N_USERS];
        uint256 capacity = _capacity(m, engine.position(ids[m], address(user)).collateral);
        uint256 assets = capacity * _clamp(fractionBps, 1, 10_000) / 10_000;
        if (assets == 0) return;
        Market[3] memory before = _snapshot();
        if (byShares) {
            (,, uint256 tba, uint256 tbs) = engine.expectedMarketBalances(params[m]);
            uint256 shares = assets.toSharesDown(tba, tbs);
            if (shares == 0) return;
            try user.borrow(params[m], 0, shares) {
                ++conversionCalls[5];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        } else {
            try user.borrow(params[m], assets, 0) {
                ++conversionCalls[4];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        }
        _after(before, m, false);
    }

    function repay(uint256 marketSeed, uint256 userSeed, uint256 fractionBps, bool byAssets) external {
        uint256 m = marketSeed % N_MARKETS;
        Actor user = users[userSeed % N_USERS];
        uint256 shares = engine.position(ids[m], address(user)).borrowShares * _clamp(fractionBps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        _mint(MockERC20(params[m].loanToken), address(user), 1e30);
        Market[3] memory before = _snapshot();
        if (byAssets) {
            (,, uint256 tba, uint256 tbs) = engine.expectedMarketBalances(params[m]);
            uint256 assets = shares.toAssetsDown(tba, tbs);
            if (assets == 0) return;
            try user.repay(params[m], assets, 0) {
                ++conversionCalls[6];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        } else {
            try user.repay(params[m], 0, shares) {
                ++conversionCalls[7];
            } catch (bytes memory reason) {
                _noteRevert(reason);
            }
        }
        _after(before, m, false);
    }

    /// @notice Compound action: fund the market, post collateral and borrow 50-99 % of capacity in one transaction,
    ///         so the campaign reaches leveraged states quickly. Three operations on one market in one transaction
    ///         also make a leaked lock visible as a `MarketLocked` revert.
    function openPosition(uint256 marketSeed, uint256 userSeed, uint256 collateral, uint256 capacityBps) external {
        uint256 m = marketSeed % N_MARKETS;
        Actor user = users[userSeed % N_USERS];
        Actor lender = users[(userSeed % N_USERS + 1) % N_USERS];
        collateral = _clamp(collateral, 1e6, 1e24);
        uint256 assets = _capacity(m, collateral) * _clamp(capacityBps, 5000, 9900) / 10_000;
        if (assets == 0) return;
        _mint(MockERC20(params[m].loanToken), address(lender), assets);
        _mint(MockERC20(params[m].collateralToken), address(user), collateral);
        Market[3] memory before = _snapshot();
        try lender.supply(params[m], assets, 0) {}
        catch (bytes memory reason) {
            _noteRevert(reason);
        }
        try user.supplyCollateral(params[m], collateral) {}
        catch (bytes memory reason) {
            _noteRevert(reason);
        }
        try user.borrow(params[m], assets, 0) {}
        catch (bytes memory reason) {
            _noteRevert(reason);
        }
        _after(before, m, false);
    }

    /// @notice A liquidation opportunity, taken in one of five modes: partial seizure, partial repayment, close by
    ///         `type(uint256).max` on either side, or close by the observed collateral amount. When nobody is
    ///         liquidatable, the chosen market's price first moves so its most leveraged borrower lands 0.01-20 %
    ///         below the threshold, which covers partial liquidations, closeouts capped at the borrower's equity and
    ///         under-water closeouts. A rejected partial (expected once collateral cannot cover debt plus bonus) is
    ///         followed by a close, as a keeper would.
    function liquidate(uint256 marketSeed, uint256 userSeed, uint256 fractionBps, uint256 mode) external {
        (uint256 m, address borrower) = _findUnhealthy(marketSeed, userSeed);
        if (borrower == address(0)) (m, borrower) = _pushToThreshold(marketSeed, fractionBps);
        if (borrower == address(0)) return;
        _mint(MockERC20(params[m].loanToken), address(liquidator), 1e30);

        uint256 healthBefore;
        try engine.healthFactor(params[m], borrower) returns (uint256 h) {
            healthBefore = h;
        } catch {
            return;
        }

        Position memory p = engine.position(ids[m], borrower);
        uint256 fraction = _clamp(fractionBps, 1, 9999);
        mode = mode % 5;
        bool done;
        if (mode == 0) {
            done = _tryLiquidate(m, borrower, uint256(p.collateral) * fraction / 10_000, 0, healthBefore);
        } else if (mode == 1) {
            done = _tryLiquidate(m, borrower, 0, uint256(p.borrowShares) * fraction / 10_000, healthBefore);
        } else if (mode == 2) {
            done = _tryLiquidate(m, borrower, type(uint256).max, 0, healthBefore);
        } else if (mode == 3) {
            done = _tryLiquidate(m, borrower, 0, type(uint256).max, healthBefore);
        } else {
            done = _tryLiquidate(m, borrower, p.collateral, 0, healthBefore);
        }
        if (!done) _tryLiquidate(m, borrower, 0, p.borrowShares, healthBefore);
    }

    /// @dev First (market, borrower) with debt and a health factor below 1, starting from the fuzzed indices.
    function _findUnhealthy(uint256 marketSeed, uint256 userSeed) internal view returns (uint256, address) {
        for (uint256 i; i < N_MARKETS; ++i) {
            uint256 m = (marketSeed % N_MARKETS + i) % N_MARKETS;
            for (uint256 k; k < N_USERS; ++k) {
                address candidate = address(users[(userSeed % N_USERS + k) % N_USERS]);
                if (engine.position(ids[m], candidate).borrowShares == 0) continue;
                try engine.healthFactor(params[m], candidate) returns (uint256 h) {
                    if (h < 1e18) return (m, candidate);
                } catch {}
            }
        }
        return (0, address(0));
    }

    /// @dev Moves one market's price so its lowest-health borrower lands `depth` (0.01-20 %) below the threshold.
    function _pushToThreshold(uint256 marketSeed, uint256 depthSeed) internal returns (uint256, address) {
        for (uint256 i; i < N_MARKETS; ++i) {
            uint256 m = (marketSeed % N_MARKETS + i) % N_MARKETS;
            address riskiest;
            uint256 lowest = type(uint256).max;
            for (uint256 k; k < N_USERS; ++k) {
                address candidate = address(users[k]);
                if (engine.position(ids[m], candidate).borrowShares == 0) continue;
                try engine.healthFactor(params[m], candidate) returns (uint256 h) {
                    if (h < lowest) (lowest, riskiest) = (h, candidate);
                } catch {}
            }
            if (riskiest == address(0) || lowest == 0) continue;
            uint256 target = 1e18 - _clamp(depthSeed, 1, 2000) * 1e14;
            uint256 newPrice = oracles[m].currentPrice() * target / lowest;
            if (newPrice < 1e30 || newPrice > 1e40) continue;
            Market[3] memory before = _snapshot();
            oracles[m].setPrice(newPrice);
            _after(before, N_MARKETS, false);
            try engine.healthFactor(params[m], riskiest) returns (uint256 h) {
                if (h < 1e18) return (m, riskiest);
            } catch {}
        }
        return (0, address(0));
    }

    function _tryLiquidate(uint256 m, address borrower, uint256 seized, uint256 repaidShares, uint256 healthBefore)
        internal
        returns (bool success)
    {
        if (seized == 0 && repaidShares == 0) return false;
        // Accrue first so the liquidation's own accrual is a no-op and the borrow-total delta is exact.
        try liquidator.accrue(params[m]) {}
        catch (bytes memory reason) {
            _noteRevert(reason);
        }
        Market[3] memory before = _snapshot();
        Position memory pre = engine.position(ids[m], borrower);
        // The engine's own test for "the collateral still covers the debt": floor(collateral * price) >= debt (up).
        bool aboveWater = LiquidationMath.collateralValue(pre.collateral, oracles[m].currentPrice())
            >= uint256(pre.borrowShares).toAssetsUp(before[m].totalBorrowAssets, before[m].totalBorrowShares);
        try liquidator.liquidate(params[m], borrower, seized, repaidShares) returns (uint256, uint256 repaidAssets) {
            success = true;
            _recordLiquidation(m, borrower, before, repaidAssets, aboveWater, healthBefore);
        } catch (bytes memory reason) {
            _noteRevert(reason);
            _after(before, m, false);
        }
    }

    /// @dev Classifies a successful liquidation and records the per-liquidation properties.
    function _recordLiquidation(
        uint256 m,
        address borrower,
        Market[3] memory before,
        uint256 repaidAssets,
        bool aboveWater,
        uint256 healthBefore
    ) internal {
        ++liquidations;
        Position memory after_ = engine.position(ids[m], borrower);
        Market memory marketAfter = engine.market(ids[m]);
        uint256 borrowDrop = uint256(before[m].totalBorrowAssets) - marketAfter.totalBorrowAssets;
        uint256 badDebt = borrowDrop > repaidAssets ? borrowDrop - repaidAssets : 0;
        if (badDebt != 0) {
            ++badDebtEvents;
            badDebtRealized[m] += badDebt;
            if (after_.collateral != 0 || after_.borrowShares != 0) ++badDebtWithoutCloseout;
        } else if (after_.collateral == 0) {
            ++closeoutsWithoutBadDebt;
        } else if (after_.borrowShares == 0) {
            ++fullRepayments;
        } else {
            ++partialLiquidations;
        }
        if (aboveWater && (badDebt != 0 || marketAfter.totalSupplyAssets < before[m].totalSupplyAssets)) {
            ++supplierLossAboveWater;
        }
        if (after_.collateral != 0 && engine.healthFactor(params[m], borrower) < healthBefore) {
            ++healthViolations;
        }
        _after(before, m, badDebt != 0);
    }

    function shockPrice(uint256 marketSeed, uint256 factorBps) external {
        uint256 m = marketSeed % N_MARKETS;
        uint256 price = oracles[m].currentPrice() * _clamp(factorBps, 4000, 13_000) / 10_000;
        if (price < 1e30) price = 1e30;
        if (price > 1e40) price = 1e40;
        Market[3] memory before = _snapshot();
        oracles[m].setPrice(price);
        _after(before, N_MARKETS, false);
    }

    function warp(uint256 secondsSeed) external {
        HEVM.warp(block.timestamp + _clamp(secondsSeed, 1, 30 days));
    }

    function accrue(uint256 marketSeed) external {
        uint256 m = marketSeed % N_MARKETS;
        Market[3] memory before = _snapshot();
        try users[marketSeed % N_USERS].accrue(params[m]) {}
        catch (bytes memory reason) {
            _noteRevert(reason);
        }
        _after(before, m, false);
    }

    /// @notice Flash loan whose callback does nothing, supplies and withdraws on a market that lends the token, or
    ///         closes a liquidatable position in such a market with the borrowed funds.
    function flashLoan(uint256 tokenSeed, uint256 assets, uint256 actionSeed, uint256 marketSeed) external {
        MockERC20 token = [l1, c1, c2][tokenSeed % 3];
        uint256 balance = token.balanceOf(address(engine));
        if (balance == 0) return;
        assets = _clamp(assets, 1, balance);
        uint256 action = actionSeed % 3;
        uint256 m = N_MARKETS;
        bytes memory data;
        if (action != 0) {
            for (uint256 i; i < N_MARKETS && m == N_MARKETS; ++i) {
                uint256 k = (marketSeed % N_MARKETS + i) % N_MARKETS;
                if (params[k].loanToken == address(token)) m = k;
            }
            if (m == N_MARKETS) action = 0;
        }
        if (action == 1) {
            data = abi.encode(action, params[m], address(0));
        } else if (action == 2) {
            (uint256 found, address borrower) = _findUnhealthy(m, marketSeed);
            if (borrower == address(0) || found != m) action = 0;
            else data = abi.encode(action, params[m], borrower);
        }
        if (action == 0) m = N_MARKETS;
        // Rounding in the supply/withdraw round trip, or the liquidation's repayment, is paid from the actor's own
        // balance when the flash loan is returned.
        _mint(token, address(liquidator), 1e30);
        Market[3] memory before = _snapshot();
        try liquidator.flashLoan(address(token), assets, data) {
            if (action != 0) ++flashCallbackActions;
        } catch (bytes memory reason) {
            _noteRevert(reason);
        }
        _after(before, m, action == 2);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Properties (each returns true when it holds)
    // ---------------------------------------------------------------------------------------------------------

    /// Sum of borrow shares equals total borrow shares, and total borrow equals the sum of the borrowers' debts
    /// within rounding: sum(toAssetsDown) <= totalBorrowAssets <= sum(toAssetsUp) + the virtual shares' claim.
    function property_borrowSharesTimesIndexEqualsTotalBorrow() public view returns (bool) {
        for (uint256 m; m < N_MARKETS; ++m) {
            Market memory mk = engine.market(ids[m]);
            uint256 shares;
            uint256 down;
            uint256 up;
            for (uint256 u; u < N_USERS; ++u) {
                uint256 bs = engine.position(ids[m], address(users[u])).borrowShares;
                shares += bs;
                down += bs.toAssetsDown(mk.totalBorrowAssets, mk.totalBorrowShares);
                up += bs.toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
            }
            uint256 virtualClaim =
                uint256(SharesMathLib.VIRTUAL_SHARES).toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
            if (shares != mk.totalBorrowShares) return false;
            if (down > mk.totalBorrowAssets || mk.totalBorrowAssets > up + virtualClaim) return false;
        }
        return true;
    }

    /// Sum of supply shares (users, liquidator and fee recipient) equals total supply shares, and the suppliers'
    /// claims never exceed total supply.
    function property_supplySharesAddUp() public view returns (bool) {
        for (uint256 m; m < N_MARKETS; ++m) {
            Market memory mk = engine.market(ids[m]);
            uint256 shares;
            uint256 claims;
            address[2] memory others = [feeRecipient, address(liquidator)];
            for (uint256 o; o < others.length; ++o) {
                uint256 s = engine.position(ids[m], others[o]).supplyShares;
                shares += s;
                claims += s.toAssetsDown(mk.totalSupplyAssets, mk.totalSupplyShares);
            }
            for (uint256 u; u < N_USERS; ++u) {
                uint256 s = engine.position(ids[m], address(users[u])).supplyShares;
                shares += s;
                claims += s.toAssetsDown(mk.totalSupplyAssets, mk.totalSupplyShares);
            }
            if (shares != mk.totalSupplyShares || claims > mk.totalSupplyAssets) return false;
        }
        return true;
    }

    /// Every market lends out at most what it holds.
    function property_borrowsCoveredBySupply() public view returns (bool) {
        for (uint256 m; m < N_MARKETS; ++m) {
            Market memory mk = engine.market(ids[m]);
            if (mk.totalBorrowAssets > mk.totalSupplyAssets) return false;
        }
        return true;
    }

    /// For every token, the engine holds at least the idle liquidity of the markets lending it plus all
    /// collateral posted in it (tokens are shared across roles: C1 is collateral in M0 and the loan token of M2).
    function property_engineIsSolvent() public view returns (bool) {
        MockERC20[3] memory tokens = [l1, c1, c2];
        for (uint256 t; t < tokens.length; ++t) {
            uint256 owed;
            for (uint256 m; m < N_MARKETS; ++m) {
                Market memory mk = engine.market(ids[m]);
                if (params[m].loanToken == address(tokens[t])) {
                    owed += uint256(mk.totalSupplyAssets) - mk.totalBorrowAssets;
                }
                if (params[m].collateralToken == address(tokens[t])) {
                    for (uint256 u; u < N_USERS; ++u) {
                        owed += engine.position(ids[m], address(users[u])).collateral;
                    }
                }
            }
            if (tokens[t].balanceOf(address(engine)) < owed) return false;
        }
        return true;
    }

    /// A position without collateral has no debt: exhausted collateral always writes off the residual debt.
    function property_noZombiePositions() public view returns (bool) {
        for (uint256 m; m < N_MARKETS; ++m) {
            for (uint256 u; u < N_USERS; ++u) {
                Position memory p = engine.position(ids[m], address(users[u]));
                if (p.collateral == 0 && p.borrowShares != 0) return false;
            }
        }
        return true;
    }

    /// No liquidation lowered a health factor without realizing bad debt.
    function property_liquidationNeverLowersHealth() public view returns (bool) {
        return healthViolations == 0;
    }

    /// Bad debt is only ever realized by a closeout that exhausts the borrower's collateral.
    function property_badDebtOnlyOnCloseout() public view returns (bool) {
        return badDebtWithoutCloseout == 0;
    }

    /// No action on one market changed another market (bad debt, interest and shocks stay isolated).
    function property_marketsAreIsolated() public view returns (bool) {
        return isolationViolations == 0;
    }

    /// Supply share value never decreased except in liquidations that realized bad debt.
    function property_supplyShareValueMonotonic() public view returns (bool) {
        return sharePriceViolations == 0;
    }

    /// Every operation released its market lock before its transaction continued: checked inside each action's
    /// transaction, and by chaining operations on one market (no action ever hit `MarketLocked`).
    function property_locksReleasedWithinTransaction() public view returns (bool) {
        return lockViolations == 0;
    }

    /// No liquidation cost suppliers anything while the borrower's collateral was still worth its debt.
    function property_noSupplierLossWhileCollateralCoversDebt() public view returns (bool) {
        return supplierLossAboveWater == 0;
    }
}
