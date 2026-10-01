// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ISchnorrVault} from "../src/ISchnorrVault.sol";
import {SchnorrSecp256k1} from "../src/SchnorrSecp256k1.sol";
import {SchnorrVault} from "../src/SchnorrVault.sol";
import {MockERC20} from "./utils/Mocks.sol";
import {SchnorrTestBase, VerifierHarness} from "./utils/SchnorrTestBase.sol";

/// @notice Cross-language differential test. `test/fixtures/sigs.json` is produced by
///         `cargo run -p fixtures-gen` from a real Pedersen DKG and real two-round
///         FROST signing in Rust. Every signature must reach exactly the verdict the
///         Rust model of this verifier recorded, and every EIP-712 digest computed by
///         Rust (alloy) must equal the one computed on-chain.
contract RustFixturesTest is SchnorrTestBase {
    string internal json;
    VerifierHarness internal harness;
    SchnorrVault internal vault;
    MockERC20 internal token;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/sigs.json"));
        harness = new VerifierHarness();
        vm.chainId(vm.parseJsonUint(json, ".chainId"));
        vm.warp(vm.parseJsonUint(json, ".now"));

        // Deploy the mock token and the vault at the addresses baked into the
        // EIP-712 domain of the fixtures.
        deployCodeTo("Mocks.sol:MockERC20", vm.parseJsonAddress(json, ".token"));
        token = MockERC20(vm.parseJsonAddress(json, ".token"));
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(token);
        uint256[] memory limits = new uint256[](2);
        limits[0] = vm.parseJsonUint(json, ".limits.eth");
        limits[1] = vm.parseJsonUint(json, ".limits.token");
        address vaultAddress = vm.parseJsonAddress(json, ".vault");
        deployCodeTo(
            "SchnorrVault.sol:SchnorrVault",
            abi.encode(
                vm.parseJsonUint(json, ".group.pubKeyX"),
                uint8(vm.parseJsonUint(json, ".group.pubKeyYParity")),
                makeAddr("guardian"),
                tokens,
                limits
            ),
            vaultAddress
        );
        vault = SchnorrVault(payable(vaultAddress));
        vm.deal(address(vault), 100 ether);
        token.mint(address(vault), 1_000_000);
    }

    function test_verifierCasesMatchRustVerdicts() public view {
        uint256 n = vm.parseJsonUint(json, ".verifierCaseCount");
        assertGt(n, 0);
        uint256 valid;
        for (uint256 i = 0; i < n; ++i) {
            string memory base = string.concat(".verifierCases[", vm.toString(i), "]");
            uint256 x = vm.parseJsonUint(json, string.concat(base, ".pubKeyX"));
            uint8 parity = uint8(vm.parseJsonUint(json, string.concat(base, ".pubKeyYParity")));
            bytes32 m = vm.parseJsonBytes32(json, string.concat(base, ".msgHash"));
            SchnorrSecp256k1.Signature memory sig = SchnorrSecp256k1.Signature({
                rAddr: vm.parseJsonAddress(json, string.concat(base, ".rAddr")),
                z: vm.parseJsonUint(json, string.concat(base, ".z"))
            });
            bool expected = vm.parseJsonBool(json, string.concat(base, ".valid"));
            string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
            assertEq(harness.verify(x, parity, m, sig), expected, name);
            if (expected) {
                ++valid;
                assertEq(
                    harness.challenge(sig.rAddr, parity, x, m),
                    vm.parseJsonUint(json, string.concat(base, ".challenge")),
                    name
                );
            }
        }
        assertEq(valid, 4);
    }

    function _intent(string memory base)
        internal
        view
        returns (ISchnorrVault.WithdrawalIntent memory)
    {
        return ISchnorrVault.WithdrawalIntent({
            to: vm.parseJsonAddress(json, string.concat(base, ".to")),
            token: vm.parseJsonAddress(json, string.concat(base, ".token")),
            amount: vm.parseJsonUint(json, string.concat(base, ".amount")),
            nonce: vm.parseJsonUint(json, string.concat(base, ".nonce")),
            deadline: vm.parseJsonUint(json, string.concat(base, ".deadline"))
        });
    }

    function _sig(string memory base) internal view returns (SchnorrSecp256k1.Signature memory) {
        return SchnorrSecp256k1.Signature({
            rAddr: vm.parseJsonAddress(json, string.concat(base, ".rAddr")),
            z: vm.parseJsonUint(json, string.concat(base, ".z"))
        });
    }

    function _expectedRevert(string memory expect, ISchnorrVault.WithdrawalIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        bytes32 e = keccak256(bytes(expect));
        if (e == keccak256("NonceAlreadyUsed")) {
            return abi.encodeWithSelector(ISchnorrVault.NonceAlreadyUsed.selector, intent.nonce);
        }
        if (e == keccak256("InvalidSignature")) {
            return abi.encodeWithSelector(
                ISchnorrVault.InvalidSignature.selector, vault.hashWithdrawal(intent)
            );
        }
        if (e == keccak256("DailyLimitExceeded")) {
            return abi.encodeWithSelector(
                ISchnorrVault.DailyLimitExceeded.selector,
                intent.token,
                intent.amount,
                vault.remainingToday(intent.token)
            );
        }
        if (e == keccak256("IntentExpired")) {
            return abi.encodeWithSelector(
                ISchnorrVault.IntentExpired.selector, intent.deadline, block.timestamp
            );
        }
        revert(string.concat("unknown expectation ", expect));
    }

    function _replay(string memory list, uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            string memory base = string.concat(list, "[", vm.toString(i), "]");
            ISchnorrVault.WithdrawalIntent memory intent = _intent(base);
            string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
            // Rust's alloy EIP-712 digest equals the contract's.
            assertEq(
                vault.hashWithdrawal(intent),
                vm.parseJsonBytes32(json, string.concat(base, ".digest")),
                name
            );
            string memory expect = vm.parseJsonString(json, string.concat(base, ".expect"));
            SchnorrSecp256k1.Signature memory sig = _sig(base);
            if (keccak256(bytes(expect)) == keccak256("ok")) {
                uint256 before =
                    intent.token == address(0) ? intent.to.balance : token.balanceOf(intent.to);
                vault.withdraw(intent, sig);
                uint256 afterBalance =
                    intent.token == address(0) ? intent.to.balance : token.balanceOf(intent.to);
                assertEq(afterBalance - before, intent.amount, name);
                assertTrue(vault.isNonceUsed(intent.nonce), name);
            } else {
                vm.expectRevert(_expectedRevert(expect, intent));
                vault.withdraw(intent, sig);
            }
        }
    }

    function test_vaultScenarioMatchesRustExpectations() public {
        _replay(".beforeRotation", vm.parseJsonUint(json, ".beforeRotationCount"));

        // Rotation: signed by the current group and by the new group.
        ISchnorrVault.KeyRotation memory r = ISchnorrVault.KeyRotation({
            newPubKeyX: vm.parseJsonUint(json, ".rotation.newPubKeyX"),
            newPubKeyYParity: uint8(vm.parseJsonUint(json, ".rotation.newPubKeyYParity")),
            nonce: vm.parseJsonUint(json, ".rotation.nonce"),
            deadline: vm.parseJsonUint(json, ".rotation.deadline")
        });
        assertEq(vault.hashKeyRotation(r), vm.parseJsonBytes32(json, ".rotation.digest"));
        assertEq(r.newPubKeyX, vm.parseJsonUint(json, ".nextGroup.pubKeyX"));
        SchnorrSecp256k1.Signature memory byCurrent = _sig(".rotation.currentKey");
        SchnorrSecp256k1.Signature memory byNext = _sig(".rotation.newKey");
        // Swapped signatures fail: the new key cannot authorise, the old key cannot prove possession.
        vm.expectRevert(
            abi.encodeWithSelector(
                ISchnorrVault.InvalidSignature.selector, vault.hashKeyRotation(r)
            )
        );
        vault.rotateGroupKey(r, byNext, byCurrent);
        vault.rotateGroupKey(r, byCurrent, byNext);
        (uint256 x,, uint64 epoch) = vault.groupKey();
        assertEq(x, r.newPubKeyX);
        assertEq(epoch, 1);

        _replay(".afterRotation", vm.parseJsonUint(json, ".afterRotationCount"));

        // Limit and guardian updates signed by the new group.
        ISchnorrVault.DailyLimitUpdate memory u = ISchnorrVault.DailyLimitUpdate({
            token: vm.parseJsonAddress(json, ".dailyLimitUpdate.token"),
            newLimit: vm.parseJsonUint(json, ".dailyLimitUpdate.newLimit"),
            nonce: vm.parseJsonUint(json, ".dailyLimitUpdate.nonce"),
            deadline: vm.parseJsonUint(json, ".dailyLimitUpdate.deadline")
        });
        assertEq(
            vault.hashDailyLimitUpdate(u), vm.parseJsonBytes32(json, ".dailyLimitUpdate.digest")
        );
        vault.updateDailyLimit(u, _sig(".dailyLimitUpdate"));
        assertEq(vault.dailyLimit(u.token), u.newLimit);

        ISchnorrVault.GuardianUpdate memory g = ISchnorrVault.GuardianUpdate({
            newGuardian: vm.parseJsonAddress(json, ".guardianUpdate.newGuardian"),
            nonce: vm.parseJsonUint(json, ".guardianUpdate.nonce"),
            deadline: vm.parseJsonUint(json, ".guardianUpdate.deadline")
        });
        assertEq(vault.hashGuardianUpdate(g), vm.parseJsonBytes32(json, ".guardianUpdate.digest"));
        vault.queueGuardianReplacement(g, _sig(".guardianUpdate"));
        vm.warp(block.timestamp + vault.GUARDIAN_CHANGE_DELAY());
        vault.activateGuardianReplacement();
        assertEq(vault.guardian(), g.newGuardian);
    }
}
