// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Paymaster} from "@openzeppelin/contracts/account/paymaster/Paymaster.sol";
import {PaymasterERC20} from "@openzeppelin/contracts/account/paymaster/extensions/PaymasterERC20.sol";
import {
    PaymasterERC20Guarantor
} from "@openzeppelin/contracts/account/paymaster/extensions/PaymasterERC20Guarantor.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/ERC4337Utils.sol";
import {IEntryPoint, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title TokenPaymaster
/// @author Passkey Smart Account contributors
/// @notice ERC-4337 v0.9 paymaster that charges gas in one ERC-20 (TestUSD locally) at an owner-set price.
/// @dev Built on OpenZeppelin 5.7 {PaymasterERC20} (pre-charge in validation, refund in postOp, unused-postOp-gas
/// penalty priced in) and {PaymasterERC20Guarantor}. Two modes, selected by the first byte of `paymasterData`:
///
/// - `0x00` user-funded: the sender must have approved this paymaster; the worst-case cost is pulled during
///   validation and the unused part is refunded in postOp.
/// - `0x01` sponsor-guaranteed: an off-chain sponsor key signs `SponsorGuarantee(userOpHash, validUntil, validAfter)`
///   and the signature travels in the EntryPoint v0.9 `paymasterSignature` suffix (excluded from the user op hash).
///   The paymaster fronts the prefund from its own token float and pulls the actual cost from the sender in postOp.
///   This lets a brand-new account approve the paymaster inside its very first, gasless, operation. If the sender does
///   not pay, the paymaster absorbs the cost that the sponsor authorized.
///
/// Guarantees are self-funded (the guarantor is this contract) so that validation only touches storage associated
/// with the sender or the paymaster, which keeps both modes inside the ERC-7562 rules for a staked paymaster.
///
/// postOp griefing protections: the full worst case is collected before execution (so a sender that drains its
/// balance or revokes its allowance mid-operation cannot make the paymaster lose the charge), `paymasterPostOpGasLimit`
/// must lie in `[MIN_POST_OP_GAS, MAX_POST_OP_GAS]` (so postOp cannot starve, and the penalty exposure is bounded), and
/// the EntryPoint's 10% unused-postOp-gas penalty is charged to the sender.
contract TokenPaymaster is PaymasterERC20Guarantor, EIP712, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Mode byte for user-funded operations.
    bytes1 public constant MODE_USER_FUNDED = 0x00;

    /// @notice Mode byte for sponsor-guaranteed operations.
    bytes1 public constant MODE_GUARANTEED = 0x01;

    /// @notice Lowest accepted `paymasterPostOpGasLimit`: enough for a guaranteed postOp (pull + refund + event).
    uint256 public constant MIN_POST_OP_GAS = 60_000;

    /// @notice Highest accepted `paymasterPostOpGasLimit`, bounding the unused-gas penalty a sender can trigger.
    uint256 public constant MAX_POST_OP_GAS = 200_000;

    /// @notice Lower bound on the owner-set price, in token units per 1e18 wei (1 TUSD per ETH).
    uint256 public constant MIN_TOKEN_PER_NATIVE = 1e6;

    /// @notice Upper bound on the owner-set price, in token units per 1e18 wei (10 million TUSD per ETH).
    uint256 public constant MAX_TOKEN_PER_NATIVE = 1e13;

    /// @notice EIP-712 typehash signed by the sponsor to guarantee one user operation.
    bytes32 public constant SPONSOR_GUARANTEE_TYPEHASH =
        keccak256("SponsorGuarantee(bytes32 userOpHash,uint48 validUntil,uint48 validAfter)");

    /// @notice The EntryPoint this paymaster serves.
    // slither-disable-next-line naming-convention
    IEntryPoint private immutable _ENTRY_POINT;

    /// @notice The only token accepted for gas payment.
    // slither-disable-next-line naming-convention
    IERC20 public immutable TOKEN;

    /// @notice Price: token units charged per 1e18 wei of gas cost (i.e. per ETH).
    uint256 public tokenPerNative;

    /// @notice Key allowed to sign sponsor guarantees (zero disables guaranteed mode).
    address public sponsorSigner;

    /// @notice Emitted when the owner changes the price.
    /// @param oldPrice Previous token units per ETH.
    /// @param newPrice New token units per ETH.
    event TokenPriceUpdated(uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when the owner changes the sponsor key.
    /// @param oldSigner Previous sponsor key.
    /// @param newSigner New sponsor key (zero disables guarantees).
    event SponsorSignerUpdated(address indexed oldSigner, address indexed newSigner);

    /// @notice Emitted when the owner withdraws accumulated tokens.
    /// @param recipient Receiver of the tokens.
    /// @param amount Amount withdrawn (`type(uint256).max` means the full balance).
    event TokensWithdrawn(address indexed recipient, uint256 amount);

    /// @notice The price is outside `[MIN_TOKEN_PER_NATIVE, MAX_TOKEN_PER_NATIVE]`.
    /// @param price The rejected price.
    error PriceOutOfBounds(uint256 price);

    /// @notice A zero address was supplied where it is not allowed.
    error ZeroAddress();

    /// @notice Deploys the paymaster.
    /// @param entryPoint_ The EntryPoint (v0.9).
    /// @param token_ The gas token.
    /// @param owner_ Admin: price, sponsor key, deposit/stake and token withdrawals.
    /// @param initialTokenPerNative Initial price in token units per ETH.
    constructor(IEntryPoint entryPoint_, IERC20 token_, address owner_, uint256 initialTokenPerNative)
        EIP712("TokenPaymaster", "1")
        Ownable(owner_)
    {
        require(address(entryPoint_) != address(0) && address(token_) != address(0), ZeroAddress());
        _ENTRY_POINT = entryPoint_;
        TOKEN = token_;
        _setTokenPrice(initialTokenPerNative);
        // Self-allowance used when this contract acts as its own guarantor (see contract NatSpec).
        token_.forceApprove(address(this), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Sets the gas price in token units per ETH.
    /// @param newTokenPerNative The new price.
    function setTokenPrice(uint256 newTokenPerNative) external onlyOwner {
        _setTokenPrice(newTokenPerNative);
    }

    /// @notice Sets the key that signs sponsor guarantees.
    /// @param newSigner The new key, or zero to disable guaranteed mode (zero is a valid, intentional value).
    // forge-lint: disable-next-line(missing-zero-check)
    function setSponsorSigner(address newSigner) external onlyOwner {
        emit SponsorSignerUpdated(sponsorSigner, newSigner);
        // slither-disable-next-line missing-zero-check
        sponsorSigner = newSigner;
    }

    /// @notice Adds ETH to this paymaster's EntryPoint deposit. Anyone may top up.
    function deposit() external payable {
        _deposit(msg.value);
    }

    /// @notice Withdraws ETH from the EntryPoint deposit.
    /// @param to Receiver.
    /// @param amount Amount in wei.
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _withdraw(to, amount);
    }

    /// @notice Adds stake (required by ERC-7562 for a paymaster that reads its own storage during validation).
    /// @param unstakeDelaySec Unstake delay in seconds.
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        _addStake(msg.value, unstakeDelaySec);
    }

    /// @notice Starts the unstake delay.
    function unlockStake() external onlyOwner {
        _unlockStake();
    }

    /// @notice Withdraws the stake after the unstake delay.
    /// @param to Receiver.
    function withdrawStake(address payable to) external onlyOwner {
        _withdrawStake(to);
    }

    /// @notice Withdraws accumulated gas tokens.
    /// @param recipient Receiver.
    /// @param amount Amount, or `type(uint256).max` for the whole balance.
    function withdrawTokens(address recipient, uint256 amount) external onlyOwner {
        require(recipient != address(0), ZeroAddress());
        _withdrawTokens(TOKEN, recipient, amount);
        emit TokensWithdrawn(recipient, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc Paymaster
    function entryPoint() public view override returns (IEntryPoint) {
        return _ENTRY_POINT;
    }

    /// @notice EIP-712 digest the sponsor signs for a guaranteed operation.
    /// @param userOpHash The EntryPoint v0.9 user operation hash (excludes the paymaster signature).
    /// @param validUntil Last timestamp at which the guarantee is valid (0 = no expiry).
    /// @param validAfter Timestamp after which the guarantee is valid.
    /// @return The digest to sign.
    function sponsorGuaranteeDigest(bytes32 userOpHash, uint48 validUntil, uint48 validAfter)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(SPONSOR_GUARANTEE_TYPEHASH, userOpHash, validUntil, validAfter)));
    }

    /// @notice Converts a native gas cost to the token amount this paymaster would charge at the current price.
    /// @param nativeCost Cost in wei.
    /// @return Token units, rounded up.
    function quote(uint256 nativeCost) external view returns (uint256) {
        return _erc20Cost(nativeCost, tokenPerNative);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // PaymasterERC20 hooks
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Parses the mode, enforces the postOp gas bounds and, in guaranteed mode, checks the sponsor signature.
    /// Invalid input returns `SIG_VALIDATION_FAILED` instead of reverting (ERC-7562 reputation friendly).
    /// No `block.timestamp` read: the guarantee window is returned as validation data for the EntryPoint to enforce.
    function _fetchDetails(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        view
        override
        returns (uint256 validationData, IERC20 token, uint256 tokenPrice)
    {
        token = TOKEN;
        tokenPrice = tokenPerNative;
        uint256 postOpGasLimit = ERC4337Utils.paymasterPostOpGasLimit(userOp);
        bytes calldata data = ERC4337Utils.paymasterData(userOp);
        if (postOpGasLimit < MIN_POST_OP_GAS || postOpGasLimit > MAX_POST_OP_GAS || data.length == 0) {
            return (ERC4337Utils.SIG_VALIDATION_FAILED, token, tokenPrice);
        }
        if (data[0] == MODE_USER_FUNDED && data.length == 1) {
            return (ERC4337Utils.SIG_VALIDATION_SUCCESS, token, tokenPrice);
        }
        if (data[0] != MODE_GUARANTEED || data.length != 13) {
            return (ERC4337Utils.SIG_VALIDATION_FAILED, token, tokenPrice);
        }
        uint48 validUntil = uint48(bytes6(data[1:7]));
        uint48 validAfter = uint48(bytes6(data[7:13]));
        address signer = sponsorSigner;
        // The third return (the error argument) is not needed: the RecoverError enum is checked instead.
        // slither-disable-next-line unused-return
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(
            sponsorGuaranteeDigest(userOpHash, validUntil, validAfter), ERC4337Utils.paymasterSignature(userOp)
        );
        bool ok = signer != address(0) && err == ECDSA.RecoverError.NoError && recovered == signer;
        return (ERC4337Utils.packValidationData(ok, validAfter, validUntil), token, tokenPrice);
    }

    /// @dev Guaranteed operations are fronted by this contract itself; `_fetchDetails` already verified the sponsor
    /// signature (the Guarantor extension only calls this after a successful `_fetchDetails`).
    function _fetchGuarantor(PackedUserOperation calldata userOp) internal view override returns (address) {
        bytes calldata data = ERC4337Utils.paymasterData(userOp);
        return (data.length == 13 && data[0] == MODE_GUARANTEED) ? address(this) : address(0);
    }

    /// @dev Rejects prices so low that small operations would round to a zero charge.
    function _minTokensPerNative() internal pure override returns (uint256) {
        return MIN_TOKEN_PER_NATIVE;
    }

    function _setTokenPrice(uint256 newTokenPerNative) private {
        require(
            newTokenPerNative >= MIN_TOKEN_PER_NATIVE && newTokenPerNative <= MAX_TOKEN_PER_NATIVE,
            PriceOutOfBounds(newTokenPerNative)
        );
        emit TokenPriceUpdated(tokenPerNative, newTokenPerNative);
        tokenPerNative = newTokenPerNative;
    }
}
