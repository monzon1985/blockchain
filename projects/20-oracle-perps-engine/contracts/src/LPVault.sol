// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ILPVault} from "./interfaces/ILPVault.sol";
import {IOracleVerifier} from "./interfaces/IOracleVerifier.sol";
import {IPerpsMarket} from "./interfaces/IPerpsMarket.sol";

/// @title LPVault
/// @notice ERC-4626 share token of the market's liquidity pool, priced at pool value: LP-owned liquidity plus pending
///         borrow and funding fees minus net unrealised trader PnL, with trader profits capped at
///         `maxPnlFactor * poolAmount` (see `PerpsMarket.poolValue`).
/// @dev Entry and exit are asynchronous, in the spirit of ERC-7540: `requestDeposit` / `requestRedeem` escrow the
///      input, and a keeper settles the request with oracle reports strictly newer than it. A synchronous
///      `deposit` / `redeem` would be priced at the last on-chain price and could be front-run by anyone who sees a
///      newer off-chain price (oracle latency arbitrage against the other LPs). The synchronous ERC-4626 entry points
///      are therefore disabled and the `max*` functions return 0, which is the compliant way for an ERC-4626 vault to
///      signal it; all conversion and preview functions work as specified. Pool assets live in the market; this
///      contract holds only the escrow of pending requests (`escrowedAssets` and its own escrowed shares).
contract LPVault is ILPVault, ERC4626, AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The market that owns the pool assets.
    IPerpsMarket public immutable market;

    /// @notice Identifier the next request will receive.
    uint256 public nextRequestId = 1;

    /// @notice Assets held for pending deposits plus the execution fees of all pending requests.
    uint256 public escrowedAssets;

    /// @notice Shares held in escrow for pending redemptions.
    uint256 public escrowedShares;

    /// @dev Pending requests by identifier.
    mapping(uint256 requestId => LpRequest) private _requests;

    /// @dev Deployed by the market's constructor, so `msg.sender` is the market.
    /// @param asset_ Collateral token of the market.
    /// @param authority_ AccessManager gating `executeRequest` to keepers.
    /// @param name_ ERC-20 name of the share token.
    /// @param symbol_ ERC-20 symbol of the share token.
    constructor(IERC20 asset_, address authority_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        AccessManaged(authority_)
    {
        market = IPerpsMarket(msg.sender);
        // The market is immutable and pulls exactly the assets of the deposit it is settling (`addLiquidity`).
        asset_.forceApprove(msg.sender, type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Asynchronous entry and exit
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Requests a deposit of `assets`; shares are minted when a keeper settles the request.
    /// @param assets Collateral to deposit.
    /// @param minShares Minimum shares accepted (slippage and share-inflation guard).
    /// @param executionFee Keeper fee, at least the market's `minExecutionFee`.
    /// @return requestId Identifier of the request.
    function requestDeposit(uint256 assets, uint256 minShares, uint256 executionFee)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        // slither-disable-next-line unused-return
        (uint256 minFee,, bool isPaused) = market.requestConfig();
        require(!isPaused, MarketPaused());
        require(assets != 0, EmptyRequest());
        require(executionFee >= minFee, ExecutionFeeTooLow(executionFee, minFee));

        requestId = _storeRequest(true, assets, minShares, executionFee);
        escrowedAssets += assets + executionFee;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets + executionFee);
    }

    /// @notice Requests the redemption of `shares`; they are escrowed now and burned when a keeper settles.
    /// @param shares Shares to redeem.
    /// @param minAssets Minimum assets accepted.
    /// @param executionFee Keeper fee, at least the market's `minExecutionFee`.
    /// @return requestId Identifier of the request.
    function requestRedeem(uint256 shares, uint256 minAssets, uint256 executionFee)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        // slither-disable-next-line unused-return
        (uint256 minFee,,) = market.requestConfig();
        require(shares != 0, EmptyRequest());
        require(executionFee >= minFee, ExecutionFeeTooLow(executionFee, minFee));

        requestId = _storeRequest(false, shares, minAssets, executionFee);
        // The escrow change is carried by the LpRequestCreated event emitted in _storeRequest.
        // slither-disable-next-line events-maths
        escrowedAssets += executionFee;
        escrowedShares += shares;
        _transfer(msg.sender, address(this), shares);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), executionFee);
    }

    /// @notice Cancels an unexecuted request after the market's `orderTimeout` and refunds its escrow and fee.
    /// @param requestId Identifier of the request.
    function cancelRequest(uint256 requestId) external nonReentrant {
        LpRequest memory req = _requests[requestId];
        require(req.account != address(0), UnknownRequest(requestId));
        require(req.account == msg.sender, NotRequestOwner(msg.sender, req.account));
        // slither-disable-next-line unused-return
        (, uint256 timeout,) = market.requestConfig();
        uint256 cancellableAt = uint256(req.createdAt) + timeout;
        require(block.timestamp >= cancellableAt, CancelTooEarly(cancellableAt));

        _consume(requestId, req);
        emit LpRequestCancelled(requestId, msg.sender, "");
        _refund(req);
        IERC20(asset()).safeTransfer(req.account, req.executionFee);
    }

    /// @notice Settles a request with reports strictly newer than it. The pool is valued at the reported median.
    /// @dev A deposit mints `previewDeposit(assets)` shares computed before the assets join the pool; a redemption
    ///      pays `previewRedeem(shares)` subject to the market's free-liquidity check. Slippage or free-liquidity
    ///      failures cancel the request, refund the escrow and still pay the keeper.
    /// @param requestId Identifier of the request.
    /// @param reports Signed reports from distinct oracle signers.
    function executeRequest(uint256 requestId, IOracleVerifier.SignedPriceReport[] calldata reports)
        external
        nonReentrant
        restricted
    {
        LpRequest memory req = _requests[requestId];
        require(req.account != address(0), UnknownRequest(requestId));
        // slither-disable-next-line unused-return
        (uint256 price,) = market.refreshPrice(reports, req.createdAt);
        _consume(requestId, req);

        if (req.isDeposit) {
            uint256 shares = previewDeposit(req.amount);
            if (shares == 0 || shares < req.minOut) {
                _cancelOnFailure(requestId, req, abi.encodeWithSelector(SlippageExceeded.selector, shares, req.minOut));
            } else {
                market.addLiquidity(req.amount);
                _mint(req.account, shares);
                emit Deposit(req.account, req.account, req.amount, shares);
                emit LpRequestExecuted(requestId, msg.sender, req.amount, shares, price);
            }
        } else {
            uint256 assets = previewRedeem(req.amount);
            if (assets < req.minOut) {
                _cancelOnFailure(requestId, req, abi.encodeWithSelector(SlippageExceeded.selector, assets, req.minOut));
            } else {
                try market.removeLiquidity(assets, req.account) {
                    _burn(address(this), req.amount);
                    emit Withdraw(req.account, req.account, req.account, assets, req.amount);
                    emit LpRequestExecuted(requestId, msg.sender, req.amount, assets, price);
                } catch (bytes memory reason) {
                    require(reason.length != 0, ExecutionOutOfGas());
                    _cancelOnFailure(requestId, req, reason);
                }
            }
        }
        IERC20(asset()).safeTransfer(msg.sender, req.executionFee);
    }

    /// @notice A pending request (all zero once executed or cancelled).
    /// @param requestId Identifier.
    /// @return The stored request.
    function getRequest(uint256 requestId) external view returns (LpRequest memory) {
        return _requests[requestId];
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC-4626
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Pool value at the market's last oracle price, with fees accrued to the current block.
    /// @return Assets backing all shares, in collateral units.
    function totalAssets() public view override returns (uint256) {
        return market.poolValue();
    }

    /// @notice Always 0: synchronous deposits are disabled (see contract notes).
    /// @return 0.
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always 0: synchronous mints are disabled (see contract notes).
    /// @return 0.
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always 0: synchronous withdrawals are disabled (see contract notes).
    /// @return 0.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always 0: synchronous redemptions are disabled (see contract notes).
    /// @return 0.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Disabled; use `requestDeposit`.
    /// @return Never returns.
    function deposit(uint256, address) public pure override returns (uint256) {
        revert SynchronousEntryDisabled();
    }

    /// @notice Disabled; use `requestDeposit`.
    /// @return Never returns.
    function mint(uint256, address) public pure override returns (uint256) {
        revert SynchronousEntryDisabled();
    }

    /// @notice Disabled; use `requestRedeem`.
    /// @return Never returns.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert SynchronousEntryDisabled();
    }

    /// @notice Disabled; use `requestRedeem`.
    /// @return Never returns.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert SynchronousEntryDisabled();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------------------------

    function _storeRequest(bool isDeposit, uint256 amount, uint256 minOut, uint256 executionFee)
        private
        returns (uint256 requestId)
    {
        requestId = nextRequestId++;
        _requests[requestId] = LpRequest({
            account: msg.sender,
            isDeposit: isDeposit,
            createdAt: uint64(block.timestamp),
            amount: amount.toUint128(),
            minOut: minOut.toUint128(),
            executionFee: executionFee.toUint128()
        });
        emit LpRequestCreated(requestId, msg.sender, isDeposit, amount, minOut, executionFee);
    }

    /// @dev Removes a request and releases its accounting escrow (tokens move in `_refund` or on settlement).
    function _consume(uint256 requestId, LpRequest memory req) private {
        delete _requests[requestId];
        escrowedAssets -= (req.isDeposit ? uint256(req.amount) : 0) + req.executionFee;
        if (!req.isDeposit) escrowedShares -= req.amount;
    }

    function _cancelOnFailure(uint256 requestId, LpRequest memory req, bytes memory reason) private {
        emit LpRequestCancelled(requestId, msg.sender, reason);
        _refund(req);
    }

    function _refund(LpRequest memory req) private {
        if (req.isDeposit) {
            IERC20(asset()).safeTransfer(req.account, req.amount);
        } else {
            _transfer(address(this), req.account, req.amount);
        }
    }
}
