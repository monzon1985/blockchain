// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {FundDeployment, FundContracts, FundConfig} from "../../script/FundDeployment.sol";
import {ComplianceEngine} from "../../src/compliance/ComplianceEngine.sol";
import {InvestorCapModule} from "../../src/compliance/modules/InvestorCapModule.sol";
import {LockupModule} from "../../src/compliance/modules/LockupModule.sol";
import {MaxHoldersPerCountryModule} from "../../src/compliance/modules/MaxHoldersPerCountryModule.sol";
import {TransferWindowModule} from "../../src/compliance/modules/TransferWindowModule.sol";
import {DividendDistributor} from "../../src/dividends/DividendDistributor.sol";
import {DocumentRegistry} from "../../src/documents/DocumentRegistry.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {FundVault} from "../../src/vault/FundVault.sol";
import {MockUSDC} from "../mocks/Mocks.sol";

/// @notice Full production wiring (via `FundDeployment`) plus five onboarded investors.
abstract contract FundFixture is Test {
    uint16 internal constant US = 840;
    uint16 internal constant DE = 276;
    uint16 internal constant SG = 702;
    uint16 internal constant GB = 826;
    uint16 internal constant FR = 250;

    /// @dev Monday 2026-01-05 10:00 UTC.
    uint256 internal constant START = 1_767_571_200 + 10 hours;
    uint128 internal constant NAV_ONE = 1e18;
    uint64 internal constant LOCKUP = 1 days;
    uint256 internal constant ALL_TOPICS = (1 << 1) | (1 << 2) | (1 << 3);
    uint256 internal constant USDC = 1e6;

    MockUSDC internal usdc;
    FundContracts internal f;
    AccessManager internal manager;
    IdentityRegistry internal registry;
    ComplianceEngine internal engine;
    DocumentRegistry internal documents;
    FundShareToken internal share;
    FundVault internal vault;
    DividendDistributor internal distributor;
    MaxHoldersPerCountryModule internal maxHolders;
    InvestorCapModule internal investorCap;
    LockupModule internal lockup;
    TransferWindowModule internal transferWindow;

    address internal governance;
    address internal fundAdmin = makeAddr("fundAdmin");
    address internal transferAgent = makeAddr("transferAgent");
    address internal navOracle = makeAddr("navOracle");
    address internal complianceOfficer = makeAddr("complianceOfficer");
    address internal custodian = makeAddr("custodian");
    address internal stranger = makeAddr("stranger");

    address internal issuer;
    uint256 internal issuerKey;

    address internal alice = makeAddr("alice");
    address internal alice2 = makeAddr("alice2");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");

    bytes32 internal constant ID_ALICE = keccak256("identity:alice");
    bytes32 internal constant ID_BOB = keccak256("identity:bob");
    bytes32 internal constant ID_CAROL = keccak256("identity:carol");
    bytes32 internal constant ID_DAVE = keccak256("identity:dave");
    bytes32 internal constant ID_ERIN = keccak256("identity:erin");

    uint256 internal claimNonce;

    function setUp() public virtual {
        vm.warp(START);
        governance = address(this);
        usdc = new MockUSDC();
        (issuer, issuerKey) = makeAddrAndKey("kycIssuer");

        f = FundDeployment.deploy(
            FundConfig({
                asset: usdc,
                decimals: 6,
                name: "Demo T-Bill Fund Share",
                symbol: "dTBILL",
                initialNav: NAV_ONE,
                lockupPeriod: LOCKUP,
                fundAdmin: fundAdmin,
                transferAgent: transferAgent,
                navOracle: navOracle,
                complianceOfficer: complianceOfficer
            }),
            address(this)
        );
        manager = f.manager;
        registry = f.registry;
        engine = f.engine;
        documents = f.documents;
        share = f.share;
        vault = f.vault;
        distributor = f.distributor;
        maxHolders = f.maxHolders;
        investorCap = f.investorCap;
        lockup = f.lockup;
        transferWindow = f.transferWindow;

        vm.prank(complianceOfficer);
        registry.setTrustedIssuer(issuer, ALL_TOPICS);

        vault.setCustodian(custodian);
        vm.prank(custodian);
        usdc.approve(address(vault), type(uint256).max);

        _onboard(alice, ID_ALICE, US);
        _onboard(bob, ID_BOB, US);
        _onboard(carol, ID_CAROL, DE);
        _onboard(dave, ID_DAVE, SG);
        _onboard(erin, ID_ERIN, GB);

        vm.label(address(usdc), "USDC");
        vm.label(address(share), "share");
        vm.label(address(vault), "vault");
        vm.label(address(engine), "engine");
        vm.label(address(registry), "registry");
    }

    // ---------------------------------------------------------------------------------------------
    // Identity helpers
    // ---------------------------------------------------------------------------------------------

    function _claim(bytes32 identity, uint256 topic, uint32 data) internal returns (IdentityRegistry.Claim memory c) {
        c = IdentityRegistry.Claim({
            identity: identity,
            topic: topic,
            data: data,
            issuer: issuer,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 365 days),
            nonce: ++claimNonce
        });
    }

    function _sign(IdentityRegistry.Claim memory c, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, registry.claimDigest(c));
        return abi.encodePacked(r, s, v);
    }

    function _addClaim(bytes32 identity, uint256 topic, uint32 data) internal returns (bytes32) {
        IdentityRegistry.Claim memory c = _claim(identity, topic, data);
        return registry.addClaim(c, _sign(c, issuerKey));
    }

    /// @dev Wallet binding is a compliance-officer power (not the transfer agent's).
    function _bind(address wallet, bytes32 identity) internal {
        vm.prank(complianceOfficer);
        registry.registerWallet(wallet, identity);
    }

    function _onboard(address wallet, bytes32 identity, uint16 country) internal {
        _bind(wallet, identity);
        _addClaim(identity, 1, 1);
        _addClaim(identity, 2, 1);
        _addClaim(identity, 3, country);
    }

    // ---------------------------------------------------------------------------------------------
    // Lawful orders
    // ---------------------------------------------------------------------------------------------

    /// @dev ERC-1643 key of the order document every test order points at.
    bytes32 internal constant ORDER_DOC = "court-order-2026-001.pdf";

    /// @dev Fund administrator anchors the order document (once) and issues order `orderId`, valid 30 days.
    function _issueOrder(bytes32 orderId, address from, address to, uint256 maxAmount) internal {
        vm.startPrank(fundAdmin);
        (, bytes32 anchored,) = documents.getDocument(ORDER_DOC);
        if (anchored == bytes32(0)) documents.setDocument(ORDER_DOC, "ipfs://bafy-order", keccak256("order pdf"));
        share.issueLawfulOrder(orderId, from, to, maxAmount, uint64(block.timestamp + 30 days), ORDER_DOC);
        vm.stopPrank();
    }

    function _setCountry(bytes32 identity, uint16 country) internal {
        vm.warp(block.timestamp + 1);
        _addClaim(identity, 3, country);
    }

    // ---------------------------------------------------------------------------------------------
    // Vault helpers
    // ---------------------------------------------------------------------------------------------

    function _fund(address who, uint256 assets) internal {
        usdc.mint(who, assets);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _requestDeposit(address investor, uint256 assets) internal {
        _fund(investor, assets);
        vm.prank(investor);
        vault.requestDeposit(assets, investor, investor);
    }

    function _close() internal {
        vm.prank(fundAdmin);
        vault.closeEpoch();
    }

    function _postAndSettle(uint128 nav) internal {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(navOracle);
        vault.postNav(nav, uint64(block.timestamp));
        vm.prank(fundAdmin);
        vault.settleEpoch();
    }

    function _closeAndSettle(uint128 nav) internal {
        _close();
        _postAndSettle(nav);
    }

    function _currentNav() internal view returns (uint128 nav) {
        (nav,) = vault.referenceNav();
    }

    /// @dev Full subscription cycle at the current reference NAV; returns shares minted.
    function _subscribe(address investor, uint256 assets) internal returns (uint256 shares) {
        _requestDeposit(investor, assets);
        _closeAndSettle(_currentNav());
        uint256 claimable = vault.maxDeposit(investor);
        vm.prank(investor);
        shares = vault.deposit(claimable, investor, investor);
    }

    /// @dev Subscribes at the current NAV and waits out the lockup so the shares are freely transferable.
    function _seed(address investor, uint256 assets) internal returns (uint256 shares) {
        shares = _subscribe(investor, assets);
        vm.warp(block.timestamp + LOCKUP + 1);
    }
}
