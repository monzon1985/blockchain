// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerpsDeployment} from "../../script/PerpsDeployment.sol";
import {IPerpsMarket} from "../../src/interfaces/IPerpsMarket.sol";
import {InvariantParams, PerpsHandler} from "../invariant/PerpsHandler.sol";
import {MockUSD} from "../mocks/MockUSD.sol";

/// @title PerpsMedusa
/// @notice Medusa harness: deploys the full system in its constructor and exposes the shared `PerpsHandler` actions
///         as fuzz targets, with the same invariants as the Foundry suite as `property_*` functions. Medusa also
///         moves `block.timestamp` by up to a week between calls, which stresses funding and borrow accrual far
///         beyond the Foundry campaign.
contract PerpsMedusa is PerpsHandler {
    uint256 internal constant PK1 = 0xA11CE;
    uint256 internal constant PK2 = 0xB0B;
    uint256 internal constant PK3 = 0xCA401;

    constructor() {
        MockUSD token = new MockUSD(18);
        address keeperAddr = address(0xBEEF);

        address[] memory signers = new address[](3);
        signers[0] = vm.addr(PK1);
        signers[1] = vm.addr(PK2);
        signers[2] = vm.addr(PK3);
        address[] memory keepers = new address[](1);
        keepers[0] = keeperAddr;

        PerpsDeployment.System memory s = PerpsDeployment.deploy(
            IERC20(address(token)),
            PerpsDeployment.Config({
                admin: address(this),
                governor: address(this),
                signers: signers,
                minSigners: 2,
                maxReportAge: 60,
                maxSpreadBps: 50,
                keepers: keepers,
                riskAdmin: address(this),
                oracleAdmin: address(this),
                guardian: address(this),
                marketId: keccak256("ETH-USD"),
                params: InvariantParams.riskParams()
            })
        );
        _initHandler(s.market, token, keeperAddr, [PK1, PK2, PK3], keccak256("ETH-USD"), 3000e18);
    }

    /// I1. After accruing to now, every position can be closed at the current price, each close pays what the
    ///     independent payout model predicts, and the LPs can then redeem the whole pool.
    function property_I1_solvency() public returns (bool) {
        (bool ok,) = checkSolvency();
        return ok;
    }

    /// I2. Each custody contract holds exactly the sum of its accounting buckets.
    function property_I2_tokenConservation() public view returns (bool) {
        return checkTokenConservation();
    }

    /// I3. Open interest, index tokens, collateral and entry sums equal the sums over positions.
    function property_I3_openInterestEqualsPositions() public view returns (bool) {
        return checkOpenInterest();
    }

    /// I4. Pool and impact-pool balances reconcile with the cumulative flow counters.
    function property_I4_feeConservationCounters() public view returns (bool) {
        return checkCounterConservation();
    }

    /// I5. External token flows reconcile with positions, escrows, pools and keeper income.
    function property_I5_feeConservationFlows() public view returns (bool) {
        return checkFlowConservation();
    }

    /// I6. No same-block, same-price round trip ever returned the collateral.
    function property_I6_noFreeRoundTrips() public view returns (bool) {
        return ghostFreeRoundTrips == 0;
    }

    /// I7. No order was ever settled with reports that do not postdate it.
    function property_I7_noStaleFills() public view returns (bool) {
        return ghostStaleFills == 0;
    }

    /// I8. Borrow indices never decrease, and open interest stays within the hard caps.
    function property_I8_monotonicIndicesAndCaps() public view returns (bool) {
        IPerpsMarket.RiskParams memory p = market.getRiskParams();
        return checkBorrowIndicesMonotonic() && market.getSide(true).openInterest <= p.maxLongOpenInterest
            && market.getSide(false).openInterest <= p.maxShortOpenInterest;
    }

    /// I9. Auto-deleveraging only ever lowers the PnL-to-pool factor.
    function property_I9_adlLowersPnlFactor() public view returns (bool) {
        return !ghostAdlRaisedFactor;
    }
}
