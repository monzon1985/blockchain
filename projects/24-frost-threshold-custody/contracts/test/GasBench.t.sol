// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ISchnorrVault} from "../src/ISchnorrVault.sol";
import {SchnorrSecp256k1} from "../src/SchnorrSecp256k1.sol";
import {SchnorrVault} from "../src/SchnorrVault.sol";
import {MockERC20} from "./utils/Mocks.sol";
import {SchnorrTestBase, VerifierHarness} from "./utils/SchnorrTestBase.sol";

/// @notice Baseline: a 3-of-5 multisig that verifies three ECDSA signatures with
///         OpenZeppelin's ECDSA library (sorted signers, membership via mapping).
contract EcdsaMultisigBaseline {
    /// @notice Signer set membership.
    mapping(address signer => bool) public isSigner;
    /// @notice Signatures required.
    uint256 public constant THRESHOLD = 3;

    /// @notice Error for any rejected signature set.
    error BadSignatures();

    constructor(address[5] memory signers) {
        for (uint256 i = 0; i < 5; ++i) {
            isSigner[signers[i]] = true;
        }
    }

    /// @notice Verifies `THRESHOLD` signatures over `digest` from distinct signers,
    ///         supplied in strictly increasing signer-address order.
    function verify(bytes32 digest, bytes[] calldata sigs) external view returns (bool) {
        require(sigs.length == THRESHOLD, BadSignatures());
        address last;
        for (uint256 i = 0; i < THRESHOLD; ++i) {
            address signer = ECDSA.recover(digest, sigs[i]);
            require(signer > last && isSigner[signer], BadSignatures());
            last = signer;
        }
        return true;
    }
}

/// @notice Schnorr verification with the group key read from storage (two cold slots, as in
///         `SchnorrVault._consumeAuthorization`). This is the like-for-like counterpart of the
///         ECDSA baseline, which also reads its signer set from storage.
contract StoredKeyVerifier {
    /// @notice Group key x-coordinate (its own storage slot).
    uint256 internal keyX;
    /// @notice Group key parity (a second slot, like the vault's packed parity and epoch).
    uint8 internal keyParity;

    constructor(uint256 x, uint8 parity) {
        keyX = x;
        keyParity = parity;
    }

    /// @notice Verifies `sig` over `digest` under the stored key.
    /// @param digest Signed message hash.
    /// @param sig Schnorr signature `(address(R), z)`.
    /// @return Whether the signature is valid under the stored key.
    function verify(bytes32 digest, SchnorrSecp256k1.Signature calldata sig)
        external
        view
        returns (bool)
    {
        return SchnorrSecp256k1.verify(keyX, keyParity, digest, sig);
    }
}

