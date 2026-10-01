// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";
import { FixedPointMath } from "kestrel/lib/FixedPointMath.sol";
import { GovToken } from "shared/GovToken.sol";

/// @notice Generic ERC-3156 borrower used by the symbolic governance property: it flash-mints
///         any amount and tries to move the treasury through the emergency path.
contract SymbolicFlashBorrower is IERC3156FlashBorrower {
    GovToken internal immutable token;
    KestrelGovernor internal immutable governor;

    constructor(GovToken _token, KestrelGovernor _governor) {
        token = _token;
        governor = _governor;
    }

    function attack(uint256 amount) external {
        token.flashLoan(this, address(token), amount, "");
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        uint256 treasury = token.balanceOf(address(governor));
        try governor.emergencyExecute(
            address(token), 0, abi.encodeCall(IERC20.transfer, (address(this), treasury))
        ) { }
            catch { }
        token.approve(address(token), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @title FixedProperties
/// @notice Halmos symbolic properties, stated against the REAL contracts. They hold on the fixed
///         build (`FOUNDRY_PROFILE=fixed halmos --match-contract FixedProperties`); the blind run
///         executes them on the vulnerable build, where the vault-rounding, governance and
///         checked-shift properties produce counterexamples.
/// @dev    Bounds, stated honestly:
///         - Vault amounts are fully symbolic 64-bit values (up to ~18.4 ETH per operation).
///           Share prices are concrete, non-integer states whose divisor (`totalManaged` for
///           withdraw/deposit, `totalSupply` for redeem) is a power of two, so the solver's
///           256-bit division is a shift; general 256-bit division by an arbitrary divisor times
///           out in both yices and z3. Arbitrary states are covered by the fuzzed regression
///           `testFuzz_regression_withdrawRoundsForTheVault`.
///         - The flash-mint amount is symbolic up to 2**128.
///         - The checked shift is proved for every n and every in-word shift, by an explicit case
///           split over the 256 shift amounts (each case is then a constant shift).
contract FixedProperties is Test {
    uint256 internal constant TREASURY = 100_000e18;
    uint256 internal constant SUPPLY = 1_000_000e18;

    /// @dev Accept ETH from the vault.
    receive() external payable { }

    /// @dev Vault with `deposit` wei of first deposit (supply == deposit, including the dead
    ///      shares) and `managedTarget` wei of managed assets after accruing yield.
    function _vault(uint256 deposit, uint256 managedTarget) internal returns (KestrelVault vault) {
        vault = new KestrelVault();
        vm.deal(address(this), 100 ether);
        vault.deposit{ value: deposit }(address(this), 0);
        if (managedTarget > deposit) vault.accrue{ value: managedTarget - deposit }();
    }

    /// @dev Three withdraw/deposit states with a power-of-two `totalManaged`: share prices
    ///      ~1.37, ~84.9 and ~1.84.
    function _managedPow2State(uint8 state) internal returns (KestrelVault) {
        if (state % 3 == 0) return _vault(3000, 1 << 12);
        if (state % 3 == 1) return _vault(12_345, 1 << 20);
        return _vault(10 ether, 1 << 64);
    }

    /// @dev Two redeem states with a power-of-two `totalSupply`: share prices ~1.46 and ~1.17.
    function _supplyPow2State(uint8 state) internal returns (KestrelVault) {
        if (state % 2 == 0) return _vault(1 << 12, 6000);
        return _vault(1 << 64, (1 << 64) + 3.141_592_653_589_793_238 ether);
    }

    // --- Property 1: vault rounding always favors the vault ---------------------------------

    /// @notice A withdrawal never burns fewer shares than the ETH it pays out is worth:
    ///         `burned * totalManaged >= assets * totalSupply`.
    function check_withdrawNeverUnderburnsShares(uint8 state, uint64 assets) public {
        KestrelVault vault = _managedPow2State(state);
        uint256 supply = vault.totalSupply();
        uint256 managed = vault.totalManaged();
        vm.assume(assets > 0 && assets <= managed);
        uint256 burned = vault.withdraw(assets, address(this));
        assert(burned * managed >= uint256(assets) * supply);
    }

    /// @notice A deposit never mints more shares than the ETH it brings is worth:
    ///         `minted * totalManaged <= assets * totalSupply`.
    function check_depositNeverOvermints(uint8 state, uint64 assets) public {
        KestrelVault vault = _managedPow2State(state);
        uint256 supply = vault.totalSupply();
        uint256 managed = vault.totalManaged();
        vm.assume(assets > 0);
        uint256 minted = vault.deposit{ value: assets }(address(this), 0);
        assert(minted * managed <= uint256(assets) * supply);
    }

    /// @notice A redemption never pays more ETH than the shares it burns are worth:
    ///         `assets * totalSupply <= shares * totalManaged`.
    function check_redeemNeverOverpays(uint8 state, uint64 shares) public {
        KestrelVault vault = _supplyPow2State(state);
        uint256 supply = vault.totalSupply();
        uint256 managed = vault.totalManaged();
        vm.assume(shares > 0 && shares <= vault.balanceOf(address(this)));
        uint256 assets = vault.redeem(shares, address(this));
        assert(assets * supply <= uint256(shares) * managed);
    }

    // --- Property 2: governance vote weight is snapshot-based --------------------------------

    function _governance() internal returns (GovToken token, KestrelGovernor governor) {
        token = new GovToken(address(this), SUPPLY);
        token.delegate(address(this));
        governor = new KestrelGovernor(token, 10, 4000, 6666, 50);
        token.transfer(address(governor), TREASURY);
        vm.roll(block.number + 51);
    }

    /// @notice No flash-minted amount lets a stakeless borrower move the treasury through the
    ///         emergency path.
    function check_flashMintCannotPassEmergencyQuorum(uint256 loan) public {
        (GovToken token, KestrelGovernor governor) = _governance();
        vm.assume(loan > 0 && loan <= type(uint128).max);
        SymbolicFlashBorrower borrower = new SymbolicFlashBorrower(token, governor);
        borrower.attack(loan);
        assert(token.balanceOf(address(governor)) == TREASURY);
    }

    /// @notice A vote counts the voter's power at the proposal snapshot, whatever the voter
    ///         acquires afterwards.
    function check_castVoteUsesSnapshotWeight(uint128 extra) public {
        (GovToken token, KestrelGovernor governor) = _governance();
        address voter = address(0xBEEF);
        token.transfer(voter, 1000e18);
        vm.prank(voter);
        token.delegate(voter);
        vm.roll(block.number + 1);
        uint256 id = governor.propose(address(token), 0, "");
        uint256 snapshotWeight = token.getPastVotes(voter, block.number - 1);
        token.mint(voter, extra); // acquired after the snapshot
        vm.prank(voter);
        governor.castVote(id, true);
        (,,,,, uint256 forVotes,,) = governor.proposals(id);
        assert(forVotes == snapshotWeight);
    }

    // --- Property 3: a checked shift reported as safe is lossless -----------------------------

    /// @notice `checkedShl(n, shift)` reports success only when no set bit of `n` is lost, for
    ///         every `n` and every in-word `shift` (explicit case split over all 256 values).
    function check_checkedShlIsLossless(uint256 n, uint8 shiftSeed) public pure {
        uint256 shift;
        for (uint256 k = 0; k < 256; ++k) {
            if (k == shiftSeed) {
                shift = k;
                break;
            }
        }
        (uint256 result, bool overflow) = FixedPointMath.checkedShl(n, shift);
        if (!overflow) assert(result >> shift == n);
    }

    /// @notice A shift by a full word or more only succeeds for zero.
    function check_checkedShlFullWord(uint256 n, uint16 extra) public pure {
        (, bool overflow) = FixedPointMath.checkedShl(n, 256 + uint256(extra));
        assert(overflow || n == 0);
    }
}
