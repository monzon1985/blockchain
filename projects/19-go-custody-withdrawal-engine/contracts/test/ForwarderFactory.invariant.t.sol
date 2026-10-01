// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ForwarderFactory} from "../src/ForwarderFactory.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {TestToken} from "./mocks/TestToken.sol";

/// @dev Drives random deposits, batch flushes and unauthorized flush attempts against one factory.
contract ForwarderHandler is Test {
    uint256 internal constant USERS = 8;

    ForwarderFactory public immutable factory;
    TestToken public immutable token;
    address public immutable sweeper;
    address payable public immutable hot;

    bytes32[USERS] internal salts;

    /// Ghost: tokens minted to forwarder addresses.
    uint256 public ghostMinted;
    /// Ghost: tokens reported as moved by successful flushMany calls.
    uint256 public ghostFlushed;
    /// Ghost: wei forced into forwarder addresses.
    uint256 public ghostNative;
    /// Ghost: wei reported as moved by successful flushNativeMany calls.
    uint256 public ghostNativeFlushed;
    /// Ghost: set if any caller other than the factory owner ever moved funds.
    bool public ghostUnauthorizedFlush;

    constructor(ForwarderFactory factory_, TestToken token_, address sweeper_) {
        factory = factory_;
        token = token_;
        sweeper = sweeper_;
        hot = factory_.DESTINATION();
        for (uint256 i; i < USERS; ++i) {
            salts[i] = keccak256(bytes(string.concat("user-", vm.toString(i))));
        }
    }

    function forwarder(uint256 i) public view returns (address) {
        return factory.forwarderAddress(salts[i]);
    }

    function userCount() external pure returns (uint256) {
        return USERS;
    }

    function deposit(uint256 userSeed, uint256 amount) external {
        uint256 i = bound(userSeed, 0, USERS - 1);
        amount = bound(amount, 1, 1e18);
        token.mint(forwarder(i), amount);
        ghostMinted += amount;
    }

    function depositNative(uint256 userSeed, uint256 amount) external {
        uint256 i = bound(userSeed, 0, USERS - 1);
        amount = bound(amount, 1, 100 ether);
        address fwd = forwarder(i);
        vm.deal(fwd, fwd.balance + amount);
        ghostNative += amount;
    }

    function flushSubset(uint8 mask) external {
        bytes32[] memory batch = _batch(mask);
        vm.prank(sweeper);
        ghostFlushed += factory.flushMany(batch, IERC20(address(token)));
    }

    function flushNativeSubset(uint8 mask) external {
        bytes32[] memory batch = _batch(mask);
        vm.prank(sweeper);
        ghostNativeFlushed += factory.flushNativeMany(batch);
    }

    function strangerFlush(address caller, uint8 mask) external {
        // The owner (through the factory) and the factory itself are the legitimate callers.
        if (caller == sweeper || caller == address(factory)) return;
        // Pranking as a counterfactual forwarder address would give it a nonce, which no real
        // account can do without that address's private key, and would make CREATE2 collide.
        for (uint256 i; i < USERS; ++i) {
            if (caller == forwarder(i)) return;
        }
        bytes32[] memory batch = _batch(mask);
        vm.prank(caller);
        try factory.flushMany(batch, IERC20(address(token))) {
            ghostUnauthorizedFlush = true;
        } catch {}
        // Try the forwarder directly as well, bypassing the factory.
        address fwd = forwarder(uint256(mask) % USERS);
        if (fwd.code.length != 0) {
            vm.prank(caller);
            try DepositForwarder(fwd).flush(IERC20(address(token))) {
                ghostUnauthorizedFlush = true;
            } catch {}
        }
    }

    function _batch(uint8 mask) internal view returns (bytes32[] memory batch) {
        uint256 bits = uint256(mask) == 0 ? 1 : uint256(mask);
        uint256 n;
        for (uint256 i; i < USERS; ++i) {
            if (bits & (1 << i) != 0) ++n;
        }
        batch = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < USERS; ++i) {
            if (bits & (1 << i) != 0) batch[k++] = salts[i];
        }
    }
}

/// @title Forwarder factory invariants
/// @notice Stateful fuzzing of deposits and sweeps. The properties are listed in the README.
contract ForwarderFactoryInvariantTest is Test {
    ForwarderFactory internal factory;
    TestToken internal token;
    ForwarderHandler internal handler;

    function setUp() public {
        address sweeper = makeAddr("sweeper");
        factory = new ForwarderFactory(payable(makeAddr("hot")), sweeper);
        token = new TestToken();
        handler = new ForwarderHandler(factory, token, sweeper);
        targetContract(address(handler));
    }

    function _forwarderTokenBalances() internal view returns (uint256 sum) {
        for (uint256 i; i < handler.userCount(); ++i) {
            sum += token.balanceOf(handler.forwarder(i));
        }
    }

    function _forwarderNativeBalances() internal view returns (uint256 sum) {
        for (uint256 i; i < handler.userCount(); ++i) {
            sum += handler.forwarder(i).balance;
        }
    }

    /// F1. Tokens are conserved: hot wallet + all forwarders == everything ever deposited.
    function invariant_tokenConservation() public view {
        assertEq(
            token.balanceOf(factory.DESTINATION()) + _forwarderTokenBalances(),
            handler.ghostMinted()
        );
    }

    /// F2. The hot wallet only ever receives tokens through flushMany, and flushMany reports
    ///     exactly what it moved.
    function invariant_hotWalletEqualsReportedFlushes() public view {
        assertEq(token.balanceOf(factory.DESTINATION()), handler.ghostFlushed());
    }

    /// F3. Native currency is conserved the same way.
    function invariant_nativeConservation() public view {
        assertEq(factory.DESTINATION().balance + _forwarderNativeBalances(), handler.ghostNative());
        assertEq(factory.DESTINATION().balance, handler.ghostNativeFlushed());
    }

    /// F4. No caller other than the owner (through the factory) ever moves funds.
    function invariant_noUnauthorizedFlush() public view {
        assertFalse(handler.ghostUnauthorizedFlush());
    }

    /// F5. Every deployed forwarder sits at its predicted address and points at the factory's
    ///     implementation, so the Go engine's off-chain address derivation stays valid.
    function invariant_deployedForwardersAreGenuine() public view {
        for (uint256 i; i < handler.userCount(); ++i) {
            address fwd = handler.forwarder(i);
            if (fwd.code.length == 0) continue;
            assertEq(DepositForwarder(fwd).FACTORY(), address(factory));
            assertEq(DepositForwarder(fwd).DESTINATION(), factory.DESTINATION());
            assertEq(fwd.code.length, 45, "ERC-1167 runtime is 45 bytes");
        }
    }
}
