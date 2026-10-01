// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";

import {LendingEngine} from "../src/LendingEngine.sol";
import {AdaptiveCurveIrm} from "../src/irm/AdaptiveCurveIrm.sol";
import {FlashLiquidator} from "../src/periphery/FlashLiquidator.sol";

/// @notice Deploys the engine, the adaptive IRM and a keeper's flash liquidator, and allowlists the LLTV grid with
///         bonus caps taken from `reports/RISK.md`.
/// @dev Keystore-based: run with `forge script script/Deploy.s.sol --rpc-url <url> --account <keystore-name>
///      --sender <address> --broadcast`. No private key is read from the environment. Governance (`OWNER`) and the
///      fee recipient default to the broadcaster; pass them as environment variables to use a multisig.
contract Deploy is Script {
    /// @notice Addresses produced by a deployment.
    struct Deployment {
        LendingEngine engine;
        AdaptiveCurveIrm irm;
        FlashLiquidator liquidator;
    }

    /// @notice Deploys and configures everything, broadcasting from the `--sender` account.
    /// @return d The deployed contracts.
    function run() external returns (Deployment memory d) {
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        address owner = vm.envOr("OWNER", broadcaster);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", broadcaster);
        address keeper = vm.envOr("KEEPER", broadcaster);
        d = _deploy(broadcaster, owner, feeRecipient, keeper);
        vm.stopBroadcast();
    }

    /// @dev `admin` (the broadcaster) owns the engine while it configures the allowlists, then offers ownership to
    ///      `owner` through Ownable2Step; `owner` must call `acceptOwnership`.
    function _deploy(address admin, address owner, address feeRecipient, address keeper)
        internal
        returns (Deployment memory d)
    {
        d.engine = new LendingEngine(admin, feeRecipient);
        d.irm = new AdaptiveCurveIrm(address(d.engine));
        d.liquidator = new FlashLiquidator(d.engine, keeper);

        d.engine.enableIrm(address(d.irm));
        // (LLTV, bonus cap, slope). Caps follow reports/RISK.md. 62.5 % and 77 % keep 0.000 % p99 bad debt with a
        // 5 % cap; 86 % needs 1-2 % (2 % is the report's recommendation, and it held on 4 of 5 seeds). Caps of 0.5 %
        // are never used even where their p99 is lowest: that bonus does not cover the pool fee plus gas, so the
        // simulated liquidators never act at all. 91.5 % and 94.5 % exceed the report's 0.5 % p99 budget under its
        // stress calibration (90 % volatility plus jumps) at every cap; there the 1 % and 2 % caps have overlapping
        // p99 intervals and 2 % leaves far fewer positions unprofitable to liquidate. They are meant for correlated
        // pairs, whose price moves are far smaller than that calibration.
        d.engine.enableLltv(0.625e18, 0.05e18, 2e18);
        d.engine.enableLltv(0.77e18, 0.05e18, 2e18);
        d.engine.enableLltv(0.86e18, 0.02e18, 2e18);
        d.engine.enableLltv(0.915e18, 0.02e18, 2e18);
        d.engine.enableLltv(0.945e18, 0.02e18, 2e18);

        if (owner != admin) d.engine.transferOwnership(owner);
    }
}
