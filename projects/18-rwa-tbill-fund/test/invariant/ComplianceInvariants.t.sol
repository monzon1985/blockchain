// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/console2.sol";
import {FundFixture} from "../utils/FundFixture.sol";
import {ComplianceProbe} from "../mocks/Mocks.sol";
import {ComplianceHandler, HandlerRoles} from "./handlers/ComplianceHandler.sol";

/// @notice Fund, probe module and handler shared by the compliance invariant campaign and its smoke test.
abstract contract ComplianceHandlerSetup is FundFixture {
    ComplianceHandler internal handler;
    ComplianceProbe internal probe;
    address internal flex = makeAddr("flex");

    /// @dev Every success counter the handler keeps, one per path.
    string[20] internal PATHS = [
        "subscribe",
        "requestDeposit",
        "settleEpoch",
        "claimDeposit",
        "convert",
        "requestRedeem",
        "claimRedeem",
        "transfer",
        "transferFrom",
        "forcedTransfer",
        "freeze",
        "recover",
        "changeCountry",
        "toggleClaim",
        "rebind",
        "setTransferWindow",
        "warp",
        "createDividend",
        "dividendClaim",
        "releaseEscrow"
    ];

    function setUp() public virtual override {
        super.setUp();
        probe = new ComplianceProbe(address(engine));
        vm.startPrank(complianceOfficer);
        engine.addModule(address(probe));
        maxHolders.setCountryCap(US, 3);
        maxHolders.setCountryCap(SG, 1);
        investorCap.setMaxPerInvestor(3_000_000 * USDC);
        registry.registerWallet(alice2, ID_ALICE);
        registry.registerWallet(flex, ID_ERIN);
        vm.stopPrank();

        address[] memory actors = new address[](7);
        actors[0] = alice;
        actors[1] = alice2;
        actors[2] = bob;
        actors[3] = carol;
        actors[4] = dave;
        actors[5] = erin;
        actors[6] = flex;
        bytes32[] memory ids = new bytes32[](5);
        ids[0] = ID_ALICE;
        ids[1] = ID_BOB;
        ids[2] = ID_CAROL;
        ids[3] = ID_DAVE;
        ids[4] = ID_ERIN;

        handler = new ComplianceHandler(
            f,
            usdc,
            HandlerRoles({
                fundAdmin: fundAdmin,
                transferAgent: transferAgent,
                navOracle: navOracle,
                complianceOfficer: complianceOfficer,
                issuer: issuer,
                issuerKey: issuerKey
            }),
            actors,
            ids,
            flex
        );

        // Everybody starts with a position so that secondary-market paths are live from the first call.
        _seed(alice, 200_000 * USDC);
        _seed(bob, 150_000 * USDC);
        _seed(carol, 100_000 * USDC);
        _seed(dave, 50_000 * USDC);
        _seed(erin, 80_000 * USDC);
        for (uint256 i; i < actors.length; ++i) {
            handler.seedGhost(actors[i]);
        }

        bytes4[] memory selectors = new bytes4[](22);
        selectors[0] = ComplianceHandler.requestDeposit.selector;
        selectors[1] = ComplianceHandler.settleEpoch.selector;
        selectors[2] = ComplianceHandler.claimDeposit.selector;
        selectors[3] = ComplianceHandler.requestRedeem.selector;
        selectors[4] = ComplianceHandler.claimRedeem.selector;
        selectors[5] = ComplianceHandler.transfer.selector;
        selectors[6] = ComplianceHandler.transferFrom.selector;
        selectors[7] = ComplianceHandler.forcedTransfer.selector;
        selectors[8] = ComplianceHandler.freeze.selector;
        selectors[9] = ComplianceHandler.recover.selector;
        selectors[10] = ComplianceHandler.changeCountry.selector;
        selectors[11] = ComplianceHandler.toggleClaim.selector;
        selectors[12] = ComplianceHandler.rebindFlexWallet.selector;
        selectors[13] = ComplianceHandler.warp.selector;
        selectors[14] = ComplianceHandler.createDividend.selector;
        selectors[15] = ComplianceHandler.claimDividend.selector;
        selectors[16] = ComplianceHandler.releaseEscrow.selector;
        selectors[17] = ComplianceHandler.transfer.selector; // transfers weighted x2
        selectors[18] = ComplianceHandler.subscribe.selector;
        selectors[19] = ComplianceHandler.convertUnclaimable.selector;
        selectors[20] = ComplianceHandler.setTransferWindow.selector;
        selectors[21] = ComplianceHandler.claimDividend.selector; // dividend claims weighted x2
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _calls(string memory path) internal view returns (uint256) {
        return handler.calls(keccak256(bytes(path)));
    }
}

/// @notice Stateful invariants for the "no path skips compliance" twist and for per-country holder bookkeeping.
contract ComplianceInvariantsTest is ComplianceHandlerSetup {
    /// @notice I-1 No path skips compliance: every successful movement was admissible under the handler's
    ///         independent model (eligible recipient; eligible, unfrozen, unlocked sender for user debits; open
    ///         trading window for transfers; canTransfer agreement; lawful orders never exceeded; no vault claim by
    ///         a retired wallet; no removed claim revived by an earlier signature), and dividends were paid only to
    ///         eligible unfrozen wallets or escrowed, never twice, never over-claimed.
    function invariant_noMovementViolatesCompliance() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// @notice I-2 No path skips compliance, witnessed: a stateful probe module that only learns about movements
    ///         through the engine mirrors every balance and the total supply exactly.
    function invariant_engineSawEveryMovement() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            assertEq(probe.mirror(actor), share.balanceOf(actor), "balance moved outside the engine");
        }
        assertEq(probe.mirroredSupply(), share.totalSupply());
        assertEq(engine.trackedSupply(), share.totalSupply());
    }

    /// @notice I-3 Per-country holder counts are exact: recomputed from the ghost ledger (identity snapshots and
    ///         balances observed from the token) they equal the engine's incremental counters.
    function invariant_holderCountsExact() public view {
        uint16[5] memory countries = handler.countries();
        uint256 ids = handler.identityCount();
        uint256 total;
        for (uint256 c; c < countries.length; ++c) {
            uint256 expected;
            for (uint256 i; i < ids; ++i) {
                bytes32 id = handler.identities(i);
                if (handler.gIdBalance(id) != 0 && handler.gIdCountry(id) == countries[c]) ++expected;
            }
            assertEq(engine.holderCount(countries[c]), expected, "holder count drift");
            total += expected;
        }
        assertEq(engine.totalHolders(), total);
    }

    /// @notice I-4 The investor ledger matches token balances: each identity's aggregate equals the sum of the
    ///         balances of the wallets attributed to it, and every holding wallet carries an identity snapshot.
    function invariant_investorLedgerMatchesBalances() public view {
        uint256 n = handler.actorCount();
        uint256 ids = handler.identityCount();
        for (uint256 i; i < ids; ++i) {
            bytes32 id = handler.identities(i);
            uint256 sum;
            for (uint256 w; w < n; ++w) {
                address actor = handler.actors(w);
                if (handler.gWalletId(actor) == id) sum += share.balanceOf(actor);
            }
            assertEq(handler.gIdBalance(id), sum, "ghost ledger inconsistent");
            assertEq(engine.investorBalance(id), sum, "engine ledger drift");
        }
        for (uint256 w; w < n; ++w) {
            address actor = handler.actors(w);
            if (share.balanceOf(actor) != 0) {
                assertTrue(engine.walletIdentity(actor) != bytes32(0), "holder without identity snapshot");
                assertEq(engine.walletIdentity(actor), handler.gWalletId(actor));
            }
        }
    }

    /// @notice I-5 Dividend solvency: the distributor always holds every unclaimed entitlement plus escrow.
    function invariant_dividendsSolvent() public view {
        assertGe(usdc.balanceOf(address(distributor)), distributor.outstandingLiability());
    }

    /// @notice I-6 Eligibility is what the rules say: for every wallet, the token's `canSend` / `canReceive`
    ///         equal the handler's independent model (bound identity, every required claim unexpired and not
    ///         removed, wallet not retired), so a bug in eligibility itself cannot hide behind I-1.
    function invariant_eligibilityMatchesIndependentModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            bool expected = handler.expectedEligible(actor);
            assertEq(share.canReceive(actor), expected, "canReceive disagrees with the model");
            assertEq(share.canSend(actor), expected, "canSend disagrees with the model");
        }
    }

    /// @dev Prints how many handler actions actually succeeded in each run. The deterministic proof that every
    ///      path can succeed is `ComplianceHandlerSmokeTest`.
    function afterInvariant() external view {
        for (uint256 i; i < 20; ++i) {
            console2.log(PATHS[i], _calls(PATHS[i]));
        }
    }
}

