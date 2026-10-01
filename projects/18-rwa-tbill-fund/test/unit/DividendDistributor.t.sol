// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAccessManaged} from "@openzeppelin-contracts/access/manager/IAccessManaged.sol";
import {DividendDistributor} from "../../src/dividends/DividendDistributor.sol";
import {FundFixture} from "../utils/FundFixture.sol";
import {StandardMerkleTree} from "../utils/StandardMerkleTree.sol";

contract DividendDistributorTest is FundFixture {
    address[] internal accounts;
    uint256[] internal amounts;
    bytes32[] internal tree;
    uint256[] internal treeIndex;
    uint64 internal recordDate;

    function setUp() public override {
        super.setUp();
        _seed(alice, 600 * USDC);
        _seed(bob, 300 * USDC);
        _seed(carol, 100 * USDC);
        recordDate = uint64(block.timestamp);

        // 10 USDC distributed pro rata to the record-date balances.
        accounts = [alice, bob, carol];
        amounts = [6 * USDC, 3 * USDC, 1 * USDC];
        (tree, treeIndex) = StandardMerkleTree.build(accounts, amounts);
        _fund(fundAdmin, 10 * USDC);
        vm.prank(fundAdmin);
        usdc.approve(address(distributor), type(uint256).max);
        vm.prank(fundAdmin);
        distributor.createDistribution(tree[0], 10 * USDC, recordDate);
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory) {
        return StandardMerkleTree.proof(tree, treeIndex[i]);
    }

    // ---------------------------------------------------------------- creation

    function test_create_storesAndPullsFunds() public view {
        DividendDistributor.Distribution memory d = distributor.getDistribution(0);
        assertEq(d.merkleRoot, tree[0]);
        assertEq(d.totalAmount, 10 * USDC);
        assertEq(d.claimedAmount, 0);
        assertEq(d.recordDate, recordDate);
        assertEq(d.createdAt, block.timestamp);
        assertEq(distributor.distributionCount(), 1);
        assertEq(usdc.balanceOf(address(distributor)), 10 * USDC);
        assertEq(distributor.outstandingLiability(), 10 * USDC);
    }

    function test_create_emits() public {
        _fund(fundAdmin, 1);
        vm.expectEmit(address(distributor));
        emit DividendDistributor.DistributionCreated(1, bytes32(uint256(1)), 1, recordDate);
        vm.prank(fundAdmin);
        assertEq(distributor.createDistribution(bytes32(uint256(1)), 1, recordDate), 1);
    }

    function test_create_validation() public {
        vm.startPrank(fundAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistributor.InvalidDistribution.selector, bytes32(0), uint256(1), recordDate)
        );
        distributor.createDistribution(bytes32(0), 1, recordDate);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistributor.InvalidDistribution.selector, tree[0], uint256(0), recordDate)
        );
        distributor.createDistribution(tree[0], 0, recordDate);
        uint64 future = uint64(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistributor.InvalidDistribution.selector, tree[0], uint256(1), future)
        );
        distributor.createDistribution(tree[0], 1, future);
        vm.stopPrank();
    }

    function test_create_restricted() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        distributor.createDistribution(tree[0], 1, recordDate);
    }

    function test_getDistribution_revertsForUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.UnknownDistribution.selector, uint256(5)));
        distributor.getDistribution(5);
    }

    // ---------------------------------------------------------------- claims

    function test_claim_paysEveryHolderByAnyCaller() public {
        vm.expectEmit(address(distributor));
        emit DividendDistributor.DividendClaimed(0, alice, alice, 6 * USDC);
        vm.prank(stranger);
        (address payee, bool escrowedFlag) = distributor.claim(0, alice, 6 * USDC, _proof(0));
        assertEq(payee, alice);
        assertFalse(escrowedFlag);
        distributor.claim(0, bob, 3 * USDC, _proof(1));
        distributor.claim(0, carol, 1 * USDC, _proof(2));
        assertEq(usdc.balanceOf(alice), 6 * USDC);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(distributor.outstandingLiability(), 0);
        assertTrue(distributor.claimed(0, alice));
    }

    function test_claim_revertsOnDoubleClaim() public {
        distributor.claim(0, alice, 6 * USDC, _proof(0));
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.AlreadyClaimed.selector, uint256(0), alice));
        distributor.claim(0, alice, 6 * USDC, _proof(0));
    }

    function test_claim_revertsOnUnknownDistribution() public {
        bytes32[] memory proof = _proof(0);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.UnknownDistribution.selector, uint256(1)));
        distributor.claim(1, alice, 6 * USDC, proof);
    }

    function test_claim_revertsOnInflatedAmount() public {
        bytes32[] memory proof = _proof(0);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.InvalidProof.selector, uint256(0), alice, 7 * USDC));
        distributor.claim(0, alice, 7 * USDC, proof);
    }

    function test_claim_revertsOnStolenProof() public {
        bytes32[] memory proof = _proof(0);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.InvalidProof.selector, uint256(0), dave, 6 * USDC));
        distributor.claim(0, dave, 6 * USDC, proof);
    }

    function test_claim_rootCannotPayMoreThanFunded() public {
        address[] memory accs = new address[](2);
        uint256[] memory amts = new uint256[](2);
        accs[0] = alice;
        accs[1] = bob;
        amts[0] = 5;
        amts[1] = 5;
        (bytes32[] memory badTree, uint256[] memory idx) = StandardMerkleTree.build(accs, amts);
        _fund(fundAdmin, 8);
        vm.prank(fundAdmin);
        distributor.createDistribution(badTree[0], 8, recordDate); // leaves sum to 10 > 8 funded
        distributor.claim(1, alice, 5, StandardMerkleTree.proof(badTree, idx[0]));
        bytes32[] memory proof = StandardMerkleTree.proof(badTree, idx[1]);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.DistributionOverclaimed.selector, uint256(1), 10, 8));
        distributor.claim(1, bob, 5, proof);
    }

    function test_claim_revertsForIneligiblePayee() public {
        vm.prank(complianceOfficer);
        registry.removeClaim(ID_BOB, 1);
        bytes32[] memory proof = _proof(1);
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.PayeeNotEligible.selector, bob));
        distributor.claim(0, bob, 3 * USDC, proof);
        assertFalse(distributor.claimed(0, bob), "entitlement preserved until eligible again");
    }

    // ---------------------------------------------------------------- escrow for frozen holders

    function test_claim_escrowsFrozenHolderUntilUnfrozen() public {
        vm.prank(complianceOfficer);
        share.setFrozenTokens(carol, 1);

        vm.expectEmit(address(distributor));
        emit DividendDistributor.DividendEscrowed(0, carol, carol, 1 * USDC);
        (address payee, bool escrowedFlag) = distributor.claim(0, carol, 1 * USDC, _proof(2));
        assertEq(payee, carol);
        assertTrue(escrowedFlag);
        assertEq(distributor.escrowed(carol), 1 * USDC);
        assertEq(distributor.totalEscrowed(), 1 * USDC);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(distributor.outstandingLiability(), 10 * USDC, "escrow is still a liability");

        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.PayeeFrozen.selector, carol, uint256(1)));
        distributor.releaseEscrow(carol);

        vm.prank(complianceOfficer);
        share.setFrozenTokens(carol, 0);
        vm.expectEmit(address(distributor));
        emit DividendDistributor.EscrowReleased(carol, carol, 1 * USDC);
        distributor.releaseEscrow(carol);
        assertEq(usdc.balanceOf(carol), 1 * USDC);
        assertEq(distributor.totalEscrowed(), 0);
    }

    function test_releaseEscrow_revertsWhenEmptyOrIneligible() public {
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.NothingEscrowed.selector, carol));
        distributor.releaseEscrow(carol);

        vm.prank(complianceOfficer);
        share.setFrozenTokens(carol, 1);
        distributor.claim(0, carol, 1 * USDC, _proof(2));
        vm.startPrank(complianceOfficer);
        share.setFrozenTokens(carol, 0);
        registry.removeClaim(ID_CAROL, 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.PayeeNotEligible.selector, carol));
        distributor.releaseEscrow(carol);
    }

    // ---------------------------------------------------------------- recovered wallets

    function test_claim_paysSuccessorOfRecoveredWallet() public {
        _bind(alice2, ID_ALICE);
        vm.startPrank(transferAgent);
        share.initiateRecovery(alice, alice2, "case");
        vm.warp(block.timestamp + 2 days);
        share.executeRecovery(alice);
        vm.stopPrank();

        (address payee,) = distributor.claim(0, alice, 6 * USDC, _proof(0));
        assertEq(payee, alice2);
        assertEq(usdc.balanceOf(alice2), 6 * USDC);
    }

    function test_escrow_followsRecoveryAndFreeze() public {
        vm.prank(complianceOfficer);
        share.setFrozenTokens(alice, 1);
        distributor.claim(0, alice, 6 * USDC, _proof(0)); // escrowed under alice

        _bind(alice2, ID_ALICE);
        vm.startPrank(transferAgent);
        share.initiateRecovery(alice, alice2, "case");
        vm.warp(block.timestamp + 2 days);
        share.executeRecovery(alice); // the freeze moves to alice2
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(DividendDistributor.PayeeFrozen.selector, alice2, uint256(1)));
        distributor.releaseEscrow(alice);
        vm.prank(complianceOfficer);
        share.setFrozenTokens(alice2, 0);
        (address payee, uint256 amount) = distributor.releaseEscrow(alice);
        assertEq(payee, alice2);
        assertEq(amount, 6 * USDC);
    }
}
