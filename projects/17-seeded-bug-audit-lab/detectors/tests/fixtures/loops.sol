// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

contract LoopPositives {
    // POSITIVE: (amount / rate) * factor inside a loop.
    function rewards(uint256[] calldata amts, uint256 rate, uint256 factor)
        external
        pure
        returns (uint256 total)
    {
        for (uint256 i = 0; i < amts.length; i++) {
            total += (amts[i] / rate) * factor;
        }
    }

    // POSITIVE: (price / 2) * mult inside a loop.
    function shares(uint256 n, uint256 price, uint256 mult) external pure returns (uint256 acc) {
        for (uint256 i = 0; i < n; i++) {
            acc += (price / 2) * mult;
        }
    }
}

contract LoopNegatives {
    // NEGATIVE: divide before multiply, but NOT in a loop.
    function once(uint256 a, uint256 b, uint256 c) external pure returns (uint256) {
        return (a / b) * c;
    }

    // NEGATIVE: loop, but multiplication happens before the division (correct order).
    function correct(uint256 n, uint256 a, uint256 b, uint256 c) external pure returns (uint256 acc) {
        for (uint256 i = 0; i < n; i++) {
            acc += a * c / b;
        }
    }

    // NEGATIVE: loop with no division/multiplication interplay.
    function total(uint256[] calldata xs) external pure returns (uint256 s) {
        for (uint256 i = 0; i < xs.length; i++) {
            s += xs[i];
        }
    }
}
