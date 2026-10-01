// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {IERC1271} from "@openzeppelin-contracts/interfaces/IERC1271.sol";
import {ComplianceEngine} from "../src/compliance/ComplianceEngine.sol";
import {DividendDistributor} from "../src/dividends/DividendDistributor.sol";
import {DocumentRegistry} from "../src/documents/DocumentRegistry.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {FundShareToken} from "../src/token/FundShareToken.sol";
import {FundVault} from "../src/vault/FundVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {FundDeployment, FundContracts, FundConfig} from "./FundDeployment.sol";

/// @notice ERC-1271 claim issuer for the local demo: its owner approves claim digests, so the demo never
///         handles a private key.
contract DemoClaimIssuer is IERC1271 {
    address public immutable owner;
    mapping(bytes32 digest => bool approved) public approved;

    constructor(address owner_) {
        owner = owner_;
    }

    function approve(bytes32 digest) external {
        require(msg.sender == owner, "issuer: not owner");
        approved[digest] = true;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        return approved[hash] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @title DemoLocal
/// @notice Lifecycle on a local anvil node, driven step by step by `scripts/demo.sh` with `--unlocked` default anvil
///         accounts (no keys in the repository). Time is advanced between steps with `evm_increaseTime`. Every step
///         checks its outcome with `require`, so a regression fails the demo (and the CI job running it) instead of
///         printing a wrong number.
contract DemoLocal is Script {
    string internal constant OUT = "demo-out/deployment.json";
    string internal constant DIVIDEND_TREE = "demo-out/dividend-tree.json";
    // Default anvil accounts 0-4 (public, well-known test addresses; used unlocked, never with keys).
    address internal constant OPERATOR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ALICE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant BOB = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant CUSTODIAN = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address internal constant ALICE_NEW_WALLET = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    bytes32 internal constant ID_ALICE = keccak256("demo:alice");
    bytes32 internal constant ORDER_ID = "order:2026-001";
    bytes32 internal constant ORDER_DOC = "court-order-2026-001.pdf";

    /// @dev Addresses persisted between steps.
    struct Deployed {
        MockUSDC usdc;
        IdentityRegistry registry;
        ComplianceEngine engine;
        DocumentRegistry documents;
        FundShareToken share;
        FundVault vault;
        DividendDistributor distributor;
    }

    /// @notice Step 1: deploy, onboard two investors (US, DE) and take their subscriptions; close epoch 1.
    function deploy() external {
        vm.startBroadcast(OPERATOR);
        MockUSDC usdc = new MockUSDC();
        FundContracts memory c = FundDeployment.deploy(
            FundConfig({
                asset: usdc,
                decimals: 6,
                name: "Demo T-Bill Fund Share",
                symbol: "dTBILL",
                initialNav: 1e18,
                lockupPeriod: 1 days,
                fundAdmin: OPERATOR,
                transferAgent: OPERATOR,
                navOracle: OPERATOR,
                complianceOfficer: OPERATOR
            }),
            OPERATOR
        );
        DemoClaimIssuer issuer = new DemoClaimIssuer(OPERATOR);
        c.registry.setTrustedIssuer(address(issuer), (1 << 1) | (1 << 2) | (1 << 3));
        _onboard(c.registry, issuer, ALICE, ID_ALICE, 840);
        _onboard(c.registry, issuer, BOB, keccak256("demo:bob"), 276);
        c.vault.setCustodian(CUSTODIAN);
        usdc.mint(ALICE, 100_000e6);
        usdc.mint(BOB, 50_000e6);
        vm.stopBroadcast();

        _subscribe(usdc, c.vault, ALICE, 100_000e6);
        _subscribe(usdc, c.vault, BOB, 50_000e6);
        vm.broadcast(OPERATOR);
        c.vault.closeEpoch();
        require(c.vault.getEpoch(1).depositAssets == 150_000e6, "demo: epoch 1 requests");
        require(usdc.balanceOf(address(c.vault)) == 150_000e6, "demo: subscriptions held by the vault");

        string memory obj = "deployment";
        vm.serializeAddress(obj, "usdc", address(usdc));
        vm.serializeAddress(obj, "registry", address(c.registry));
        vm.serializeAddress(obj, "engine", address(c.engine));
        vm.serializeAddress(obj, "documents", address(c.documents));
        vm.serializeAddress(obj, "share", address(c.share));
        vm.serializeAddress(obj, "distributor", address(c.distributor));
        string memory json = vm.serializeAddress(obj, "vault", address(c.vault));
        vm.writeJson(json, OUT);
        console2.log(
            "deployed share %s, vault %s; epoch 1 closed with 150,000 USDC of requests",
            address(c.share),
            address(c.vault)
        );
    }

    /// @notice Step 2 (after >= 1 s): post NAV 1.00, settle epoch 1, investors claim their shares.
    function settle() external {
        Deployed memory d = _load();
        vm.startBroadcast(OPERATOR);
        d.vault.postNav(1e18, uint64(block.timestamp));
        d.vault.settleEpoch();
        d.vault.deployToCustodian(100_000e6);
        vm.stopBroadcast();
        vm.broadcast(ALICE);
        d.vault.deposit(100_000e6, ALICE, ALICE);
        vm.broadcast(BOB);
        d.vault.deposit(50_000e6, BOB, BOB);
        require(d.share.balanceOf(ALICE) == 100_000e6, "demo: alice shares");
        require(d.share.balanceOf(BOB) == 50_000e6, "demo: bob shares");
        require(d.vault.deployedAssets() == 100_000e6, "demo: deployed principal");
        console2.log("alice shares %s, bob shares %s", d.share.balanceOf(ALICE), d.share.balanceOf(BOB));
    }

    /// @notice Step 3 (after the 1-day lockup): a compliant transfer, a redemption request, epoch 2 closes.
    function trade() external {
        Deployed memory d = _load();
        vm.broadcast(ALICE);
        d.share.transfer(BOB, 10_000e6);
        vm.broadcast(BOB);
        d.vault.requestRedeem(20_000e6, BOB, BOB);
        vm.broadcast(OPERATOR);
        d.vault.closeEpoch();
        require(d.engine.holderCount(840) == 1 && d.engine.holderCount(276) == 1, "demo: holder counts");
        require(d.vault.pendingRedeemRequest(0, BOB) == 20_000e6, "demo: pending redemption");
        console2.log("holders US=%s DE=%s", d.engine.holderCount(840), d.engine.holderCount(276));
    }

    /// @notice Step 4: NAV +0.10 %, settle epoch 2 and pay bob's redemption.
    function finish() external {
        Deployed memory d = _load();
        vm.startBroadcast(OPERATOR);
        d.vault.postNav(1.001e18, uint64(block.timestamp));
        d.vault.settleEpoch();
        vm.stopBroadcast();
        vm.broadcast(BOB);
        uint256 paid = d.vault.redeem(20_000e6, BOB, BOB);
        require(paid == 20_020e6, "demo: redemption at NAV 1.001");
        require(d.share.balanceOf(BOB) == 40_000e6 && d.usdc.balanceOf(BOB) == 20_020e6, "demo: bob after redemption");
        require(d.vault.totalAssets() == 130_130e6, "demo: AUM at NAV 1.001");
        console2.log("bob redeemed 20,000 shares for %s USDC base units", paid);
        console2.log("bob shares %s, bob USDC %s", d.share.balanceOf(BOB), d.usdc.balanceOf(BOB));
        console2.log("fund AUM at NAV 1.001: %s", d.vault.totalAssets());
    }

    /// @notice Step 5: a court order (anchored document + lawful order bound to bob -> alice, 5,000 shares) is
    ///         enforced; then alice reports her key lost: her new wallet is bound to her identity and a recovery
    ///         is initiated (2-day timelock).
    function enforce() external {
        Deployed memory d = _load();
        vm.startBroadcast(OPERATOR);
        d.documents.setDocument(ORDER_DOC, "ipfs://demo-court-order", keccak256("demo court order"));
        d.share.issueLawfulOrder(ORDER_ID, BOB, ALICE, 5000e6, uint64(block.timestamp + 7 days), ORDER_DOC);
        d.share.forcedTransfer(BOB, ALICE, 5000e6, ORDER_ID);
        d.registry.registerWallet(ALICE_NEW_WALLET, ID_ALICE);
        d.share.initiateRecovery(ALICE, ALICE_NEW_WALLET, "TA-CASE-0001");
        vm.stopBroadcast();
        (,,, uint256 remaining,) = d.share.lawfulOrders(ORDER_ID);
        require(remaining == 0, "demo: order consumed");
        require(d.share.balanceOf(BOB) == 35_000e6 && d.share.balanceOf(ALICE) == 95_000e6, "demo: forced transfer");
        (address successor,,) = d.share.pendingRecovery(ALICE);
        require(successor == ALICE_NEW_WALLET && !d.share.canSend(ALICE), "demo: recovery pending");
        console2.log("order enforced: bob %s, alice %s shares", d.share.balanceOf(BOB), d.share.balanceOf(ALICE));
        console2.log("recovery of alice to %s pending", ALICE_NEW_WALLET);
    }

    /// @notice Step 6 (after the 2-day timelock): the recovery executes; the old wallet is retired.
    function recover() external {
        Deployed memory d = _load();
        vm.broadcast(OPERATOR);
        uint256 moved = d.share.executeRecovery(ALICE);
        require(moved == 95_000e6, "demo: recovered amount");
        require(d.share.balanceOf(ALICE_NEW_WALLET) == 95_000e6 && d.share.balanceOf(ALICE) == 0, "demo: balances");
        require(d.share.currentWalletOf(ALICE) == ALICE_NEW_WALLET && !d.share.canReceive(ALICE), "demo: retired");
        require(d.engine.holderCount(840) == 1, "demo: same investor, same holder count");
        console2.log("recovered %s shares to %s", moved, ALICE_NEW_WALLET);
    }

    /// @notice Step 7: funds the record-date dividend the Node builder computed from on-chain balances
    ///         (`demo-out/dividend-tree.json`) and claims every entitlement with the builder's proofs.
    function dividend() external {
        Deployed memory d = _load();
        string memory json = vm.readFile(DIVIDEND_TREE);
        uint256 allocated = vm.parseJsonUint(json, ".allocatedAmount");
        uint256 count = vm.parseJsonUint(json, ".count");
        vm.startBroadcast(OPERATOR);
        d.usdc.mint(OPERATOR, allocated);
        d.usdc.approve(address(d.distributor), allocated);
        uint256 id = d.distributor
            .createDistribution(
                vm.parseJsonBytes32(json, ".root"), allocated, uint64(vm.parseJsonUint(json, ".recordDate"))
            );
        for (uint256 i; i < count; ++i) {
            string memory base = string.concat(".claims[", vm.toString(i), "]");
            address account = vm.parseJsonAddress(json, string.concat(base, ".account"));
            uint256 amount = vm.parseJsonUint(json, string.concat(base, ".amount"));
            uint256 before = d.usdc.balanceOf(account);
            d.distributor.claim(id, account, amount, vm.parseJsonBytes32Array(json, string.concat(base, ".proof")));
            require(d.usdc.balanceOf(account) == before + amount, "demo: dividend paid");
            console2.log("dividend %s USDC base units paid to %s", amount, account);
        }
        vm.stopBroadcast();
        require(d.usdc.balanceOf(address(d.distributor)) == 0, "demo: distribution fully paid");
    }

    function _subscribe(MockUSDC usdc, FundVault vault, address investor, uint256 assets) internal {
        vm.startBroadcast(investor);
        usdc.approve(address(vault), assets);
        vault.requestDeposit(assets, investor, investor);
        vm.stopBroadcast();
    }

    function _onboard(IdentityRegistry registry, DemoClaimIssuer issuer, address wallet, bytes32 id, uint32 country)
        internal
    {
        registry.registerWallet(wallet, id);
        for (uint256 topic = 1; topic <= 3; ++topic) {
            IdentityRegistry.Claim memory claim = IdentityRegistry.Claim({
                identity: id,
                topic: topic,
                data: topic == 3 ? country : 1,
                issuer: address(issuer),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp + 365 days),
                nonce: topic
            });
            issuer.approve(registry.claimDigest(claim));
            registry.addClaim(claim, "");
        }
    }

    function _load() internal view returns (Deployed memory d) {
        string memory json = vm.readFile(OUT);
        d.usdc = MockUSDC(vm.parseJsonAddress(json, ".usdc"));
        d.registry = IdentityRegistry(vm.parseJsonAddress(json, ".registry"));
        d.engine = ComplianceEngine(vm.parseJsonAddress(json, ".engine"));
        d.documents = DocumentRegistry(vm.parseJsonAddress(json, ".documents"));
        d.share = FundShareToken(vm.parseJsonAddress(json, ".share"));
        d.vault = FundVault(vm.parseJsonAddress(json, ".vault"));
        d.distributor = DividendDistributor(vm.parseJsonAddress(json, ".distributor"));
    }
}
