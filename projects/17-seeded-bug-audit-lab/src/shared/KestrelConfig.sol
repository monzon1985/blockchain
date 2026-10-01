// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IKestrelConfig } from "./IKestrelConfig.sol";

/// @title KestrelConfig
/// @notice Upgradeable risk-parameter store for the Kestrel lending market (loan-to-value and
///         the reference ETH price), deployed behind {KestrelProxy}. A risk owner manages the
///         parameters; ownership moves in two steps.
/// @dev    Storage uses the sequential, pre-ERC-7201 layout of many deployed upgradeable
///         contracts, with an initializer modelled on OpenZeppelin Contracts 3.x
///         (`_initialized` / `_initializing` packed into slot 0). Deploy it only behind a
///         proxy that keeps its own state out of the sequential slots (EIP-1967).
///
///         The implementation contract locks its own initializer in the constructor (the
///         equivalent of `_disableInitializers`), so only proxies can be initialized.
contract KestrelConfig is IKestrelConfig {
    /// @notice Upper bound for {ltvBps}: 90%.
    uint256 public constant MAX_LTV_BPS = 9000;

    /// @notice Slot 0, byte 0: whether {initialize} has completed.
    bool private _initialized;
    /// @notice Slot 0, byte 1: whether {initialize} is executing.
    bool private _initializing;
    /// @inheritdoc IKestrelConfig
    /// @dev Slot 1.
    uint256 public ltvBps;
    /// @inheritdoc IKestrelConfig
    /// @dev Slot 2.
    uint256 public ethPrice;
    /// @notice Slot 3: account allowed to change the risk parameters.
    address public owner;
    /// @notice Slot 4: account that may accept ownership.
    address public pendingOwner;

    /// @notice Emitted once, when the proxy is initialized.
    /// @param owner Initial risk owner.
    /// @param ltvBps Initial loan-to-value.
    /// @param ethPrice Initial ETH reference price.
    event Initialized(address indexed owner, uint256 ltvBps, uint256 ethPrice);
    /// @notice Emitted when the loan-to-value changes.
    /// @param ltvBps New loan-to-value in basis points.
    event LtvSet(uint256 ltvBps);
    /// @notice Emitted when the ETH reference price changes.
    /// @param ethPrice New price, WAD.
    event EthPriceSet(uint256 ethPrice);
    /// @notice Emitted when an ownership transfer is started.
    /// @param owner Current owner.
    /// @param pendingOwner Account that may accept.
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    /// @notice Emitted when ownership changes.
    /// @param previousOwner Previous owner.
    /// @param newOwner New owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Thrown when {initialize} runs a second time.
    error AlreadyInitialized();
    /// @notice Thrown when a caller other than the owner (or pending owner) acts.
    /// @param caller The unauthorized caller.
    error Unauthorized(address caller);
    /// @notice Thrown when the loan-to-value is zero or above {MAX_LTV_BPS}.
    /// @param ltvBps The rejected value.
    error InvalidLtv(uint256 ltvBps);
    /// @notice Thrown when the ETH price is zero.
    error InvalidPrice();
    /// @notice Thrown when an owner address is zero.
    error ZeroAddress();

    /// @dev OpenZeppelin 3.x-style initializer guard over the slot-0 flags.
    modifier initializer() {
        require(_initializing || !_initialized, AlreadyInitialized());
        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }
        _;
        if (isTopLevelCall) {
            _initializing = false;
        }
    }

    /// @dev Restrict to {owner}.
    modifier onlyOwner() {
        require(msg.sender == owner, Unauthorized(msg.sender));
        _;
    }

    /// @notice Lock the implementation contract so it can never be initialized directly.
    constructor() {
        _initialized = true;
    }

    /// @notice Initialize the proxy's storage. Callable once.
    /// @param owner_ Risk owner.
    /// @param ltvBps_ Loan-to-value in basis points (1..{MAX_LTV_BPS}).
    /// @param ethPrice_ Debt-token value of 1 ETH, WAD (non-zero).
    function initialize(address owner_, uint256 ltvBps_, uint256 ethPrice_) external initializer {
        require(owner_ != address(0), ZeroAddress());
        owner = owner_;
        _setLtv(ltvBps_);
        _setEthPrice(ethPrice_);
        emit Initialized(owner_, ltvBps_, ethPrice_);
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Change the loan-to-value. Owner only.
    /// @param newLtvBps New loan-to-value in basis points (1..{MAX_LTV_BPS}).
    function setLtvBps(uint256 newLtvBps) external onlyOwner {
        _setLtv(newLtvBps);
    }

    /// @notice Change the ETH reference price. Owner only.
    /// @param newPrice New debt-token value of 1 ETH, WAD (non-zero).
    function setEthPrice(uint256 newPrice) external onlyOwner {
        _setEthPrice(newPrice);
    }

    /// @notice Start a two-step ownership transfer. Owner only.
    /// @param newOwner Account that may accept ownership.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), ZeroAddress());
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete a two-step ownership transfer. Pending owner only.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, Unauthorized(msg.sender));
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @notice Implementation version tag.
    /// @return tag A human-readable version string.
    function version() external pure returns (string memory tag) {
        tag = "KestrelConfig-1";
    }

    /// @dev Validate and store the loan-to-value.
    function _setLtv(uint256 newLtvBps) private {
        require(newLtvBps > 0 && newLtvBps <= MAX_LTV_BPS, InvalidLtv(newLtvBps));
        ltvBps = newLtvBps;
        emit LtvSet(newLtvBps);
    }

    /// @dev Validate and store the ETH price.
    function _setEthPrice(uint256 newPrice) private {
        require(newPrice != 0, InvalidPrice());
        ethPrice = newPrice;
        emit EthPriceSet(newPrice);
    }
}
