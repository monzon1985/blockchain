// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {Roles} from "../../src/access/Roles.sol";
import {TestPaymentDollarV1} from "../../src/TestPaymentDollarV1.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {StablecoinHandler} from "./StablecoinHandler.sol";

/// @notice Handler-based invariants. Compliance is treated as a security property: I-1 must hold for every
///         value-moving entry point, before and after the mid-run v1 -> v2 upgrade the handler can trigger.
contract StablecoinInvariants is StdInvariant, Test {
    StablecoinHandler internal handler;
    TestPaymentDollarV1 internal token;

    function setUp() public {
        vm.warp(1_780_000_000);
        (address attestor, uint256 attestorKey) = makeAddrAndKey("attestor");
        address[] memory eoaHolders = new address[](6);
        uint256[] memory eoaKeys = new uint256[](6);
        string[6] memory names = ["alice", "bob", "carol", "minterA", "minterB", "custody"];
        for (uint256 i; i < names.length; ++i) {
            (eoaHolders[i], eoaKeys[i]) = makeAddrAndKey(names[i]);
        }
        address[2] memory minters = [eoaHolders[3], eoaHolders[4]];
        (address walletOwner, uint256 walletOwnerKey) = makeAddrAndKey("walletOwner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);

        StablecoinHandler.Roster memory roster = StablecoinHandler.Roster({
            governance: makeAddr("governance"),
            masterMinter: makeAddr("masterMinter"),
            pauser: makeAddr("pauser"),
            blocklister: makeAddr("blocklister"),
            compliance: makeAddr("compliance"),
            bridge: makeAddr("bridge"),
            upgrader: makeAddr("upgrader"),
            attestorKey: attestorKey
        });
        address[] memory minterList = new address[](2);
        minterList[0] = minters[0];
        minterList[1] = minters[1];
        // The limits are fixed here and handed to the handler, which checks I-4 against them instead of against
        // whatever the token reports (10,000 tPD is the flagged-account cap that v2 documents and installs).
        StablecoinHandler.Limits memory limits = StablecoinHandler.Limits({
            minterCeiling: 2_000_000e6, bridgeMint: 3_000_000e6, bridgeBurn: 2_000_000e6, flaggedDaily: 10_000e6
        });
        StablecoinDeployment.Deployment memory d = StablecoinDeployment.deploy(
            StablecoinDeployment.Config({
                deployer: address(this),
                governance: roster.governance,
                masterMinter: roster.masterMinter,
                pauser: roster.pauser,
                blocklister: roster.blocklister,
                complianceOfficer: roster.compliance,
                bridge: roster.bridge,
                upgrader: roster.upgrader,
                attestor: attestor,
                minters: minterList,
                governanceDelay: Roles.GOVERNANCE_DELAY,
                minterLimitCeiling: uint208(limits.minterCeiling),
                bridgeMintLimit: uint208(limits.bridgeMint),
                bridgeBurnLimit: uint208(limits.bridgeBurn)
            })
        );
        token = d.token;
        handler = new StablecoinHandler(d, roster, limits, eoaHolders, eoaKeys, wallet, walletOwnerKey, minters);

        // Start with configured minters and a covering attestation so value can move from the first call on.
        handler.configureMinter(0, 20_000_000e6, 1_000_000e6);
        handler.configureMinter(1, 20_000_000e6, 1_000_000e6);
        handler.attest(10_000_000e6, 0);

        bytes4[] memory selectors = new bytes4[](24);
        selectors[0] = StablecoinHandler.transfer.selector;
        selectors[1] = StablecoinHandler.approve.selector;
        selectors[2] = StablecoinHandler.transferFrom.selector;
        selectors[3] = StablecoinHandler.permitAndTransferFrom.selector;
        selectors[4] = StablecoinHandler.transferWithAuthorization.selector;
        selectors[5] = StablecoinHandler.receiveWithAuthorization.selector;
        selectors[6] = StablecoinHandler.cancelAuthorization.selector;
        selectors[7] = StablecoinHandler.mint.selector;
        selectors[8] = StablecoinHandler.burn.selector;
        selectors[9] = StablecoinHandler.crosschainMint.selector;
        selectors[10] = StablecoinHandler.crosschainBurn.selector;
        selectors[11] = StablecoinHandler.seize.selector;
        selectors[12] = StablecoinHandler.burnFrozen.selector;
        selectors[13] = StablecoinHandler.freeze.selector;
        selectors[14] = StablecoinHandler.unfreeze.selector;
        selectors[15] = StablecoinHandler.blocklist.selector;
        selectors[16] = StablecoinHandler.unBlocklist.selector;
        selectors[17] = StablecoinHandler.setPaused.selector;
        selectors[18] = StablecoinHandler.attest.selector;
        selectors[19] = StablecoinHandler.configureMinter.selector;
        selectors[20] = StablecoinHandler.removeMinter.selector;
        selectors[21] = StablecoinHandler.warp.selector;
        selectors[22] = StablecoinHandler.upgradeToV2.selector;
        selectors[23] = StablecoinHandler.setTransferCapFlag.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// I-1. The balance of a blocklisted or frozen account never changes except through a lawful-order path
    ///      (seize / burnFrozen, which only decrease it), and nothing is ever credited to such an account.
    function invariant_restrictedBalancesOnlyMoveThroughLawfulOrders() public view {
        for (uint256 i; i < handler.holderCount(); ++i) {
            address holder = handler.holders(i);
            if (handler.isRestricted(holder)) {
                assertEq(token.balanceOf(holder), handler.ghostLockedBalance(holder), "restricted balance moved");
            }
        }
        assertFalse(handler.ghostRestrictedMoveSucceeded(), "a non-lawful movement touching a restricted account");
    }

    /// I-2. Supply never exceeds the latest attested reserves, unless that attestation itself reported a shortfall;
    ///      in that case supply has not grown since the attestation.
    function invariant_supplyBoundedByAttestedReserves() public view {
        (uint256 reserves,,, uint256 supplyAtAttestation) = token.latestReserveAttestation();
        uint256 supply = token.totalSupply();
        if (handler.ghostSupplyIncreasedSinceAttestation()) {
            assertLe(supply, reserves, "minted above attested reserves");
        } else {
            assertLe(
                supply, reserves > supplyAtAttestation ? reserves : supplyAtAttestation, "supply grew in shortfall"
            );
        }
    }

    /// I-3. Minter allowance conservation: remaining allowance + minted since the last configuration equals the
    ///      configured allowance, and a removed minter has no allowance.
    function invariant_minterAllowanceConservation() public view {
        for (uint256 i; i < 2; ++i) {
            address m = handler.minters(i);
            uint256 expected = handler.ghostMinterConfigured(m)
                ? handler.ghostAllowanceBase(m) - handler.ghostMintedSinceConfig(m)
                : 0;
            assertEq(token.minterAllowance(m), expected, "minter allowance drifted");
            assertEq(token.isMinter(m), handler.ghostMinterConfigured(m));
        }
    }

    /// I-4. No rolling 24 h window (per minter, per bridge direction, per flagged account in v2) ever exceeds its
    ///      limit, checked against a naive reference log at every successful consumption. The limits are the ones the
    ///      test configured (deployment config, the handler's own `configureMinter` inputs, v2's documented default),
    ///      never values read back from the token.
    function invariant_rollingLimitsRespected() public view {
        assertFalse(handler.ghostRollingLimitBreached(), "rolling limit exceeded");
    }

    /// I-5. Supply accounting: supply equals the sum of all balances and the net of every mint and burn path.
    function invariant_supplyAccounting() public view {
        uint256 sum;
        for (uint256 i; i < handler.holderCount(); ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances");
        assertEq(
            token.totalSupply(),
            handler.ghostMinted() + handler.ghostBridgeMinted() - handler.ghostBurned() - handler.ghostBridgeBurned()
                - handler.ghostFrozenBurned(),
            "supply != net of mints and burns"
        );
    }

    /// I-6. Nothing moves while the token is paused, lawful-order paths included.
    function invariant_nothingMovesWhilePaused() public view {
        assertFalse(handler.ghostMovedWhilePaused(), "value moved while paused");
    }

    /// I-7. The mid-run upgrade preserves balances, nonces, allowances, restrictions and minter allowances, and
    ///      the proxy points at the implementation the handler installed.
    function invariant_upgradePreservesState() public view {
        assertFalse(handler.ghostUpgradeSentinelBroken(), "upgrade changed state");
        address impl = address(uint160(uint256(vm.load(address(token), ERC1967Utils.IMPLEMENTATION_SLOT))));
        if (handler.upgraded()) {
            assertEq(impl, handler.implementationV2());
            assertEq(token.implementationVersion(), "2");
        } else {
            assertEq(token.implementationVersion(), "1");
        }
    }

    /// @dev Per-run campaign statistics. Set TPD_INVARIANT_STATS=true to append one CSV line per call to
    ///      demo-out/invariant-stats.csv (summarised by scripts/invariant-stats.mjs); otherwise only logged.
    ///      Foundry 1.8.3 calls this hook once per run plus once more after the campaign on the last run's state, so
    ///      every line starts with the run's fingerprint and the summary drops a line that repeats the previous one.
    function afterInvariant() external {
        string memory line = string.concat(
            vm.toString(abi.encodePacked(bytes8(handler.runFingerprint()))),
            ",",
            vm.toString(handler.movesSucceeded()),
            ",",
            vm.toString(handler.restrictedAttemptsBlocked()),
            ",",
            vm.toString(handler.lawfulOrdersExecuted()),
            ",",
            vm.toString(handler.shortfallAttestations()),
            ",",
            vm.toString(handler.callsAfterUpgrade()),
            ",",
            handler.upgraded() ? "1" : "0"
        );
        console2.log("run,moves,denied,lawful,shortfalls,movesAfterUpgrade,upgraded:", line);
        if (vm.envOr("TPD_INVARIANT_STATS", false)) vm.writeLine("demo-out/invariant-stats.csv", line);
    }
}
