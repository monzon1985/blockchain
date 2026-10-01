// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {AMMFactory} from "../../src/AMMFactory.sol";
import {AMMPair} from "../../src/AMMPair.sol";
import {AMMRouter} from "../../src/AMMRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture: factory (owned by `owner`), router, three 18-decimal tokens and funded users.
abstract contract AMMTestBase is Test {
    AMMFactory internal factory;
    AMMRouter internal router;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal feeRecipient = makeAddr("feeRecipient");

    uint256 internal constant USER_FUNDS = 1e30;
    uint256 internal deadline;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        deadline = block.timestamp + 1 hours;
        factory = new AMMFactory(owner);
        router = new AMMRouter(address(factory));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);
        address[3] memory users = [alice, bob, address(this)];
        MockERC20[3] memory tokens = [tokenA, tokenB, tokenC];
        for (uint256 u; u < users.length; ++u) {
            for (uint256 t; t < tokens.length; ++t) {
                tokens[t].mint(users[u], USER_FUNDS);
                vm.prank(users[u]);
                tokens[t].approve(address(router), type(uint256).max);
            }
        }
    }

    function _pair(address a, address b) internal view returns (AMMPair) {
        return AMMPair(factory.getPair(a, b));
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        (path[0], path[1]) = (a, b);
    }

    function _path(address a, address b, address c) internal pure returns (address[] memory path) {
        path = new address[](3);
        (path[0], path[1], path[2]) = (a, b, c);
    }

    function _addLiquidity(address user, address a, address b, uint256 amountA, uint256 amountB)
        internal
        returns (uint256 liquidity)
    {
        vm.prank(user);
        (,, liquidity) = router.addLiquidity(a, b, amountA, amountB, 0, 0, user, deadline);
    }

    /// @dev Reserves ordered as (a, b).
    function _reserves(address a, address b) internal view returns (uint256 ra, uint256 rb) {
        AMMPair pair = _pair(a, b);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (ra, rb) = pair.token0() == a ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _k(AMMPair pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return uint256(r0) * r1;
    }
}
