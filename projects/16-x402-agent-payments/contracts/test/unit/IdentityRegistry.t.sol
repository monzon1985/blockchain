// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {IdentityRegistry} from "../../src/registry/IdentityRegistry.sol";
import {Fixture} from "../utils/Fixture.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract IdentityRegistryTest is Fixture {
    string internal constant CARD = "data:application/json;base64,eyJuYW1lIjoiZGVtbyJ9";
    address internal agentOwner;
    uint256 internal agentOwnerKey;
    address internal wallet;
    uint256 internal walletKey;

    function setUp() public override {
        super.setUp();
        (agentOwner, agentOwnerKey) = makeAddrAndKey("agentOwner");
        (wallet, walletKey) = makeAddrAndKey("wallet");
    }

    function _register() internal returns (uint256 id) {
        vm.prank(agentOwner);
        id = identity.register(CARD);
    }

    function _walletSig(uint256 key, uint256 agentId, address newWallet, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(key, identity.agentWalletDigest(agentId, newWallet, deadline));
    }

    function _setWallet(uint256 id, address newWallet, uint256 key) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _walletSig(key, id, newWallet, deadline);
        vm.prank(identity.ownerOf(id));
        identity.setAgentWallet(id, newWallet, deadline, sig);
    }

    function test_Register() public {
        vm.expectEmit(address(identity));
        emit IdentityRegistry.Registered(1, CARD, agentOwner);
        vm.expectEmit(address(identity));
        emit IdentityRegistry.AgentWalletSet(1, agentOwner);
        uint256 id = _register();
        assertEq(id, 1);
        assertEq(identity.ownerOf(1), agentOwner);
        assertEq(identity.tokenURI(1), CARD);
        assertEq(identity.getAgentWallet(1), agentOwner, "wallet defaults to owner");
        assertEq(identity.agentOfWallet(agentOwner), 1);
        assertEq(identity.totalAgents(), 1);
        assertEq(identity.name(), "ERC-8004 Agent Identity (local)");
    }

    function test_RegisterWithMetadataAndWithoutURI() public {
        IdentityRegistry.MetadataEntry[] memory md = new IdentityRegistry.MetadataEntry[](1);
        md[0] = IdentityRegistry.MetadataEntry("category", bytes("pricing"));
        vm.prank(agentOwner);
        uint256 a = identity.register(CARD, md);
        assertEq(identity.getMetadata(a, "category"), bytes("pricing"));

        vm.prank(agentOwner);
        uint256 b = identity.register();
        assertEq(b, 2);
        assertEq(identity.tokenURI(b), "");
        // The registrant already receives payments for agent `a`, so `b` starts without a wallet.
        assertEq(identity.getAgentWallet(b), address(0));
        assertEq(identity.agentOfWallet(agentOwner), a);
    }

    function test_RevertWhen_WalletServesAnotherAgent() public {
        uint256 a = _register();
        vm.prank(relayer);
        uint256 b = identity.register(CARD);
        _setWallet(a, wallet, walletKey);
        assertEq(identity.agentOfWallet(wallet), a);
        assertEq(identity.agentOfWallet(agentOwner), 0, "the previous wallet of a is released");

        // A sibling agent cannot share the wallet: a receipt paid to it must identify a single agent.
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _walletSig(walletKey, b, wallet, deadline);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WalletInUse.selector, wallet, a));
        vm.prank(relayer);
        identity.setAgentWallet(b, wallet, deadline, sig);

        // Re-confirming the wallet of the agent that already uses it is allowed.
        _setWallet(a, wallet, walletKey);
        assertEq(identity.getAgentWallet(a), wallet);

        // Once `a` releases it, `b` can take it.
        vm.prank(agentOwner);
        identity.unsetAgentWallet(a);
        assertEq(identity.agentOfWallet(wallet), 0);
        _setWallet(b, wallet, walletKey);
        assertEq(identity.agentOfWallet(wallet), b);
        assertEq(identity.agentOfWallet(relayer), 0);
    }

    function test_WalletHistory() public {
        uint256 t0 = block.timestamp;
        uint256 id = _register();
        vm.warp(t0 + 10);
        _setWallet(id, wallet, walletKey);
        vm.warp(t0 + 20);
        vm.prank(agentOwner);
        identity.unsetAgentWallet(id);

        assertEq(identity.getAgentWalletAt(id, t0 - 1), address(0), "before registration");
        assertEq(identity.getAgentWalletAt(id, t0), agentOwner);
        assertEq(identity.getAgentWalletAt(id, t0 + 9), agentOwner);
        assertEq(identity.getAgentWalletAt(id, t0 + 10), wallet);
        assertEq(identity.getAgentWalletAt(id, t0 + 19), wallet);
        assertEq(identity.getAgentWalletAt(id, t0 + 20), address(0));
        assertEq(identity.getAgentWalletAt(id, t0 + 1000), address(0), "future reads the latest");
        assertEq(identity.getAgentWallet(id), address(0));

        // In force at the end of the second, or at the end of the previous one.
        assertTrue(identity.wasAgentWalletAt(id, agentOwner, t0 + 10), "replaced during that second");
        assertFalse(identity.wasAgentWalletAt(id, agentOwner, t0 + 11));
        assertFalse(identity.wasAgentWalletAt(id, wallet, t0 + 9));
        assertTrue(identity.wasAgentWalletAt(id, wallet, t0 + 10));
        assertTrue(identity.wasAgentWalletAt(id, wallet, t0 + 20), "cleared during that second");
        assertFalse(identity.wasAgentWalletAt(id, wallet, t0 + 21));
        assertFalse(identity.wasAgentWalletAt(id, address(0), t0 + 30), "zero never matches");
        assertFalse(identity.wasAgentWalletAt(id, agentOwner, 0));
    }

    function test_WalletHistory_OnlyLastChangeOfASecondIsKept() public {
        uint256 id = _register();
        _setWallet(id, wallet, walletKey);
        assertEq(identity.getAgentWalletAt(id, block.timestamp), wallet);
        assertFalse(identity.wasAgentWalletAt(id, agentOwner, block.timestamp), "overwritten within the second");
    }

    function test_RevertWhen_WalletHistoryQueriedBeyondUint96() public {
        uint256 id = _register();
        uint256 tooLate = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, tooLate));
        identity.getAgentWalletAt(id, tooLate);
    }

    function test_RevertWhen_MetadataUsesReservedKey() public {
        IdentityRegistry.MetadataEntry[] memory md = new IdentityRegistry.MetadataEntry[](1);
        md[0] = IdentityRegistry.MetadataEntry("agentWallet", abi.encode(relayer));
        vm.expectRevert(IdentityRegistry.ReservedMetadataKey.selector);
        vm.prank(agentOwner);
        identity.register(CARD, md);

        uint256 id = _register();
        vm.expectRevert(IdentityRegistry.ReservedMetadataKey.selector);
        vm.prank(agentOwner);
        identity.setMetadata(id, "agentWallet", abi.encode(relayer));
    }

    function test_SetMetadataAndURI_AuthorizedOnly() public {
        uint256 id = _register();
        vm.prank(agentOwner);
        identity.setMetadata(id, "k", "v");
        assertEq(identity.getMetadata(id, "k"), bytes("v"));

        vm.expectEmit(address(identity));
        emit IdentityRegistry.URIUpdated(id, "ipfs://new", agentOwner);
        vm.prank(agentOwner);
        identity.setAgentURI(id, "ipfs://new");
        assertEq(identity.tokenURI(id), "ipfs://new");

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, relayer, id));
        vm.prank(relayer);
        identity.setMetadata(id, "k", "x");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, relayer, id));
        vm.prank(relayer);
        identity.setAgentURI(id, "x");

        vm.prank(agentOwner);
        identity.approve(relayer, id);
        vm.prank(relayer);
        identity.setAgentURI(id, "ipfs://operator");
        assertTrue(identity.isOwnerOrOperator(id, relayer));
        assertFalse(identity.isOwnerOrOperator(id, payee));
    }

    function test_SetAgentWallet_EOA() public {
        uint256 id = _register();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _walletSig(walletKey, id, wallet, deadline);
        vm.expectEmit(address(identity));
        emit IdentityRegistry.AgentWalletSet(id, wallet);
        vm.prank(agentOwner);
        identity.setAgentWallet(id, wallet, deadline, sig);
        assertEq(identity.getAgentWallet(id), wallet);
        assertEq(identity.nonces(wallet), 1);

        // The same consent cannot be replayed (nonce consumed).
        vm.prank(agentOwner);
        identity.unsetAgentWallet(id);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidWalletSignature.selector, wallet));
        vm.prank(agentOwner);
        identity.setAgentWallet(id, wallet, deadline, sig);
    }

    function test_SetAgentWallet_ERC1271() public {
        AgentAccount smartWallet = _createAccount(_defaultPolicy(), _payees());
        uint256 id = _register();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(identity.SET_AGENT_WALLET_TYPEHASH(), id, address(smartWallet), agentOwner, 0, deadline)
        );
        bytes memory sig = _erc7739Sign(
            ownerKey,
            smartWallet,
            _domainSeparator(address(identity)),
            structHash,
            "SetAgentWallet",
            "SetAgentWallet(uint256 agentId,address newWallet,address owner,uint256 nonce,uint256 deadline)"
        );
        vm.prank(agentOwner);
        identity.setAgentWallet(id, address(smartWallet), deadline, sig);
        assertEq(identity.getAgentWallet(id), address(smartWallet));
    }

    function test_RevertWhen_SetAgentWalletInvalid() public {
        uint256 id = _register();
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory wrongSigner = _walletSig(agentOwnerKey, id, wallet, deadline);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidWalletSignature.selector, wallet));
        vm.prank(agentOwner);
        identity.setAgentWallet(id, wallet, deadline, wrongSigner);

        vm.expectRevert(IdentityRegistry.ZeroWallet.selector);
        vm.prank(agentOwner);
        identity.setAgentWallet(id, address(0), deadline, "");

        bytes memory sig = _walletSig(walletKey, id, wallet, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.SignatureExpired.selector, deadline));
        vm.prank(agentOwner);
        identity.setAgentWallet(id, wallet, deadline, sig);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, relayer, id));
        vm.prank(relayer);
        identity.setAgentWallet(id, wallet, deadline, sig);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, relayer, id));
        vm.prank(relayer);
        identity.unsetAgentWallet(id);
    }

    function test_TransferClearsWallet() public {
        uint256 id = _register();
        vm.expectEmit(address(identity));
        emit IdentityRegistry.AgentWalletSet(id, address(0));
        vm.prank(agentOwner);
        identity.transferFrom(agentOwner, relayer, id);
        assertEq(identity.getAgentWallet(id), address(0));
        assertEq(identity.agentOfWallet(agentOwner), 0, "the old wallet is released");
        assertEq(identity.ownerOf(id), relayer);
    }

    function test_TransferWithoutWalletEmitsNothingExtra() public {
        uint256 id = _register();
        vm.prank(agentOwner);
        identity.unsetAgentWallet(id);
        vm.prank(agentOwner);
        identity.transferFrom(agentOwner, relayer, id);
        assertEq(identity.getAgentWallet(id), address(0));
    }

    function test_RevertWhen_UnknownAgent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        identity.getAgentWallet(42);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        identity.getMetadata(42, "k");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        identity.isOwnerOrOperator(42, relayer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        identity.agentWalletDigest(42, wallet, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        identity.getAgentWalletAt(42, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        identity.wasAgentWalletAt(42, wallet, block.timestamp);
    }

    function test_SupportsERC721() public view {
        assertTrue(identity.supportsInterface(0x80ac58cd));
    }

    // ------------------------------------------------------------------ fuzz

    /// @notice A wallet consent works up to and including its deadline, only when signed by the new wallet, and
    ///         only once (its nonce is consumed).
    function testFuzz_SetAgentWalletBinding(uint256 deadlineOffset, uint256 elapsed, uint256 otherKey) public {
        uint256 id = _register();
        deadlineOffset = bound(deadlineOffset, 0, 30 days);
        elapsed = bound(elapsed, 0, 60 days);
        otherKey = bound(otherKey, 1, type(uint128).max);
        if (otherKey == walletKey) ++otherKey;
        uint256 deadline = block.timestamp + deadlineOffset;
        bytes memory good = _walletSig(walletKey, id, wallet, deadline);
        bytes memory forged = _walletSig(otherKey, id, wallet, deadline);
        vm.warp(block.timestamp + elapsed);

        vm.startPrank(agentOwner);
        if (elapsed > deadlineOffset) {
            vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.SignatureExpired.selector, deadline));
            identity.setAgentWallet(id, wallet, deadline, good);
            vm.stopPrank();
            return;
        }
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidWalletSignature.selector, wallet));
        identity.setAgentWallet(id, wallet, deadline, forged);
        identity.setAgentWallet(id, wallet, deadline, good);
        assertEq(identity.getAgentWallet(id), wallet);
        assertEq(identity.nonces(wallet), 1);
        identity.unsetAgentWallet(id);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.InvalidWalletSignature.selector, wallet));
        identity.setAgentWallet(id, wallet, deadline, good);
        vm.stopPrank();
    }

    /// @notice A transfer at any time clears the wallet and frees it, but the history still shows it up to the
    ///         transfer.
    function testFuzz_TransferClearsWalletKeepsHistory(address newOwner, uint256 dt) public {
        vm.assume(newOwner != address(0) && newOwner != agentOwner);
        dt = bound(dt, 1, 365 days);
        uint256 t0 = block.timestamp;
        uint256 id = _register();
        vm.warp(t0 + dt);
        vm.prank(agentOwner);
        identity.transferFrom(agentOwner, newOwner, id);
        assertEq(identity.getAgentWallet(id), address(0));
        assertEq(identity.agentOfWallet(agentOwner), 0);
        assertTrue(identity.wasAgentWalletAt(id, agentOwner, t0));
        assertTrue(identity.wasAgentWalletAt(id, agentOwner, t0 + dt - 1));
        assertTrue(identity.wasAgentWalletAt(id, agentOwner, t0 + dt), "cleared during that second");
        assertFalse(identity.wasAgentWalletAt(id, agentOwner, t0 + dt + 1));
    }
}
