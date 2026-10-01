// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FundFixture} from "../utils/FundFixture.sol";

/// @notice ERC-7943 freeze semantics under fuzzing, and agreement between `canTransfer` and enforcement.
contract FreezeFuzzTest is FundFixture {
    bytes32 internal constant ORDER = "order";
    uint256 internal constant BALANCE = 1000 * USDC;

    function setUp() public override {
        super.setUp();
        _seed(alice, BALANCE);
        _issueOrder(ORDER, alice, bob, BALANCE);
    }

    function testFuzz_transferSucceedsIffWithinUnfrozenBalance(uint256 frozen, uint256 amount) public {
        frozen = bound(frozen, 0, 2 * BALANCE);
        amount = bound(amount, 0, BALANCE);
        vm.prank(complianceOfficer);
        share.setFrozenTokens(alice, frozen);
        uint256 unfrozen = frozen >= BALANCE ? 0 : BALANCE - frozen;

        bool predicted = share.canTransfer(alice, bob, amount);
        vm.prank(alice);
        (bool ok,) = address(share).call(abi.encodeCall(share.transfer, (bob, amount)));
        assertEq(ok, amount <= unfrozen, "freeze enforcement");
        assertEq(predicted, ok, "canTransfer predicts the outcome");
        if (ok) assertGe(share.balanceOf(alice), frozen < BALANCE ? frozen : BALANCE - amount);
    }

    function testFuzz_forcedTransferUnfreezesOnlyTheShortfall(uint256 frozen, uint256 amount) public {
        frozen = bound(frozen, 0, 2 * BALANCE);
        amount = bound(amount, 1, BALANCE);
        vm.prank(complianceOfficer);
        share.setFrozenTokens(alice, frozen);
        uint256 unfrozen = frozen >= BALANCE ? 0 : BALANCE - frozen;

        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, amount, ORDER);

        uint256 expectedFrozen = amount > unfrozen ? frozen - (amount - unfrozen) : frozen;
        assertEq(share.getFrozenTokens(alice), expectedFrozen);
        assertEq(share.balanceOf(alice), BALANCE - amount);
        // Whatever stays frozen is still covered by the remaining balance, or was over-frozen to begin with.
        if (frozen <= BALANCE) assertLe(share.getFrozenTokens(alice), share.balanceOf(alice));
    }

    function testFuzz_canTransferNeverRevertsAndMatchesEnforcement(
        uint8 fromSeed,
        uint8 toSeed,
        uint256 amount,
        bool expireSenderKyc
    ) public {
        address[4] memory wallets = [alice, bob, stranger, address(0)];
        address from = wallets[bound(fromSeed, 0, 2)];
        address to = wallets[bound(toSeed, 0, 3)];
        amount = bound(amount, 0, BALANCE);
        if (expireSenderKyc) {
            vm.prank(complianceOfficer);
            registry.removeClaim(ID_ALICE, 1);
        }
        bool predicted = share.canTransfer(from, to, amount);
        uint256 balance = share.balanceOf(from);
        vm.prank(from);
        (bool ok,) = address(share).call(abi.encodeCall(share.transfer, (to, amount)));
        if (amount <= balance && to != address(0)) assertEq(predicted, ok);
        if (ok) assertTrue(predicted, "no transfer succeeds that canTransfer rejects");
    }
}