/// @notice Gas measurements. `forge snapshot --check --match-contract GasBench` pins the
///         per-test totals in `.gas-snapshot`; `vm.snapshotGasLastFrame` records the exact
///         gas of each measured call (callee frame) in `snapshots/GasBench.json`, checked with
///         `FORGE_SNAPSHOT_CHECK=true forge test --match-contract GasBench`.
contract GasBench is SchnorrTestBase {
    VerifierHarness internal harness;
    StoredKeyVerifier internal storedKey;
    EcdsaMultisigBaseline internal baseline;
    SchnorrVault internal vault;
    MockERC20 internal token;
    Key internal group;
    Key internal nextGroup;

    bytes32 internal digest = keccak256("gas bench message");
    SchnorrSecp256k1.Signature internal schnorrSig;
    bytes[] internal ecdsaSigs;

    ISchnorrVault.WithdrawalIntent internal ethIntent;
    SchnorrSecp256k1.Signature internal ethSig;
    ISchnorrVault.WithdrawalIntent internal tokenIntent;
    SchnorrSecp256k1.Signature internal tokenSig;
    ISchnorrVault.KeyRotation internal rotation;
    SchnorrSecp256k1.Signature internal rotationByCurrent;
    SchnorrSecp256k1.Signature internal rotationByNext;
    ISchnorrVault.DailyLimitUpdate internal limitUpdate;
    SchnorrSecp256k1.Signature internal limitSig;

    function setUp() public {
        vm.warp(1_800_000_000);
        harness = new VerifierHarness();
        group = makeKey(0x6A5);
        nextGroup = makeKey(0x6A6);
        schnorrSig = schnorrSign(group, digest);
        storedKey = new StoredKeyVerifier(group.x, group.parity);

        // ECDSA baseline: five signers, three sign, sorted by address.
        address[5] memory signers;
        uint256[5] memory keys = [uint256(11), 12, 13, 14, 15];
        for (uint256 i = 0; i < 5; ++i) {
            signers[i] = vm.addr(keys[i]);
        }
        baseline = new EcdsaMultisigBaseline(signers);
        for (uint256 i = 0; i < 5; ++i) {
            for (uint256 j = i + 1; j < 5; ++j) {
                if (signers[j] < signers[i]) {
                    (signers[i], signers[j]) = (signers[j], signers[i]);
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
        for (uint256 i = 0; i < 3; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            ecdsaSigs.push(abi.encodePacked(r, s, v));
        }

        token = new MockERC20();
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(token);
        uint256[] memory limits = new uint256[](2);
        limits[0] = 100 ether;
        limits[1] = 100 ether;
        vault = new SchnorrVault(group.x, group.parity, makeAddr("guardian"), tokens, limits);
        vm.deal(address(vault), 10 ether);
        token.mint(address(vault), 10 ether);
        // Warm the recipient accounts so ETH and token transfers are measured
        // without the one-off new-account surcharge.
        address recipient = makeAddr("recipient");
        vm.deal(recipient, 1);
        token.mint(recipient, 1);

        ethIntent = withdrawal(recipient, address(0), 1 ether, 1, block.timestamp);
        ethSig = signWithdrawal(vault, group, ethIntent);
        tokenIntent = withdrawal(recipient, address(token), 1 ether, 2, block.timestamp);
        tokenSig = signWithdrawal(vault, group, tokenIntent);
        rotation = ISchnorrVault.KeyRotation({
            newPubKeyX: nextGroup.x,
            newPubKeyYParity: nextGroup.parity,
            nonce: 3,
            deadline: block.timestamp
        });
        bytes32 rotationDigest = vault.hashKeyRotation(rotation);
        rotationByCurrent = schnorrSign(group, rotationDigest);
        rotationByNext = schnorrSign(nextGroup, rotationDigest);
        limitUpdate = ISchnorrVault.DailyLimitUpdate({
            token: address(0), newLimit: 1 ether, nonce: 4, deadline: block.timestamp
        });
        limitSig = schnorrSign(group, vault.hashDailyLimitUpdate(limitUpdate));
    }

    function test_gas_schnorrVerify() public {
        assertTrue(harness.verify(group.x, group.parity, digest, schnorrSig));
        vm.snapshotGasLastFrame("schnorr_verify");
    }

    function test_gas_schnorrVerifyStoredKey() public {
        assertTrue(storedKey.verify(digest, schnorrSig));
        vm.snapshotGasLastFrame("schnorr_verify_stored_key");
    }

    function test_gas_ecdsaMultisig3of5Verify() public {
        assertTrue(baseline.verify(digest, ecdsaSigs));
        vm.snapshotGasLastFrame("baseline_ecdsa_3of5_verify");
    }

    function test_gas_withdrawEth() public {
        vault.withdraw(ethIntent, ethSig);
        vm.snapshotGasLastFrame("vault_withdraw_eth");
    }

    function test_gas_withdrawToken() public {
        vault.withdraw(tokenIntent, tokenSig);
        vm.snapshotGasLastFrame("vault_withdraw_erc20");
    }

    function test_gas_rotateGroupKey() public {
        vault.rotateGroupKey(rotation, rotationByCurrent, rotationByNext);
        vm.snapshotGasLastFrame("vault_rotate_group_key");
    }

    function test_gas_updateDailyLimit() public {
        vault.updateDailyLimit(limitUpdate, limitSig);
        vm.snapshotGasLastFrame("vault_update_daily_limit");
    }
}
