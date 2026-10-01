// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin-contracts/proxy/Clones.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "@openzeppelin-contracts/utils/Errors.sol";
import {ForwarderFactory} from "../src/ForwarderFactory.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {TestToken} from "./mocks/TestToken.sol";
import {NoReturnToken} from "./mocks/NoReturnToken.sol";
import {FalseReturnToken} from "./mocks/FalseReturnToken.sol";

/// @dev Rejects plain ETH, to exercise the native flush failure path.
contract RejectingWallet {}

contract ForwarderFactoryTest is Test {
    event ForwarderDeployed(bytes32 indexed salt, address indexed forwarder);
    event BatchFlushed(address indexed token, uint256 forwarders, uint256 total);
    event Flushed(address indexed token, uint256 amount);

    address payable internal hot = payable(makeAddr("hot"));
    address internal sweeper = makeAddr("sweeper");
    address internal stranger = makeAddr("stranger");

    ForwarderFactory internal factory;
    TestToken internal token;

    function setUp() public {
        factory = new ForwarderFactory(hot, sweeper);
        token = new TestToken();
    }

    // ------------------------------------------------------------------ helpers

    function _salts(uint256 n) internal pure returns (bytes32[] memory salts) {
        salts = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            salts[i] = keccak256(bytes(string.concat("user-", vm.toString(i))));
        }
    }

    /// @dev Reference CREATE2 computation for an ERC-1167 clone, written independently from
    ///      OpenZeppelin's assembly so the two can be compared (the Go engine uses this formula).
    function _referenceAddress(address deployer, address impl, bytes32 salt)
        internal
        pure
        returns (address)
    {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initCode)));
        return address(uint160(uint256(h)));
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_setsImmutablesAndOwner() public view {
        assertEq(factory.DESTINATION(), hot);
        assertEq(factory.owner(), sweeper);
        DepositForwarder impl = DepositForwarder(factory.IMPLEMENTATION());
        assertEq(impl.FACTORY(), address(factory));
        assertEq(impl.DESTINATION(), hot);
    }

    function test_constructor_revertsOnZeroDestination() public {
        vm.expectRevert(ForwarderFactory.ZeroDestination.selector);
        new ForwarderFactory(payable(address(0)), sweeper);
    }

    function test_forwarderConstructor_revertsOnZeroDestination() public {
        vm.expectRevert(DepositForwarder.ZeroDestination.selector);
        new DepositForwarder(payable(address(0)));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ForwarderFactory(hot, address(0));
    }

    // ------------------------------------------------------------------ addressing

    function test_saltFor_isKeccakOfUserId() public view {
        assertEq(factory.saltFor("alice"), keccak256(bytes("alice")));
    }

    function test_forwarderAddress_matchesDeployment() public {
        bytes32 salt = factory.saltFor("alice");
        address predicted = factory.forwarderAddress(salt);
        assertFalse(factory.isDeployed(salt));
        vm.prank(sweeper);
        address deployed = factory.deploy(salt);
        assertEq(deployed, predicted);
        assertTrue(factory.isDeployed(salt));
    }

    function test_deploy_isIdempotentAndEmitsOnce() public {
        bytes32 salt = factory.saltFor("alice");
        address predicted = factory.forwarderAddress(salt);
        vm.expectEmit(address(factory));
        emit ForwarderDeployed(salt, predicted);
        vm.prank(sweeper);
        factory.deploy(salt);

        vm.recordLogs();
        vm.prank(sweeper);
        assertEq(factory.deploy(salt), predicted);
        assertEq(vm.getRecordedLogs().length, 0, "second deploy must not emit");
    }

    function test_deploy_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        factory.deploy(bytes32(0));
    }

    // ------------------------------------------------------------------ flushMany

    function test_flushMany_deploysLazilyAndSweepsEverything() public {
        bytes32[] memory salts = _salts(3);
        uint256 expected;
        for (uint256 i; i < salts.length; ++i) {
            uint256 amount = (i + 1) * 1e6;
            token.mint(factory.forwarderAddress(salts[i]), amount);
            expected += amount;
        }

        vm.expectEmit(address(factory));
        emit BatchFlushed(address(token), 3, expected);
        vm.prank(sweeper);
        uint256 total = factory.flushMany(salts, IERC20(address(token)));

        assertEq(total, expected);
        assertEq(token.balanceOf(hot), expected);
        for (uint256 i; i < salts.length; ++i) {
            assertEq(token.balanceOf(factory.forwarderAddress(salts[i])), 0);
            assertTrue(factory.isDeployed(salts[i]));
        }
    }

    function test_flushMany_emitsFlushedFromTheForwarder() public {
        bytes32[] memory salts = _salts(1);
        address fwd = factory.forwarderAddress(salts[0]);
        token.mint(fwd, 42);
        vm.expectEmit(fwd);
        emit Flushed(address(token), 42);
        vm.prank(sweeper);
        factory.flushMany(salts, IERC20(address(token)));
    }

    function test_flushMany_zeroBalanceDeploysButMovesNothing() public {
        bytes32[] memory salts = _salts(2);
        vm.prank(sweeper);
        assertEq(factory.flushMany(salts, IERC20(address(token))), 0);
        assertTrue(factory.isDeployed(salts[0]));
        assertEq(token.balanceOf(hot), 0);
    }

    function test_flushMany_duplicateSaltsAreHarmless() public {
        bytes32[] memory salts = new bytes32[](3);
        salts[0] = salts[1] = salts[2] = keccak256("dup");
        token.mint(factory.forwarderAddress(salts[0]), 500);
        vm.prank(sweeper);
        assertEq(factory.flushMany(salts, IERC20(address(token))), 500);
        assertEq(token.balanceOf(hot), 500);
    }

    function test_flushMany_canFlushTheSameForwarderAgain() public {
        bytes32[] memory salts = _salts(1);
        address fwd = factory.forwarderAddress(salts[0]);
        token.mint(fwd, 10);
        vm.prank(sweeper);
        factory.flushMany(salts, IERC20(address(token)));
        token.mint(fwd, 7);
        vm.prank(sweeper);
        assertEq(factory.flushMany(salts, IERC20(address(token))), 7);
        assertEq(token.balanceOf(hot), 17);
    }

    function test_flushMany_revertsOnEmptyBatch() public {
        vm.expectRevert(ForwarderFactory.EmptyBatch.selector);
        vm.prank(sweeper);
        factory.flushMany(new bytes32[](0), IERC20(address(token)));
    }

    function test_flushMany_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        factory.flushMany(_salts(1), IERC20(address(token)));
    }

    function test_flushMany_handlesTokensWithoutReturnValue() public {
        NoReturnToken usdtLike = new NoReturnToken();
        bytes32[] memory salts = _salts(2);
        usdtLike.mint(factory.forwarderAddress(salts[0]), 3);
        usdtLike.mint(factory.forwarderAddress(salts[1]), 4);
        vm.prank(sweeper);
        assertEq(factory.flushMany(salts, IERC20(address(usdtLike))), 7);
        assertEq(usdtLike.balanceOf(hot), 7);
    }

    function test_flushMany_revertsWhenTokenReturnsFalse() public {
        FalseReturnToken bad = new FalseReturnToken();
        bytes32[] memory salts = _salts(1);
        bad.mint(factory.forwarderAddress(salts[0]), 1);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad))
        );
        vm.prank(sweeper);
        factory.flushMany(salts, IERC20(address(bad)));
    }

    // ------------------------------------------------------------------ forwarder access control

    function test_flush_revertsWhenCalledDirectlyOnClone() public {
        bytes32 salt = keccak256("alice");
        vm.prank(sweeper);
        address fwd = factory.deploy(salt);
        token.mint(fwd, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositForwarder.UnauthorizedCaller.selector, stranger, address(factory)
            )
        );
        vm.prank(stranger);
        DepositForwarder(fwd).flush(IERC20(address(token)));
    }

    function test_flush_revertsWhenOwnerBypassesFactory() public {
        bytes32 salt = keccak256("alice");
        vm.prank(sweeper);
        address fwd = factory.deploy(salt);
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositForwarder.UnauthorizedCaller.selector, sweeper, address(factory)
            )
        );
        vm.prank(sweeper);
        DepositForwarder(fwd).flushNative();
    }

    function test_flush_revertsOnImplementation() public {
        DepositForwarder impl = DepositForwarder(factory.IMPLEMENTATION());
        vm.expectRevert(
            abi.encodeWithSelector(
                DepositForwarder.UnauthorizedCaller.selector, stranger, address(factory)
            )
        );
        vm.prank(stranger);
        impl.flush(IERC20(address(token)));
    }

    // ------------------------------------------------------------------ native currency

    function test_deployedForwarder_rejectsPlainEth() public {
        vm.prank(sweeper);
        address fwd = factory.deploy(keccak256("alice"));
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = fwd.call{value: 1 ether}("");
        assertFalse(ok, "deployed forwarders must not accept ETH");
    }

    function test_flushNativeMany_recoversPreDeploymentEth() public {
        bytes32[] memory salts = _salts(2);
        vm.deal(factory.forwarderAddress(salts[0]), 1 ether);
        vm.deal(factory.forwarderAddress(salts[1]), 2 ether);

        vm.expectEmit(address(factory));
        emit BatchFlushed(address(0), 2, 3 ether);
        vm.prank(sweeper);
        assertEq(factory.flushNativeMany(salts), 3 ether);
        assertEq(hot.balance, 3 ether);
        assertEq(factory.forwarderAddress(salts[0]).balance, 0);
    }

    function test_flushNativeMany_zeroBalanceIsNoop() public {
        vm.prank(sweeper);
        assertEq(factory.flushNativeMany(_salts(1)), 0);
    }

    function test_flushNativeMany_revertsOnEmptyBatch() public {
        vm.expectRevert(ForwarderFactory.EmptyBatch.selector);
        vm.prank(sweeper);
        factory.flushNativeMany(new bytes32[](0));
    }

    function test_flushNativeMany_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        factory.flushNativeMany(_salts(1));
    }

    function test_flushNativeMany_bubblesDestinationRejection() public {
        RejectingWallet wallet = new RejectingWallet();
        ForwarderFactory f = new ForwarderFactory(payable(address(wallet)), sweeper);
        bytes32[] memory salts = _salts(1);
        vm.deal(f.forwarderAddress(salts[0]), 1 ether);
        vm.expectRevert(Errors.FailedCall.selector);
        vm.prank(sweeper);
        f.flushNativeMany(salts);
    }

    // ------------------------------------------------------------------ ownership

    function test_renounceOwnership_alwaysReverts() public {
        vm.expectRevert(ForwarderFactory.OwnershipCannotBeRenounced.selector);
        vm.prank(sweeper);
        factory.renounceOwnership();
        assertEq(factory.owner(), sweeper);
    }

    function test_ownership_isTwoStep() public {
        address next = makeAddr("next");
        vm.prank(sweeper);
        factory.transferOwnership(next);
        assertEq(factory.owner(), sweeper, "ownership moves only on accept");
        assertEq(factory.pendingOwner(), next);

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        factory.acceptOwnership();

        vm.prank(next);
        factory.acceptOwnership();
        assertEq(factory.owner(), next);

        // The old sweeper key loses its rights immediately.
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, sweeper)
        );
        vm.prank(sweeper);
        factory.deploy(bytes32(0));
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        factory.transferOwnership(stranger);
    }

    // ------------------------------------------------------------------ fuzz

    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_forwarderAddress_matchesReferenceAndOpenZeppelin(bytes32 salt) public view {
        address predicted = factory.forwarderAddress(salt);
        assertEq(predicted, _referenceAddress(address(factory), factory.IMPLEMENTATION(), salt));
        assertEq(
            predicted,
            Clones.predictDeterministicAddress(factory.IMPLEMENTATION(), salt, address(factory))
        );
    }

    function testFuzz_deploy_landsOnPredictedAddress(bytes32 salt) public {
        address predicted = factory.forwarderAddress(salt);
        vm.prank(sweeper);
        assertEq(factory.deploy(salt), predicted);
        assertGt(predicted.code.length, 0);
    }

    function testFuzz_flushMany_conservesTokens(uint256 seed, uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 24);
        bytes32[] memory salts = new bytes32[](count);
        uint256 expected;
        for (uint256 i; i < count; ++i) {
            salts[i] = keccak256(abi.encode(seed, i));
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i, "amt"))), 0, 1e15);
            token.mint(factory.forwarderAddress(salts[i]), amount);
            expected += amount;
        }
        uint256 supplyBefore = token.totalSupply();
        vm.prank(sweeper);
        uint256 total = factory.flushMany(salts, IERC20(address(token)));
        assertEq(total, expected);
        assertEq(token.balanceOf(hot), expected);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function testFuzz_nonOwnerCannotFlush(address caller) public {
        vm.assume(caller != sweeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        factory.flushMany(_salts(1), IERC20(address(token)));
    }

    function testFuzz_nativeFlush_movesExactBalance(uint96 amount) public {
        bytes32[] memory salts = _salts(1);
        vm.deal(factory.forwarderAddress(salts[0]), amount);
        vm.prank(sweeper);
        assertEq(factory.flushNativeMany(salts), amount);
        assertEq(hot.balance, amount);
    }
}
