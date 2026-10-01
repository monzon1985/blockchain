// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only ERC-20 whose `symbol()` and `decimals()` misbehave on demand, to stress the renderer.
contract RawSymbolToken is ERC20 {
    enum SymbolMode {
        AbiString, // returns abi.encode(string(rawSymbol))
        Bytes32, // returns the first 32 bytes of rawSymbol as a bytes32 (MKR-style)
        Revert, // reverts
        BurnGas, // consumes all forwarded gas
        Empty // returns no data at all
    }

    bytes public rawSymbol;
    SymbolMode public mode;
    uint8 public rawDecimals;
    bool public decimalsReverts;

    constructor(bytes memory rawSymbol_, uint8 decimals_) ERC20("Raw Symbol Token", "") {
        rawSymbol = rawSymbol_;
        rawDecimals = decimals_;
    }

    function setSymbol(bytes calldata rawSymbol_, SymbolMode mode_) external {
        rawSymbol = rawSymbol_;
        mode = mode_;
    }

    function setDecimals(uint8 decimals_, bool reverts) external {
        rawDecimals = decimals_;
        decimalsReverts = reverts;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function symbol() public view override returns (string memory) {
        SymbolMode m = mode;
        if (m == SymbolMode.AbiString) return string(rawSymbol);
        if (m == SymbolMode.Revert) revert("no symbol");
        if (m == SymbolMode.BurnGas) {
            uint256 i;
            while (gasleft() > 0) {
                ++i;
            }
        }
        if (m == SymbolMode.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        bytes memory raw = rawSymbol;
        bytes32 word;
        assembly ("memory-safe") {
            word := mload(add(raw, 0x20))
            mstore(0x00, word)
            return(0x00, 0x20)
        }
    }

    function decimals() public view override returns (uint8) {
        if (decimalsReverts) revert("no decimals");
        return rawDecimals;
    }
}
