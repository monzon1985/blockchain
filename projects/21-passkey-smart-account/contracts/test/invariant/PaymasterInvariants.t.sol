// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseTest} from "../utils/BaseTest.sol";
import {PaymasterHandler} from "./handlers/PaymasterHandler.sol";

/// @notice Stateful invariants of the TestUSD paymaster under randomized, partly adversarial operations. The expected
/// balances come from EntryPoint and paymaster events and from the handler's own admin flows, never from the balances
/// being checked.
contract PaymasterInvariantsTest is BaseTest {
    PaymasterHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new PaymasterHandler(entryPoint, factory, usd, paymaster, admin, sponsor, sponsorPk);
        targetContract(address(handler));
        // Explicit selectors: the handler inherits test helpers (e.g. `setUp`) that must never be fuzzed.
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = PaymasterHandler.userFundedTransfer.selector;
        selectors[1] = PaymasterHandler.userFundedTransfer.selector;
        selectors[2] = PaymasterHandler.griefingOp.selector;
        selectors[3] = PaymasterHandler.guaranteedOp.selector;
        selectors[4] = PaymasterHandler.guaranteedOp.selector;
        selectors[5] = PaymasterHandler.setPrice.selector;
        selectors[6] = PaymasterHandler.topUp.selector;
        selectors[7] = PaymasterHandler.withdrawDeposit.selector;
        selectors[8] = PaymasterHandler.withdrawTokens.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// INV-7: the paymaster's EntryPoint deposit is exactly deposits − withdrawals − the `actualGasCost` of every
    /// operation it paid for (summed from `UserOperationEvent`): nothing else leaks.
    function invariant_DepositAccounting() public view {
        assertEq(
            entryPoint.balanceOf(address(paymaster)) + handler.ghostWithdrawn() + handler.ghostGasCharged(),
            handler.initialDeposit() + handler.ghostDeposited()
        );
    }

    /// INV-8: never under-collateralized: after every user-funded operation (griefing ones included) the paymaster
    /// kept at least the operation's ETH gas cost, valued at the price in force, in TestUSD.
    function invariant_NeverUndercharged() public view {
        assertEq(handler.ghostUnderchargedOps(), 0);
        assertEq(handler.ghostUnderchargedGuaranteedOps(), 0);
    }

    /// INV-9: the token float moves only through the charges the paymaster reports (`UserOperationSponsored`, zero for
    /// a guaranteed operation the sender did not repay) and admin withdrawals, and postOp never reverts.
    function invariant_TokenConservation() public view {
        assertEq(
            usd.balanceOf(address(paymaster)) + handler.ghostTokensWithdrawn(),
            handler.initialFloat() + handler.ghostTokensCharged()
        );
        assertEq(handler.ghostPostOpReverts(), 0);
        assertEq(handler.ghostMissingEvents(), 0);
    }

    function afterInvariant() external {
        emit log_named_uint("user-funded ops", handler.ghostUserFundedOps());
        emit log_named_uint("griefing ops", handler.ghostGriefingOps());
        emit log_named_uint("guaranteed ops", handler.ghostGuaranteedOps());
        emit log_named_uint("guaranteed ops not repaid", handler.ghostGuaranteedUnpaid());
        // The invariants above are only meaningful if operations actually went through.
        assertGt(handler.ghostUserFundedOps() + handler.ghostGriefingOps() + handler.ghostGuaranteedOps(), 0);
    }
}
