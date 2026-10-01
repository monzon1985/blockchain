// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IFlashLoanCallback} from "../interfaces/ILendingCallbacks.sol";
import {ILendingEngine, Id, MarketParams} from "../interfaces/ILendingEngine.sol";
import {MarketParamsLib} from "../libraries/MarketParamsLib.sol";
import {ISwapVenue} from "./ISwapVenue.sol";

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title FlashLiquidator
/// @notice Capital-free liquidations: borrow the loan token from the engine's flash loan, repay the borrower's debt,
///         sell the seized collateral, return the flash loan and keep the difference.
/// @dev Only the owner (the keeper's hot wallet) can start a liquidation. The callback is accepted only from the
///      engine and only while this contract's own `liquidate` is executing, which is tracked in transient storage,
///      so nobody can make the contract spend its balance through an unsolicited callback.
contract FlashLiquidator is Ownable2Step, IFlashLoanCallback {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /// @notice A liquidation to perform inside the flash loan.
    /// @param marketParams The market.
    /// @param borrower The position to liquidate.
    /// @param seizedAssets Collateral to seize (exclusive with `repaidShares`).
    /// @param repaidShares Debt shares to repay (exclusive with `seizedAssets`).
    /// @param venue Where the seized collateral is sold.
    /// @param minAmountOut Minimum loan tokens the collateral sale must return.
    struct Order {
        MarketParams marketParams;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
        ISwapVenue venue;
        uint256 minAmountOut;
    }

    /// @notice A liquidation completed.
    /// @param id The market id.
    /// @param borrower The liquidated account.
    /// @param seizedAssets Collateral seized and sold.
    /// @param repaidAssets Loan tokens repaid to the engine.
    /// @param proceeds Loan tokens received for the collateral.
    /// @param profit Loan tokens sent to the owner (before gas, which is paid in ETH).
    event Liquidation(
        Id indexed id,
        address indexed borrower,
        uint256 seizedAssets,
        uint256 repaidAssets,
        uint256 proceeds,
        uint256 profit
    );

    /// @notice Tokens were rescued by the owner.
    /// @param token The token.
    /// @param to The recipient.
    /// @param amount The amount.
    event Rescue(address indexed token, address indexed to, uint256 amount);

    /// @notice The callback came from an address other than the engine.
    /// @param caller The rejected caller.
    error NotEngine(address caller);

    /// @notice The callback arrived while no liquidation was in flight.
    error UnexpectedCallback();

    /// @notice The liquidation did not clear the owner's profit floor.
    /// @param balanceBefore Loan-token balance before the liquidation.
    /// @param balanceAfter Loan-token balance after the flash loan was repaid.
    /// @param minProfit The required profit.
    error InsufficientProfit(uint256 balanceBefore, uint256 balanceAfter, uint256 minProfit);

    /// @notice A required address was zero.
    error ZeroAddress();

    /// @dev Transient flag set only while `liquidate` runs:
    ///      keccak256(abi.encode(uint256(keccak256("isolated-lending.flash-liquidator.in-flight")) - 1)) & ~0xff.
    bytes32 private constant IN_FLIGHT_SLOT = 0x0ed2c8daaeca95ab5fe9e93a50213dd7c5e634da69723ad3b6942b42f767ef00;

    /// @notice The lending engine used for both the flash loan and the liquidation.
    ILendingEngine public immutable ENGINE;

    /// @param engine The lending engine.
    /// @param initialOwner The keeper account allowed to trigger liquidations.
    constructor(ILendingEngine engine, address initialOwner) Ownable(initialOwner) {
        require(address(engine) != address(0), ZeroAddress());
        ENGINE = engine;
    }

    /// @notice Liquidates `order.borrower` with `flashAssets` of flash-borrowed loan token and sends the profit to
    ///         the owner.
    /// @param order The liquidation to perform.
    /// @param flashAssets Loan tokens to flash-borrow; must cover the repayment (unused funds are returned).
    /// @param minProfit Minimum loan-token profit, reverting otherwise (set it to cover gas).
    /// @return profit Loan tokens sent to the owner.
    /// @dev (Slither triage, reentrancy-balance) The balance is read before the flash loan on purpose: the profit is
    ///      the balance delta across it. Re-entering `liquidate` requires the owner, and `onFlashLoan` only accepts
    ///      the engine while this call is in flight, so no third party can move the balance in between.
    // slither-disable-next-line reentrancy-balance
    function liquidate(Order calldata order, uint256 flashAssets, uint256 minProfit)
        external
        onlyOwner
        returns (uint256 profit)
    {
        IERC20 loanToken = IERC20(order.marketParams.loanToken);
        uint256 balanceBefore = loanToken.balanceOf(address(this));

        TransientSlot.BooleanSlot inFlight = IN_FLIGHT_SLOT.asBoolean();
        inFlight.tstore(true);
        ENGINE.flashLoan(address(loanToken), flashAssets, abi.encode(order));
        inFlight.tstore(false);

        uint256 balanceAfter = loanToken.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + minProfit, InsufficientProfit(balanceBefore, balanceAfter, minProfit));
        profit = balanceAfter - balanceBefore;
        if (profit != 0) loanToken.safeTransfer(owner(), profit);
    }

    /// @inheritdoc IFlashLoanCallback
    function onFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(ENGINE), NotEngine(msg.sender));
        require(IN_FLIGHT_SLOT.asBoolean().tload(), UnexpectedCallback());

        Order memory order = abi.decode(data, (Order));
        IERC20 loanToken = IERC20(order.marketParams.loanToken);
        IERC20 collateralToken = IERC20(order.marketParams.collateralToken);

        // The engine pulls the repayment with transferFrom; it can never exceed the flash-borrowed amount.
        loanToken.forceApprove(address(ENGINE), assets);
        (uint256 seized, uint256 repaidAssets) =
            ENGINE.liquidate(order.marketParams, order.borrower, order.seizedAssets, order.repaidShares, "");

        uint256 proceeds = 0;
        if (seized != 0) {
            collateralToken.forceApprove(address(order.venue), seized);
            proceeds = order.venue
                .swapExactIn(address(collateralToken), address(loanToken), seized, order.minAmountOut, address(this));
        }

        // Re-arm the allowance for the flash-loan repayment pulled by the engine after this callback returns.
        loanToken.forceApprove(address(ENGINE), assets);

        uint256 profit = proceeds > repaidAssets ? proceeds - repaidAssets : 0;
        emit Liquidation(order.marketParams.id(), order.borrower, seized, repaidAssets, proceeds, profit);
    }

    /// @notice Sends tokens held by this contract to `to`.
    /// @param token The token.
    /// @param to The recipient.
    /// @param amount The amount.
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), ZeroAddress());
        token.safeTransfer(to, amount);
        emit Rescue(address(token), to, amount);
    }
}
