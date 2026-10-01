// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReserveGate} from "../../src/modules/ReserveGate.sol";
import {TestPaymentDollarV1} from "../../src/TestPaymentDollarV1.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice EIP-712 reserve attestations: acceptance rules, the shortfall path, ERC-1271 attestors and the views.
contract ReservesTest is StablecoinTestBase {
    function test_submit_recordsAndEmits() public {
        _mint(alice, 10e6);
        vm.warp(block.timestamp + 1 hours);
        uint64 asOf = uint64(block.timestamp - 10 minutes);
        bytes memory sig = _signAttestation(attestorKey, 77e6, asOf, keccak256("report-2"));
        vm.expectEmit(false, true, false, true);
        emit ReservesAttested(77e6, asOf, keccak256("report-2"), 10e6);
        vm.prank(relayer); // anyone may relay a signed attestation
        token.submitReserveAttestation(77e6, asOf, keccak256("report-2"), sig);
        (uint256 reserves, uint64 recordedAsOf, bytes32 reportHash, uint256 supplyAt) = token.latestReserveAttestation();
        assertEq(reserves, 77e6);
        assertEq(recordedAsOf, asOf);
        assertEq(reportHash, keccak256("report-2"));
        assertEq(supplyAt, 10e6);
        assertEq(token.mintHeadroom(), 67e6);
    }

    function test_submit_shortfallIsRecordedAndBlocksMinting() public {
        _mint(alice, 1000e6);
        vm.warp(block.timestamp + 1);
        bytes memory sig = _signAttestation(attestorKey, 400e6, uint64(block.timestamp), REPORT_HASH);
        vm.expectEmit(false, false, false, true);
        emit ReserveShortfall(400e6, 1000e6);
        token.submitReserveAttestation(400e6, uint64(block.timestamp), REPORT_HASH, sig);
        assertEq(token.mintHeadroom(), 0);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAttestedReserves.selector, 1000e6, 1, 400e6));
        token.mint(alice, 1);
        // Transfers keep working during a shortfall.
        vm.prank(alice);
        token.transfer(bob, 1e6);
    }

    function test_submit_revertsFromFuture() public {
        uint64 asOf = uint64(block.timestamp + 1);
        bytes memory sig = _signAttestation(attestorKey, 1, asOf, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(AttestationFromFuture.selector, asOf, block.timestamp));
        token.submitReserveAttestation(1, asOf, REPORT_HASH, sig);
    }

    function test_submit_revertsOnReplayAndOlder() public {
        uint64 latest = uint64(block.timestamp);
        bytes memory sig = _signAttestation(attestorKey, INITIAL_RESERVES, latest, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(AttestationNotNewer.selector, latest, latest));
        token.submitReserveAttestation(INITIAL_RESERVES, latest, REPORT_HASH, sig);

        vm.warp(block.timestamp + 1 hours);
        uint64 older = latest - 1;
        bytes memory olderSig = _signAttestation(attestorKey, type(uint128).max, older, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(AttestationNotNewer.selector, older, latest));
        token.submitReserveAttestation(type(uint128).max, older, REPORT_HASH, olderSig);
    }

    function test_submit_revertsWhenAlreadyTooOld() public {
        vm.warp(block.timestamp + 30 hours);
        uint64 asOf = uint64(block.timestamp - 26 hours - 1);
        bytes memory sig = _signAttestation(attestorKey, 1, asOf, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(AttestationTooOld.selector, asOf, block.timestamp));
        token.submitReserveAttestation(1, asOf, REPORT_HASH, sig);
        // Exactly 26 h old is still accepted.
        asOf = uint64(block.timestamp - 26 hours);
        token.submitReserveAttestation(1, asOf, REPORT_HASH, _signAttestation(attestorKey, 1, asOf, REPORT_HASH));
    }

    function test_submit_revertsOnWrongSigner() public {
        vm.warp(block.timestamp + 1);
        uint64 asOf = uint64(block.timestamp);
        bytes memory sig = _signAttestation(aliceKey, 1e12, asOf, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, attestor));
        token.submitReserveAttestation(1e12, asOf, REPORT_HASH, sig);
    }

    function test_submit_revertsOnTamperedFields() public {
        vm.warp(block.timestamp + 1);
        uint64 asOf = uint64(block.timestamp);
        bytes memory sig = _signAttestation(attestorKey, 1e12, asOf, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, attestor));
        token.submitReserveAttestation(1e12 + 1, asOf, REPORT_HASH, sig);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, attestor));
        token.submitReserveAttestation(1e12, asOf, bytes32(uint256(1)), sig);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, attestor));
        token.submitReserveAttestation(1e12, asOf, REPORT_HASH, hex"1234");
    }

    function test_erc1271Attestor() public {
        _governance(address(token), abi.encodeCall(ReserveGate.setReserveAttestor, (address(wallet))));
        assertEq(token.reserveAttestor(), address(wallet));
        uint64 asOf = uint64(block.timestamp);
        bytes memory sig = _signAttestation(walletOwnerKey, 5e12, asOf, REPORT_HASH);
        token.submitReserveAttestation(5e12, asOf, REPORT_HASH, sig);
        (uint256 reserves,,,) = token.latestReserveAttestation();
        assertEq(reserves, 5e12);

        // The old EOA attestor no longer counts, and a wallet that stops validating rejects its own signatures.
        vm.warp(block.timestamp + 1);
        asOf = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, address(wallet)));
        token.submitReserveAttestation(1, asOf, REPORT_HASH, _signAttestation(attestorKey, 1, asOf, REPORT_HASH));
        vm.prank(walletOwner);
        wallet.setRejectAll(true);
        sig = _signAttestation(walletOwnerKey, 1, asOf, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, address(wallet)));
        token.submitReserveAttestation(1, asOf, REPORT_HASH, sig);
    }

    function test_setReserveAttestor_revertsOnZero() public {
        bytes memory data = abi.encodeCall(ReserveGate.setReserveAttestor, (address(0)));
        vm.prank(governance);
        manager.schedule(address(token), data, 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        manager.execute(address(token), data);
    }

    function test_setReserveAttestor_emits() public {
        bytes memory data = abi.encodeCall(ReserveGate.setReserveAttestor, (alice));
        vm.prank(governance);
        manager.schedule(address(token), data, 0);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, true, false, false, address(token));
        emit ReserveAttestorSet(attestor, alice);
        vm.prank(governance);
        manager.execute(address(token), data);
    }

    function test_mintHeadroom_zeroWhenStale() public {
        assertEq(token.mintHeadroom(), INITIAL_RESERVES);
        vm.warp(block.timestamp + 26 hours + 1);
        assertEq(token.mintHeadroom(), 0);
    }

    function test_freshDeployment_hasNoAttestation() public {
        StablecoinDeployment.Deployment memory d = StablecoinDeployment.deploy(_config());
        TestPaymentDollarV1 fresh = d.token;
        assertEq(fresh.mintHeadroom(), 0);
        vm.prank(masterMinter);
        fresh.configureMinter(minter, 1e6, 1e6);
        vm.prank(minter);
        vm.expectRevert(NoReserveAttestation.selector);
        fresh.mint(alice, 1);
    }

    function test_attestationIsBoundToThisToken() public {
        // Same attestor, same chain, different proxy: a signature for one deployment is useless on the other.
        StablecoinDeployment.Deployment memory d = StablecoinDeployment.deploy(_config());
        vm.warp(block.timestamp + 1);
        uint64 asOf = uint64(block.timestamp);
        bytes memory sigForOriginal = _signAttestation(attestorKey, 9e12, asOf, REPORT_HASH);
        vm.expectRevert(abi.encodeWithSelector(InvalidAttestationSignature.selector, attestor));
        d.token.submitReserveAttestation(9e12, asOf, REPORT_HASH, sigForOriginal);
    }

    function test_walletMockOnlyOwnerToggles() public {
        vm.expectRevert(MockERC1271Wallet.NotOwner.selector);
        wallet.setRejectAll(true);
    }
}
