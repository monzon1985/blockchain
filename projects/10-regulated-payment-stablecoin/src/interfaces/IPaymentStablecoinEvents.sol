// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/**
 * @title IPaymentStablecoinEvents
 * @notice Events and custom errors shared by every module of the Test Payment Dollar (tPD).
 * @dev Declared once in an interface so the abstract modules can all inherit it without identifier clashes.
 *      Every error carries the values that made the call fail so off-chain tooling can explain a revert
 *      without re-simulating it.
 */
interface IPaymentStablecoinEvents {
    // ------------------------------------------------------------------------------------------------------------
    // Compliance: blocklist, freeze and lawful orders
    // ------------------------------------------------------------------------------------------------------------

    /// @notice `account` was added to the sanctions blocklist; it can no longer send, receive, approve or spend.
    /// @param account The blocklisted address.
    event Blocklisted(address indexed account);

    /// @notice `account` was removed from the sanctions blocklist.
    /// @param account The address that regained its transfer rights (unless it is also frozen).
    event UnBlocklisted(address indexed account);

    /// @notice `account` was frozen under the lawful order identified by `orderRef`.
    /// @param account The frozen address.
    /// @param orderRef Hash of the lawful order (e.g. keccak256 of the court order document) that required the freeze.
    event Frozen(address indexed account, bytes32 indexed orderRef);

    /// @notice `account` was unfrozen under the lawful order identified by `orderRef`.
    /// @param account The unfrozen address.
    /// @param orderRef Hash of the lawful order that lifted the freeze.
    event Unfrozen(address indexed account, bytes32 indexed orderRef);

    /// @notice `amount` tokens were moved out of the frozen account `from` into `to` under a lawful order.
    /// @param from The frozen account that was debited.
    /// @param to The unrestricted account that received the seized funds (e.g. a court-controlled custody wallet).
    /// @param amount The number of tokens seized (6 decimals).
    /// @param orderRef Hash of the lawful order that authorised the seizure.
    event Seized(address indexed from, address indexed to, uint256 amount, bytes32 indexed orderRef);

    /// @notice The whole balance of the frozen account `account` was destroyed under a lawful order.
    /// @param account The frozen account whose balance was burned.
    /// @param amount The number of tokens burned (6 decimals).
    /// @param orderRef Hash of the lawful order that authorised the burn.
    event FrozenFundsBurned(address indexed account, uint256 amount, bytes32 indexed orderRef);

    /// @notice The call touched `account`, which is on the sanctions blocklist.
    /// @param account The blocklisted address.
    error AccountBlocklisted(address account);

    /// @notice The call touched `account`, which is frozen under a lawful order.
    /// @param account The frozen address.
    error AccountFrozen(address account);

    /// @notice A blocklist update would not change anything (`account` is already in the requested state).
    /// @param account The address whose status was requested.
    /// @param blocklisted The status it already has.
    error BlocklistStatusUnchanged(address account, bool blocklisted);

    /// @notice A freeze update would not change anything (`account` is already in the requested state).
    /// @param account The address whose status was requested.
    /// @param frozen The status it already has.
    error FreezeStatusUnchanged(address account, bool frozen);

    /// @notice Lawful-order actions must reference the order that authorises them; `bytes32(0)` is not a reference.
    error MissingOrderReference();

    /// @notice Seizing or burning requires the source account to be frozen first.
    /// @param account The account that is not frozen.
    error AccountNotFrozen(address account);

    /// @notice `account` is not acceptable here (zero address, or otherwise invalid for the operation).
    /// @param account The rejected address.
    error InvalidAccount(address account);

    /// @notice The operation requires a non-zero amount.
    error ZeroAmount();

    // ------------------------------------------------------------------------------------------------------------
    // Minting: minter allowances, rolling limits and the bridge
    // ------------------------------------------------------------------------------------------------------------

    /// @notice `minter` was (re)configured with a remaining mint allowance and a rolling 24 h limit.
    /// @param minter The minter address.
    /// @param allowance The total amount the minter may still mint (replaces the previous value, USDC-style).
    /// @param dailyLimit The maximum amount the minter may mint in any rolling 24 h window.
    event MinterConfigured(address indexed minter, uint256 allowance, uint256 dailyLimit);

    /// @notice `minter` was removed: its allowance and rolling limit are now zero.
    /// @param minter The removed minter.
    event MinterRemoved(address indexed minter);

    /// @notice The governance ceiling on any single minter's rolling 24 h limit changed.
    /// @param ceiling The new ceiling.
    event MinterLimitCeilingSet(uint256 ceiling);

    /// @notice `minter` minted `amount` new tokens to `to`.
    /// @param minter The minter that consumed its allowance.
    /// @param to The recipient.
    /// @param amount The number of tokens minted.
    event Mint(address indexed minter, address indexed to, uint256 amount);

    /// @notice `minter` burned `amount` tokens from its own balance (redemption).
    /// @param minter The minter whose balance was burned.
    /// @param amount The number of tokens burned.
    event Burn(address indexed minter, uint256 amount);

