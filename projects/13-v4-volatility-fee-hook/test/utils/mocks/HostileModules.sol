// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILiquidityModule} from "../../../src/interfaces/ILiquidityModule.sol";
import {IVolatilityFeeHook} from "../../../src/interfaces/IVolatilityFeeHook.sol";

/// @dev Common base: records how many times the module completed successfully.
abstract contract ModuleBase is ILiquidityModule {
    uint256 public completedCalls;
}

/// @notice Always reverts with a custom error.
contract RevertingModule is ModuleBase {
    error ModuleDown();

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
        pure
    {
        revert ModuleDown();
    }
}

/// @notice Burns every unit of gas it is given (infinite loop writing storage).
contract GasGuzzlerModule is ModuleBase {
    uint256 public sink;

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        while (true) {
            ++sink;
        }
    }
}

/// @notice Reverts with ~150 KB of return data to make a naive caller pay for copying it (a "return bomb").
contract ReturnBombModule is ModuleBase {
    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
        pure
    {
        // Revert with 150,000 bytes of (zeroed) memory; expanding memory to that size costs ~57k gas here.
        assembly ("memory-safe") {
            revert(0, 150000)
        }
    }
}

/// @notice Takes 1 wei out of the PoolManager and never settles it. Inside somebody's unlock this would leave their
/// transaction unsettled; at delivery time the PoolManager is locked, so `take` itself reverts.
contract DanglingDeltaModule is ModuleBase {
    IPoolManager internal immutable manager;
    Currency internal immutable currency;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        manager.take(currency, address(this), 1);
        ++completedCalls;
    }
}

/// @notice Mints itself an ERC-6909 claim without paying for it (another unsettled delta).
contract ClaimMintModule is ModuleBase {
    IPoolManager internal immutable manager;
    Currency internal immutable currency;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        manager.mint(address(this), currency.toId(), 1);
        ++completedCalls;
    }
}

/// @notice Moves the PoolManager's `sync` checkpoint to another currency. `sync` is callable while the PoolManager is
/// locked, so this module succeeds at delivery; the checkpoint only lives in the delivering transaction, and every
/// settlement re-syncs before paying.
contract SyncHijackModule is ModuleBase {
    IPoolManager internal immutable manager;
    Currency internal immutable currency;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        manager.sync(currency);
        ++completedCalls;
    }
}

/// @notice Opens an unlock of its own at delivery and leaves a delta open in it: the PoolManager reverts that unlock
/// with CurrencyNotSettled, which only fails this module's own call.
contract UnsettledUnlockModule is ModuleBase, IUnlockCallback {
    IPoolManager internal immutable manager;
    Currency internal immutable currency;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        manager.unlock("");
        ++completedCalls;
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        manager.take(currency, address(this), 1);
        return "";
    }
}

/// @notice Tries to escalate privileges: swap itself out of the hook.
contract PrivilegeEscalationModule is ModuleBase {
    IVolatilityFeeHook internal immutable hook;

    constructor(IVolatilityFeeHook hook_) {
        hook = hook_;
    }

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        hook.setLiquidityModule(ILiquidityModule(address(0)));
        ++completedCalls;
    }
}

/// @notice Flash-borrows from the PoolManager inside an unlock of its own and repays it before the unlock ends:
/// net-zero accounting, so the delivery succeeds (no false positives).
contract FlashRepayModule is ModuleBase, IUnlockCallback {
    IPoolManager internal immutable manager;
    Currency internal immutable currency;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function onLiquidityModified(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta)
        external
    {
        manager.unlock("");
        ++completedCalls;
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        manager.take(currency, address(this), 1e6);
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(manager), 1e6);
        manager.settle();
        return "";
    }
}

/// @notice Well-behaved module that counts notifications (control case).
contract CountingModule is ModuleBase {
    int256 public netLiquidity;

    function onLiquidityModified(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta
    ) external {
        netLiquidity += params.liquidityDelta;
        ++completedCalls;
    }
}

/// @notice Tries to trade in the hook's own pool from inside the liquidity notification (without settling).
contract NestedSwapModule is ModuleBase {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function onLiquidityModified(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta
    ) external {
        manager.swap(key, SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 4_295_128_740}), "");
        ++completedCalls;
    }
}

/// @notice The external review's count-neutral attack on the old in-unlock sandbox. It takes 1 wei (its own delta
/// becomes non-zero, open-delta count +1) and pays off another party's open debt with sync + transfer + settleFor
/// (that delta becomes zero, count -1, sync checkpoint cleared). The three PoolManager words the old sandbox compared
/// were unchanged, yet the unlock could no longer settle. With the queue it never runs inside an unlock at all.
contract CountNeutralModule is ModuleBase {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    address internal immutable victim;

    constructor(IPoolManager manager_, address victim_) {
        manager = manager_;
        victim = victim_;
    }

    function onLiquidityModified(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta
    ) external {
        int256 debt = manager.currencyDelta(victim, key.currency0);
        if (debt >= 0) return;
        manager.take(key.currency1, address(this), 1);
        manager.sync(key.currency0);
        IERC20(Currency.unwrap(key.currency0)).transfer(address(manager), uint256(-debt));
        manager.settleFor(victim);
        ++completedCalls;
    }
}
