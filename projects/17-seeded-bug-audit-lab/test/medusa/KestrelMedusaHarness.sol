// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { KestrelSystem } from "../invariant/KestrelSystem.sol";
import { KestrelHandler } from "../invariant/KestrelHandler.sol";

/// @title KestrelMedusaHarness
/// @notice Medusa entry point. It deploys the same {KestrelSystem} and spec-only
///         {KestrelHandler} as the Foundry invariant suite, exposes the handler's actions to the
///         fuzzer and states the same rules as `property_*` functions. Run with
///         `FOUNDRY_PROFILE=fixed medusa fuzz --config medusa.json` (or `vulnerable` for the blind run).
contract KestrelMedusaHarness {
    KestrelSystem internal immutable sys;
    KestrelHandler internal immutable h;

    constructor() {
        sys = new KestrelSystem();
        h = new KestrelHandler(sys);
    }

    // --- actions (forwarded to the spec-only handler) ---

    function swap(uint256 a, bool z, uint256 x) external {
        h.swap(a, z, x);
    }

    function batchSwap(uint256 a, uint256 layout, uint256 x) external {
        h.batchSwap(a, layout, x);
    }

    function joinProportional(uint256 a, uint256 x) external {
        h.joinProportional(a, x);
    }

    function joinExactShares(uint256 a, uint256 shares) external {
        h.joinExactShares(a, shares);
    }

    function exit(uint256 a, uint256 shares) external {
        h.exit(a, shares);
    }

    function sponsoredSwap(uint256 a, uint256 x, uint256 overpay, bool wallet) external {
        h.sponsoredSwap(a, x, overpay, wallet);
    }

    function privileged(uint256 a, uint256 action, uint256 v) external {
        h.privileged(a, action, v);
    }

    function rewards(uint256 a, uint256 x) external {
        h.rewards(a, x);
    }

    function amplifyPool6(uint256 n, uint256 x) external {
        h.amplifyPool6(n, x);
    }

    function swapPool6(uint256 a, uint256 x) external {
        h.swapPool6(a, x);
    }

    function vaultDeposit(uint256 a, uint256 x, bool integrator) external {
        h.vaultDeposit(a, x, integrator);
    }

    function vaultWithdraw(uint256 a, uint256 x, bool integrator) external {
        h.vaultWithdraw(a, x, integrator);
    }

    function vaultRedeem(uint256 a, uint256 x, bool integrator) external {
        h.vaultRedeem(a, x, integrator);
    }

    function vaultAccrue(uint256 x) external {
        h.vaultAccrue(x);
    }

    function amplifyVaultDust(uint256 n, uint256 x) external {
        h.amplifyVaultDust(n, x);
    }

    function borrow(uint256 a, uint256 pledge, uint256 x) external {
        h.borrow(a, pledge, x);
    }

    function repayAndWithdraw(uint256 a, uint256 x) external {
        h.repayAndWithdraw(a, x);
    }

    function keeper() external {
        h.keeper();
    }

    function warp(uint256 s) external {
        h.warp(s);
    }

    function flashGovern(uint256 loan, uint256 action) external {
        h.flashGovern(loan, action);
    }

    function relay(uint256 signer, uint256 x) external {
        h.relay(signer, x);
    }

    function replay(uint256 index, uint256 chainSeed) external {
        h.replay(index, chainSeed);
    }

    function configCall(uint256 a, uint256 action, uint256 v) external {
        h.configCall(a, action, v);
    }

    function upgrade(uint256 a) external {
        h.upgrade(a);
    }

    // --- properties (the README invariants, as Medusa properties) ---

    function property_poolSolvency() external view returns (bool) {
        return sys.pool().reserve0() <= sys.collateral().balanceOf(address(sys.pool()))
            && sys.pool().reserve1() <= sys.debt().balanceOf(address(sys.pool()))
            && sys.pool6().reserve0() <= sys.stable().balanceOf(address(sys.pool6()))
            && sys.pool6().reserve1() <= sys.usdc().balanceOf(address(sys.pool6()));
    }

    function property_batchMatchesSingleSwap() external view returns (bool) {
        return h.batchExcessOverQuote() == 0;
    }

    function property_poolRoundingFavorsPool() external view returns (bool) {
        return h.amplifier().maxError(h.OP_POOL6_BATCH()) == 0;
    }

    function property_joinsPayProRata() external view returns (bool) {
        return h.underpricedJoins() == 0;
    }

    function property_nativeFeeAccounting() external view returns (bool) {
        return address(sys.pool()).balance == sys.pool().nativeFeesCollected();
    }

    function property_privilegedActionsOwnerOnly() external view returns (bool) {
        return h.unauthorizedPrivilegedCalls() == 0;
    }

    function property_rewardReserveBacked() external view returns (bool) {
        return sys.pool().rewardReserve() <= sys.reward().balanceOf(address(sys.pool()));
    }

    function property_vaultSolvency() external view returns (bool) {
        return sys.vault().totalManaged() <= address(sys.vault()).balance;
    }

    function property_sharePriceMonotonic() external view returns (bool) {
        return h.maxSharePriceDrop() == 0;
    }

    function property_vaultRoundingFavorsVault() external view returns (bool) {
        return h.amplifier().maxError(h.OP_VAULT_DUST()) == 0;
    }

    function property_integratorsSeeConsistentPrice() external view returns (bool) {
        return h.inconsistentPriceReads() == 0;
    }

    function property_valuationIgnoresSameBlockSwaps() external view returns (bool) {
        return h.valuationMovedBySwap() == 0;
    }

    function property_treasuryNeedsDurableStake() external view returns (bool) {
        return h.treasuryMovedByFlashStake() == 0;
    }

    function property_signaturesSingleUse() external view returns (bool) {
        return h.signatureReuses() == 0;
    }

    function property_configChangesAuthorized() external view returns (bool) {
        return h.unauthorizedConfigChanges() == 0;
    }

    function property_onlyAdminUpgrades() external view returns (bool) {
        return h.unauthorizedUpgrades() == 0;
    }
}
