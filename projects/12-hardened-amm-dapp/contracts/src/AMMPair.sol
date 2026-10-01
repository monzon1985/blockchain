// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Uniswap v2-core UniswapV2Pair.sol (GPL-3.0-or-later); see the "License" section of the README.
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IAMMCallee} from "./interfaces/IAMMCallee.sol";
import {IAMMFactory} from "./interfaces/IAMMFactory.sol";
import {IAMMPair} from "./interfaces/IAMMPair.sol";

/// @title AMMPair
/// @notice Constant-product pair, behaviourally equivalent to the canonical UniswapV2Pair for every
///         mint / burn / swap / skim / sync sequence (checked by differential fuzzing against its bytecode),
///         except for the hardening documented in DEVIATIONS.md.
/// @dev The LP token is a Solady ERC-20 with EIP-2612 permit. `token0`/`token1` are immutables read from the
///      factory's transient parameters during construction, so there is no `initialize` function and the
///      init code (hence the CREATE2 address) does not depend on the tokens.
contract AMMPair is IAMMPair, ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IAMMPair
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Value a flash-swap callee must return from `ammSwapCall`.
    bytes32 public constant CALLBACK_SUCCESS = keccak256("IAMMCallee.ammSwapCall");

    /// @dev keccak256("Hardened AMM LP"), precomputed for the EIP-712 domain (Solady fast path).
    bytes32 private constant _NAME_HASH = keccak256("Hardened AMM LP");

    /// @inheritdoc IAMMPair
    address public immutable factory;

    /// @inheritdoc IAMMPair
    address public immutable token0;

    /// @inheritdoc IAMMPair
    address public immutable token1;

    /// @notice Token0 reserve; packed with `reserve1` and `blockTimestampLast` into one slot.
    uint112 private reserve0;

    /// @notice Token1 reserve.
    uint112 private reserve1;

    /// @notice Block timestamp (mod 2^32) of the last reserve update.
    uint32 private blockTimestampLast;

    /// @inheritdoc IAMMPair
    uint256 public price0CumulativeLast;

    /// @inheritdoc IAMMPair
    uint256 public price1CumulativeLast;

    /// @inheritdoc IAMMPair
    uint256 public kLast;

    /// @notice Reads the token pair from the deploying factory.
    constructor() {
        factory = msg.sender;
        (token0, token1) = IAMMFactory(msg.sender).parameters();
    }

    // ------------------------------------------------------------------------------------------------------
    // ERC-20 metadata
    // ------------------------------------------------------------------------------------------------------

    /// @notice LP token name. Constant across pairs, like Uniswap v2 ("Uniswap V2").
    /// @return The token name.
    function name() public pure override returns (string memory) {
        return "Hardened AMM LP";
    }

    /// @notice LP token symbol.
    /// @return The token symbol.
    function symbol() public pure override returns (string memory) {
        return "HAMM-LP";
    }

    /// @dev Precomputed name hash for the EIP-712 domain separator.
    function _constantNameHash() internal pure override returns (bytes32) {
        return _NAME_HASH;
    }

    /// @dev LP tokens do not grant the Permit2 contract an implicit infinite allowance: allowances behave
    ///      exactly like the canonical pair's (spenders need `approve` or `permit`).
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    // ------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAMMPair
    function getReserves()
        external
        view
        nonReentrantView
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @inheritdoc IAMMPair
    function isLocked() external view returns (bool locked) {
        return _reentrancyGuardEntered();
    }

    // ------------------------------------------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAMMPair
    // slither-disable-next-line incorrect-equality -- totalSupply == 0 only before the first mint (1000 LP are locked forever)
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1) = (reserve0, reserve1);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        // Checked subtraction: a balance below its reserve (negative rebase) reverts, as in the canonical pair.
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply(); // read after _mintFee, which can mint
        if (_totalSupply == 0) {
            uint256 rootK = FixedPointMathLib.sqrt(amount0 * amount1);
            require(rootK > MINIMUM_LIQUIDITY, InsufficientLiquidityMinted(0));
            liquidity = rootK - MINIMUM_LIQUIDITY;
            // Permanently lock the first MINIMUM_LIQUIDITY units so that the LP share price can never be
            // inflated from a 1-wei supply (first-depositor / donation attack).
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = FixedPointMathLib.min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        }
        require(liquidity > 0, InsufficientLiquidityMinted(liquidity));
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        // forge-lint: disable-next-line(reentrancy-events) -- nonReentrant: no call can interleave with this log
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @inheritdoc IAMMPair
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1) = (reserve0, reserve1);
        IERC20 _token0 = IERC20(token0);
        IERC20 _token1 = IERC20(token1);
        uint256 balance0 = _token0.balanceOf(address(this));
        uint256 balance1 = _token1.balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply(); // read after _mintFee, which can mint
        // Pro-rata on balances (not reserves), rounded down in favour of the remaining LPs.
        amount0 = liquidity * balance0 / _totalSupply;
        amount1 = liquidity * balance1 / _totalSupply;
        require(amount0 > 0 && amount1 > 0, InsufficientLiquidityBurned(amount0, amount1));
        _burn(address(this), liquidity);
        _token0.safeTransfer(to, amount0);
        _token1.safeTransfer(to, amount1);
        balance0 = _token0.balanceOf(address(this));
        balance1 = _token1.balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        // forge-lint: disable-next-line(reentrancy-events) -- nonReentrant: no call can interleave with this log
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // ------------------------------------------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAMMPair
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign -- flash-swap design; nonReentrant + k checked after the callback
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, InsufficientOutputAmount());
        (uint112 _reserve0, uint112 _reserve1) = (reserve0, reserve1);
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            InsufficientLiquidity(amount0Out, amount1Out, _reserve0, _reserve1)
        );

        uint256 balance0;
        uint256 balance1;
        {
            // Scope keeps the token handles off the stack for the k check below.
            IERC20 _token0 = IERC20(token0);
            IERC20 _token1 = IERC20(token1);
            require(to != address(_token0) && to != address(_token1), InvalidTo(to));
            if (amount0Out > 0) _token0.safeTransfer(to, amount0Out); // optimistic transfer
            if (amount1Out > 0) _token1.safeTransfer(to, amount1Out); // optimistic transfer
            if (data.length > 0) {
                require(to.code.length != 0, CallbackTargetNotContract(to));
                // Optimistic transfer + callback before the reserve update is the flash-swap design: the lock is
                // held (every entry point and getReserves() revert on reentry) and k is enforced afterwards.
                // forge-lint: disable-next-line(reentrancy-no-eth)
                bytes32 magic = IAMMCallee(to).ammSwapCall(msg.sender, amount0Out, amount1Out, data);
                require(magic == CALLBACK_SUCCESS, InvalidCallbackReturn(magic));
            }
            balance0 = _token0.balanceOf(address(this));
            balance1 = _token1.balanceOf(address(this));
        }

        // amountIn = whatever arrived on top of (reserve - amountOut). amountOut < reserve, so no underflow.
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, InsufficientInputAmount());
        {
            // 0.30 % fee: the input side is charged 3/1000 before the product is compared with the old k.
            uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
            uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
            uint256 balanceProduct = balance0Adjusted * balance1Adjusted;
            uint256 reserveProduct = uint256(_reserve0) * _reserve1 * 1_000_000;
            require(balanceProduct >= reserveProduct, K(balanceProduct, reserveProduct));
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        // forge-lint: disable-next-line(reentrancy-events) -- nonReentrant: no call can interleave with this log
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // ------------------------------------------------------------------------------------------------------
    // Balance reconciliation
    // ------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAMMPair
    function skim(address to) external nonReentrant {
        IERC20 _token0 = IERC20(token0);
        IERC20 _token1 = IERC20(token1);
        _token0.safeTransfer(to, _token0.balanceOf(address(this)) - reserve0);
        _token1.safeTransfer(to, _token1.balanceOf(address(this)) - reserve1);
    }

    /// @inheritdoc IAMMPair
    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    // ------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------

    /// @dev Writes balances into the reserves and, on the first update of a block, accrues the TWAP accumulators.
    // slither-disable-next-line divide-before-multiply,timestamp -- bit-exact Uniswap v2 TWAP accumulators
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, Overflow(balance0, balance1));
        // Truncation to 32 bits is intentional: identical to Uniswap v2's `block.timestamp % 2**32`.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 blockTimestamp = uint32(block.timestamp);
        unchecked {
            // Safe by design: the elapsed time is computed modulo 2^32, so it stays correct when the 32-bit
            // timestamp wraps (year 2106), provided consecutive updates are less than ~136 years apart.
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                // UQ112x112 price: (r1 << 112) / r0 < 2^224, times a 32-bit duration < 2^256, so the products
                // cannot overflow. Only the accumulators wrap, and consumers difference them modulo 2^256.
                // Dividing before multiplying is required for bit-exact Uniswap v2 accumulators (the price is a
                // truncated UQ112x112 value that is then scaled by the elapsed time).
                // forge-lint: disable-next-line(divide-before-multiply)
                price0CumulativeLast += ((uint256(_reserve1) << 112) / _reserve0) * timeElapsed;
                // forge-lint: disable-next-line(divide-before-multiply)
                price1CumulativeLast += ((uint256(_reserve0) << 112) / _reserve1) * timeElapsed;
            }
        }
        // Both balances were checked against type(uint112).max above, so the casts cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint112 newReserve0, uint112 newReserve1) = (uint112(balance0), uint112(balance1));
        (reserve0, reserve1, blockTimestampLast) = (newReserve0, newReserve1, blockTimestamp);
        // forge-lint: disable-next-line(reentrancy-events) -- called only from nonReentrant entry points
        emit Sync(newReserve0, newReserve1);
    }

    /// @dev If the protocol fee is on, mints feeTo the equivalent of 1/6 of the growth in sqrt(k) since the
    ///      last liquidity event. Identical formula to Uniswap v2.
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IAMMFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = FixedPointMathLib.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = FixedPointMathLib.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply() * (rootK - rootKLast);
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }
}
