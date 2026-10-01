// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {MockERC20} from "./MockERC20.sol";

/// @notice Pair surface shared by the hardened and the canonical pair (enough to price an LP token).
interface ILPPricedPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
}

/// @notice Receiver hook of HookToken (ERC-777 style tokensReceived, reduced to what the scenario needs).
interface IHookRecipient {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @notice ERC-20 that calls the recipient after every transfer to a contract (models ERC-777 / hook tokens).
contract HookToken is MockERC20 {
    constructor() MockERC20("Hook Token", "HOOK", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to.code.length != 0) IHookRecipient(to).onTokenReceived(msg.sender, amount);
        return ok;
    }
}

/// @notice A naive lending-market oracle that values one LP token as 2 * reserve0 / totalSupply (in token0).
contract LPOracleVictim {
    function lpValueInToken0(ILPPricedPair pair) external view returns (uint256) {
        (uint112 reserve0,,) = pair.getReserves();
        return 2 * uint256(reserve0) * 1e18 / pair.totalSupply();
    }
}

/// @notice Burns liquidity to itself and, from inside the pair's token transfer, asks the victim oracle for
///         the LP price. Records the observed price or the revert data.
contract ReadOnlyReentrancyAttacker is IHookRecipient {
    LPOracleVictim public immutable oracle;
    ILPPricedPair public pair;
    bool public attempted;
    bool public readSucceeded;
    uint256 public observedLpValue;
    bytes public revertData;

    constructor(LPOracleVictim oracle_) {
        oracle = oracle_;
    }

    function arm(ILPPricedPair pair_) external {
        pair = pair_;
    }

    /// @dev Reacts once, to the first hook after `arm` (the pair paying out during `burn`).
    function onTokenReceived(address, uint256) external {
        if (attempted || address(pair) == address(0)) return;
        attempted = true;
        try oracle.lpValueInToken0(pair) returns (uint256 value) {
            readSucceeded = true;
            observedLpValue = value;
        } catch (bytes memory data) {
            revertData = data;
        }
    }
}
