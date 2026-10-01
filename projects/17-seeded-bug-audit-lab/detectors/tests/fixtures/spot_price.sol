// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface IPool {
    function getReserves() external view returns (uint256, uint256);
    function spotPrice0In1() external view returns (uint256);
}

interface IVault {
    function convertToAssets(uint256) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IOracle {
    function latestPrice() external view returns (uint256);
    function priceToken0In1() external view returns (uint256);
}

contract SpotPositives {
    IPool pool;
    IVault vault;
    IERC20 token;

    // POSITIVE: values collateral from AMM spot reserves and a live balance.
    function collateralValue(address u) external view returns (uint256) {
        (uint256 r0, uint256 r1) = pool.getReserves();
        return r1 * token.balanceOf(u) / r0;
    }

    // POSITIVE: share price derived from convertToAssets.
    function priceOfShare() external view returns (uint256) {
        return vault.convertToAssets(1e18);
    }
}

contract SpotNegatives {
    IOracle oracle;
    IERC20 token;
    uint256 storedPrice;

    // NEGATIVE: valuation priced from an external oracle.
    function collateralValue(address) external view returns (uint256) {
        return oracle.latestPrice();
    }

    // NEGATIVE (adversarial): valuation priced from a TWAP oracle whose name contains "price".
    function twapCollateralValue(uint256 amount) external view returns (uint256) {
        return amount * oracle.priceToken0In1() / 1e18;
    }

    // NEGATIVE (adversarial): valuation from a stored, governance-set price.
    function quoteValue(uint256 amount) external view returns (uint256) {
        return amount * storedPrice / 1e18;
    }

    // NEGATIVE: reads balanceOf, but the function is not a valuation (accounting view).
    function totalDeposits() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
