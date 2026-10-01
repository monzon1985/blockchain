// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC3009Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC3009Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {MintController} from "./modules/MintController.sol";

/**
 * @title Test Payment Dollar (tPD), version 1
 * @notice A clearly labelled TEST payment stablecoin demonstrating GENIUS-style issuer controls. It is a technical
 *         demonstration for local chains only: not a real currency, not backed by anything, not affiliated with any
 *         issuer, and not audited.
 * @dev Composition (C3 order): ComplianceControls -> ReserveGate -> MintController (+ ERC-7802) -> this
 *      contract (+ EIP-2612, ERC-3009, UUPS). All state lives in ERC-7201 namespaces; the implementation disables its
 *      initializers so it can only be used behind a proxy.
 *
 *      Every balance change goes through {_update}, which enforces the pause and the blocklist / freeze
 *      restrictions on both sides of the movement. That covers transfer, transferFrom, permit + transferFrom, both
 *      ERC-3009 flavours, mint, burn, crosschainMint and crosschainBurn. Only the lawful-order paths of
 *      `ComplianceControls` (seize, burnFrozen) may debit a frozen account, and they can never credit a restricted one.
 *
 *      Gasless payments accept ECDSA `(v, r, s)` signatures (standard EIP-2612 / ERC-3009 entry points) and `bytes`
 *      signatures verified with `SignatureChecker`, which covers ERC-1271 smart-contract wallets. ERC-3009 uses random
 *      32-byte nonces (the OpenZeppelin `ERC3009` base), not the keyed sequential nonces of `ERC20TransferAuthorization`.
 */
