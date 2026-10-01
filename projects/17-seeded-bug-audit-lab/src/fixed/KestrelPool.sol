// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { FixedPointMath } from "./lib/FixedPointMath.sol";

/// @title KestrelPool
/// @notice A two-asset weighted constant-mean AMM with proportional and exact-share liquidity,
///         single and batch swap paths, an LP staking-reward accumulator, a native-currency
///         sponsored swap and a Uniswap-v2-style price accumulator.
/// @dev    Balances are upscaled to 18 decimals for the curve math. The owner (`Ownable2Step`)
///         sets the reward emission rate and withdraws the native sponsor fees.
contract KestrelPool is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using FixedPointMath for uint256;

    /// @notice 1.0 in WAD fixed point.
    uint256 internal constant WAD = 1e18;
    /// @notice Liquidity permanently locked on the first join to block inflation attacks.
    uint256 internal constant MINIMUM_LIQUIDITY = 1e3;

    /// @notice First pool asset.
    IERC20 public immutable token0;
    /// @notice Second pool asset.
    IERC20 public immutable token1;
    /// @notice Normalized weight of {token0} in WAD; `weight0 + weight1 == WAD`.
    uint256 public immutable weight0;
    /// @notice Normalized weight of {token1} in WAD.
    uint256 public immutable weight1;
    /// @notice Upscale factor for {token0} to 18 decimals (`10**(18 - decimals)`).
    uint256 public immutable scale0;
    /// @notice Upscale factor for {token1} to 18 decimals.
    uint256 public immutable scale1;
    /// @notice Reward token paid to liquidity providers by the staking accumulator.
    IERC20 public immutable rewardToken;
    /// @notice Swap fee charged on the input amount, in WAD (e.g. 0.003e18 = 0.30%).
    uint256 public immutable swapFee;
    /// @notice Fixed native-currency fee retained by {swapWithNativeSponsor}, in wei.
    uint256 public immutable nativeSwapFee;

    /// @notice Tracked reserve of {token0} (native units).
    uint256 public reserve0;
    /// @notice Tracked reserve of {token1} (native units).
    uint256 public reserve1;
    /// @notice Total LP shares outstanding.
    uint256 public totalShares;
    /// @notice LP shares held by each provider.
    mapping(address account => uint256 shares) public sharesOf;

    /// @notice Native fees accrued through {swapWithNativeSponsor} and not yet withdrawn, in wei.
    uint256 public nativeFeesCollected;

    /// @notice Time-weighted accumulator of {spotPrice0In1}, WAD-seconds.
    uint256 public priceCumulativeLast;
    /// @notice Timestamp at which {priceCumulativeLast} was last synced.
    uint256 public blockTimestampLast;

    // --- Reward accumulator state ---
    /// @notice Reward emission rate in reward-token units per second.
    uint256 public rewardRate;
    /// @notice Reward tokens available to be paid out.
    uint256 public rewardReserve;
    /// @notice Accumulated reward per LP share, WAD-scaled.
    uint256 public rewardPerShareStored;
    /// @notice Timestamp of the last reward accumulator update.
    uint256 public lastRewardUpdate;
    /// @notice Reward-per-share already credited to each account, WAD-scaled.
    mapping(address account => uint256 checkpoint) public rewardPerSharePaid;
    /// @notice Reward tokens owed to each account.
    mapping(address account => uint256 owed) public rewardsOwed;

    /// @notice A step in a {batchSwap}: swap `amountIn` of `assets[assetInIndex]` for
    ///         `assets[assetOutIndex]`.
    /// @param assetInIndex Index into the caller's `assets` array of the input token.
    /// @param assetOutIndex Index into the caller's `assets` array of the output token.
    /// @param amountIn Input amount for this step, in the input token's native units.
    struct BatchStep {
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amountIn;
    }

    /// @notice Emitted when liquidity is added.
    /// @param provider Account credited with the minted LP shares.
    /// @param amount0 {token0} deposited.
    /// @param amount1 {token1} deposited.
    /// @param shares LP shares minted.
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    /// @notice Emitted when liquidity is removed.
    /// @param provider Account that removed liquidity.
    /// @param amount0 {token0} withdrawn.
    /// @param amount1 {token1} withdrawn.
    /// @param shares LP shares burned.
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    /// @notice Emitted on every executed swap (single or per batch step).
    /// @param trader Account that received the output.
    /// @param tokenIn Input token.
    /// @param tokenOut Output token.
    /// @param amountIn Input amount.
    /// @param amountOut Output amount.
    event Swap(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    /// @notice Emitted when the reward emission rate changes.
    /// @param newRate New reward rate in reward-token units per second.
    event RewardRateSet(uint256 newRate);
    /// @notice Emitted when the reward reserve is funded.
    /// @param funder Account that funded the reserve.
    /// @param amount Reward tokens added.
    event RewardsFunded(address indexed funder, uint256 amount);
    /// @notice Emitted when a provider claims staking rewards.
    /// @param account Provider that claimed.
    /// @param amount Reward tokens paid.
    event RewardClaimed(address indexed account, uint256 amount);
    /// @notice Emitted when a sponsored swap retains the native fee.
    /// @param payer Account that paid the fee.
    /// @param fee Wei retained.
    event NativeFeeCollected(address indexed payer, uint256 fee);
    /// @notice Emitted when the owner withdraws native fees.
    /// @param to Recipient.
    /// @param amount Wei withdrawn.
    event NativeFeesWithdrawn(address indexed to, uint256 amount);

    /// @notice Thrown when a deposit or swap amount is zero.
    error ZeroAmount();
    /// @notice Thrown when a proportional join is not balanced against current reserves.
    /// @param expected1 The {token1} amount implied by `amount0`.
    /// @param provided1 The {token1} amount the caller offered.
    error UnbalancedJoin(uint256 expected1, uint256 provided1);
    /// @notice Thrown when a swap's output falls below the caller's minimum.
    /// @param out Actual output.
    /// @param minOut Requested minimum.
    error InsufficientOutput(uint256 out, uint256 minOut);
    /// @notice Thrown when an address is not one of the pool's two tokens.
    /// @param token The offending address.
    error UnknownToken(address token);
    /// @notice Thrown when a batch is malformed: fewer than two assets, an out-of-range index or
    ///         a step whose input and output index are equal.
    error BadAssetIndex();
    /// @notice Thrown when {batchSwap} lists the same asset twice. [SC05]
    /// @param asset The repeated asset.
    error DuplicateAsset(address asset);
    /// @notice Thrown when burning more LP shares than the caller holds.
    /// @param shares Requested shares.
    /// @param balance Available shares.
    error InsufficientShares(uint256 shares, uint256 balance);
    /// @notice Thrown when an exact-share join asks for more shares than the Q128 math supports.
    /// @param shares Requested shares.
    error SharesTooLarge(uint256 shares);
    /// @notice Thrown when an exact-share join costs more than the caller's maxima.
    /// @param amount0 {token0} required.
    /// @param amount1 {token1} required.
    /// @param maxAmount0 {token0} maximum accepted.
    /// @param maxAmount1 {token1} maximum accepted.
    error SlippageExceeded(uint256 amount0, uint256 amount1, uint256 maxAmount0, uint256 maxAmount1);
    /// @notice Thrown when an exact-share join is attempted before the first liquidity.
    error EmptyPool();
    /// @notice Thrown when the native fee sent is below {nativeSwapFee}.
    /// @param sent Value sent.
    /// @param required Value required.
    error InsufficientNativeFee(uint256 sent, uint256 required);
    /// @notice Thrown when the native-currency refund of a sponsored swap fails. [SC06]
    error RefundFailed();
    /// @notice Thrown when a native fee withdrawal transfer fails.
    error NativeTransferFailed();
    /// @notice Thrown when withdrawing more native fees than were collected.
    /// @param amount Requested wei.
    /// @param available Collected wei.
    error ExceedsNativeFees(uint256 amount, uint256 available);
    /// @notice Thrown when a recipient address is zero.
    error InvalidRecipient();

    /// @notice Deploy a pool over `_token0`/`_token1` with the given weights and fees.
    /// @param _token0 First asset.
    /// @param _token1 Second asset.
    /// @param _weight0 Normalized weight of `_token0` in WAD; `_weight1 = WAD - _weight0`.
    /// @param _rewardToken Token paid by the LP staking accumulator.
    /// @param _swapFee Swap fee on input, in WAD (below 10%).
    /// @param _nativeSwapFee Fixed native fee for {swapWithNativeSponsor}, in wei.
    constructor(
        IERC20 _token0,
        IERC20 _token1,
        uint256 _weight0,
        IERC20 _rewardToken,
        uint256 _swapFee,
        uint256 _nativeSwapFee
    ) Ownable(msg.sender) {
        require(address(_token0) != address(0) && address(_token1) != address(0), UnknownToken(address(0)));
        require(address(_token0) != address(_token1), UnknownToken(address(_token1)));
        require(_weight0 > 0 && _weight0 < WAD, ZeroAmount());
        require(_swapFee < WAD / 10, ZeroAmount());
        token0 = _token0;
        token1 = _token1;
        weight0 = _weight0;
        weight1 = WAD - _weight0;
        scale0 = 10 ** (18 - IERC20Metadata(address(_token0)).decimals());
        scale1 = 10 ** (18 - IERC20Metadata(address(_token1)).decimals());
        rewardToken = _rewardToken;
        swapFee = _swapFee;
        nativeSwapFee = _nativeSwapFee;
        lastRewardUpdate = block.timestamp;
        blockTimestampLast = block.timestamp;
    }

    /// @notice Read the price accumulator brought up to the current block.
    /// @return cumulative {spotPrice0In1} integrated over time, WAD-seconds.
    /// @return timestamp The current block timestamp.
    function observe() external view returns (uint256 cumulative, uint256 timestamp) {
        timestamp = block.timestamp;
        cumulative = priceCumulativeLast;
        uint256 elapsed = timestamp - blockTimestampLast;
        if (elapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            cumulative += spotPrice0In1() * elapsed;
        }
    }

    // ---------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------

    /// @notice Add liquidity. The first join seeds the reserves; later joins must match the
    ///         current reserve ratio exactly.
    /// @param amount0 {token0} to deposit.
    /// @param amount1 {token1} to deposit.
    /// @param to Recipient of the minted LP shares.
    /// @return shares LP shares minted to `to`.
    function addLiquidity(uint256 amount0, uint256 amount1, address to)
        external
        nonReentrant
        returns (uint256 shares)
    {
        require(amount0 > 0 && amount1 > 0, ZeroAmount());
        _syncOracle();
        _updateReward(to);
        uint256 _totalShares = totalShares;
        if (_totalShares == 0) {
            shares = FixedPointMathLib.sqrt(amount0 * amount1);
            require(shares > MINIMUM_LIQUIDITY, ZeroAmount());
            unchecked {
                // Safe: `shares > MINIMUM_LIQUIDITY` was just checked.
                shares -= MINIMUM_LIQUIDITY;
            }
            _mintShares(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            // Proportional join: amount1 must match the ratio implied by amount0.
            uint256 expected1 = FixedPointMath.mulDivDown(amount0, reserve1, reserve0);
            require(expected1 == amount1, UnbalancedJoin(expected1, amount1));
            shares = FixedPointMath.mulDivDown(amount0, _totalShares, reserve0);
        }
        require(shares > 0, ZeroAmount());
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
        _mintShares(to, shares);
        emit LiquidityAdded(to, amount0, amount1, shares);
    }

    /// @notice Mint an exact number of LP shares, paying the pro-rata amount of each reserve
    ///         rounded up, in the pool's favor. The pro-rata ratio is computed in Q128 fixed
    ///         point, as in concentrated-liquidity position math.
    /// @param shares LP shares to mint.
    /// @param maxAmount0 Maximum {token0} the caller accepts to pay.
    /// @param maxAmount1 Maximum {token1} the caller accepts to pay.
    /// @param to Recipient of the minted shares.
    /// @return amount0 {token0} paid.
    /// @return amount1 {token1} paid.
    function addLiquidityExactShares(uint256 shares, uint256 maxAmount0, uint256 maxAmount1, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(shares > 0, ZeroAmount());
        uint256 _totalShares = totalShares;
        require(_totalShares > 0, EmptyPool());
        _syncOracle();
        _updateReward(to);
        (uint256 sharesX128, bool overflow) = FixedPointMath.checkedShl(shares, 128);
        require(!overflow, SharesTooLarge(shares));
        uint256 ratioX128 = FixedPointMath.mulDivUp(sharesX128, 1, _totalShares);
        amount0 = FixedPointMath.mulDivUp(reserve0, ratioX128, FixedPointMath.Q128);
        amount1 = FixedPointMath.mulDivUp(reserve1, ratioX128, FixedPointMath.Q128);
        require(
            amount0 <= maxAmount0 && amount1 <= maxAmount1,
            SlippageExceeded(amount0, amount1, maxAmount0, maxAmount1)
        );
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
        _mintShares(to, shares);
        emit LiquidityAdded(to, amount0, amount1, shares);
    }

    /// @notice Remove liquidity proportionally.
    /// @param shares LP shares to burn.
    /// @param to Recipient of the withdrawn tokens.
    /// @return amount0 {token0} returned.
    /// @return amount1 {token1} returned.
    function removeLiquidity(uint256 shares, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(shares > 0, ZeroAmount());
        require(sharesOf[msg.sender] >= shares, InsufficientShares(shares, sharesOf[msg.sender]));
        _syncOracle();
        _updateReward(msg.sender);
        uint256 _totalShares = totalShares;
        amount0 = FixedPointMath.mulDivDown(shares, reserve0, _totalShares);
        amount1 = FixedPointMath.mulDivDown(shares, reserve1, _totalShares);
        require(amount0 > 0 && amount1 > 0, ZeroAmount());
        _burnShares(msg.sender, shares);
        reserve0 -= amount0;
        reserve1 -= amount1;
        token0.safeTransfer(to, amount0);
        token1.safeTransfer(to, amount1);
        emit LiquidityRemoved(msg.sender, amount0, amount1, shares);
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    /// @notice Swap an exact input amount for as much output as the curve allows, net of fee.
    /// @param tokenIn Input token (must be {token0} or {token1}).
    /// @param amountIn Input amount.
    /// @param minOut Minimum acceptable output.
    /// @param to Output recipient.
    /// @return out Output amount transferred to `to`.
    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        nonReentrant
        returns (uint256 out)
    {
        require(amountIn > 0, ZeroAmount());
        out = _executeSwap(tokenIn, amountIn, to);
        require(out >= minOut, InsufficientOutput(out, minOut));
    }

    /// @notice Swap while sponsoring the transaction with native currency: a fixed
    ///         {nativeSwapFee} is retained and any overpayment is refunded to the caller.
    /// @param tokenIn Input token.
    /// @param amountIn Input amount.
    /// @param minOut Minimum acceptable output.
    /// @param to Output recipient.
    /// @return out Output amount transferred to `to`.
    function swapWithNativeSponsor(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        require(amountIn > 0, ZeroAmount());
        require(msg.value >= nativeSwapFee, InsufficientNativeFee(msg.value, nativeSwapFee));
        out = _executeSwap(tokenIn, amountIn, to);
        require(out >= minOut, InsufficientOutput(out, minOut));

        nativeFeesCollected += nativeSwapFee;
        emit NativeFeeCollected(msg.sender, nativeSwapFee);
        uint256 refund = msg.value - nativeSwapFee;
        if (refund > 0) {
            // [SC06] Check the refund: a failed refund reverts the swap instead of stranding ETH.
            (bool ok,) = msg.sender.call{ value: refund }("");
            require(ok, RefundFailed());
        }
    }

    /// @notice Execute a sequence of swaps over an explicit asset list, settling net deltas.
    /// @param assets The tokens referenced by `steps`, by index.
    /// @param steps The ordered swap steps.
    /// @param to Recipient of any net output tokens.
    /// @return deltas Signed settlement per `assets` entry: positive = paid by the caller,
    ///         negative = paid to `to`.
    function batchSwap(address[] calldata assets, BatchStep[] calldata steps, address to)
        external
        nonReentrant
        returns (int256[] memory deltas)
    {
        uint256 n = assets.length;
        require(n >= 2, BadAssetIndex());
        _syncOracle();
        // [SC05] Reject duplicated assets, so each token has exactly one running balance and
        // settlement writes each reserve once.
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                require(assets[i] != assets[j], DuplicateAsset(assets[i]));
            }
        }
        uint256[] memory bal = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            bal[i] = _reserveOf(assets[i]);
        }

        deltas = new int256[](n);
        uint256 stepCount = steps.length;
        for (uint256 s = 0; s < stepCount; ++s) {
            _applyBatchStep(assets, bal, deltas, steps[s], to);
        }

        // Settle: write back reserves and move net tokens.
        for (uint256 i = 0; i < n; ++i) {
            _setReserveOf(assets[i], bal[i]);
        }
        for (uint256 i = 0; i < n; ++i) {
            int256 d = deltas[i];
            if (d > 0) {
                IERC20(assets[i]).safeTransferFrom(msg.sender, address(this), SafeCast.toUint256(d));
            } else if (d < 0) {
                IERC20(assets[i]).safeTransfer(to, SafeCast.toUint256(-d));
            }
        }
    }

    /// @notice Quote the single-swap output for `amountIn` of `tokenIn` at the current reserves.
    /// @param tokenIn Input token.
    /// @param amountIn Input amount.
    /// @return out Output {swap} would return now (fee charged, rounded down).
    function getAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 out) {
        (address tokenOut, bool zeroForOne) = _counterparty(tokenIn);
        (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        out = _outGivenInScaled(tokenIn, tokenOut, rIn, rOut, _netOfFee(amountIn)) / _scaleOf(tokenOut);
    }

    // ---------------------------------------------------------------------
    // Rewards and fees
    // ---------------------------------------------------------------------

    /// @notice Fund the staking-reward reserve.
    /// @param amount Reward tokens to pull from the caller.
    function fundRewards(uint256 amount) external nonReentrant {
        require(amount > 0, ZeroAmount());
        _globalRewardUpdate();
        rewardReserve += amount;
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(msg.sender, amount);
    }

    /// @notice Set the reward emission rate.
    /// @dev Owner only. [SC01]
    /// @param newRate New reward rate in reward-token units per second.
    function setRewardRate(uint256 newRate) external onlyOwner {
        _globalRewardUpdate();
        rewardRate = newRate;
        emit RewardRateSet(newRate);
    }

    /// @notice Claim accrued staking rewards (capped by the reserve).
    /// @return amount Reward tokens paid to the caller.
    function claimReward() external nonReentrant returns (uint256 amount) {
        _updateReward(msg.sender);
        amount = rewardsOwed[msg.sender];
        if (amount > rewardReserve) {
            amount = rewardReserve;
        }
        if (amount > 0) {
            rewardsOwed[msg.sender] -= amount;
            rewardReserve -= amount;
            rewardToken.safeTransfer(msg.sender, amount);
        }
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice Withdraw collected native sponsor fees. Owner only.
    /// @param to Recipient (non-zero).
    /// @param amount Wei to withdraw (at most {nativeFeesCollected}).
    function withdrawNativeFees(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(to != address(0), InvalidRecipient());
        uint256 available = nativeFeesCollected;
        require(amount <= available, ExceedsNativeFees(amount, available));
        nativeFeesCollected = available - amount;
        emit NativeFeesWithdrawn(to, amount);
        (bool ok,) = to.call{ value: amount }("");
        require(ok, NativeTransferFailed());
    }

    /// @notice Preview the rewards currently claimable by `account` (before the reserve cap).
    /// @param account Provider to preview.
    /// @return owed Reward tokens accrued to `account`.
    function earned(address account) external view returns (uint256 owed) {
        uint256 perShare = rewardPerShareStored;
        if (totalShares > 0) {
            uint256 elapsed = block.timestamp - lastRewardUpdate;
            perShare += FixedPointMath.mulDivDown(rewardRate * elapsed, WAD, totalShares);
        }
        owed = rewardsOwed[account]
            + FixedPointMath.mulDivDown(sharesOf[account], perShare - rewardPerSharePaid[account], WAD);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Current tracked reserves.
    /// @return r0 {token0} reserve.
    /// @return r1 {token1} reserve.
    function getReserves() external view returns (uint256 r0, uint256 r1) {
        return (reserve0, reserve1);
    }

    /// @notice Instantaneous spot price of {token0} denominated in {token1}, WAD-scaled.
    /// @dev Spot reflects the current reserves, which any swap moves within a block. Price
    ///      consumers must use a time-weighted average or an external oracle instead.
    /// @return price WAD price: {token1} per 1e18 of {token0} (decimal-normalized).
    function spotPrice0In1() public view returns (uint256 price) {
        uint256 bal0 = reserve0 * scale0;
        uint256 bal1 = reserve1 * scale1;
        // spot = (bal1 / weight1) / (bal0 / weight0)
        uint256 num = FixedPointMath.mulDivDown(bal1, weight0, weight1);
        price = FixedPointMath.divWadDown(num, bal0);
    }

    // ---------------------------------------------------------------------
    // Internal: swap math
    // ---------------------------------------------------------------------

    /// @dev Advance the TWAP accumulator using the OLD reserves over the elapsed time, then
    ///      stamp the current time. Must be called before reserves change.
    function _syncOracle() internal {
        uint256 ts = block.timestamp;
        uint256 elapsed = ts - blockTimestampLast;
        if (elapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            priceCumulativeLast += spotPrice0In1() * elapsed;
        }
        blockTimestampLast = ts;
    }

    /// @dev Execute a single swap (fee charged, output rounded down) and settle it.
    function _executeSwap(address tokenIn, uint256 amountIn, address to) internal returns (uint256 out) {
        _syncOracle();
        (address tokenOut, bool zeroForOne) = _counterparty(tokenIn);
        uint256 rIn = zeroForOne ? reserve0 : reserve1;
        uint256 rOut = zeroForOne ? reserve1 : reserve0;
        out = _outGivenInScaled(tokenIn, tokenOut, rIn, rOut, _netOfFee(amountIn)) / _scaleOf(tokenOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (zeroForOne) {
            reserve0 = rIn + amountIn;
            reserve1 = rOut - out;
        } else {
            reserve1 = rIn + amountIn;
            reserve0 = rOut - out;
        }
        IERC20(tokenOut).safeTransfer(to, out);
        emit Swap(to, tokenIn, tokenOut, amountIn, out);
    }

    /// @dev Price one {batchSwap} step against the running balances and record its deltas.
    function _applyBatchStep(
        address[] calldata assets,
        uint256[] memory bal,
        int256[] memory deltas,
        BatchStep calldata step,
        address to
    ) internal {
        uint256 n = assets.length;
        uint256 iIn = step.assetInIndex;
        uint256 iOut = step.assetOutIndex;
        require(iIn < n && iOut < n && iIn != iOut, BadAssetIndex());
        uint256 amountIn = step.amountIn;
        require(amountIn > 0, ZeroAmount());
        address aIn = assets[iIn];
        address aOut = assets[iOut];
        uint256 outAmt = _batchStepOut(aIn, aOut, bal[iIn], bal[iOut], amountIn);
        bal[iIn] += amountIn;
        bal[iOut] -= outAmt;
        deltas[iIn] += SafeCast.toInt256(amountIn);
        deltas[iOut] -= SafeCast.toInt256(outAmt);
        emit Swap(to, aIn, aOut, amountIn, outAmt);
    }

    /// @dev Output of one batch step of `amountIn` against the running balances.
    function _batchStepOut(address aIn, address aOut, uint256 balIn, uint256 balOut, uint256 amountIn)
        internal
        view
        returns (uint256 outAmt)
    {
        // [SC02] Charge the swap fee exactly as the single-swap path does.
        uint256 amountInNet = _netOfFee(amountIn);
        uint256 outScaled = _outGivenInScaled(aIn, aOut, balIn, balOut, amountInNet);
        uint256 scaleOut = _scaleOf(aOut);
        // [SC07a] Downscale rounding DOWN, toward the pool, as the single-swap path does.
        outAmt = outScaled / scaleOut;
    }

    /// @dev Input amount net of the swap fee (fee rounded up, in the pool's favor).
    function _netOfFee(uint256 amountIn) internal view returns (uint256 net) {
        net = amountIn - FixedPointMath.mulWadUp(amountIn, swapFee);
    }

    /// @dev Weighted constant-mean "out given in" on 18-decimal upscaled balances. Returns the
    ///      output in 18-decimal units; callers downscale it.
    /// @param tokenIn Input token.
    /// @param tokenOut Output token.
    /// @param reserveIn Input reserve (native units).
    /// @param reserveOut Output reserve (native units).
    /// @param amountInNet Input amount after fees (native units).
    /// @return outScaled Output amount, upscaled to 18 decimals.
    function _outGivenInScaled(
        address tokenIn,
        address tokenOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountInNet
    ) internal view returns (uint256 outScaled) {
        (uint256 sIn, uint256 wIn) = _scaleWeight(tokenIn);
        (uint256 sOut, uint256 wOut) = _scaleWeight(tokenOut);
        uint256 balIn = reserveIn * sIn;
        uint256 balOut = reserveOut * sOut;
        uint256 amtInScaled = amountInNet * sIn;
        // base = balIn / (balIn + amtIn) in WAD (<= 1).
        uint256 base = FixedPointMath.divWadDown(balIn, balIn + amtInScaled);
        // exponent = wIn / wOut in WAD.
        uint256 exponent = FixedPointMath.divWadDown(wIn, wOut);
        uint256 power = base.powWad(exponent);
        // outScaled = balOut * (1 - power).
        outScaled = FixedPointMath.mulWadDown(balOut, WAD - power);
    }

    // ---------------------------------------------------------------------
    // Internal: reserves, shares, rewards
    // ---------------------------------------------------------------------

    /// @dev Return the tracked reserve of `token` (must be a pool token).
    function _reserveOf(address token) internal view returns (uint256) {
        if (token == address(token0)) return reserve0;
        if (token == address(token1)) return reserve1;
        revert UnknownToken(token);
    }

    /// @dev Write the tracked reserve of `token`. Callers pass only tokens already validated by
    ///      {_reserveOf} or {_counterparty}, so anything but {token0} is {token1}.
    function _setReserveOf(address token, uint256 value) internal {
        if (token == address(token0)) {
            reserve0 = value;
        } else {
            reserve1 = value;
        }
    }

    /// @dev Return the counterparty token and whether `tokenIn` is {token0}.
    function _counterparty(address tokenIn) internal view returns (address tokenOut, bool zeroForOne) {
        zeroForOne = tokenIn == address(token0);
        require(zeroForOne || tokenIn == address(token1), UnknownToken(tokenIn));
        tokenOut = zeroForOne ? address(token1) : address(token0);
    }

    /// @dev Return the scale factor and normalized weight for a pool token. Callers pass only
    ///      validated pool tokens, so anything but {token0} is {token1}.
    function _scaleWeight(address token) internal view returns (uint256 scale, uint256 weight) {
        (scale, weight) = token == address(token0) ? (scale0, weight0) : (scale1, weight1);
    }

    /// @dev Return the 18-decimal upscale factor of a pool token.
    function _scaleOf(address token) internal view returns (uint256 scale) {
        (scale,) = _scaleWeight(token);
    }

    /// @dev Mint LP shares (the caller settles rewards for `to` first).
    function _mintShares(address to, uint256 shares) internal {
        totalShares += shares;
        sharesOf[to] += shares;
    }

    /// @dev Burn LP shares from `from`.
    function _burnShares(address from, uint256 shares) internal {
        sharesOf[from] -= shares;
        totalShares -= shares;
    }

    /// @dev Advance the global reward-per-share accumulator to `block.timestamp`.
    function _globalRewardUpdate() internal {
        uint256 _totalShares = totalShares;
        if (_totalShares > 0) {
            uint256 elapsed = block.timestamp - lastRewardUpdate;
            if (elapsed > 0 && rewardRate > 0) {
                rewardPerShareStored += FixedPointMath.mulDivDown(rewardRate * elapsed, WAD, _totalShares);
            }
        }
        lastRewardUpdate = block.timestamp;
    }

    /// @dev Settle `account`'s owed rewards and checkpoint them.
    function _updateReward(address account) internal {
        _globalRewardUpdate();
        uint256 stored = rewardPerShareStored;
        rewardsOwed[
            account
        ] += FixedPointMath.mulDivDown(sharesOf[account], stored - rewardPerSharePaid[account], WAD);
        rewardPerSharePaid[account] = stored;
    }
}
