// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ComplianceControls} from "./ComplianceControls.sol";

/**
 * @title ReserveGate
 * @notice Records EIP-712 reserve attestations and gates every supply increase on them: a mint (minter or bridge)
 *         reverts when the latest attestation is older than {MAX_ATTESTATION_AGE} or when `supply + amount` would
 *         exceed the attested reserves.
 * @dev Submission is permissionless (anyone can relay a signed attestation); authenticity comes from the signature
 *      of the configured attestor, verified with `SignatureChecker`, so the attestor can be an EOA or an ERC-1271
 *      contract (for example a multisig of the accounting firm). The domain is the token's own EIP-712 domain, which
 *      binds an attestation to this chain id and this proxy address.
 *
 *      Attestations must be strictly newer than the recorded one, not dated in the future, and not already stale, so
 *      replaying an old (possibly higher) figure is impossible. An attestation that reports fewer reserves than the
 *      outstanding supply is recorded (hiding bad news would be worse) and emits {ReserveShortfall}; minting then
 *      stays blocked until a covering attestation arrives, while burns and transfers keep working.
 */
abstract contract ReserveGate is ComplianceControls, EIP712Upgradeable {
    /// @notice EIP-712 type hash of a reserve attestation.
    bytes32 public constant RESERVE_ATTESTATION_TYPEHASH =
        keccak256("ReserveAttestation(uint256 reserves,uint64 asOf,bytes32 reportHash)");

    /// @notice Maximum age of the latest attestation for minting to be allowed: a daily attestation plus 2 h of grace.
    uint256 public constant MAX_ATTESTATION_AGE = 26 hours;

    /// @custom:storage-location erc7201:tpd.storage.Reserves
    struct ReservesStorage {
        /// @dev Key allowed to sign attestations (EOA or ERC-1271 contract).
        address attestor;
        /// @dev Timestamp the latest accepted attestation certifies reserves at; 0 if none was ever accepted.
        uint64 asOf;
        /// @dev Reserves certified by the latest accepted attestation, in token units.
        uint256 reserves;
        /// @dev Token supply at the moment the latest attestation was recorded.
        uint256 supplyAtAttestation;
        /// @dev Hash of the off-chain report behind the latest attestation.
        bytes32 reportHash;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("tpd.storage.Reserves")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant RESERVES_STORAGE_LOCATION =
        0x594c6292389e4eaea542ddfaf0b4b6d8c7c3c2a46ba4db9cd340a0cff7465900;

    /// @notice Records a reserve attestation signed by the configured attestor. Callable by anyone.
    /// @param reserves Reserves backing the token, in token units (6 decimals).
    /// @param asOf Timestamp the reserves were certified at; strictly newer than the recorded attestation, not in the
    ///        future and at most {MAX_ATTESTATION_AGE} old.
    /// @param reportHash Hash of the off-chain attestation report.
    /// @param signature Attestor signature over the EIP-712 `ReserveAttestation` struct (65-byte ECDSA or ERC-1271).
    function submitReserveAttestation(uint256 reserves, uint64 asOf, bytes32 reportHash, bytes calldata signature)
        external
    {
        ReservesStorage storage $ = _getReservesStorage();
        address attestor_ = $.attestor;
        uint64 latest = $.asOf;
        require(asOf <= block.timestamp, AttestationFromFuture(asOf, block.timestamp));
        require(asOf > latest, AttestationNotNewer(asOf, latest));
        require(block.timestamp - asOf <= MAX_ATTESTATION_AGE, AttestationTooOld(asOf, block.timestamp));

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(RESERVE_ATTESTATION_TYPEHASH, reserves, asOf, reportHash)));
        require(
            SignatureChecker.isValidSignatureNowCalldata(attestor_, digest, signature),
            InvalidAttestationSignature(attestor_)
        );

        uint256 supply = totalSupply();
        $.asOf = asOf;
        $.reserves = reserves;
        $.supplyAtAttestation = supply;
        $.reportHash = reportHash;
        emit ReservesAttested(reserves, asOf, reportHash, supply);
        if (reserves < supply) emit ReserveShortfall(reserves, supply);
    }

    /// @notice Replaces the attestor key. Restricted to ADMIN (2-day execution delay).
    /// @dev The recorded attestation is kept; the new attestor's first attestation must be newer than it.
    /// @param newAttestor The new attestor; must not be the zero address.
    function setReserveAttestor(address newAttestor) external restricted {
        _setReserveAttestor(newAttestor);
    }

    /// @notice The key currently allowed to sign reserve attestations.
    /// @return The attestor address.
    function reserveAttestor() external view returns (address) {
        return _getReservesStorage().attestor;
    }

    /// @notice The latest accepted reserve attestation.
    /// @return reserves Attested reserves (token units).
    /// @return asOf Timestamp the reserves were certified at (0 if none).
    /// @return reportHash Hash of the off-chain report.
    /// @return supplyAtAttestation Supply when the attestation was recorded.
    function latestReserveAttestation()
        external
        view
        returns (uint256 reserves, uint64 asOf, bytes32 reportHash, uint256 supplyAtAttestation)
    {
        ReservesStorage storage $ = _getReservesStorage();
        return ($.reserves, $.asOf, $.reportHash, $.supplyAtAttestation);
    }

    /// @notice How much could be minted right now as far as reserves are concerned (ignores minter allowances and
    ///         rolling limits). Zero when there is no attestation, when it is stale, or during a shortfall.
    /// @return The remaining reserve headroom in token units.
    function mintHeadroom() external view returns (uint256) {
        ReservesStorage storage $ = _getReservesStorage();
        uint64 asOf = $.asOf;
        if (asOf == 0 || block.timestamp - asOf > MAX_ATTESTATION_AGE) return 0;
        uint256 supply = totalSupply();
        return $.reserves > supply ? $.reserves - supply : 0;
    }

    /// @dev Reverts unless a fresh attestation covers `totalSupply() + amount`. Called by every supply increase.
    function _requireReserveHeadroom(uint256 amount) internal view {
        ReservesStorage storage $ = _getReservesStorage();
        uint64 asOf = $.asOf;
        require(asOf != 0, NoReserveAttestation());
        require(block.timestamp - asOf <= MAX_ATTESTATION_AGE, StaleReserveAttestation(asOf, block.timestamp));
        uint256 supply = totalSupply();
        uint256 reserves = $.reserves;
        // Written as a subtraction so an absurd `amount` reports a clean error instead of an overflow panic.
        if (supply > reserves || amount > reserves - supply) {
            revert InsufficientAttestedReserves(supply, amount, reserves);
        }
    }

    /// @dev Sets the attestor and emits {ReserveAttestorSet}.
    function _setReserveAttestor(address newAttestor) internal {
        require(newAttestor != address(0), InvalidAccount(newAttestor));
        ReservesStorage storage $ = _getReservesStorage();
        emit ReserveAttestorSet($.attestor, newAttestor);
        $.attestor = newAttestor;
    }

    /// @dev Returns the ERC-7201 namespaced storage of this module.
    function _getReservesStorage() private pure returns (ReservesStorage storage $) {
        // Assigning a constant slot to a storage pointer is the ERC-7201 pattern; nothing is read or written here.
        assembly ("memory-safe") {
            $.slot := RESERVES_STORAGE_LOCATION
        }
    }
}