contract TestPaymentDollarV1 is MintController, ERC20PermitUpgradeable, ERC3009Upgradeable, UUPSUpgradeable {
    /// @notice Token name, also the EIP-712 domain name.
    string public constant NAME = "Test Payment Dollar";

    /// @notice Token symbol.
    string public constant SYMBOL = "tPD";

    /// @dev EIP-2612 type hash, re-declared because OpenZeppelin keeps its copy private.
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @notice Parameters of {initialize}.
    /// @param authority The AccessManager that authorises every restricted selector; must be a deployed contract.
    /// @param attestor The key allowed to sign reserve attestations (EOA or ERC-1271).
    /// @param minterLimitCeiling Upper bound on any minter's rolling 24 h limit.
    /// @param bridgeMintLimit Per-bridge rolling 24 h `crosschainMint` cap.
    /// @param bridgeBurnLimit Per-bridge rolling 24 h `crosschainBurn` cap.
    struct InitParams {
        address authority;
        address attestor;
        uint208 minterLimitCeiling;
        uint208 bridgeMintLimit;
        uint208 bridgeBurnLimit;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy: metadata, EIP-712 domain ("Test Payment Dollar", "1"), authority, attestor and
    ///         governance limits.
    /// @dev Reverts with {InvalidAccount} for an authority without code (the zero address included): every
    ///      restricted selector, `upgradeToAndCall` among them, would otherwise be unauthorisable forever.
    /// @param params See {InitParams}.
    function initialize(InitParams calldata params) external initializer {
        require(params.authority.code.length != 0, InvalidAccount(params.authority));
        __ERC20_init(NAME, SYMBOL);
        __ERC20Permit_init(NAME);
        __ERC3009_init();
        __ERC20Bridgeable_init();
        __Pausable_init();
        __AccessManaged_init(params.authority);
        _setReserveAttestor(params.attestor);
        _setMinterLimitCeiling(params.minterLimitCeiling);
        _setBridgeLimits(params.bridgeMintLimit, params.bridgeBurnLimit);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Token decimals: 6, like most fiat-backed payment stablecoins.
    /// @return 6.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice EIP-712 domain version: build permit, ERC-3009 and attestation domains from {name} and this value (or
    ///         read the whole domain from {eip712Domain}, EIP-5267). It stays "1" across upgrades so that signatures
    ///         made before an upgrade remain valid, and it always equals the version {eip712Domain} reports.
    /// @dev The logic version lives in {implementationVersion}; keeping the two apart means a domain built from
    ///      `name()` and `version()` (the USDC convention) can never disagree with the domain the token verifies.
    /// @return The EIP-712 domain version.
    function version() external view returns (string memory) {
        return _EIP712Version();
    }

    /// @notice Version of the token logic behind the proxy: "1" for this implementation. Not part of any signature
    ///         domain (see {version}).
    /// @return The implementation version string.
    function implementationVersion() external pure virtual returns (string memory) {
        return "1";
    }

    // ------------------------------------------------------------------------------------------------------------
    // ERC-20 entry points with caller checks
    // ------------------------------------------------------------------------------------------------------------

    /// @notice ERC-20 `transferFrom`; additionally rejects a blocklisted or frozen spender.
    /// @param from Token owner; must be unrestricted.
    /// @param to Recipient; must be unrestricted.
    /// @param value Amount.
    /// @return True on success.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _requireUnrestricted(_msgSender());
        return super.transferFrom(from, to, value);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gasless payments with bytes signatures (EOA or ERC-1271)
    // ------------------------------------------------------------------------------------------------------------

    /// @notice EIP-2612 permit taking a `bytes` signature, so ERC-1271 smart-contract wallets can sign permits.
    /// @dev Shares the nonce sequence of the `(v, r, s)` permit. Reverts with `ERC2612ExpiredSignature` after the
    ///      deadline and with {InvalidPermitSignature} for a bad signature.
    /// @param owner Token owner and signer.
    /// @param spender Approved spender.
    /// @param value Allowance to set.
    /// @param deadline Last timestamp at which the permit is valid.
    /// @param signature 65-byte ECDSA signature (EOA owner) or ERC-1271 signature (contract owner).
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes calldata signature)
        external
    {
        require(block.timestamp <= deadline, ERC2612ExpiredSignature(deadline));
        bytes32 hash =
            _hashTypedDataV4(keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline)));
        require(SignatureChecker.isValidSignatureNowCalldata(owner, hash, signature), InvalidPermitSignature(owner));
        _approve(owner, spender, value);
    }

    /// @notice ERC-3009 `transferWithAuthorization` taking a `bytes` signature (EOA or ERC-1271 `from`).
    /// @param from Payer and signer.
    /// @param to Payee.
    /// @param value Amount.
    /// @param validAfter The authorization is valid strictly after this time.
    /// @param validBefore The authorization is valid strictly before this time.
    /// @param nonce Random 32-byte nonce chosen by the payer.
    /// @param signature Signature over the EIP-712 `TransferWithAuthorization` struct.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        bytes32 hash = _hashTypedDataV4(
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
        require(SignatureChecker.isValidSignatureNowCalldata(from, hash, signature), ERC3009InvalidSignature());
        _transferWithAuthorization(from, to, value, validAfter, validBefore, nonce);
    }

    /// @notice ERC-3009 `receiveWithAuthorization` taking a `bytes` signature; the caller must be the payee.
    /// @param from Payer and signer.
    /// @param to Payee; must be `msg.sender` (prevents front-running of the authorization).
    /// @param value Amount.
    /// @param validAfter The authorization is valid strictly after this time.
    /// @param validBefore The authorization is valid strictly before this time.
    /// @param nonce Random 32-byte nonce chosen by the payer.
    /// @param signature Signature over the EIP-712 `ReceiveWithAuthorization` struct.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        bytes32 hash = _hashTypedDataV4(
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
        require(SignatureChecker.isValidSignatureNowCalldata(from, hash, signature), ERC3009InvalidSignature());
        require(to == _msgSender(), ERC20InvalidReceiver(to));
        _transferWithAuthorization(from, to, value, validAfter, validBefore, nonce);
    }

    /// @notice ERC-3009 `cancelAuthorization` taking a `bytes` signature (EOA or ERC-1271 authorizer).
    /// @param authorizer The payer that signed the authorization being cancelled.
    /// @param nonce The nonce to burn.
    /// @param signature Signature over the EIP-712 `CancelAuthorization` struct.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)));
        require(SignatureChecker.isValidSignatureNowCalldata(authorizer, hash, signature), ERC3009InvalidSignature());
        _cancelAuthorization(authorizer, nonce);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Choke points
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Every balance change except the lawful-order paths lands here: reverts while paused and when either side
    ///      of the movement is blocklisted or frozen. The zero address stands for mint (`from`) or burn (`to`).
    function _update(address from, address to, uint256 value) internal virtual override {
        _requireNotPaused();
        if (from != address(0)) _requireUnrestricted(from);
        if (to != address(0)) _requireUnrestricted(to);
        super._update(from, to, value);
    }

    /// @dev Explicit approvals (approve, both permits) that grant a non-zero allowance are refused while paused, from
    ///      a restricted owner and towards a restricted spender. Revoking (`value == 0`) is always allowed: it moves
    ///      no value and only shrinks what a spender could take, so holders can revoke during an incident pause and
    ///      a restricted owner can still cut off its spenders. Allowance bookkeeping inside `transferFrom`
    ///      (`emitEvent == false`) is not re-checked here: `transferFrom` has already checked the spender and
    ///      `_update` checks both balances.
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal override {
        if (emitEvent && value != 0) {
            _requireNotPaused();
            _requireUnrestricted(owner);
            _requireUnrestricted(spender);
        }
        super._approve(owner, spender, value, emitEvent);
    }

    /// @dev UUPS upgrade authorisation, delegated to the AccessManager (UPGRADER, 2-day execution delay). The
    ///      `restricted` modifier sees the calldata of `upgradeToAndCall`, the external entry point.
    function _authorizeUpgrade(address) internal override restricted {}
}
