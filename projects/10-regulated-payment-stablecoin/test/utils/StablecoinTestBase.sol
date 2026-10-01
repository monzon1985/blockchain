// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {TestPaymentDollarV1} from "../../src/TestPaymentDollarV1.sol";
import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";
import {IPaymentStablecoinEvents} from "../../src/interfaces/IPaymentStablecoinEvents.sol";
import {Roles} from "../../src/access/Roles.sol";
import {StablecoinDeployment} from "../../script/StablecoinDeployment.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";

/// @notice Shared fixture: the production deployment (via `StablecoinDeployment`) with named role holders, a funded
///         reserve attestation, and independent EIP-712 helpers. The digests are rebuilt here from the raw type
///         strings instead of asking the token, so every signature test is also a differential check of the domain.
abstract contract StablecoinTestBase is Test, IPaymentStablecoinEvents {
    // Token amounts (6 decimals).
    uint256 internal constant ONE = 1e6;
    uint208 internal constant MINTER_CEILING = 5_000_000e6;
    uint208 internal constant MINTER_DAILY = 1_000_000e6;
    uint256 internal constant MINTER_ALLOWANCE = 10_000_000e6;
    uint208 internal constant BRIDGE_MINT_LIMIT = 2_000_000e6;
    uint208 internal constant BRIDGE_BURN_LIMIT = 1_500_000e6;
    uint256 internal constant INITIAL_RESERVES = 50_000_000e6;
    uint256 internal constant START_TIME = 1_780_000_000;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant TRANSFER_AUTH_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant RECEIVE_AUTH_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant CANCEL_AUTH_TYPEHASH = keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");
    bytes32 internal constant ATTESTATION_TYPEHASH =
        keccak256("ReserveAttestation(uint256 reserves,uint64 asOf,bytes32 reportHash)");

    bytes32 internal constant ORDER_REF = keccak256("court-order:demo-2026-001");
    bytes32 internal constant REPORT_HASH = keccak256("attestation-report:2026-09");

    AccessManager internal manager;
    TestPaymentDollarV1 internal token;
    address internal implementationV1;

    address internal governance = makeAddr("governance");
    address internal masterMinter = makeAddr("masterMinter");
    address internal minter = makeAddr("minter");
    address internal minter2 = makeAddr("minter2");
    address internal pauser = makeAddr("pauser");
    address internal blocklister = makeAddr("blocklister");
    address internal compliance = makeAddr("complianceOfficer");
    address internal bridge = makeAddr("bridge");
    address internal upgrader = makeAddr("upgrader");
    address internal custody = makeAddr("courtCustody");
    address internal relayer = makeAddr("relayer");

    address internal attestor;
    uint256 internal attestorKey;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    address internal carol;
    uint256 internal carolKey;

    MockERC1271Wallet internal wallet;
    address internal walletOwner;
    uint256 internal walletOwnerKey;

    function setUp() public virtual {
        vm.warp(START_TIME);
        (attestor, attestorKey) = makeAddrAndKey("attestor");
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (carol, carolKey) = makeAddrAndKey("carol");
        (walletOwner, walletOwnerKey) = makeAddrAndKey("walletOwner");
        wallet = new MockERC1271Wallet(walletOwner);

        StablecoinDeployment.Deployment memory d = StablecoinDeployment.deploy(_config());
        manager = d.manager;
        token = d.token;
        implementationV1 = d.implementation;

        vm.prank(masterMinter);
        token.configureMinter(minter, MINTER_ALLOWANCE, MINTER_DAILY);
        vm.prank(masterMinter);
        token.configureMinter(minter2, MINTER_ALLOWANCE, MINTER_DAILY);
        _attest(INITIAL_RESERVES);
    }

    function _config() internal view returns (StablecoinDeployment.Config memory cfg) {
        address[] memory minters = new address[](2);
        minters[0] = minter;
        minters[1] = minter2;
        cfg = StablecoinDeployment.Config({
            deployer: address(this),
            governance: governance,
            masterMinter: masterMinter,
            pauser: pauser,
            blocklister: blocklister,
            complianceOfficer: compliance,
            bridge: bridge,
            upgrader: upgrader,
            attestor: attestor,
            minters: minters,
            governanceDelay: Roles.GOVERNANCE_DELAY,
            minterLimitCeiling: MINTER_CEILING,
            bridgeMintLimit: BRIDGE_MINT_LIMIT,
            bridgeBurnLimit: BRIDGE_BURN_LIMIT
        });
    }

    // ------------------------------------------------------------------------------------------------------------
    // Operational helpers
    // ------------------------------------------------------------------------------------------------------------

    function _mint(address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    function _attest(uint256 reserves) internal {
        _attestAt(reserves, uint64(block.timestamp));
    }

    /// @dev Attestations must be strictly newer than the recorded one: advance one second, then attest.
    function _reattest(uint256 reserves) internal {
        vm.warp(block.timestamp + 1);
        _attest(reserves);
    }

    function _attestAt(uint256 reserves, uint64 asOf) internal {
        bytes memory sig = _signAttestation(attestorKey, reserves, asOf, REPORT_HASH);
        token.submitReserveAttestation(reserves, asOf, REPORT_HASH, sig);
    }

    /// @dev Runs `data` on `target` as governance through the AccessManager: schedule, wait the delay, execute.
    function _governance(address target, bytes memory data) internal {
        vm.prank(governance);
        manager.schedule(target, data, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        vm.prank(governance);
        manager.execute(target, data);
    }

    /// @dev Full v1 -> v2 procedure: upgrader schedules the upgrade, governance schedules the v2 wiring, both
    ///      execute after the delay. Keeps the reserve attestation fresh across the warp.
    function _upgradeToV2() internal returns (TestPaymentDollarV2 v2, address implementationV2) {
        implementationV2 = address(new TestPaymentDollarV2());
        bytes memory upgradeCall = StablecoinDeployment.v2UpgradeCalldata(implementationV2);
        bytes memory wiringCall = StablecoinDeployment.v2WiringCalldata(address(token));
        vm.prank(upgrader);
        manager.schedule(address(token), upgradeCall, 0);
        vm.prank(governance);
        manager.schedule(address(manager), wiringCall, 0);
        vm.warp(block.timestamp + Roles.GOVERNANCE_DELAY);
        vm.prank(upgrader);
        manager.execute(address(token), upgradeCall);
        vm.prank(governance);
        manager.execute(address(manager), wiringCall);
        v2 = TestPaymentDollarV2(address(token));
    }

    // ------------------------------------------------------------------------------------------------------------
    // EIP-712 helpers (independent re-implementation of the domain)
    // ------------------------------------------------------------------------------------------------------------

    function _domainSeparator() internal view returns (bytes32) {
        return _domainSeparatorFor("Test Payment Dollar", "1", block.chainid, address(token));
    }

    function _domainSeparatorFor(string memory name, string memory ver, uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(ver)), chainId, verifyingContract
            )
        );
    }

    function _digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _permitStructHash(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
    }

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            key, _digest(_domainSeparator(), _permitStructHash(owner, spender, value, token.nonces(owner), deadline))
        );
    }

    function _authStructHash(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce));
    }

    function _signTransferAuth(
        uint256 key,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        return _sign(
            key,
            _digest(
                _domainSeparator(),
                _authStructHash(TRANSFER_AUTH_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
            )
        );
    }

    function _signReceiveAuth(
        uint256 key,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        return _sign(
            key,
            _digest(
                _domainSeparator(),
                _authStructHash(RECEIVE_AUTH_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
            )
        );
    }

    function _signCancelAuth(uint256 key, address authorizer, bytes32 nonce) internal view returns (bytes memory) {
        return _sign(key, _digest(_domainSeparator(), keccak256(abi.encode(CANCEL_AUTH_TYPEHASH, authorizer, nonce))));
    }

    function _signAttestation(uint256 key, uint256 reserves, uint64 asOf, bytes32 reportHash)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            key, _digest(_domainSeparator(), keccak256(abi.encode(ATTESTATION_TYPEHASH, reserves, asOf, reportHash)))
        );
    }

    function _split(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }
}
