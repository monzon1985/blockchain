// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IAllocatorVault} from "../../src/interfaces/IAllocatorVault.sol";
import {MockStrategyBase} from "./MockStrategies.sol";

/// @notice Hostile strategy: while the vault is inside `withdraw`/`deposit` on it, it calls back into every price view
///         and every entry point of the vault and records, per call, whether it went through and what it reverted
///         with. A view or entry point without its reentrancy guard shows up as a call that succeeded.
contract MockReentrantStrategy is MockStrategyBase {
    IAllocatorVault public target;
    bytes[] internal _probes;
    string[] internal _names;
    /// @notice Number of probe rounds run (one per strategy deposit or withdrawal while armed).
    uint256 public rounds;
    /// @notice Per probe: true if any round let the call through.
    mapping(uint256 index => bool) public succeeded;
    /// @notice Per probe: the revert data of the last round.
    mapping(uint256 index => bytes) public lastRevert;

    constructor(IERC20 asset_) MockStrategyBase(asset_, "Mock Reentrant Strategy") {}

    /// @notice Arms the strategy against `target_` with every guarded view and entry point of the vault.
    function arm(IAllocatorVault target_) external {
        target = target_;
        address me = address(this);
        IAllocatorVault.Allocation[] memory none = new IAllocatorVault.Allocation[](0);
        // Price views (`nonReentrantView`).
        _add("totalAssets", abi.encodeCall(IERC4626.totalAssets, ()));
        _add("convertToShares", abi.encodeCall(IERC4626.convertToShares, (1e18)));
        _add("convertToAssets", abi.encodeCall(IERC4626.convertToAssets, (1e18)));
        _add("previewDeposit", abi.encodeCall(IERC4626.previewDeposit, (1e18)));
        _add("previewMint", abi.encodeCall(IERC4626.previewMint, (1e18)));
        _add("previewWithdraw", abi.encodeCall(IERC4626.previewWithdraw, (1e18)));
        _add("previewRedeem", abi.encodeCall(IERC4626.previewRedeem, (1e18)));
        _add("maxDeposit", abi.encodeCall(IERC4626.maxDeposit, (me)));
        _add("maxMint", abi.encodeCall(IERC4626.maxMint, (me)));
        _add("maxWithdraw", abi.encodeCall(IERC4626.maxWithdraw, (me)));
        _add("maxRedeem", abi.encodeCall(IERC4626.maxRedeem, (me)));
        _add("previewAccrual", abi.encodeCall(IAllocatorVault.previewAccrual, ()));
        _add("sharePrice", abi.encodeCall(IAllocatorVault.sharePrice, ()));
        _add("safeSharePrice", abi.encodeCall(IAllocatorVault.safeSharePrice, ()));
        _add("safeConvertToAssets", abi.encodeCall(IAllocatorVault.safeConvertToAssets, (1e18)));
        _add("strategyAssets", abi.encodeCall(IAllocatorVault.strategyAssets, (IERC4626(me))));
        _add("availableLiquidity", abi.encodeCall(IAllocatorVault.availableLiquidity, ()));
        // Entry points (`nonReentrant`, checked before any role).
        _add("deposit", abi.encodeCall(IERC4626.deposit, (0, me)));
        _add("mint", abi.encodeCall(IERC4626.mint, (0, me)));
        _add("withdraw", abi.encodeCall(IERC4626.withdraw, (0, me, me)));
        _add("redeem", abi.encodeCall(IERC4626.redeem, (0, me, me)));
        _add("accrue", abi.encodeCall(IAllocatorVault.accrue, ()));
        _add("reallocate", abi.encodeCall(IAllocatorVault.reallocate, (none)));
        _add("submitStrategyRemoval", abi.encodeCall(IAllocatorVault.submitStrategyRemoval, (IERC4626(me))));
        _add("removeStrategy", abi.encodeCall(IAllocatorVault.removeStrategy, (IERC4626(me))));
        _add("submitFees", abi.encodeCall(IAllocatorVault.submitFees, (0, 0)));
        _add("setFeeRecipient", abi.encodeCall(IAllocatorVault.setFeeRecipient, (me)));
        _add("acceptFees", abi.encodeCall(IAllocatorVault.acceptFees, ()));
    }

    /// @notice Number of probes.
    function probes() external view returns (uint256) {
        return _probes.length;
    }

    /// @notice Name of probe `index`.
    function probeName(uint256 index) external view returns (string memory) {
        return _names[index];
    }

    function _add(string memory name, bytes memory data) private {
        _names.push(name);
        _probes.push(data);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _reenter();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _reenter();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _reenter() private {
        if (address(target) == address(0)) return;
        ++rounds;
        for (uint256 i; i < _probes.length; ++i) {
            (bool ok, bytes memory ret) = address(target).call(_probes[i]);
            if (ok) succeeded[i] = true;
            else lastRevert[i] = ret;
        }
    }
}
