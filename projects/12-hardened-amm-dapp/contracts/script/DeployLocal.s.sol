// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {console2} from "forge-std/Script.sol";

import {AMMFactory} from "../src/AMMFactory.sol";
import {AMMRouter} from "../src/AMMRouter.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Deploy} from "./Deploy.s.sol";

/// @notice Local demo deployment for anvil: core protocol, three demo tokens with 6 / 18 / 24 decimals, two
///         seeded pools (so TUSD -> TGLD needs a two-hop route), demo balances for the given accounts, and a
///         JSON manifest for the dApp. Driven by `web/scripts/dev.mjs` and `web/scripts/e2e-chain.mjs` with
///         anvil's unlocked accounts (`--unlocked --sender`), so no key material is involved.
///
/// Environment:
///   AMM_FUND_ACCOUNTS   comma-separated addresses that receive demo tokens (optional)
///   AMM_DEPLOYMENT_OUT  manifest path, relative to contracts/ (default deployments/local.json)
contract DeployLocal is Deploy {
    struct Demo {
        AMMFactory factory;
        AMMRouter router;
        MockERC20 tusd;
        MockERC20 teth;
        MockERC20 tgld;
    }

    function run() external override returns (AMMFactory, AMMRouter) {
        uint256 startBlock = block.number;
        address[] memory fund = vm.envOr("AMM_FUND_ACCOUNTS", ",", new address[](0));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Demo memory d;
        (d.factory, d.router) = _deployCore(deployer);
        d.tusd = new MockERC20("Test Dollar", "TUSD", 6);
        d.teth = new MockERC20("Test Ether", "TETH", 18);
        d.tgld = new MockERC20("Test Gold", "TGLD", 24);

        // Seed: 1 TETH = 3,000 TUSD and 1 TGLD = 2 TETH (so 1 TGLD ~ 6,000 TUSD through the two hops).
        d.teth.mint(deployer, 1000 ether);
        d.tusd.mint(deployer, 1_500_000e6);
        d.tgld.mint(deployer, 250e24);
        d.teth.approve(address(d.router), type(uint256).max);
        d.tusd.approve(address(d.router), type(uint256).max);
        d.tgld.approve(address(d.router), type(uint256).max);
        uint256 deadline = block.timestamp + 1 hours;
        d.router.addLiquidity(address(d.teth), address(d.tusd), 500 ether, 1_500_000e6, 0, 0, deployer, deadline);
        d.router.addLiquidity(address(d.tgld), address(d.teth), 250e24, 500 ether, 0, 0, deployer, deadline);

        for (uint256 i; i < fund.length; ++i) {
            d.tusd.mint(fund[i], 100_000e6);
            d.teth.mint(fund[i], 100 ether);
            d.tgld.mint(fund[i], 50e24);
        }
        vm.stopBroadcast();

        _writeManifest(d, startBlock);
        return (d.factory, d.router);
    }

    function _token(string memory key, MockERC20 token) internal returns (string memory) {
        vm.serializeAddress(key, "address", address(token));
        vm.serializeString(key, "symbol", token.symbol());
        vm.serializeString(key, "name", token.name());
        return vm.serializeUint(key, "decimals", token.decimals());
    }

    function _writeManifest(Demo memory d, uint256 startBlock) internal {
        string memory tokens = "tokens";
        vm.serializeString(tokens, "TUSD", _token("tusd", d.tusd));
        vm.serializeString(tokens, "TETH", _token("teth", d.teth));
        string memory tokensJson = vm.serializeString(tokens, "TGLD", _token("tgld", d.tgld));

        string memory pairs = "pairs";
        vm.serializeAddress(pairs, "TETH-TUSD", d.factory.getPair(address(d.teth), address(d.tusd)));
        string memory pairsJson =
            vm.serializeAddress(pairs, "TGLD-TETH", d.factory.getPair(address(d.tgld), address(d.teth)));

        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "startBlock", startBlock);
        vm.serializeAddress(root, "factory", address(d.factory));
        vm.serializeAddress(root, "router", address(d.router));
        vm.serializeBytes32(root, "pairInitCodeHash", d.factory.PAIR_INIT_CODE_HASH());
        vm.serializeString(root, "tokens", tokensJson);
        string memory json = vm.serializeString(root, "pairs", pairsJson);

        string memory out = vm.envOr("AMM_DEPLOYMENT_OUT", string("deployments/local.json"));
        vm.writeJson(json, out);
        console2.log("Deployment manifest written to", out);
    }
}
