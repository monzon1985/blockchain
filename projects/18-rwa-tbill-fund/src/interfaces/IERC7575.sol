// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IERC7575
/// @notice ERC-7575 vault entry point: the ERC-4626 surface without the ERC-20 methods, plus `share()`.
/// @dev `type(IERC7575).interfaceId == 0x2f0a18c5` (ERC-165 itself is excluded from the id).
interface IERC7575 {
    /// @notice Emitted when claimed `assets` are exchanged for `shares` minted to `owner`.
    /// @param sender For ERC-7540 claims: the controller of the request.
    /// @param owner Receiver of the shares.
    /// @param assets Assets consumed.
    /// @param shares Shares issued.
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /// @notice Emitted when claimed `shares` are exchanged for `assets` sent to `receiver`.
    /// @param sender Caller.
    /// @param receiver Receiver of the assets.
    /// @param owner For ERC-7540 claims: the controller of the request.
    /// @param assets Assets paid out.
    /// @param shares Shares consumed.
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /// @notice Underlying asset accepted by the vault.
    /// @return assetTokenAddress Asset address.
    function asset() external view returns (address assetTokenAddress);

    /// @notice External share token issued by the vault.
    /// @return shareTokenAddress Share token address.
    function share() external view returns (address shareTokenAddress);

    /// @notice Converts assets to shares at the last settled NAV, rounding down.
    /// @param assets Asset amount.
    /// @return shares Share amount.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts shares to assets at the last settled NAV, rounding down.
    /// @param shares Share amount.
    /// @return assets Asset amount.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Total assets under management, valued at the last settled NAV.
    /// @return totalManagedAssets Asset amount.
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice Assets `receiver` (as controller) can currently claim through `deposit`.
    /// @param receiver Controller to query.
    /// @return maxAssets Claimable assets.
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /// @notice Unsupported for asynchronous deposit flows; always reverts.
    /// @param assets Ignored.
    /// @return shares Never returned.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Claims `assets` of a settled deposit request of `msg.sender` and mints the shares to `receiver`.
    /// @param assets Claimed assets.
    /// @param receiver Share receiver.
    /// @return shares Shares minted.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Shares `receiver` (as controller) can currently claim through `mint`.
    /// @param receiver Controller to query.
    /// @return maxShares Claimable shares.
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /// @notice Unsupported for asynchronous deposit flows; always reverts.
    /// @param shares Ignored.
    /// @return assets Never returned.
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Claims `shares` of a settled deposit request of `msg.sender` and mints them to `receiver`.
    /// @param shares Shares to mint.
    /// @param receiver Share receiver.
    /// @return assets Assets consumed from the claimable balance.
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Assets `owner` (as controller) can currently claim through `withdraw`.
    /// @param owner Controller to query.
    /// @return maxAssets Claimable assets.
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /// @notice Unsupported for asynchronous redemption flows; always reverts.
    /// @param assets Ignored.
    /// @return shares Never returned.
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Claims `assets` of a settled redeem request of `controller`.
    /// @param assets Assets to pay out.
    /// @param receiver Asset receiver.
    /// @param controller Controller of the request.
    /// @return shares Shares consumed from the claimable balance.
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Shares `owner` (as controller) can currently claim through `redeem`.
    /// @param owner Controller to query.
    /// @return maxShares Claimable shares.
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /// @notice Unsupported for asynchronous redemption flows; always reverts.
    /// @param shares Ignored.
    /// @return assets Never returned.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Claims `shares` of a settled redeem request of `controller`.
    /// @param shares Shares to redeem.
    /// @param receiver Asset receiver.
    /// @param controller Controller of the request.
    /// @return assets Assets paid out.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
}

/// @title IERC7575Share
/// @notice Share-token side of ERC-7575: asset-to-vault lookup.
/// @dev `type(IERC7575Share).interfaceId == 0xf815c03d`.
interface IERC7575Share {
    /// @notice Emitted when the vault serving `asset` changes.
    /// @param asset Asset.
    /// @param vault New vault (zero to unset).
    event VaultUpdate(address indexed asset, address vault);

    /// @notice Vault entry point that issues this share for `asset`.
    /// @param asset Asset.
    /// @return vaultAddress Vault address, or zero.
    function vault(address asset) external view returns (address vaultAddress);
}
