// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {StablecoinTestBase} from "../utils/StablecoinTestBase.sol";

/// @notice Differential check of the rolling 24 h minter limit against a naive reference model: a mint must succeed
///         exactly when the sum of this minter's mints in the half-open window (now - 24 h, now] plus the new amount
///         stays within the limit.
contract RateLimitFuzzTest is StablecoinTestBase {
    uint256 internal constant STEPS = 24;
    uint208 internal constant LIMIT = 1000e6;

    uint256[] internal mintTimes;
    uint256[] internal mintAmounts;

    function setUp() public override {
        super.setUp();
        vm.prank(masterMinter);
        token.configureMinter(minter, type(uint256).max, LIMIT);
    }

    function _windowSum(uint256 nowTs) internal view returns (uint256 sum) {
        for (uint256 i; i < mintTimes.length; ++i) {
            if (mintTimes[i] + 24 hours > nowTs) sum += mintAmounts[i];
        }
    }

    function testFuzz_rollingLimitMatchesReferenceModel(uint256[STEPS] calldata gaps, uint256[STEPS] calldata amounts)
        public
    {
        for (uint256 i; i < STEPS; ++i) {
            vm.warp(block.timestamp + bound(gaps[i], 0, 9 hours));
            if (block.timestamp - _latestAsOf() > 20 hours) _attest(INITIAL_RESERVES);
            uint256 amount = bound(amounts[i], 1, LIMIT);
            uint256 used = _windowSum(block.timestamp);
            assertEq(token.minterWindowAvailable(minter), LIMIT - used, "available == limit - reference usage");
            if (used + amount <= LIMIT) {
                _mint(alice, amount);
                mintTimes.push(block.timestamp);
                mintAmounts.push(amount);
            } else {
                vm.prank(minter);
                vm.expectRevert(abi.encodeWithSelector(MinterRateLimitExceeded.selector, minter, LIMIT - used, amount));
                token.mint(alice, amount);
            }
            assertLe(_windowSum(block.timestamp), LIMIT);
        }
    }

    function _latestAsOf() internal view returns (uint256 asOf) {
        (, asOf,,) = token.latestReserveAttestation();
    }
}
