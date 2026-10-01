// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IERC7540Operator
/// @notice ERC-7540 operator approvals. `type(IERC7540Operator).interfaceId == 0xe3bc4e65`.
interface IERC7540Operator {
    /// @notice Emitted when `controller` approves or revokes `operator`.
    /// @param controller Account granting the approval.
    /// @param operator Account approved or revoked.
    /// @param approved New status.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Grants or revokes `operator` the right to manage requests and claims of `msg.sender`.
    /// @param operator Operator.
    /// @param approved New status.
    /// @return success Always true; reverts on failure.
    function setOperator(address operator, bool approved) external returns (bool success);

    /// @notice Whether `operator` may act for `controller`.
    /// @param controller Controller.
    /// @param operator Operator.
    /// @return status Approval status.
    function isOperator(address controller, address operator) external view returns (bool status);
}

/// @title IERC7540Deposit
/// @notice ERC-7540 asynchronous deposit requests. `type(IERC7540Deposit).interfaceId == 0xce3bbe50`.
interface IERC7540Deposit {
    /// @notice Emitted when `assets` are locked into a deposit request for `controller`.
    /// @param controller Controller of the request.
    /// @param owner Account the assets were pulled from.
    /// @param requestId Request id (0: requests are aggregated per controller).
    /// @param sender Caller.
    /// @param assets Assets requested.
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Pulls `assets` from `owner` into a deposit request controlled by `controller`.
    /// @param assets Assets to lock.
    /// @param controller Controller of the request.
    /// @param owner Asset owner; must be `msg.sender` or have approved it as operator.
    /// @return requestId Request id (always 0).
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Assets of `controller` in requests that are not yet claimable.
    /// @param requestId Must be 0.
    /// @param controller Controller.
    /// @return pendingAssets Pending assets.
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);

    /// @notice Assets of `controller` in settled requests that can be claimed.
    /// @param requestId Must be 0.
    /// @param controller Controller.
    /// @return claimableAssets Claimable assets.
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableAssets);

    /// @notice Claims `assets` of `controller`'s settled deposits, minting the shares to `receiver`.
    /// @param assets Claimed assets.
    /// @param receiver Share receiver.
    /// @param controller Controller.
    /// @return shares Shares minted.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Claims `shares` of `controller`'s settled deposits, minting them to `receiver`.
    /// @param shares Shares to mint.
    /// @param receiver Share receiver.
    /// @param controller Controller.
    /// @return assets Assets consumed.
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);
}

/// @title IERC7540Redeem
/// @notice ERC-7540 asynchronous redemption requests. `type(IERC7540Redeem).interfaceId == 0x620ee8e4`.
interface IERC7540Redeem {
    /// @notice Emitted when `shares` are taken into a redeem request for `controller`.
    /// @param controller Controller of the request.
    /// @param owner Account the shares were taken from.
    /// @param requestId Request id (0: requests are aggregated per controller).
    /// @param sender Caller.
    /// @param shares Shares requested.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @notice Takes `shares` from `owner` into a redeem request controlled by `controller`.
    /// @param shares Shares to redeem.
    /// @param controller Controller of the request.
    /// @param owner Share owner; `msg.sender` must be the owner, an operator, or hold an ERC-20 allowance.
    /// @return requestId Request id (always 0).
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @notice Shares of `controller` in requests that are not yet claimable.
    /// @param requestId Must be 0.
    /// @param controller Controller.
    /// @return pendingShares Pending shares.
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);

    /// @notice Shares of `controller` in settled requests that can be claimed.
    /// @param requestId Must be 0.
    /// @param controller Controller.
    /// @return claimableShares Claimable shares.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);
}
