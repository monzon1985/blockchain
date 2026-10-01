// SPDX-License-Identifier: AGPL-3.0-only
// This file extends a16z's AGPL-3.0 ERC-4626 property suite (https://github.com/a16z/erc4626-tests), so it is
// licensed AGPL-3.0 as well. Production code in src/ is MIT and does not depend on it.
pragma solidity 0.8.37;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC4626 as OzIERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20 as OzIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";

import {AllocatorVault} from "../../src/AllocatorVault.sol";
import {VaultRoles} from "../../src/access/VaultRoles.sol";
import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockLiquidStrategy, MockLossyStrategy} from "../mocks/MockStrategies.sol";

/// @notice Wires `AllocatorVault` (with non-zero fees) into the a16z ERC-4626 property suite with `_delta_ = 0`:
///         every preview, max and round-trip property must hold exactly.
abstract contract A16zAllocatorVaultBase is ERC4626Test {
    MockERC20 internal token;
    AllocatorVault internal allocatorVault;
    MockLiquidStrategy internal liquid;
    MockLossyStrategy internal lossy;

    function _decimals() internal pure virtual returns (uint8);

    function setUp() public virtual override {
        token = new MockERC20("Mock", "MOCK", _decimals());
        AccessManager manager = new AccessManager(address(this));
        allocatorVault = new AllocatorVault(
            AllocatorVault.InitParams({
                asset: OzIERC20(address(token)),
                name: "Curated Vault",
                symbol: "cV",
                authority: address(manager),
                feeRecipient: address(0xFEE),
                performanceFee: 0.1e18,
                managementFee: 0.01e18,
                maxSharePriceGrowthPerYear: 0.25e18
            })
        );
        VaultRoles.configure(manager, address(allocatorVault));
        manager.grantRole(VaultRoles.CURATOR, address(this), 0);
        manager.grantRole(VaultRoles.ALLOCATOR, address(this), 0);

        liquid = new MockLiquidStrategy(OzIERC20(address(token)));
        lossy = new MockLossyStrategy(OzIERC20(address(token)));
        allocatorVault.submitCap(liquid, type(uint128).max);
        allocatorVault.submitCap(lossy, type(uint128).max);
        vm.warp(block.timestamp + allocatorVault.TIMELOCK());
        allocatorVault.acceptCap(liquid);
        allocatorVault.acceptCap(lossy);

        _underlying_ = address(token);
        _vault_ = address(allocatorVault);
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = false;
    }
}

/// @notice Idle-only vault, yield and loss applied to the vault's own balance (the suite's default `setUpYield`).
contract A16zAllocatorVault6DecimalsTest is A16zAllocatorVaultBase {
    function _decimals() internal pure override returns (uint8) {
        return 6;
    }
}

/// @notice Idle-only vault, 8 decimals.
contract A16zAllocatorVault8DecimalsTest is A16zAllocatorVaultBase {
    function _decimals() internal pure override returns (uint8) {
        return 8;
    }
}

/// @notice Idle-only vault, 18 decimals.
contract A16zAllocatorVault18DecimalsTest is A16zAllocatorVaultBase {
    function _decimals() internal pure override returns (uint8) {
        return 18;
    }
}

/// @notice Time and fees. The suite never moves time, so in the other configurations no fee share is ever minted and a
///         yield only lands as locked profit. Here the suite's yield (or loss) is booked by an accrual and then 8 days
///         pass: the profit has fully unlocked into the price, and 8 days of management fee plus the performance fee
///         on the unlocked gain are pending, so the first vault call inside every property mints fee shares. Every
///         preview must still match execution exactly.
contract A16zAllocatorVaultTimeAndFeesTest is A16zAllocatorVaultBase {
    function _decimals() internal pure override returns (uint8) {
        return 18;
    }

    /// @dev The fee recipient's share balance grows by the minted fee inside the very call a property makes, so the
    ///      suite's "balance changed by exactly the shares of this call" checks cannot apply to it as a user.
    function setUpVault(Init memory init) public override {
        for (uint256 i = 0; i < N; i++) {
            vm.assume(init.user[i] != allocatorVault.feeRecipient());
        }
        super.setUpVault(init);
    }

    function setUpYield(Init memory init) public override {
        super.setUpYield(init);
        // The suite deposits and donates up to ~2^255. In the other configurations no fee share is ever minted and a
        // donation never unlocks, so neither ever reaches the price or the supply; here both do. The vault supports
        // total assets up to 2^186 (trust assumption 2 in docs/THREAT_MODEL.md, pinned in test/unit/AssetBound.t.sol):
        // below that every RAY price and every share supply fits in 256 bits. Inputs beyond it are discarded.
        vm.assume(token.balanceOf(_vault_) <= 2 ** 186);
        allocatorVault.accrue(); // a yield is locked from here; a loss is realized
        vm.warp(block.timestamp + 8 days);
    }

    /// @dev Not an a16z property: checks that this configuration does what it claims for a typical input.
    function test_configuration_profitIsUnlockedAndBothFeesArePending() public {
        Init memory init;
        for (uint256 i = 0; i < N; i++) {
            init.user[i] = address(uint160(0x1000 + i));
            init.share[i] = 1000e18;
            init.asset[i] = 1000e18;
        }
        init.yield = 100e18;
        setUpVault(init);
        IAllocatorVault.Accrual memory a = allocatorVault.previewAccrual();
        assertEq(a.lockedProfit, 0, "the yield has fully unlocked");
        assertGt(a.managementFeeShares, 0, "management fee pending");
        assertGt(a.performanceFeeShares, 0, "performance fee pending");
    }
}

/// @notice Allocated vault: two thirds of the deposits sit in strategies, yield is realized inside a strategy and
///         losses hit a strategy, so every property also exercises withdraw-queue liquidity and live valuation.
contract A16zAllocatorVaultAllocatedTest is A16zAllocatorVaultBase {
    function _decimals() internal pure override returns (uint8) {
        return 18;
    }

    function setUpYield(Init memory init) public override {
        // A third of the idle assets into each strategy, bounded by the strategy caps.
        uint256 third = token.balanceOf(_vault_) / 3;
        if (third > type(uint128).max) third = type(uint128).max;
        IAllocatorVault.Allocation[] memory allocations = new IAllocatorVault.Allocation[](2);
        allocations[0] = IAllocatorVault.Allocation({strategy: OzIERC4626(address(liquid)), assets: third});
        allocations[1] = IAllocatorVault.Allocation({strategy: OzIERC4626(address(lossy)), assets: third});
        allocatorVault.reallocate(allocations);

        if (init.yield >= 0) {
            try token.mint(address(liquid), uint256(init.yield)) {}
            catch {
                vm.assume(false);
            }
        } else {
            vm.assume(init.yield > type(int256).min);
            uint256 loss = uint256(-init.yield);
            vm.assume(loss <= token.balanceOf(address(lossy)));
            lossy.simulateLoss(loss);
        }
    }
}
