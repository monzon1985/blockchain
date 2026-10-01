// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin-contracts/utils/math/Math.sol";
import {FundContracts} from "../../../script/FundDeployment.sol";
import {MockUSDC} from "../../mocks/Mocks.sol";

/// @notice Drives the ERC-7540 vault through random interleavings of requests (for the caller or for another
///         controller), partial claims through all four claim functions (by the controller or by an ERC-7540
///         operator it approved, to itself or to another receiver), epoch closes, NAV moves with matching fund
///         P&L, custody moves and settlements, while keeping ghost totals of every asset that enters or leaves
///         the vault.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC = 1e6;

    FundContracts internal f;
    MockUSDC internal usdc;
    address internal fundAdmin;
    address internal navOracle;
    address public custodian;

    address[] public actors;

    // Ghost flows of the settlement asset through the vault.
    uint256 public gDeposited;
    uint256 public gPaidOut;
    uint256 public gDeployed;
    uint256 public gRecalled;
    // Ghost share flows.
    uint256 public gMintedByClaims;
    uint256 public gRedeemClaimedShares;
    // Number of per-controller folds that can each lose < 1 unit to rounding.
    uint256 public gDepositRequests;
    uint256 public gRedeemRequests;

    mapping(bytes32 => uint256) public calls;

    constructor(
        FundContracts memory contracts,
        MockUSDC usdc_,
        address fundAdmin_,
        address navOracle_,
        address custodian_,
        address[] memory actors_
    ) {
        f = contracts;
        usdc = usdc_;
        fundAdmin = fundAdmin_;
        navOracle = navOracle_;
        custodian = custodian_;
        actors = actors_;
    }

    /// @dev Gives every actor a position through the handler's own (ghost-tracked) actions. Not a target.
    function bootstrap() external {
        for (uint256 i; i < actors.length; ++i) {
            this.requestDeposit(i, i, (i + 1) * 100_000 * USDC);
        }
        this.closeEpoch();
        this.settle(1e18);
        for (uint256 i; i < actors.length; ++i) {
            this.claimDeposit(i, type(uint256).max, false, 0, i);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Who submits a claim for `controller`: the controller itself (even `viaSeed`) or another actor that
    ///      the controller approves as its ERC-7540 operator first (odd `viaSeed`).
    function _caller(address controller, uint256 viaSeed) internal returns (address caller) {
        if (viaSeed % 2 == 0) return controller;
        uint256 index = bound(viaSeed >> 1, 0, actors.length - 1);
        caller = actors[index];
        if (caller == controller) caller = actors[(index + 1) % actors.length];
        if (!f.vault.isOperator(controller, caller)) {
            vm.prank(controller);
            f.vault.setOperator(caller, true);
        }
        ++calls[keccak256("viaOperator")];
    }

    function _countReceiver(address controller, address receiver) internal {
        if (receiver != controller) ++calls[keccak256("otherReceiver")];
    }

    // ---------------------------------------------------------------- requests

    /// @dev The actor pays; the request may be booked for another controller.
    function requestDeposit(uint256 actorSeed, uint256 controllerSeed, uint256 assets) external {
        address owner = _actor(actorSeed);
        address controller = _actor(controllerSeed);
        assets = bound(assets, 1, 2_000_000 * USDC);
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(f.vault), assets);
        f.vault.requestDeposit(assets, controller, owner);
        vm.stopPrank();
        gDeposited += assets;
        ++gDepositRequests;
        ++calls[keccak256("requestDeposit")];
        if (controller != owner) ++calls[keccak256("requestForOther")];
    }

    /// @dev The actor's shares are burned; the redemption may be booked for another controller.
    function requestRedeem(uint256 actorSeed, uint256 controllerSeed, uint256 shares) external {
        address owner = _actor(actorSeed);
        address controller = _actor(controllerSeed);
        uint256 balance = f.share.balanceOf(owner);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        vm.prank(owner);
        f.vault.requestRedeem(shares, controller, owner);
        ++gRedeemRequests;
        ++calls[keccak256("requestRedeem")];
        if (controller != owner) ++calls[keccak256("requestForOther")];
    }

    // ---------------------------------------------------------------- claims

    function claimDeposit(uint256 actorSeed, uint256 amount, bool useMint, uint256 viaSeed, uint256 receiverSeed)
        external
    {
        address controller = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        if (useMint) {
            uint256 claimable = f.vault.maxMint(controller);
            if (claimable == 0) return;
            uint256 shares = bound(amount, 1, claimable);
            vm.prank(_caller(controller, viaSeed));
            f.vault.mint(shares, receiver, controller);
            gMintedByClaims += shares;
            ++calls[keccak256("mint")];
        } else {
            uint256 claimable = f.vault.maxDeposit(controller);
            if (claimable == 0) return;
            uint256 assets = bound(amount, 1, claimable);
            vm.prank(_caller(controller, viaSeed));
            gMintedByClaims += f.vault.deposit(assets, receiver, controller);
            ++calls[keccak256("deposit")];
        }
        _countReceiver(controller, receiver);
    }

    function claimRedeem(uint256 actorSeed, uint256 amount, bool useWithdraw, uint256 viaSeed, uint256 receiverSeed)
        external
    {
        address controller = _actor(actorSeed);
        address receiver = _actor(receiverSeed);
        if (useWithdraw) {
            uint256 claimable = f.vault.maxWithdraw(controller);
            if (claimable == 0) return;
            uint256 assets = bound(amount, 1, claimable);
            vm.prank(_caller(controller, viaSeed));
            gRedeemClaimedShares += f.vault.withdraw(assets, receiver, controller);
            gPaidOut += assets;
            ++calls[keccak256("withdraw")];
        } else {
            uint256 claimable = f.vault.maxRedeem(controller);
            if (claimable == 0) return;
            uint256 shares = bound(amount, 1, claimable);
            vm.prank(_caller(controller, viaSeed));
            gPaidOut += f.vault.redeem(shares, receiver, controller);
            gRedeemClaimedShares += shares;
            ++calls[keccak256("redeem")];
        }
        _countReceiver(controller, receiver);
    }

    // ---------------------------------------------------------------- epochs, NAV and custody

    function closeEpoch() external {
        if (f.vault.epochAwaitingSettlement() != 0) return;
        vm.prank(fundAdmin);
        f.vault.closeEpoch();
        ++calls[keccak256("closeEpoch")];
    }

    /// @dev Applies fund P&L consistent with the new NAV (gains rounded up, losses rounded down), then settles at
    ///      a NAV the circuit breaker accepts (per-epoch band and 24 h window).
    function settle(uint256 navSeed) external {
        uint256 epochId = f.vault.epochAwaitingSettlement();
        if (epochId == 0) return;
        vm.warp(block.timestamp + 1 hours);
        (uint128 ref,) = f.vault.referenceNav();
        (uint256 minNav, uint256 maxNav) = f.vault.navBounds();
        uint128 nav = uint128(bound(navSeed, minNav, maxNav));

        _deployIdle();
        uint256 outstanding = f.vault.outstandingShares();
        if (nav > ref) {
            usdc.mint(custodian, Math.mulDiv(outstanding, nav - ref, WAD, Math.Rounding.Ceil));
        } else if (nav < ref) {
            usdc.burn(custodian, Math.mulDiv(outstanding, ref - nav, WAD));
        }
        uint256 need = Math.mulDiv(f.vault.getEpoch(epochId).redeemShares, nav, WAD);
        uint256 recallAmount = Math.min(need, usdc.balanceOf(custodian));
        if (recallAmount != 0) {
            vm.prank(fundAdmin);
            f.vault.recallFromCustodian(recallAmount);
            gRecalled += recallAmount;
        }

        vm.prank(navOracle);
        f.vault.postNav(nav, uint64(block.timestamp));
        vm.prank(fundAdmin);
        f.vault.settleEpoch();
        ++calls[keccak256("settle")];
    }

    function deployIdle() external {
        _deployIdle();
        ++calls[keccak256("deployIdle")];
    }

    function recall(uint256 amount) external {
        uint256 available = usdc.balanceOf(custodian);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(fundAdmin);
        f.vault.recallFromCustodian(amount);
        gRecalled += amount;
        ++calls[keccak256("recall")];
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 12 hours));
        ++calls[keccak256("warp")];
    }

    function _deployIdle() internal {
        uint256 idle = f.vault.idleAssets();
        if (idle == 0) return;
        vm.prank(fundAdmin);
        f.vault.deployToCustodian(idle);
        gDeployed += idle;
    }
}
