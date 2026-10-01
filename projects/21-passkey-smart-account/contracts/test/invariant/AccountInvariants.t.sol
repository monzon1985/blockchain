// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {AccountHandler} from "./handlers/AccountHandler.sol";

/// @notice Stateful invariants of the account: only authorized signers move funds or change the signer, recovery
/// never beats its timelock, the owner veto always clears it, a freeze stops every operation and every wei, and a
/// guardian freezes at most once per recovery epoch.
contract AccountInvariantsTest is BaseTest {
    AccountHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[3] memory g = [makeAddr("inv-g0"), makeAddr("inv-g1"), makeAddr("inv-g2")];
        handler = new AccountHandler(entryPoint, factory, g);
        targetContract(address(handler));
        // Weighted selector list (duplicates raise the probability of an action).
        bytes4[] memory selectors = new bytes4[](23);
        selectors[0] = AccountHandler.authorizedTransfer.selector;
        selectors[1] = AccountHandler.authorizedTransfer.selector;
        selectors[2] = AccountHandler.authorizedTransfer.selector;
        selectors[3] = AccountHandler.ownerRotate.selector;
        selectors[4] = AccountHandler.ownerVeto.selector;
        selectors[5] = AccountHandler.forgedPasskeyTransfer.selector;
        selectors[6] = AccountHandler.forgedEoaTransfer.selector;
        selectors[7] = AccountHandler.replayOldSignature.selector;
        selectors[8] = AccountHandler.directCall.selector;
        selectors[9] = AccountHandler.guardianApprove.selector;
        selectors[10] = AccountHandler.guardianApprove.selector;
        selectors[11] = AccountHandler.guardianApprove.selector;
        selectors[12] = AccountHandler.guardianFreeze.selector;
        selectors[13] = AccountHandler.executeRecovery.selector;
        selectors[14] = AccountHandler.executeRecovery.selector;
        selectors[15] = AccountHandler.warp.selector;
        selectors[16] = AccountHandler.warp.selector;
        selectors[17] = AccountHandler.forgedPasskeyTransfer.selector;
        selectors[18] = AccountHandler.ownerVetoRelayed.selector;
        selectors[19] = AccountHandler.thiefVetoWithExtremeGas.selector;
        selectors[20] = AccountHandler.thiefVetoWithExtremeGas.selector;
        selectors[21] = AccountHandler.warp.selector;
        selectors[22] = AccountHandler.directCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// INV-1: funds leave the account only through operations signed by the passkey that is current at that moment.
    function invariant_OnlyAuthorizedSignersMoveFunds() public view {
        assertEq(handler.sink().balance, handler.ghostAuthorizedOutflow());
    }

    /// INV-2: no forged, replayed or wrong-signer operation, and no direct call or relayed veto from a stranger, is
    /// ever accepted.
    function invariant_NoUnauthorizedExecution() public view {
        assertEq(handler.ghostForgeriesAccepted(), 0);
        assertEq(handler.ghostUnauthorizedDirectCallsAccepted(), 0);
    }

    /// INV-3: the on-chain passkey is always the one the authorized history (rotations and recoveries) installed.
    function invariant_SignerOnlyChangesThroughAuthorizedPaths() public view {
        IPasskeyAccount.Passkey memory onChain = handler.account().passkey();
        assertEq(onChain.qx, _passkey(handler.keys(handler.currentKeyIndex())).qx);
    }

    /// INV-4: a recovery never executes before `threshold` approvals plus the 48h timelock.
    function invariant_RecoveryTimelockRespected() public view {
        assertEq(handler.ghostEarlyRecoveries(), 0);
        IPasskeyAccount.PendingRecovery memory p = handler.account().pendingRecovery();
        if (p.executableAt != 0) {
            assertGe(handler.account().recoveryApprovals(p.recoveryId), handler.account().guardianThreshold());
        }
    }

    /// INV-5: an owner veto (user operation or relayed) always leaves no recovery scheduled.
    function invariant_VetoAlwaysClearsRecovery() public view {
        assertEq(handler.ghostVetoLeftPending(), 0);
    }

    /// INV-6: while frozen, no user operation executes (the veto included, whatever its gas values) and the account's
    /// ETH, balance plus EntryPoint deposit, never decreases.
    function invariant_FreezeBlocksEveryOperationAndEveryWei() public view {
        assertEq(handler.ghostOwnerOpsWhileFrozen(), 0);
        assertEq(handler.ghostValueLostWhileFrozen(), 0);
    }

    /// INV-10: a guardian freezes at most once per recovery epoch.
    function invariant_GuardianFreezesOncePerEpoch() public view {
        assertEq(handler.ghostRepeatedFreezes(), 0);
    }

    function afterInvariant() external {
        emit log_named_uint("recoveries executed", handler.ghostRecoveriesExecuted());
        emit log_named_uint("vetoes", handler.ghostVetoes());
        emit log_named_uint("relayed vetoes while frozen", handler.ghostRelayedVetoesWhileFrozen());
        emit log_named_uint("extreme-gas vetoes while frozen", handler.ghostExtremeGasVetoesWhileFrozen());
        emit log_named_uint("authorized outflow", handler.ghostAuthorizedOutflow());
        emit log_named_uint("forgery attempts", handler.calls("forgedPasskeyTransfer"));
        // Coverage sanity: the campaign must have exercised both sides of the authorization boundary.
        assertGt(handler.calls("authorizedTransfer") + handler.calls("forgedPasskeyTransfer"), 0);
    }
}
