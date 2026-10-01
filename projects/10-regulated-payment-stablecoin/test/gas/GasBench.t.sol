// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Test.sol";

import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";
import {PlainERC20, PlainERC3009} from "../mocks/PlainTokens.sol";
import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice Gas benchmarks for the hot payment paths, next to bare OpenZeppelin baselines. `.gas-snapshot` holds the
///         per-test totals and is checked in CI (`forge snapshot --check --match-contract GasBench`); run with -vv to
///         print the exact gas of each measured call (`vm.lastFrameGas`, excluding the 21,000 intrinsic cost).
///         Every scenario is warm-recipient: the payee already holds a balance, as in steady-state payments.
contract GasBench is StablecoinTestBase {
    PlainERC20 internal plain;
    PlainERC3009 internal plain3009;

    uint256 internal va;
    uint256 internal vb;
    bytes internal authSig;
    bytes internal authSigWallet;
    bytes internal receiveSig;
    uint8 internal pv;
    bytes32 internal pr;
    bytes32 internal ps;
    bytes internal permitSig;
    bytes internal permitSigWallet;
    uint8 internal v;
    bytes32 internal r;
    bytes32 internal s;
    uint64 internal nextAsOf;
    bytes internal attestationSig;

    function setUp() public override {
        super.setUp();
        _mint(alice, 1000e6);
        _mint(bob, 1000e6);
        _mint(address(wallet), 1000e6);
        vm.prank(alice);
        token.approve(carol, type(uint256).max);

        plain = new PlainERC20();
        plain.mint(alice, 1000e6);
        plain.mint(bob, 1000e6);
        plain3009 = new PlainERC3009();
        plain3009.mint(alice, 1000e6);
        plain3009.mint(bob, 1000e6);

        va = block.timestamp - 1;
        vb = block.timestamp + 1 hours;
        authSig = _signTransferAuth(aliceKey, alice, bob, 10e6, va, vb, keccak256("gas"));
        (v, r, s) = _split(authSig);
        authSigWallet = _signTransferAuth(walletOwnerKey, address(wallet), bob, 10e6, va, vb, keccak256("gas"));
        receiveSig = _signReceiveAuth(aliceKey, alice, bob, 10e6, va, vb, keccak256("gas"));
        (pv, pr, ps) = _split(
            _sign(
                aliceKey,
                _digest(
                    _domainSeparatorFor("Plain", "1", block.chainid, address(plain3009)),
                    _authStructHash(TRANSFER_AUTH_TYPEHASH, alice, bob, 10e6, va, vb, keccak256("gas"))
                )
            )
        );
        permitSig = _signPermit(aliceKey, alice, bob, 10e6, vb);
        permitSigWallet = _signPermit(walletOwnerKey, address(wallet), bob, 10e6, vb);
        nextAsOf = uint64(block.timestamp + 1);
        vm.warp(nextAsOf);
        attestationSig = _signAttestation(attestorKey, INITIAL_RESERVES, nextAsOf, REPORT_HASH);
    }

    function _report(string memory label) internal view {
        console2.log(label, vm.lastFrameGas().gasTotalUsed);
    }

    // ---- tPD --------------------------------------------------------------------------------------------------

    function test_gas_transfer() public {
        vm.prank(alice);
        token.transfer(bob, 10e6);
        _report("tPD transfer                          ");
    }

    function test_gas_transferFrom() public {
        vm.prank(carol);
        token.transferFrom(alice, bob, 10e6);
        _report("tPD transferFrom (infinite allowance) ");
    }

    function test_gas_transferWithAuthorization_vrs() public {
        token.transferWithAuthorization(alice, bob, 10e6, va, vb, keccak256("gas"), v, r, s);
        _report("tPD transferWithAuthorization (v,r,s)");
    }

    function test_gas_transferWithAuthorization_bytesEoa() public {
        token.transferWithAuthorization(alice, bob, 10e6, va, vb, keccak256("gas"), authSig);
        _report("tPD transferWithAuthorization (bytes)");
    }

    function test_gas_transferWithAuthorization_erc1271() public {
        token.transferWithAuthorization(address(wallet), bob, 10e6, va, vb, keccak256("gas"), authSigWallet);
        _report("tPD transferWithAuthorization (1271) ");
    }

    function test_gas_receiveWithAuthorization() public {
        vm.prank(bob);
        token.receiveWithAuthorization(alice, bob, 10e6, va, vb, keccak256("gas"), receiveSig);
        _report("tPD receiveWithAuthorization (bytes) ");
    }

    function test_gas_permit_bytesEoa() public {
        token.permit(alice, bob, 10e6, vb, permitSig);
        _report("tPD permit (bytes, EOA)              ");
    }

    function test_gas_permit_erc1271() public {
        token.permit(address(wallet), bob, 10e6, vb, permitSigWallet);
        _report("tPD permit (bytes, ERC-1271)         ");
    }

    function test_gas_mint() public {
        vm.prank(minter);
        token.mint(bob, 10e6);
        _report("tPD mint (allowance+window+reserves) ");
    }

    function test_gas_submitReserveAttestation() public {
        token.submitReserveAttestation(INITIAL_RESERVES, nextAsOf, REPORT_HASH, attestationSig);
        _report("tPD submitReserveAttestation         ");
    }

    function test_gas_v2_transfer_flagged() public {
        (TestPaymentDollarV2 v2,) = _upgradeToV2();
        vm.prank(compliance);
        v2.setTransferCapFlag(alice, true);
        vm.prank(alice);
        v2.transfer(bob, 10e6);
        _report("tPD v2 transfer from flagged account ");
    }

    // ---- baselines ----------------------------------------------------------------------------------------------

    function test_gas_baseline_plainErc20Transfer() public {
        vm.prank(alice);
        plain.transfer(bob, 10e6);
        _report("baseline OZ ERC20 transfer           ");
    }

    function test_gas_baseline_plainErc3009() public {
        plain3009.transferWithAuthorization(alice, bob, 10e6, va, vb, keccak256("gas"), pv, pr, ps);
        _report("baseline OZ ERC3009 (v,r,s)          ");
    }
}
