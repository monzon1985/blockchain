// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";

/// @notice Canonical Uniswap v2 factory ABI (v2-core 1.0.1).
interface IUniswapV2Factory {
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function setFeeTo(address) external;
}

/// @notice Canonical Uniswap v2 pair ABI (v2-core 1.0.1), restricted to what the oracle needs.
interface IUniswapV2Pair {
    function MINIMUM_LIQUIDITY() external pure returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function kLast() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}

/// @notice Deploys the canonical Uniswap v2 contracts from the bytecode shipped in the
///         Uniswap v2-core 1.0.1 npm package (`build/*.json`), with a plain CREATE.
/// @dev Pairs are then created by the canonical factory itself (CREATE2 with its embedded pair bytecode).
abstract contract CanonicalV2 is CommonBase {
    /// @dev The init-code hash of the mainnet UniswapV2Pair. The npm artifact must hash to exactly this value,
    ///      which proves the oracle is the genuine canonical bytecode (checked in CanonicalOracleTest).
    bytes32 internal constant CANONICAL_PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    string internal constant V2_BUILD = "node_modules/@uniswap/v2-core/build/";

    function _canonicalBytecode(string memory contractName) internal view returns (bytes memory) {
        string memory json = vm.readFile(string.concat(V2_BUILD, contractName, ".json"));
        // The waffle artifacts store the creation code as un-prefixed hex.
        return vm.parseBytes(string.concat("0x", vm.parseJsonString(json, ".bytecode")));
    }

    function _deployCanonicalFactory(address feeToSetter) internal returns (IUniswapV2Factory factory) {
        bytes memory initCode = abi.encodePacked(_canonicalBytecode("UniswapV2Factory"), abi.encode(feeToSetter));
        address deployed;
        assembly ("memory-safe") {
            // Plain CREATE of the canonical creation code; zero address on failure is checked below.
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "canonical factory deployment failed");
        factory = IUniswapV2Factory(deployed);
    }
}
