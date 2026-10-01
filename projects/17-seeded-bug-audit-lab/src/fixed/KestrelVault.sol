// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { FixedPointMath } from "./lib/FixedPointMath.sol";

/// @title KestrelVault
/// @notice A native-ETH yield vault whose shares are an ERC-20 token (kETH). Deposit ETH for
///         shares, withdraw or redeem shares for ETH. The lending market values pledged kETH at
///         {convertToAssets}.
/// @dev    ERC-4626-shaped but not ERC-4626: the asset is native ETH, not an ERC-20, and the
///         ETH transfer to the receiver is an intended callback point. Rounding always favors
///         the vault. The first deposit burns {DEAD_SHARES} to a dead address, so the share
///         price can never be inflated against a near-empty supply; {deposit} also takes a
///         minimum-shares bound against front-running.
contract KestrelVault is ERC20, ReentrancyGuardTransient {
    /// @notice Shares minted to {DEAD} on the first deposit (first-depositor inflation guard).
    uint256 public constant DEAD_SHARES = 1e3;
    /// @notice Holder of the {DEAD_SHARES}; it can never redeem them.
    address public constant DEAD = address(0xdead);

    /// @notice Total ETH (wei) the vault accounts as managed assets.
    uint256 public totalManaged;

    /// @notice Emitted on deposit.
    /// @param caller Depositor.
    /// @param receiver Share recipient.
    /// @param assets ETH deposited (wei).
    /// @param shares Shares minted to `receiver`.
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    /// @notice Emitted on withdraw/redeem.
    /// @param caller Withdrawer.
    /// @param receiver ETH recipient.
    /// @param assets ETH returned (wei).
    /// @param shares Shares burned.
    event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    /// @notice Emitted when yield is accrued without minting shares.
    /// @param caller Account that sent the yield.
    /// @param assets ETH added to {totalManaged} (wei).
    event Accrued(address indexed caller, uint256 assets);

    /// @notice Thrown when an amount is zero (or a first deposit does not exceed {DEAD_SHARES}).
    error ZeroAmount();
    /// @notice Thrown when burning more shares than held.
    /// @param shares Requested shares.
    /// @param balance Available shares.
    error InsufficientShares(uint256 shares, uint256 balance);
    /// @notice Thrown when a withdrawal exceeds the managed assets.
    /// @param assets Requested wei.
    /// @param managed Managed wei.
    error InsufficientAssets(uint256 assets, uint256 managed);
    /// @notice Thrown when a deposit would mint fewer shares than the caller's minimum.
    /// @param shares Shares the deposit would mint.
    /// @param minShares Caller's minimum.
    error SlippageExceeded(uint256 shares, uint256 minShares);
    /// @notice Thrown when yield is accrued while no shares exist.
    error NoShares();
    /// @notice Thrown when the ETH transfer to the receiver fails.
    error EthTransferFailed();
    /// @notice Thrown when a price view is read while a state-changing call is in flight. [SC08]
    error ReentrantRead();

    /// @notice Deploy the vault share token.
    constructor() ERC20("Kestrel ETH Vault", "kETH") { }

    /// @notice Accrue native yield into the vault without minting shares (harvest). Raises the
    ///         share price for every holder.
    function accrue() external payable {
        require(msg.value > 0, ZeroAmount());
        require(totalSupply() != 0, NoShares());
        totalManaged += msg.value;
        emit Accrued(msg.sender, msg.value);
    }

    /// @notice Deposit ETH and mint shares (rounded down) to `receiver`.
    /// @param receiver Recipient of the minted shares.
    /// @param minShares Minimum shares the caller accepts; protects against front-running.
    /// @return shares Shares minted to `receiver`.
    function deposit(address receiver, uint256 minShares)
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        require(msg.value > 0, ZeroAmount());
        if (totalSupply() == 0) {
            require(msg.value > DEAD_SHARES, ZeroAmount());
            shares = msg.value - DEAD_SHARES;
            _mint(DEAD, DEAD_SHARES);
        } else {
            shares = _convertToShares(msg.value);
        }
        require(shares > 0 && shares >= minShares, SlippageExceeded(shares, minShares));
        totalManaged += msg.value;
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, msg.value, shares);
    }

    /// @notice Withdraw an exact ETH amount by burning the caller's shares.
    /// @param assets ETH (wei) to withdraw.
    /// @param receiver ETH recipient.
    /// @return shares Shares burned.
    function withdraw(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets > 0, ZeroAmount());
        require(assets <= totalManaged, InsufficientAssets(assets, totalManaged));
        // [SC07b] Round the shares to burn UP, in the vault's favor: any non-zero withdrawal
        // burns at least one share, so no withdrawal is free.
        shares = FixedPointMath.mulDivUp(assets, totalSupply(), totalManaged);
        require(balanceOf(msg.sender) >= shares, InsufficientShares(shares, balanceOf(msg.sender)));
        _burn(msg.sender, shares);
        totalManaged -= assets;
        _sendEth(receiver, assets);
        emit Withdraw(msg.sender, receiver, assets, shares);
    }

    /// @notice Redeem an exact number of the caller's shares for ETH (rounded down).
    /// @param shares Shares to burn.
    /// @param receiver ETH recipient.
    /// @return assets ETH (wei) returned.
    function redeem(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        require(shares > 0, ZeroAmount());
        require(balanceOf(msg.sender) >= shares, InsufficientShares(shares, balanceOf(msg.sender)));
        // The share price never falls below 1 wei (it starts at 1 and every path rounds in the
        // vault's favor), so a non-zero share count always redeems a non-zero amount.
        assets = _convertToAssets(shares);
        _burn(msg.sender, shares);
        totalManaged -= assets; // [SC08] effects before the ETH transfer: the price is never stale
        _sendEth(receiver, assets);
        emit Withdraw(msg.sender, receiver, assets, shares);
    }

    /// @notice Convert an ETH amount to shares (rounding down).
    /// @param assets ETH (wei).
    /// @return shares Corresponding shares.
    function convertToShares(uint256 assets) external view returns (uint256 shares) {
        require(!_reentrancyGuardEntered(), ReentrantRead()); // [SC08] no reads mid-operation
        shares = _convertToShares(assets);
    }

    /// @notice Convert shares to an ETH amount (rounding down).
    /// @param shares Vault shares.
    /// @return assets Corresponding ETH (wei).
    function convertToAssets(uint256 shares) external view returns (uint256 assets) {
        require(!_reentrancyGuardEntered(), ReentrantRead()); // [SC08] no reads mid-operation
        assets = _convertToAssets(shares);
    }

    /// @notice Price of 1e18 shares in ETH (wei).
    /// @return price ETH per 1e18 shares.
    function pricePerShare() external view returns (uint256 price) {
        require(!_reentrancyGuardEntered(), ReentrantRead()); // [SC08] no reads mid-operation
        price = _convertToAssets(1e18);
    }

    /// @dev Assets -> shares at the current price, rounding down.
    function _convertToShares(uint256 assets) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        shares = supply == 0 ? assets : FixedPointMath.mulDivDown(assets, supply, totalManaged);
    }

    /// @dev Shares -> assets at the current price, rounding down.
    function _convertToAssets(uint256 shares) internal view returns (uint256 assets) {
        uint256 supply = totalSupply();
        assets = supply == 0 ? shares : FixedPointMath.mulDivDown(shares, totalManaged, supply);
    }

    /// @dev Send ETH via a low-level call, reverting on failure.
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{ value: amount }("");
        require(ok, EthTransferFailed());
    }
}
