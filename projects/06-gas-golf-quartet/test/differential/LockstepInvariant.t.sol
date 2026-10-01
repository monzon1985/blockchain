// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetToken} from "../../src/interfaces/IQuartetToken.sol";
import {RevertClass} from "../utils/RevertClassifier.sol";
import {LockstepHandler} from "./LockstepHandler.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

/// @title LockstepInvariantTest
/// @notice Stateful differential fuzzing of the quartet against the OpenZeppelin oracle. The handler
///         checks every call's outcome and logs in lockstep; these invariants check the state after
///         every call of every sequence.
contract LockstepInvariantTest is StdInvariant, Test {
    LockstepHandler internal handler;

    function setUp() public {
        handler = new LockstepHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = LockstepHandler.transfer.selector;
        selectors[1] = LockstepHandler.approve.selector;
        selectors[2] = LockstepHandler.transferFrom.selector;
        selectors[3] = LockstepHandler.permit.selector;
        selectors[4] = LockstepHandler.malformed.selector;
        selectors[5] = LockstepHandler.raw.selector;
        selectors[6] = LockstepHandler.warp.selector;
        selectors[7] = LockstepHandler.fork.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Invariant 2: all five implementations hold the same balances, allowances (every ordered pair
    ///         of actors and the zero address), nonces and total supply.
    function invariant_StateIsIdenticalAcrossImplementations() public view {
        IQuartetToken oracle = handler.token(0);
        uint256 n = handler.actorCount();
        for (uint256 t = 1; t < handler.tokenCount(); ++t) {
            IQuartetToken token = handler.token(t);
            assertEq(token.totalSupply(), oracle.totalSupply(), "totalSupply");
            for (uint256 i; i <= n; ++i) {
                address a = i == n ? address(0) : handler.actor(i);
                assertEq(token.balanceOf(a), oracle.balanceOf(a), "balanceOf");
                assertEq(token.nonces(a), oracle.nonces(a), "nonces");
                for (uint256 j; j <= n; ++j) {
                    address b = j == n ? address(0) : handler.actor(j);
                    assertEq(token.allowance(a, b), oracle.allowance(a, b), "allowance");
                }
            }
        }
    }

    /// @notice Invariant 3: in every implementation the balances sum to the fixed total supply and the zero
    ///         address never holds tokens.
    function invariant_BalancesSumToTotalSupply() public view {
        uint256 n = handler.actorCount();
        for (uint256 t; t < handler.tokenCount(); ++t) {
            IQuartetToken token = handler.token(t);
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                sum += token.balanceOf(handler.actor(i));
            }
            assertEq(sum, token.totalSupply(), "sum of balances");
            assertEq(token.balanceOf(address(0)), 0, "zero address balance");
        }
    }

    /// @notice Invariant 4: a nonce equals the number of successful permits of its owner.
    function invariant_NoncesCountSuccessfulPermits() public view {
        uint256 n = handler.actorCount();
        for (uint256 t; t < handler.tokenCount(); ++t) {
            IQuartetToken token = handler.token(t);
            for (uint256 i; i <= n; ++i) {
                address a = i == n ? address(0) : handler.actor(i);
                assertEq(token.nonces(a), handler.ghostNonces(a), "nonce vs successful permits");
            }
        }
    }

    /// @notice Invariant 5: every domain separator equals the EIP-712 formula for the current chain id and
    ///         the token's own address, including after `fork` changed the chain id.
    function invariant_DomainSeparatorFollowsChainId() public view {
        for (uint256 t; t < handler.tokenCount(); ++t) {
            IQuartetToken token = handler.token(t);
            bytes32 expected = keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256("Gas Golf Quartet"),
                    keccak256("1"),
                    block.chainid,
                    address(token)
                )
            );
            assertEq(token.DOMAIN_SEPARATOR(), expected, "domain separator");
        }
    }

    /// @notice The oracle never produced an unknown or Panic revert over the whole campaign.
    function invariant_OracleNeverPanics() public view {
        assertEq(handler.classHits(uint256(RevertClass.Panic)), 0);
        assertEq(handler.classHits(uint256(RevertClass.Unknown)), 0);
    }
}
