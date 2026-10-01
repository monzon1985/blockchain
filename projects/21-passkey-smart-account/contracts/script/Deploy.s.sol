// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";

import {IEntryPoint} from "@openzeppelin/contracts/interfaces/IERC4337.sol";

import {PasskeyAccountFactory} from "../src/PasskeyAccountFactory.sol";
import {TestUSD} from "../src/TestUSD.sol";
import {TokenPaymaster} from "../src/TokenPaymaster.sol";

/// @notice Deploys the factory (and its implementation), TestUSD and the paymaster against an existing EntryPoint v0.9.
/// @dev Keystore-based, no raw keys:
/// `forge script script/Deploy.s.sol --rpc-url <url> --account <keystore> --sender <address> --broadcast`.
/// Environment: `ENTRY_POINT` (default: canonical v0.9 address), `ADMIN` (default: the broadcaster),
/// `TOKEN_PER_NATIVE` (default 3000 TUSD per ETH). Staking and funding the paymaster are separate admin calls.
/// Technical demo: TestUSD is a valueless test token.
contract Deploy is Script {
    /// @notice Canonical EntryPoint v0.9 address.
    address public constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    /// @notice Runs the deployment.
    /// @return factory The account factory.
    /// @return usd The test token.
    /// @return paymaster The token paymaster.
    function run() external returns (PasskeyAccountFactory factory, TestUSD usd, TokenPaymaster paymaster) {
        IEntryPoint entryPoint = IEntryPoint(vm.envOr("ENTRY_POINT", ENTRY_POINT_V09));
        uint256 price = vm.envOr("TOKEN_PER_NATIVE", uint256(3000e6));
        vm.startBroadcast();
        address admin = vm.envOr("ADMIN", msg.sender);
        factory = new PasskeyAccountFactory(entryPoint);
        usd = new TestUSD(admin);
        paymaster = new TokenPaymaster(entryPoint, usd, admin, price);
        vm.stopBroadcast();
    }
}
