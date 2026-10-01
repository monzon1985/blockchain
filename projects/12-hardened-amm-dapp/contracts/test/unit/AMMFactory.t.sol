// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AMMFactory} from "../../src/AMMFactory.sol";
import {AMMPair} from "../../src/AMMPair.sol";
import {IAMMFactory} from "../../src/interfaces/IAMMFactory.sol";
import {AMMTestBase} from "../utils/AMMTestBase.sol";

contract AMMFactoryTest is AMMTestBase {
    function test_constructor_setsOwnerAndInitCodeHash() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.PAIR_INIT_CODE_HASH(), keccak256(type(AMMPair).creationCode));
        assertEq(factory.feeTo(), address(0));
        assertEq(factory.allPairsLength(), 0);
    }

    function test_createPair_deploysAtCreate2AddressWithSortedImmutableTokens() public {
        (address t0, address t1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        address expected = vm.computeCreate2Address(
            keccak256(abi.encodePacked(t0, t1)), factory.PAIR_INIT_CODE_HASH(), address(factory)
        );

        vm.expectEmit(address(factory));
        emit IAMMFactory.PairCreated(t0, t1, expected, 1);
        address pair = factory.createPair(address(tokenB), address(tokenA));

        assertEq(pair, expected);
        assertEq(factory.getPair(address(tokenA), address(tokenB)), pair);
        assertEq(factory.getPair(address(tokenB), address(tokenA)), pair);
        assertEq(factory.allPairs(0), pair);
        assertEq(factory.allPairsLength(), 1);
        assertEq(AMMPair(pair).token0(), t0);
        assertEq(AMMPair(pair).token1(), t1);
        assertEq(AMMPair(pair).factory(), address(factory));
        // The transient construction parameters are gone after the call.
        (address p0, address p1) = factory.parameters();
        assertEq(p0, address(0));
        assertEq(p1, address(0));
    }

    function test_createPair_revertsOnIdenticalTokens() public {
        vm.expectRevert(abi.encodeWithSelector(IAMMFactory.IdenticalAddresses.selector, address(tokenA)));
        factory.createPair(address(tokenA), address(tokenA));
    }

    function test_createPair_revertsOnZeroAddressInEitherPosition() public {
        vm.expectRevert(IAMMFactory.ZeroAddress.selector);
        factory.createPair(address(0), address(tokenA));
        vm.expectRevert(IAMMFactory.ZeroAddress.selector);
        factory.createPair(address(tokenA), address(0));
    }

    function test_createPair_revertsWhenPairExistsInEitherOrder() public {
        address pair = factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(abi.encodeWithSelector(IAMMFactory.PairExists.selector, pair));
        factory.createPair(address(tokenA), address(tokenB));
        vm.expectRevert(abi.encodeWithSelector(IAMMFactory.PairExists.selector, pair));
        factory.createPair(address(tokenB), address(tokenA));
    }

    function test_createPair_revertsForTokenWithoutCode() public {
        address noCodeLow = address(1); // sorts below every token
        address noCodeHigh = address(type(uint160).max); // sorts above every token
        vm.expectRevert(abi.encodeWithSelector(IAMMFactory.TokenHasNoCode.selector, noCodeLow));
        factory.createPair(noCodeLow, address(tokenA));
        vm.expectRevert(abi.encodeWithSelector(IAMMFactory.TokenHasNoCode.selector, noCodeHigh));
        factory.createPair(address(tokenA), noCodeHigh);
    }

    function test_pairConstructor_revertsOutsideTheFactory() public {
        // The pair reads its tokens from msg.sender.parameters(); this test contract has no such function.
        vm.expectRevert();
        new AMMPair();
    }

    function test_setFeeTo_onlyOwner_emitsAndAllowsZero() public {
        vm.expectEmit(address(factory));
        emit IAMMFactory.FeeToUpdated(address(0), feeRecipient);
        vm.prank(owner);
        factory.setFeeTo(feeRecipient);
        assertEq(factory.feeTo(), feeRecipient);

        vm.expectEmit(address(factory));
        emit IAMMFactory.FeeToUpdated(feeRecipient, address(0));
        vm.prank(owner);
        factory.setFeeTo(address(0));
        assertEq(factory.feeTo(), address(0));
    }

    function test_setFeeTo_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        factory.setFeeTo(alice);
    }

    function test_ownership_isTwoStep() public {
        vm.prank(owner);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), owner, "owner unchanged until accepted");
        assertEq(factory.pendingOwner(), alice);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        factory.acceptOwnership();

        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AMMFactory(address(0));
    }
}
