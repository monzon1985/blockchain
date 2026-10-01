// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {StdAssertions} from "forge-std/StdAssertions.sol";

import {AMMFactory} from "../../src/AMMFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalV2, IUniswapV2Factory, IUniswapV2Pair} from "../utils/CanonicalV2.sol";

/// @notice Drives the hardened pair and the canonical UniswapV2Pair (deployed from its own bytecode) with the
///         same operation, in the same block, from the same starting state, and checks that both end in the
///         same observable state. Both pairs share the two tokens and are driven through one ABI: every
///         selector used here is identical on both contracts.
/// @dev Each operation runs inside an external self-call so that a revert also undoes the token transfers that
///      precede the pair call, exactly as it would in a real transaction.
contract DualPairHarness is CanonicalV2, StdAssertions {
    uint256 internal constant ACTORS = 3;

    AMMFactory public immutable hardenedFactory;
    IUniswapV2Factory public immutable canonicalFactory;
    IUniswapV2Pair public immutable hardened;
    IUniswapV2Pair public immutable canonical;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    address public immutable feeRecipient = address(0xFEE);
    address[ACTORS] public actors = [address(0xA11CE), address(0xB0B), address(0xCA7)];

    /// @notice Number of operations where both implementations agreed, split by outcome.
    uint256 public bothSucceeded;
    uint256 public bothReverted;

    error OnlySelf();
    error OutcomeMismatch(string op, bool hardenedOk, bool canonicalOk);

    constructor() {
        hardenedFactory = new AMMFactory(address(this));
        canonicalFactory = _deployCanonicalFactory(address(this));
        MockERC20 a = new MockERC20("Token X", "X", 18);
        MockERC20 b = new MockERC20("Token Y", "Y", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        hardened = IUniswapV2Pair(hardenedFactory.createPair(address(token0), address(token1)));
        canonical = IUniswapV2Pair(canonicalFactory.createPair(address(token0), address(token1)));
        // Enough for any bounded sequence; the harness pays every deposit twice (once per pair).
        token0.mint(address(this), type(uint128).max);
        token1.mint(address(this), type(uint128).max);
    }

    modifier onlySelf() {
        require(msg.sender == address(this), OnlySelf());
        _;
    }

    // ------------------------------------------------------------------------------------------------------
    // Atomic single-pair executors (called through `this` so reverts undo the pre-transfers)
    // ------------------------------------------------------------------------------------------------------

    function execMint(IUniswapV2Pair pair, uint256 amount0, uint256 amount1, address to)
        external
        onlySelf
        returns (uint256)
    {
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
        return pair.mint(to);
    }

    function execBurn(IUniswapV2Pair pair, address holder, uint256 liquidity)
        external
        onlySelf
        returns (uint256, uint256)
    {
        vm.prank(holder);
        pair.transfer(address(pair), liquidity);
        return pair.burn(holder);
    }

    function execSwap(
        IUniswapV2Pair pair,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external onlySelf {
        if (amount0In > 0) token0.transfer(address(pair), amount0In);
        if (amount1In > 0) token1.transfer(address(pair), amount1In);
        pair.swap(amount0Out, amount1Out, to, "");
    }

    function execDonate(IUniswapV2Pair pair, uint256 amount0, uint256 amount1) external onlySelf {
        token0.transfer(address(pair), amount0);
        token1.transfer(address(pair), amount1);
    }

    function execSkim(IUniswapV2Pair pair, address to) external onlySelf {
        pair.skim(to);
    }

    function execSync(IUniswapV2Pair pair) external onlySelf {
        pair.sync();
    }

    function execTransferLp(IUniswapV2Pair pair, address from, address to, uint256 amount) external onlySelf {
        vm.prank(from);
        pair.transfer(to, amount);
    }

    // ------------------------------------------------------------------------------------------------------
    // Dual operations
    // ------------------------------------------------------------------------------------------------------

    /// @dev Runs `callData` (an exec* call with the pair argument in the first slot) on both pairs.
    function _dual(string memory op, bytes memory callH, bytes memory callC) internal returns (bool ok) {
        (bool okH, bytes memory retH) = address(this).call(callH);
        (bool okC, bytes memory retC) = address(this).call(callC);
        if (okH != okC) revert OutcomeMismatch(op, okH, okC);
        if (okH) {
            ++bothSucceeded;
            assertEq(retH, retC, string.concat(op, ": return data"));
        } else {
            ++bothReverted;
        }
        assertSameState(op);
        return okH;
    }

    function mint(uint256 amount0, uint256 amount1, uint256 actorSeed) external returns (bool) {
        address to = actors[actorSeed % ACTORS];
        return _dual(
            "mint",
            abi.encodeCall(this.execMint, (hardened, amount0, amount1, to)),
            abi.encodeCall(this.execMint, (canonical, amount0, amount1, to))
        );
    }

    function burn(uint256 actorSeed, uint256 liquidity) external returns (bool) {
        address holder = actors[actorSeed % ACTORS];
        return _dual(
            "burn",
            abi.encodeCall(this.execBurn, (hardened, holder, liquidity)),
            abi.encodeCall(this.execBurn, (canonical, holder, liquidity))
        );
    }

    function swap(uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, uint256 actorSeed)
        external
        returns (bool)
    {
        address to = actors[actorSeed % ACTORS];
        return _dual(
            "swap",
            abi.encodeCall(this.execSwap, (hardened, amount0In, amount1In, amount0Out, amount1Out, to)),
            abi.encodeCall(this.execSwap, (canonical, amount0In, amount1In, amount0Out, amount1Out, to))
        );
    }

    function donate(uint256 amount0, uint256 amount1) external returns (bool) {
        return _dual(
            "donate",
            abi.encodeCall(this.execDonate, (hardened, amount0, amount1)),
            abi.encodeCall(this.execDonate, (canonical, amount0, amount1))
        );
    }

    function skim(uint256 actorSeed) external returns (bool) {
        address to = actors[actorSeed % ACTORS];
        return
            _dual("skim", abi.encodeCall(this.execSkim, (hardened, to)), abi.encodeCall(this.execSkim, (canonical, to)));
    }

    function sync() external returns (bool) {
        return _dual("sync", abi.encodeCall(this.execSync, (hardened)), abi.encodeCall(this.execSync, (canonical)));
    }

    function transferLp(uint256 fromSeed, uint256 toSeed, uint256 amount) external returns (bool) {
        address from = actors[fromSeed % ACTORS];
        address to = actors[toSeed % ACTORS];
        return _dual(
            "transferLp",
            abi.encodeCall(this.execTransferLp, (hardened, from, to, amount)),
            abi.encodeCall(this.execTransferLp, (canonical, from, to, amount))
        );
    }

    function setProtocolFee(bool on) external {
        address recipient = on ? feeRecipient : address(0);
        hardenedFactory.setFeeTo(recipient);
        canonicalFactory.setFeeTo(recipient);
    }

    // ------------------------------------------------------------------------------------------------------
    // Views and the equivalence check
    // ------------------------------------------------------------------------------------------------------

    function reserves() public view returns (uint112 r0, uint112 r1) {
        (r0, r1,) = hardened.getReserves();
    }

    function lpBalance(uint256 actorSeed) external view returns (uint256) {
        return hardened.balanceOf(actors[actorSeed % ACTORS]);
    }

    /// @notice Every observable of the two pairs must be identical.
    function assertSameState(string memory op) public view {
        (uint112 h0, uint112 h1, uint32 hT) = hardened.getReserves();
        (uint112 c0, uint112 c1, uint32 cT) = canonical.getReserves();
        assertEq(h0, c0, string.concat(op, ": reserve0"));
        assertEq(h1, c1, string.concat(op, ": reserve1"));
        assertEq(hT, cT, string.concat(op, ": blockTimestampLast"));
        assertEq(hardened.price0CumulativeLast(), canonical.price0CumulativeLast(), string.concat(op, ": price0Cum"));
        assertEq(hardened.price1CumulativeLast(), canonical.price1CumulativeLast(), string.concat(op, ": price1Cum"));
        assertEq(hardened.kLast(), canonical.kLast(), string.concat(op, ": kLast"));
        assertEq(hardened.totalSupply(), canonical.totalSupply(), string.concat(op, ": totalSupply"));
        assertEq(
            token0.balanceOf(address(hardened)), token0.balanceOf(address(canonical)), string.concat(op, ": balance0")
        );
        assertEq(
            token1.balanceOf(address(hardened)), token1.balanceOf(address(canonical)), string.concat(op, ": balance1")
        );
        assertEq(
            hardened.balanceOf(address(0)), canonical.balanceOf(address(0)), string.concat(op, ": locked liquidity")
        );
        assertEq(
            hardened.balanceOf(feeRecipient), canonical.balanceOf(feeRecipient), string.concat(op, ": protocol fee LP")
        );
        assertEq(
            hardened.balanceOf(address(hardened)),
            canonical.balanceOf(address(canonical)),
            string.concat(op, ": LP held by pair")
        );
        for (uint256 i; i < ACTORS; ++i) {
            assertEq(
                hardened.balanceOf(actors[i]), canonical.balanceOf(actors[i]), string.concat(op, ": actor LP balance")
            );
        }
    }
}
