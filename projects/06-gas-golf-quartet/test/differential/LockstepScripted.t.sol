// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RevertClass, RevertClassifier} from "../utils/RevertClassifier.sol";
import {LockstepHandler} from "./LockstepHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Test} from "forge-std/Test.sol";

/// @title LockstepScriptedTest
/// @notice Drives the lockstep handler through a fixed script that reaches every revert class the call
///         surface can produce, so the differential comparison is demonstrably exercised on each of them
///         (the random campaign's coverage is visible in the invariant metrics table).
/// @dev `InvalidSender` is unreachable through calls (the zero address cannot approve anyone); it is covered
///      by the halmos proof of transferFrom and by ERC20Spec with a directly written storage state.
contract LockstepScriptedTest is Test {
    LockstepHandler internal handler;

    function setUp() public {
        handler = new LockstepHandler();
    }

    function test_LockstepReachesEveryRevertClass() public {
        // Seeds follow the handler's input shaping: actor = seed % 4, target 4 is the zero address,
        // amount mode = seed % 6 (0: zero, 1: exactly the limit, 2: limit + 1).
        handler.transfer(0, 1, 7); // actor0 -> actor1, the whole balance: success
        handler.transfer(0, 2, 2); // actor0 has nothing left: InsufficientBalance
        handler.transfer(1, 4, 1); // to the zero address: InvalidReceiver
        handler.approve(1, 4, 1); // zero spender: InvalidSpender
        handler.approve(1, 2, 1); // actor1 approves actor2: success
        handler.transferFrom(3, 1, 0, 2); // actor3 has no allowance from actor1: InsufficientAllowance
        handler.transferFrom(3, 4, 0, 0); // from the zero address, zero amount: InvalidApprover
        handler.transferFrom(2, 1, 3, 1); // actor2 spends its full allowance: success
        handler.permit(1, 2, 0, 0, 1, 0); // expired deadline: PermitExpired
        handler.permit(1, 2, 0, 0, 2, 0); // signed by the wrong key: InvalidPermit
        handler.permit(1, 2, 0, 0, 3, 0); // malleable high-s twin: InvalidPermit
        handler.permit(1, 2, 0, 0, 0, 0); // valid: success
        handler.malformed(0, 0, 5, 0); // truncated calldata: EmptyRevert
        handler.malformed(3, 3, 5, 0); // value sent to a view: EmptyRevert

        RevertClass[9] memory reached = [
            RevertClass.None,
            RevertClass.InsufficientBalance,
            RevertClass.InsufficientAllowance,
            RevertClass.InvalidReceiver,
            RevertClass.InvalidApprover,
            RevertClass.InvalidSpender,
            RevertClass.PermitExpired,
            RevertClass.InvalidPermit,
            RevertClass.EmptyRevert
        ];
        for (uint256 i; i < reached.length; ++i) {
            assertGt(handler.classHits(uint256(reached[i])), 0, RevertClassifier.name(reached[i]));
        }
        assertEq(handler.calls(), 14);
        assertEq(handler.ghostNonces(handler.actor(1)), 1);
    }

    /// @notice `malformed` mode 1 dirties exactly one strictly typed word per call, and it can reach every
    ///         such word: each address argument of every function and permit's `uint8 v`. All five decoders
    ///         must reject each of them (the handler asserts agreement; the oracle reverts with empty data).
    ///         This is the deterministic guard for the Yul object's paired checks (trick T8): with the second
    ///         address of `transferFrom`, `allowance` or `permit` left unvalidated, the Yul call would
    ///         succeed or revert with a different class, and the handler would fail.
    function test_LockstepRejectsEachDirtyStrictWord() public {
        // fnSeed -> _validCall: 0 transfer, 1 approve, 2 transferFrom, 3 balanceOf, 4 allowance, 5 nonces,
        // 6 permit. argSeed 1 makes both address arguments actors (never the zero address), so every clean
        // call except the garbage-signature permit succeeds.
        bytes4[7] memory selectors = [
            IERC20.transfer.selector,
            IERC20.approve.selector,
            IERC20.transferFrom.selector,
            IERC20.balanceOf.selector,
            IERC20.allowance.selector,
            IERC20Permit.nonces.selector,
            IERC20Permit.permit.selector
        ];
        uint256 dirtied;
        for (uint256 fn; fn < selectors.length; ++fn) {
            (uint256[] memory words,) = handler.strictWords(selectors[fn]);
            for (uint256 k; k < words.length; ++k) {
                uint256 before = handler.classHits(uint256(RevertClass.EmptyRevert));
                handler.malformed(fn, 1 + 6 * k, 1, 0);
                assertEq(handler.classHits(uint256(RevertClass.EmptyRevert)), before + 1, "oracle must reject");
                ++dirtied;
            }
        }
        // 4 one-address functions, 2 two-address functions, permit with two addresses and v.
        assertEq(dirtied, 4 + 2 * 2 + 3);
    }
}
