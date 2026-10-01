// SPDX-License-Identifier: MIT
//! ABI bindings for the contracts the keeper talks to.
//!
//! These are declared inline (the subset the keeper uses) so the crate builds without Foundry artifacts. The
//! `anvil-e2e` test deploys the real contracts from `out/` and drives them through these bindings, and it also
//! checks every selector below against the compiled ABI, so the two cannot drift silently.
//!
//! `Id` is a user-defined value type over `bytes32` in Solidity; it is declared as `bytes32` here, which is
//! ABI-identical (same selectors, same event topics).

// Generated code: `sol!` emits undocumented items and a 10-argument constructor for the `Liquidate` event.
#![allow(missing_docs, clippy::too_many_arguments)]

use alloy::primitives::{B256, keccak256};
use alloy::sol;
use alloy::sol_types::SolValue;

sol! {
    #[derive(Debug, PartialEq, Eq)]
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    #[derive(Debug, PartialEq, Eq)]
    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    #[derive(Debug, PartialEq, Eq)]
    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    #[derive(Debug, PartialEq, Eq)]
    struct LiquidationConfig {
        uint96 maxBonus;
        uint96 bonusSlope;
        bool enabled;
    }

    #[derive(Debug, PartialEq, Eq)]
    struct Order {
        MarketParams marketParams;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
        address venue;
        uint256 minAmountOut;
    }

    #[sol(rpc)]
    interface ILendingEngine {
        event SupplyCollateral(bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets);
        event WithdrawCollateral(
            bytes32 indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets
        );
        event Borrow(
            bytes32 indexed id,
            address caller,
            address indexed onBehalf,
            address indexed receiver,
            uint256 assets,
            uint256 shares
        );
        event Repay(bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
        event Liquidate(
            bytes32 indexed id,
            address indexed caller,
            address indexed borrower,
            uint256 repaidAssets,
            uint256 repaidShares,
            uint256 seizedAssets,
            uint256 badDebtAssets,
            uint256 badDebtShares,
            uint256 healthFactor,
            uint256 bonus
        );

        function market(bytes32 id) external view returns (Market memory);
        function position(bytes32 id, address user) external view returns (Position memory);
        function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
        function liquidationConfig(uint256 lltv) external view returns (LiquidationConfig memory);
        function expectedMarketBalances(MarketParams calldata marketParams)
            external
            view
            returns (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets, uint256 totalBorrowShares);
        function healthFactor(MarketParams calldata marketParams, address borrower) external view returns (uint256);
    }

    #[sol(rpc)]
    interface IOracle {
        function price() external view returns (uint256);
    }

    #[sol(rpc)]
    interface IFlashLiquidator {
        event Liquidation(
            bytes32 indexed id,
            address indexed borrower,
            uint256 seizedAssets,
            uint256 repaidAssets,
            uint256 proceeds,
            uint256 profit
        );
        error InsufficientProfit(uint256 balanceBefore, uint256 balanceAfter, uint256 minProfit);

        function liquidate(Order calldata order, uint256 flashAssets, uint256 minProfit) external returns (uint256 profit);
        function owner() external view returns (address);
    }
}

/// Market id: `keccak256(abi.encode(marketParams))`, as in `MarketParamsLib.id`.
pub fn market_id(params: &MarketParams) -> B256 {
    keccak256(params.abi_encode())
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{Address, U256};
    use alloy::sol_types::{SolCall, SolEvent};

    #[test]
    fn market_id_is_hash_of_five_words() {
        let params = MarketParams {
            loanToken: Address::repeat_byte(1),
            collateralToken: Address::repeat_byte(2),
            oracle: Address::repeat_byte(3),
            irm: Address::repeat_byte(4),
            lltv: U256::from(860_000_000_000_000_000u64),
        };
        let encoded = params.abi_encode();
        assert_eq!(encoded.len(), 5 * 32);
        assert_eq!(market_id(&params), keccak256(encoded));
    }

    #[test]
    fn selectors_match_the_solidity_signatures() {
        assert_eq!(
            ILendingEngine::Liquidate::SIGNATURE,
            "Liquidate(bytes32,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        assert_eq!(ILendingEngine::positionCall::SIGNATURE, "position(bytes32,address)");
        assert_eq!(
            IFlashLiquidator::liquidateCall::SIGNATURE,
            "liquidate(((address,address,address,address,uint256),address,uint256,uint256,address,uint256),uint256,uint256)"
        );
    }
}
