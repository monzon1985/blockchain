// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {FundFixture} from "../utils/FundFixture.sol";
import {StandardMerkleTree} from "../utils/StandardMerkleTree.sol";

/// @notice One operation per test so that `forge snapshot` records its cost. The full production wiring is
///         active: 4 compliance modules (holders per country, investor cap, lockup, transfer window) and 3
///         required claim topics per identity.
contract GasBench is FundFixture {
    bytes32 internal constant ORDER = "ORDER-GAS";
    IdentityRegistry.Claim internal pendingClaim;
    bytes internal pendingSig;
    bytes32[] internal dividendProof;

    function setUp() public override {
        super.setUp();
        _seed(alice, 1000 * USDC);
        _seed(bob, 1000 * USDC);
        usdc.mint(alice, 1000 * USDC);

        _issueOrder(ORDER, alice, bob, 1 * USDC);
        vm.prank(alice);
        share.approve(stranger, type(uint256).max);

        // A settled deposit for carol, a settled redemption for bob, and an open epoch with a pending request.
        _requestDeposit(carol, 500 * USDC);
        vm.prank(bob);
        vault.requestRedeem(400 * USDC, bob, bob);
        _closeAndSettle(NAV_ONE);
        _fund(dave, 100 * USDC);
        _requestDeposit(erin, 100 * USDC);
        _close();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(navOracle);
        vault.postNav(1.001e18, uint64(block.timestamp));

        // A matured recovery for alice.
        _bind(alice2, ID_ALICE);

        // A signed claim waiting to be submitted.
        vm.warp(block.timestamp + 1);
        pendingClaim = _claim(ID_DAVE, 1, 1);
        pendingSig = _sign(pendingClaim, issuerKey);

        // A funded dividend distribution.
        address[] memory accounts = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        amounts[0] = 10 * USDC;
        amounts[1] = 5 * USDC;
        (bytes32[] memory tree, uint256[] memory idx) = StandardMerkleTree.build(accounts, amounts);
        dividendProof = StandardMerkleTree.proof(tree, idx[0]);
        _fund(fundAdmin, 15 * USDC);
        vm.startPrank(fundAdmin);
        usdc.approve(address(distributor), 15 * USDC);
        distributor.createDistribution(tree[0], 15 * USDC, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_gas_baseline_plainErc20Transfer() public {
        vm.prank(alice);
        usdc.transfer(bob, 1 * USDC);
    }

    function test_gas_transfer_betweenExistingHolders() public {
        vm.prank(alice);
        share.transfer(bob, 1 * USDC);
    }

    function test_gas_transfer_toNewHolder() public {
        vm.prank(alice);
        share.transfer(dave, 1 * USDC);
    }

    function test_gas_transferFrom() public {
        vm.prank(stranger);
        share.transferFrom(alice, bob, 1 * USDC);
    }

    function test_gas_canTransfer_view() public view {
        share.canTransfer(alice, bob, 1 * USDC);
    }

    function test_gas_requestDeposit() public {
        vm.prank(dave);
        vault.requestDeposit(100 * USDC, dave, dave);
    }

    function test_gas_claimDeposit_mintsThroughCompliance() public {
        vm.prank(carol);
        vault.deposit(500 * USDC, carol, carol);
    }

    function test_gas_requestRedeem_burnsThroughCompliance() public {
        vm.prank(alice);
        vault.requestRedeem(100 * USDC, alice, alice);
    }

    function test_gas_claimRedeem() public {
        vm.prank(bob);
        vault.redeem(400 * USDC, bob, bob);
    }

    function test_gas_settleEpoch() public {
        vm.prank(fundAdmin);
        vault.settleEpoch();
    }

    function test_gas_forcedTransfer_withLawfulOrder() public {
        vm.prank(transferAgent);
        share.forcedTransfer(alice, bob, 1 * USDC, ORDER);
    }

    function test_gas_initiateRecovery() public {
        vm.prank(transferAgent);
        share.initiateRecovery(alice, alice2, "case");
    }

    function test_gas_addClaim() public {
        registry.addClaim(pendingClaim, pendingSig);
    }

    function test_gas_isVerified_view() public view {
        registry.isVerified(alice);
    }

    function test_gas_dividendClaim() public {
        distributor.claim(0, alice, 10 * USDC, dividendProof);
    }
}