/// @notice Guards the handler itself: every path succeeds when driven with inputs known to be admissible, so a
///         regression that makes a path always revert (and silently empties the campaign) fails here.
contract ComplianceHandlerSmokeTest is ComplianceHandlerSetup {
    /// @dev Runs `action` through the handler and requires exactly one more success on `path`.
    function _expectSuccess(string memory path, bytes memory action) internal {
        uint256 before = _calls(path);
        (bool ok, bytes memory ret) = address(handler).call(action);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        assertEq(_calls(path), before + 1, path);
    }

    function test_everyHandlerPathSucceeds() public {
        // Actor indexes: 0 alice, 1 alice2, 2 bob, 3 carol, 4 dave, 5 erin, 6 flex, 7 outsider.
        // Identity indexes: 0 alice, 1 bob, 2 carol, 3 dave, 4 erin.
        uint256 odd = 1_000_001; // not a multiple of 4: a partial amount, not the whole balance
        _expectSuccess("transfer", abi.encodeCall(handler.transfer, (0, 2, odd)));
        _expectSuccess("transferFrom", abi.encodeCall(handler.transferFrom, (0, 3, 2, odd)));
        _expectSuccess("requestDeposit", abi.encodeCall(handler.requestDeposit, (2, 100 * USDC)));
        _expectSuccess("settleEpoch", abi.encodeCall(handler.settleEpoch, (1e18)));
        _expectSuccess("claimDeposit", abi.encodeCall(handler.claimDeposit, (2, 2, 50 * USDC)));
        _expectSuccess("requestRedeem", abi.encodeCall(handler.requestRedeem, (2, odd)));
        _expectSuccess("settleEpoch", abi.encodeCall(handler.settleEpoch, (1e18)));
        _expectSuccess("claimRedeem", abi.encodeCall(handler.claimRedeem, (2, 2)));
        _expectSuccess("subscribe", abi.encodeCall(handler.subscribe, (3, 3, 50 * USDC)));
        _expectSuccess("forcedTransfer", abi.encodeCall(handler.forcedTransfer, (0, 2, odd)));
        _expectSuccess("freeze", abi.encodeCall(handler.freeze, (4, 0)));
        _expectSuccess("recover", abi.encodeCall(handler.recover, (5)));
        _expectSuccess("changeCountry", abi.encodeCall(handler.changeCountry, (1, 1)));
        _expectSuccess("rebind", abi.encodeCall(handler.rebindFlexWallet, (0)));
        _expectSuccess("setTransferWindow", abi.encodeCall(handler.setTransferWindow, (3 << 8, 0, 1 days)));
        _expectSuccess("setTransferWindow", abi.encodeCall(handler.setTransferWindow, (1, 0, 0)));
        _expectSuccess("warp", abi.encodeCall(handler.warp, (1 hours)));

        // A settled subscription that compliance then refuses to mint (carol's KYC is removed) converts.
        _expectSuccess("requestDeposit", abi.encodeCall(handler.requestDeposit, (3, 10 * USDC)));
        _expectSuccess("settleEpoch", abi.encodeCall(handler.settleEpoch, (1e18)));
        _expectSuccess("toggleClaim", abi.encodeCall(handler.toggleClaim, (2, 0)));
        _expectSuccess("convert", abi.encodeCall(handler.convertUnclaimable, (3)));
        _expectSuccess("toggleClaim", abi.encodeCall(handler.toggleClaim, (2, 0)));

        // A multi-leaf distribution: one leaf paid, one escrowed while frozen and released after the unfreeze.
        _expectSuccess("createDividend", abi.encodeCall(handler.createDividend, (2))); // 4 leaves from bob
        address frozenHolder = handler.distributionAccount(0, 1);
        vm.prank(complianceOfficer);
        share.setFrozenTokens(frozenHolder, 1);
        _expectSuccess("dividendClaim", abi.encodeCall(handler.claimDividend, (0, 0, 1)));
        _expectSuccess("dividendClaim", abi.encodeCall(handler.claimDividend, (0, 1, 0)));
        vm.prank(complianceOfficer);
        share.setFrozenTokens(frozenHolder, 0);
        _expectSuccess("releaseEscrow", abi.encodeCall(handler.releaseEscrow, (3)));

        assertEq(handler.violations(), 0, handler.lastViolation());
        for (uint256 i; i < 20; ++i) {
            assertGt(_calls(PATHS[i]), 0, PATHS[i]);
        }
    }
}