    /// @notice The rolling 24 h limits applied to each bridge were updated.
    /// @param mintLimit Maximum `crosschainMint` volume per bridge in any rolling 24 h window.
    /// @param burnLimit Maximum `crosschainBurn` volume per bridge in any rolling 24 h window.
    event BridgeLimitsSet(uint256 mintLimit, uint256 burnLimit);

    /// @notice The caller is not a configured minter (never configured, or removed).
    /// @param minter The caller.
    error MinterNotConfigured(address minter);

    /// @notice The mint exceeds the minter's remaining allowance.
    /// @param minter The minter.
    /// @param allowance Its remaining allowance.
    /// @param amount The requested amount.
    error MinterAllowanceExceeded(address minter, uint256 allowance, uint256 amount);

    /// @notice The mint exceeds what the minter may still mint in the current rolling 24 h window.
    /// @param minter The minter.
    /// @param available What is still available in the window.
    /// @param amount The requested amount.
    error MinterRateLimitExceeded(address minter, uint256 available, uint256 amount);

    /// @notice The requested rolling limit is above the governance ceiling.
    /// @param dailyLimit The requested limit.
    /// @param ceiling The ceiling set by governance.
    error DailyLimitAboveCeiling(uint256 dailyLimit, uint256 ceiling);

    /// @notice The bridge mint exceeds what `bridge` may still mint in the current rolling 24 h window.
    /// @param bridge The bridge.
    /// @param available What is still available in the window.
    /// @param amount The requested amount.
    error BridgeMintLimitExceeded(address bridge, uint256 available, uint256 amount);

    /// @notice The bridge burn exceeds what `bridge` may still burn in the current rolling 24 h window.
    /// @param bridge The bridge.
    /// @param available What is still available in the window.
    /// @param amount The requested amount.
    error BridgeBurnLimitExceeded(address bridge, uint256 available, uint256 amount);

    // ------------------------------------------------------------------------------------------------------------
    // Reserve attestations
    // ------------------------------------------------------------------------------------------------------------

    /// @notice A new EIP-712 reserve attestation was accepted.
    /// @param reserves The attested reserves, in token units (6 decimals).
    /// @param asOf The timestamp the attestor certified the reserves at.
    /// @param reportHash Hash of the off-chain attestation report the figure comes from.
    /// @param supplyAtAttestation Token supply when the attestation was recorded.
    event ReservesAttested(uint256 reserves, uint64 asOf, bytes32 indexed reportHash, uint256 supplyAtAttestation);

    /// @notice The accepted attestation reports fewer reserves than the outstanding supply. Minting stays blocked
    ///         until a covering attestation arrives.
    /// @param reserves The attested reserves.
    /// @param supply The supply at that moment.
    event ReserveShortfall(uint256 reserves, uint256 supply);

    /// @notice The key allowed to sign reserve attestations changed.
    /// @param previousAttestor The old attestor.
    /// @param newAttestor The new attestor (EOA or ERC-1271 contract).
    event ReserveAttestorSet(address indexed previousAttestor, address indexed newAttestor);

    /// @notice The attestation is dated in the future.
    /// @param asOf The attestation timestamp.
    /// @param currentTime `block.timestamp`.
    error AttestationFromFuture(uint64 asOf, uint256 currentTime);

    /// @notice The attestation is not newer than the one already recorded (replay or out-of-order submission).
    /// @param asOf The attestation timestamp.
    /// @param latest The timestamp of the recorded attestation.
    error AttestationNotNewer(uint64 asOf, uint64 latest);

    /// @notice The attestation is already older than the maximum age and would be useless.
    /// @param asOf The attestation timestamp.
    /// @param currentTime `block.timestamp`.
    error AttestationTooOld(uint64 asOf, uint256 currentTime);

    /// @notice The signature does not come from the configured attestor.
    /// @param attestor The configured attestor.
    error InvalidAttestationSignature(address attestor);

    /// @notice Minting requires a reserve attestation and none was ever recorded.
    error NoReserveAttestation();

    /// @notice The latest attestation is older than the maximum age, so minting is blocked.
    /// @param asOf The attestation timestamp.
    /// @param currentTime `block.timestamp`.
    error StaleReserveAttestation(uint64 asOf, uint256 currentTime);

    /// @notice Minting `amount` would take the supply above the attested reserves.
    /// @param supply Current supply.
    /// @param amount Requested mint.
    /// @param reserves Attested reserves.
    error InsufficientAttestedReserves(uint256 supply, uint256 amount, uint256 reserves);

    // ------------------------------------------------------------------------------------------------------------
    // Gasless payments
    // ------------------------------------------------------------------------------------------------------------

    /// @notice The bytes-encoded permit signature is not valid for `owner` (ECDSA for EOAs, ERC-1271 for contracts).
    /// @param owner The token owner the permit claims to come from.
    error InvalidPermitSignature(address owner);
}
