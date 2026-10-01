// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {AMMFactory} from "../../src/AMMFactory.sol";
import {AMMPair} from "../../src/AMMPair.sol";
import {AMMRouter} from "../../src/AMMRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalV2, IUniswapV2Factory, IUniswapV2Pair} from "../utils/CanonicalV2.sol";

/// @notice Gas of every user-facing operation, and of the core pair operations next to the canonical
///         UniswapV2Pair bytecode (same tokens, same reserves, same call sequence). Each measured call runs as
///         its own transaction (`isolate`), so storage is cold exactly as for a real user.
/// forge-config: default.isolate = true
contract GasBench is Test, CanonicalV2 {
    AMMFactory internal factory;
    AMMRouter internal router;
    IUniswapV2Factory internal canonicalFactory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    AMMPair internal pair;
    IUniswapV2Pair internal canonical;
    address internal user;
    uint256 internal userKey;
    uint256 internal deadline;

    function setUp() public {
        vm.warp(1_750_000_000);
        deadline = block.timestamp + 1 hours;
        (user, userKey) = makeAddrAndKey("gas-user");
        factory = new AMMFactory(address(this));
        router = new AMMRouter(address(factory));
        canonicalFactory = _deployCanonicalFactory(address(this));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);
        MockERC20[3] memory tokens = [tokenA, tokenB, tokenC];
        for (uint256 i; i < 3; ++i) {
            tokens[i].mint(user, 1e30);
            tokens[i].mint(address(this), 1e30);
            tokens[i].approve(address(router), type(uint256).max);
            vm.prank(user);
            tokens[i].approve(address(router), type(uint256).max);
        }
        router.addLiquidity(address(tokenA), address(tokenB), 1000 ether, 1000 ether, 0, 0, user, deadline);
        router.addLiquidity(address(tokenB), address(tokenC), 1000 ether, 1000 ether, 0, 0, user, deadline);
        pair = AMMPair(factory.getPair(address(tokenA), address(tokenB)));
        canonical = IUniswapV2Pair(canonicalFactory.createPair(address(tokenA), address(tokenB)));
        tokenA.transfer(address(canonical), 1000 ether);
        tokenB.transfer(address(canonical), 1000 ether);
        canonical.mint(user);
        vm.prank(user);
        pair.approve(address(router), type(uint256).max);
        vm.warp(block.timestamp + 12); // measured calls accrue the TWAP, as the first trade of a block does
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    // ------------------------------------------------------------------ core pair: hardened vs canonical

    function test_gas_pair_swap() public {
        uint256 out = router.getAmountOut(1 ether, 1000 ether, 1000 ether);
        tokenA.transfer(address(pair), 1 ether);
        tokenA.transfer(address(canonical), 1 ether);
        (uint256 o0, uint256 o1) = pair.token0() == address(tokenA) ? (uint256(0), out) : (out, uint256(0));
        pair.swap(o0, o1, user, "");
        vm.snapshotGasLastFrame("pair", "swap_hardened");
        canonical.swap(o0, o1, user, "");
        vm.snapshotGasLastFrame("pair", "swap_canonical");
    }

    function test_gas_pair_mint() public {
        tokenA.transfer(address(pair), 10 ether);
        tokenB.transfer(address(pair), 10 ether);
        tokenA.transfer(address(canonical), 10 ether);
        tokenB.transfer(address(canonical), 10 ether);
        pair.mint(user);
        vm.snapshotGasLastFrame("pair", "mint_hardened");
        canonical.mint(user);
        vm.snapshotGasLastFrame("pair", "mint_canonical");
    }

    function test_gas_pair_burn() public {
        vm.startPrank(user);
        pair.transfer(address(pair), 10 ether);
        canonical.transfer(address(canonical), 10 ether);
        vm.stopPrank();
        pair.burn(user);
        vm.snapshotGasLastFrame("pair", "burn_hardened");
        canonical.burn(user);
        vm.snapshotGasLastFrame("pair", "burn_canonical");
    }

    function test_gas_pair_sync() public {
        pair.sync();
        vm.snapshotGasLastFrame("pair", "sync_hardened");
        canonical.sync();
        vm.snapshotGasLastFrame("pair", "sync_canonical");
    }

    function test_gas_pair_getReserves() public {
        pair.getReserves();
        vm.snapshotGasLastFrame("pair", "getReserves_hardened");
        canonical.getReserves();
        vm.snapshotGasLastFrame("pair", "getReserves_canonical");
    }

    function test_gas_factory_createPair() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        factory.createPair(address(x), address(tokenA));
        vm.snapshotGasLastFrame("factory", "createPair_hardened");
        canonicalFactory.createPair(address(x), address(tokenA));
        vm.snapshotGasLastFrame("factory", "createPair_canonical");
    }

    // ------------------------------------------------------------------ router (user-facing)

    function test_gas_router_swapExactIn_1hop() public {
        vm.prank(user);
        router.swapExactTokensForTokens(1 ether, 0, _path(address(tokenA), address(tokenB)), user, deadline);
        vm.snapshotGasLastFrame("router", "swapExactTokensForTokens_1hop");
    }

    function test_gas_router_swapExactIn_2hop() public {
        address[] memory path = new address[](3);
        (path[0], path[1], path[2]) = (address(tokenA), address(tokenB), address(tokenC));
        vm.prank(user);
        router.swapExactTokensForTokens(1 ether, 0, path, user, deadline);
        vm.snapshotGasLastFrame("router", "swapExactTokensForTokens_2hop");
    }

    function test_gas_router_swapExactOut_1hop() public {
        vm.prank(user);
        router.swapTokensForExactTokens(
            1 ether, type(uint256).max, _path(address(tokenA), address(tokenB)), user, deadline
        );
        vm.snapshotGasLastFrame("router", "swapTokensForExactTokens_1hop");
    }

    function test_gas_router_swapSupportingFeeOnTransfer_1hop() public {
        vm.prank(user);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, 0, _path(address(tokenA), address(tokenB)), user, deadline
        );
        vm.snapshotGasLastFrame("router", "swapSupportingFeeOnTransfer_1hop");
    }

    function test_gas_router_addLiquidity() public {
        vm.prank(user);
        router.addLiquidity(address(tokenA), address(tokenB), 10 ether, 10 ether, 0, 0, user, deadline);
        vm.snapshotGasLastFrame("router", "addLiquidity_existingPair");
    }

    function test_gas_router_removeLiquidity() public {
        vm.prank(user);
        router.removeLiquidity(address(tokenA), address(tokenB), 10 ether, 0, 0, user, deadline);
        vm.snapshotGasLastFrame("router", "removeLiquidity");
    }

    function test_gas_router_removeLiquidityWithPermit() public {
        vm.prank(user);
        pair.approve(address(router), 0);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(router),
                10 ether,
                pair.nonces(user),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(userKey, keccak256(abi.encodePacked("\x19\x01", pair.DOMAIN_SEPARATOR(), structHash)));
        vm.prank(user);
        router.removeLiquidityWithPermit(
            address(tokenA), address(tokenB), 10 ether, 0, 0, user, deadline, false, v, r, s
        );
        vm.snapshotGasLastFrame("router", "removeLiquidityWithPermit");
    }
}
