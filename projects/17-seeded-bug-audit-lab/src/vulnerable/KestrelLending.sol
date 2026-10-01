// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { FixedPointMath } from "./lib/FixedPointMath.sol";
import { KestrelPool } from "./KestrelPool.sol";
import { KestrelVault } from "./KestrelVault.sol";
import { IPriceOracle } from "shared/IPriceOracle.sol";
import { IKestrelConfig } from "shared/IKestrelConfig.sol";

/// @title KestrelLending
/// @notice An isolated lending market. Lenders supply the debt token; borrowers pledge either
///         the AMM's collateral token or Kestrel vault shares (kETH) and borrow the debt token.
/// @dev    Risk parameters (loan-to-value, ETH reference price) are read from {config} on every
///         health check. The ERC-20 collateral is priced in the debt token; vault shares are
///         valued at {KestrelVault.convertToAssets} times the configured ETH price. Collateral
///         and debt tokens are 18-decimal (README scope notes). There are no liquidations.
contract KestrelLending is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Token borrowers receive and lenders supply (18 decimals); equals `pool.token1`.
    IERC20 public immutable debtToken;
    /// @notice ERC-20 collateral token; equals `pool.token0` (18 decimals).
    IERC20 public immutable collateralToken;
    /// @notice AMM that lists the collateral against the debt token.
    KestrelPool public immutable pool;
    /// @notice Vault whose shares may be pledged as collateral.
    KestrelVault public immutable vault;
    /// @notice Time-weighted price of the collateral token in the debt token (token0 in token1).
    IPriceOracle public immutable oracle;
    /// @notice Risk-parameter store (behind a proxy).
    IKestrelConfig public immutable config;

    /// @notice Debt-token liquidity supplied by each lender.
    mapping(address lender => uint256 amount) public supplied;
    /// @notice Total debt-token liquidity supplied.
    uint256 public totalSupplied;
    /// @notice Outstanding debt per borrower (debt-token units).
    mapping(address borrower => uint256 amount) public debtOf;
    /// @notice Total outstanding debt.
    uint256 public totalDebt;
    /// @notice ERC-20 collateral pledged per borrower.
    mapping(address borrower => uint256 amount) public collateralOf;
    /// @notice Vault-share collateral pledged per borrower.
    mapping(address borrower => uint256 shares) public vaultCollateralOf;

    /// @notice Emitted when a lender supplies liquidity.
    /// @param lender Lender.
    /// @param amount Debt tokens supplied.
    event Supplied(address indexed lender, uint256 amount);
    /// @notice Emitted when a lender withdraws liquidity.
    /// @param lender Lender.
    /// @param amount Debt tokens withdrawn.
    event Unsupplied(address indexed lender, uint256 amount);
    /// @notice Emitted when collateral is pledged.
    /// @param borrower Borrower.
    /// @param isVault True for vault shares, false for the ERC-20 collateral.
    /// @param amount Amount (or shares) pledged.
    event CollateralDeposited(address indexed borrower, bool isVault, uint256 amount);
    /// @notice Emitted when collateral is withdrawn.
    /// @param borrower Borrower.
    /// @param isVault True for vault shares, false for the ERC-20 collateral.
    /// @param amount Amount (or shares) withdrawn.
    event CollateralWithdrawn(address indexed borrower, bool isVault, uint256 amount);
    /// @notice Emitted on borrow.
    /// @param borrower Borrower.
    /// @param amount Debt tokens borrowed.
    event Borrowed(address indexed borrower, uint256 amount);
    /// @notice Emitted on repay.
    /// @param borrower Borrower.
    /// @param amount Debt tokens repaid.
    event Repaid(address indexed borrower, uint256 amount);

    /// @notice Thrown on a zero amount.
    error ZeroAmount();
    /// @notice Thrown when an action would leave a position under-collateralized.
    /// @param debt Resulting debt.
    /// @param maxDebt Maximum debt allowed by collateral and LTV.
    error Undercollateralized(uint256 debt, uint256 maxDebt);
    /// @notice Thrown when there is not enough idle liquidity to borrow or unsupply.
    /// @param requested Amount requested.
    /// @param idle Idle liquidity.
    error InsufficientLiquidity(uint256 requested, uint256 idle);
    /// @notice Thrown when repaying or withdrawing more than held.
    /// @param requested Amount requested.
    /// @param balance Amount held.
    error ExceedsBalance(uint256 requested, uint256 balance);
    /// @notice Thrown when the pool does not list the debt token against a collateral token.
    error PoolMismatch();

    /// @notice Deploy the market.
    /// @param _debtToken Debt token (18 decimals); must be `_pool.token1()`.
    /// @param _pool AMM listing the collateral token (`token0`) against the debt token.
    /// @param _vault Vault whose shares are accepted as collateral.
    /// @param _oracle Time-weighted price of `token0` in `token1`.
    /// @param _config Risk-parameter store.
    constructor(
        IERC20 _debtToken,
        KestrelPool _pool,
        KestrelVault _vault,
        IPriceOracle _oracle,
        IKestrelConfig _config
    ) {
        require(address(_pool.token1()) == address(_debtToken), PoolMismatch());
        debtToken = _debtToken;
        pool = _pool;
        collateralToken = _pool.token0();
        vault = _vault;
        oracle = _oracle;
        config = _config;
    }

    // --- Lenders ---

    /// @notice Supply debt-token liquidity.
    /// @param amount Debt tokens to supply.
    function supply(uint256 amount) external nonReentrant {
        require(amount > 0, ZeroAmount());
        supplied[msg.sender] += amount;
        totalSupplied += amount;
        debtToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(msg.sender, amount);
    }

    /// @notice Withdraw previously supplied liquidity, if idle liquidity allows.
    /// @param amount Debt tokens to withdraw.
    function unsupply(uint256 amount) external nonReentrant {
        require(amount > 0, ZeroAmount());
        require(supplied[msg.sender] >= amount, ExceedsBalance(amount, supplied[msg.sender]));
        uint256 idle = _idleLiquidity();
        require(idle >= amount, InsufficientLiquidity(amount, idle));
        supplied[msg.sender] -= amount;
        totalSupplied -= amount;
        debtToken.safeTransfer(msg.sender, amount);
        emit Unsupplied(msg.sender, amount);
    }

    // --- Borrowers ---

    /// @notice Pledge ERC-20 collateral.
    /// @param amount Collateral-token amount.
    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, ZeroAmount());
        collateralOf[msg.sender] += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, false, amount);
    }

    /// @notice Pledge vault-share collateral.
    /// @param shares Vault shares (kETH) to pledge.
    function depositVaultCollateral(uint256 shares) external nonReentrant {
        require(shares > 0, ZeroAmount());
        vaultCollateralOf[msg.sender] += shares;
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);
        emit CollateralDeposited(msg.sender, true, shares);
    }

    /// @notice Withdraw ERC-20 collateral if the position stays healthy.
    /// @param amount Collateral-token amount.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, ZeroAmount());
        require(collateralOf[msg.sender] >= amount, ExceedsBalance(amount, collateralOf[msg.sender]));
        collateralOf[msg.sender] -= amount;
        _requireHealthy(msg.sender);
        collateralToken.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, false, amount);
    }

    /// @notice Withdraw vault-share collateral if the position stays healthy.
    /// @param shares Vault shares to withdraw.
    function withdrawVaultCollateral(uint256 shares) external nonReentrant {
        require(shares > 0, ZeroAmount());
        require(
            vaultCollateralOf[msg.sender] >= shares, ExceedsBalance(shares, vaultCollateralOf[msg.sender])
        );
        vaultCollateralOf[msg.sender] -= shares;
        _requireHealthy(msg.sender);
        IERC20(address(vault)).safeTransfer(msg.sender, shares);
        emit CollateralWithdrawn(msg.sender, true, shares);
    }

    /// @notice Borrow debt tokens against pledged collateral.
    /// @param amount Debt tokens to borrow.
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, ZeroAmount());
        uint256 idle = _idleLiquidity();
        require(idle >= amount, InsufficientLiquidity(amount, idle));
        debtOf[msg.sender] += amount;
        totalDebt += amount;
        _requireHealthy(msg.sender);
        debtToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repay outstanding debt.
    /// @param amount Debt tokens to repay.
    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, ZeroAmount());
        require(debtOf[msg.sender] >= amount, ExceedsBalance(amount, debtOf[msg.sender]));
        debtOf[msg.sender] -= amount;
        totalDebt -= amount;
        debtToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Repaid(msg.sender, amount);
    }

    // --- Views ---

    /// @notice Total debt-token value of a borrower's collateral.
    /// @dev The ERC-20 price source is only consulted when the account holds ERC-20 collateral,
    ///      so a price-source outage cannot block accounts that do not depend on it.
    /// @param account Borrower to value.
    /// @return value Collateral value in debt-token units (18 decimals).
    function collateralValue(address account) public view returns (uint256 value) {
        uint256 amount = collateralOf[account];
        if (amount > 0) {
            uint256 price = pool.spotPrice0In1();
            value = FixedPointMath.mulWadDown(amount, price);
        }
        uint256 shares = vaultCollateralOf[account];
        if (shares > 0) {
            uint256 ethValue = vault.convertToAssets(shares);
            value += FixedPointMath.mulWadDown(ethValue, config.ethPrice());
        }
    }

    /// @notice Maximum debt a borrower may carry given collateral and LTV.
    /// @param account Borrower.
    /// @return maxDebt_ Maximum debt in debt-token units.
    function maxDebt(address account) public view returns (uint256 maxDebt_) {
        maxDebt_ = collateralValue(account) * config.ltvBps() / BPS;
    }

    /// @notice Time-weighted reference price of the collateral token, for integrators.
    /// @return price token0-in-token1 WAD price from {oracle}.
    function referencePrice() external view returns (uint256 price) {
        price = oracle.priceToken0In1();
    }

    /// @dev Idle (borrowable) liquidity.
    function _idleLiquidity() internal view returns (uint256 idle) {
        idle = totalSupplied - totalDebt;
    }

    /// @dev Revert unless `account`'s debt is within its collateral limit. Debt-free accounts
    ///      are always healthy, so withdrawing collateral never depends on a price source.
    function _requireHealthy(address account) internal view {
        uint256 debt = debtOf[account];
        if (debt == 0) return;
        uint256 max = maxDebt(account);
        require(debt <= max, Undercollateralized(debt, max));
    }
}
