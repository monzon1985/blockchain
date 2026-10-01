// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {FixtureToken} from "../src/FixtureToken.sol";
import {FixtureVault} from "../src/FixtureVault.sol";

/// @notice Unit and fuzz tests for the traffic fixtures. The indexer derives balances, supply and
///         vault totals purely from logs, so these tests pin down the event behaviour it relies on.
contract FixturesTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    FixtureToken internal token;
    FixtureVault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new FixtureToken("Fixture USD", "fUSD", 6, owner);
        vault = new FixtureVault(IERC20(address(token)), "Fixture Vault", "fvUSD");
    }

    function test_metadata() public view {
        assertEq(token.decimals(), 6);
        assertEq(token.owner(), owner);
        assertEq(vault.decimals(), 9, "asset decimals + offset 3");
        assertEq(vault.asset(), address(token));
    }

    function test_mint_emitsTransferFromZero() public {
        vm.expectEmit(address(token));
        emit Transfer(address(0), alice, 100);
        vm.prank(owner);
        token.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.totalSupply(), 100);
    }

    function test_mint_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.mint(alice, 1);
    }

    function test_mint_revertsForZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        vm.prank(owner);
        token.mint(address(0), 1);
    }

    function test_burn_emitsTransferToZero() public {
        vm.prank(owner);
        token.mint(alice, 100);
        vm.expectEmit(address(token));
        emit Transfer(alice, address(0), 40);
        vm.prank(alice);
        token.burn(40);
        assertEq(token.balanceOf(alice), 60);
        assertEq(token.totalSupply(), 60);
    }

    function test_burn_revertsAboveBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1)
        );
        vm.prank(alice);
        token.burn(1);
    }

    function test_batchTransfer_emitsOneLogPerLeg() public {
        vm.prank(owner);
        token.mint(alice, 10);
        address[] memory to = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (to[0], to[1], amounts[0], amounts[1]) = (bob, owner, 3, 4);
        vm.expectEmit(address(token));
        emit Transfer(alice, bob, 3);
        vm.expectEmit(address(token));
        emit Transfer(alice, owner, 4);
        vm.prank(alice);
        assertTrue(token.batchTransfer(to, amounts));
        assertEq(token.balanceOf(alice), 3);
    }

    function test_batchTransfer_revertsOnEmptyBatch() public {
        vm.expectRevert(FixtureToken.EmptyBatch.selector);
        token.batchTransfer(new address[](0), new uint256[](0));
    }

    function test_batchTransfer_revertsOnLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(FixtureToken.LengthMismatch.selector, 1, 2));
        token.batchTransfer(new address[](1), new uint256[](2));
    }

    function test_batchTransfer_revertsOnInsufficientBalance() public {
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (to[0], amounts[0]) = (bob, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1)
        );
        vm.prank(alice);
        token.batchTransfer(to, amounts);
    }

    function test_vault_depositWithdrawAndDonation() public {
        vm.prank(owner);
        token.mint(alice, 1_000_000);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);

        vm.expectEmit(address(vault));
        emit Deposit(alice, alice, 1_000_000, 1_000_000_000);
        uint256 shares = vault.deposit(1_000_000, alice);
        assertEq(shares, 1_000_000_000, "1:1000 at the first deposit (offset 3)");
        vm.stopPrank();

        // A donation raises assets per share without any vault event.
        vm.prank(owner);
        token.mint(address(vault), 1_000_000);
        assertEq(vault.totalAssets(), 2_000_000);
        assertEq(vault.totalSupply(), 1_000_000_000);

        vm.startPrank(alice);
        uint256 assets = vault.previewRedeem(shares / 2);
        vm.expectEmit(address(vault));
        emit Withdraw(alice, bob, alice, assets, shares / 2);
        vault.redeem(shares / 2, bob, alice);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), assets);
        assertGt(assets, 500_000, "donation accrued to shareholders");
    }

    /// @notice Supply only changes through mint and burn, whatever the batch looks like.
    function testFuzz_batchTransferConservesSupply(uint96 minted, uint8 legs, uint256 seed) public {
        uint256 n = bound(legs, 1, 16);
        vm.prank(owner);
        token.mint(alice, minted);
        address[] memory to = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 remaining = minted;
        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
            amounts[i] = bound(uint256(keccak256(abi.encode(seed, i, "a"))), 0, remaining);
            remaining -= amounts[i];
        }
        vm.prank(alice);
        token.batchTransfer(to, amounts);
        assertEq(token.totalSupply(), minted);
        assertEq(token.balanceOf(alice), remaining + _selfPaid(to, amounts));
    }

    function _selfPaid(address[] memory to, uint256[] memory amounts)
        internal
        view
        returns (uint256 sum)
    {
        for (uint256 i; i < to.length; ++i) {
            if (to[i] == alice) sum += amounts[i];
        }
    }
}
