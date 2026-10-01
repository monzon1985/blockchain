// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {DemoToken} from "../../../contracts/demo/DemoToken.sol";

/// @notice The Ignition demo token: initial supply to the owner, owner-only mint.
contract DemoTokenTest is Test {
    DemoToken internal demo;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        demo = new DemoToken(owner, 1_000e18);
    }

    function test_initialSupplyGoesToTheOwner() public view {
        assertEq(demo.balanceOf(owner), 1_000e18);
        assertEq(demo.totalSupply(), 1_000e18);
        assertEq(demo.decimals(), 18);
        assertEq(demo.symbol(), "DEMO");
        assertEq(demo.owner(), owner);
    }

    function test_mint_byOwner() public {
        vm.prank(owner);
        demo.mint(alice, 5e18);
        assertEq(demo.balanceOf(alice), 5e18);
        assertEq(demo.totalSupply(), 1_005e18);
    }

    function test_revert_mint_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        demo.mint(alice, 1);
    }
}
