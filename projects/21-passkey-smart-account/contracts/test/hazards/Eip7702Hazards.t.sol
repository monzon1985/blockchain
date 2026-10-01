// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";

import {EIP7702Utils} from "@openzeppelin/contracts/account/utils/EIP7702Utils.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {PasskeyAccount} from "../../src/PasskeyAccount.sol";
import {IPasskeyAccount} from "../../src/interfaces/IPasskeyAccount.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Erc7739Helper} from "../utils/Erc7739Helper.sol";
import {
    ChainSweeper,
    GuardedVault,
    IWithdrawable,
    NaiveErc1271Account,
    NaiveInitAccount,
    OriginGuardedVault,
    PlainOwnerAccountB,
    ReentrantDelegate,
    SessionKeyAccountA
} from "./fixtures/VulnerableBaselines.sol";

/// @notice One named test per published EIP-7702 hazard. Each hazard check is written once and run twice: against
/// the production contract (must pass) and against a deliberately vulnerable baseline (must fail with the hazard's
/// message). The second run proves the check actually detects the hazard, i.e. the test fails before the fix.
contract Eip7702HazardsTest is BaseTest {
    uint256 internal constant VICTIM_PK = 0x71C71;
    uint256 internal constant ATTACKER_PK = 0xA77AC;
    address internal victim;
    address internal attacker;

    function setUp() public override {
        super.setUp();
        victim = vm.addr(VICTIM_PK);
        attacker = vm.addr(ATTACKER_PK);
        vm.deal(victim, 10 ether);
    }

    // =================================================================================================================
    // H01: initialization front-running. The victim's signed authorization is public once broadcast; an attacker
    // bundles it into their own type-4 transaction together with a call to the initializer.
    // =================================================================================================================

    function hazard01_InitFrontRunning(address impl, bytes calldata attackerInitCall) external {
        Vm.SignedDelegation memory auth = vm.signDelegation(impl, VICTIM_PK);
        vm.attachDelegation(auth);
        vm.prank(attacker);
        (bool initialized,) = victim.call(attackerInitCall);
        require(EIP7702Utils.fetchDelegate(victim) == impl, "setup: delegation not applied");
        require(!initialized, "H01: attacker initialized the victim's delegated EOA");
    }

    function test_Hazard01_InitFrontRunning() public {
        bytes memory call_ =
            abi.encodeCall(PasskeyAccount.initialize, (_initParams(ATTACKER_PASSKEY_PK, _noGuardians(), 0)));
        this.hazard01_InitFrontRunning(address(implementation), call_);
        assertFalse(PasskeyAccount(payable(victim)).initialized());
        // The legitimate owner can still initialize (self-call signed by the EOA key).
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        vm.prank(victim);
        PasskeyAccount(payable(victim)).initialize(p);
        assertEq(PasskeyAccount(payable(victim)).passkey().qx, p.passkey.qx);
    }

    function test_Hazard01_InitFrontRunning_FailsOnVulnerableBaseline() public {
        NaiveInitAccount naive = new NaiveInitAccount();
        vm.expectRevert(bytes("H01: attacker initialized the victim's delegated EOA"));
        this.hazard01_InitFrontRunning(address(naive), abi.encodeCall(NaiveInitAccount.initialize, (attacker)));
    }

    function test_Hazard01_BaselineConsequence_FundsStolen() public {
        NaiveInitAccount naive = new NaiveInitAccount();
        vm.attachDelegation(vm.signDelegation(address(naive), VICTIM_PK));
        vm.startPrank(attacker);
        NaiveInitAccount(payable(victim)).initialize(attacker);
        NaiveInitAccount(payable(victim)).execute(attacker, 10 ether, "");
        vm.stopPrank();
        assertEq(attacker.balance, 10 ether);
    }

    // =================================================================================================================
    // H02: storage collision when re-delegating from implementation A to implementation B. B reads whatever A left
    // in the same slots. Fix: all state in an ERC-7201 namespace unique to the implementation.
    // =================================================================================================================

    function hazard02_StorageCollision(address implB, bytes calldata probeCall) external {
        // A: the user granted a dApp session key under implementation A.
        SessionKeyAccountA implA = new SessionKeyAccountA();
        address dappSessionKey = makeAddr("dappSessionKey");
        vm.signAndAttachDelegation(address(implA), VICTIM_PK);
        vm.prank(victim);
        SessionKeyAccountA(payable(victim)).grantSession(dappSessionKey);
        // The user moves to implementation B.
        vm.signAndAttachDelegation(implB, VICTIM_PK);
        vm.prank(victim);
        (bool ok,) = victim.call("");
        require(ok && EIP7702Utils.fetchDelegate(victim) == implB, "setup: re-delegation failed");
        // Does the old session key hold any power under B?
        vm.prank(dappSessionKey);
        (bool staleKeyHasPower,) = victim.call(probeCall);
        require(!staleKeyHasPower, "H02: stale storage from implementation A granted control under B");
    }

    function test_Hazard02_StorageCollisionOnRedelegation() public {
        bytes memory probe = abi.encodeCall(PasskeyAccount.execute, (MODE_BATCH, abi.encode(new bytes[](0))));
        this.hazard02_StorageCollision(address(implementation), probe);
        // Under PasskeyAccount the EOA starts clean: uninitialized, no guardians, no passkey.
        PasskeyAccount acct = PasskeyAccount(payable(victim));
        assertFalse(acct.initialized());
        assertEq(acct.guardians().length, 0);
        assertEq(acct.passkey().qx, bytes32(0));
    }

    function test_Hazard02_StorageCollisionOnRedelegation_FailsOnVulnerableBaseline() public {
        PlainOwnerAccountB implB = new PlainOwnerAccountB();
        vm.expectRevert(bytes("H02: stale storage from implementation A granted control under B"));
        this.hazard02_StorageCollision(address(implB), abi.encodeCall(PlainOwnerAccountB.execute, (attacker, 1 ether)));
    }

    function test_Hazard02_Note_StateSurvivesRoundTrip() public {
        // Documented limitation: storage is keyed by the EOA, so delegating away and back restores the old config.
        address eoa = _delegate(VICTIM_PK);
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        vm.prank(eoa);
        PasskeyAccount(payable(eoa)).initialize(p);
        vm.signAndAttachDelegation(address(new SessionKeyAccountA()), VICTIM_PK);
        vm.prank(eoa);
        (bool ok,) = eoa.call("");
        assertTrue(ok);
        vm.signAndAttachDelegation(address(implementation), VICTIM_PK);
        vm.prank(eoa);
        (ok,) = eoa.call("");
        assertTrue(ok);
        assertEq(PasskeyAccount(payable(eoa)).passkey().qx, p.passkey.qx);
    }

    // =================================================================================================================
    // H03: chainId-0 authorizations are valid on every chain. Replayed where the same address holds other code, they
    // hand the EOA to that code. The fix lives off chain: the wallet policy never signs chainId 0 and bundler-lite
    // refuses it (bundler/test/units.test.ts policy tests, bundler.integration.test.ts "-32602"). On chain,
    // initialization signatures are chain-bound, so a replayed delegation to PasskeyAccount stays uninitialized
    // (test_Hazard03_InitSignatureIsChainBound, which runs project code).
    // The hazard03 pair below is a protocol demonstration: it does not call project code. Its "fix" run signs a
    // chain-specific authorization, which is the behaviour the TypeScript policy enforces; its baseline run signs
    // chainId 0 and shows the replay draining the EOA.
    // =================================================================================================================

    function hazard03_ChainIdZero(bool crossChainAuthorization) external {
        address target = address(implementation);
        Vm.SignedDelegation memory auth = vm.signDelegation(target, VICTIM_PK, crossChainAuthorization);
        // Replay on another chain where the attacker controls the code at the same address.
        vm.chainId(block.chainid + 1);
        vm.etch(target, address(new ChainSweeper()).code);
        uint256 before = victim.balance;
        // The relayer submits the tuple as signed: chain id 0 if cross-chain, otherwise the original chain id, which
        // no longer matches and makes the signature recover to an unrelated authority.
        try this.relayAuthorization(auth, crossChainAuthorization) {} catch {}
        require(victim.balance == before, "H03: chainId-0 authorization replayed on another chain drained the EOA");
    }

    function relayAuthorization(Vm.SignedDelegation calldata auth, bool crossChain) external {
        vm.attachDelegation(auth, crossChain);
        vm.prank(attacker);
        (bool ok,) = victim.call("");
        ok;
    }

    function test_Hazard03_ChainIdZeroAuthorization() public {
        this.hazard03_ChainIdZero(false);
        assertEq(EIP7702Utils.fetchDelegate(victim), address(0));
    }

    function test_Hazard03_ChainIdZeroAuthorization_FailsOnVulnerableBaseline() public {
        vm.expectRevert(bytes("H03: chainId-0 authorization replayed on another chain drained the EOA"));
        this.hazard03_ChainIdZero(true);
    }

    function test_Hazard03_InitSignatureIsChainBound() public {
        // Even if a delegation to PasskeyAccount is replayed on another chain, the initialization signature is not.
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        address eoa = _delegate(VICTIM_PK);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _initDigest(eoa, p, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VICTIM_PK, digest);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IPasskeyAccount.InvalidInitSignature.selector);
        PasskeyAccount(payable(eoa)).initializeWithSig(p, deadline, abi.encodePacked(r, s, v));
    }

    function _initDigest(address account, IPasskeyAccount.InitParams memory p, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                implementation.INITIALIZE_TYPEHASH(),
                p.passkey.qx,
                p.passkey.qy,
                p.passkey.rpIdHash,
                keccak256(abi.encodePacked(p.guardians)),
                p.threshold,
                deadline
            )
        );
        return MessageHashUtils.toTypedDataHash(Erc7739Helper.accountSeparator(account), structHash);
    }

    // =================================================================================================================
    // H04: `tx.origin == msg.sender` no longer means "no code". A delegated EOA calling from its own code satisfies the
    // guard and can re-enter. Fix: never use tx.origin for authorization or reentrancy protection; use CEI and a
    // reentrancy guard. The hazard04_TxOriginGuard pair is a demonstration on vault fixtures (GuardedVault is a test
    // contract, not project code); hazard04_NoOriginOpcode checks the actual fix on the deployed production bytecode.
    // =================================================================================================================

    function hazard04_TxOriginGuard(address vault) external {
        vm.deal(address(this), 9 ether);
        (bool ok,) = vault.call{value: 9 ether}(abi.encodeWithSignature("deposit()"));
        require(ok, "setup: deposit failed");
        // The attacker deposits 1 ETH, delegates their EOA to a re-entrant delegate and withdraws from their own code.
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (ok,) = vault.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        require(ok, "setup: attacker deposit failed");
        vm.signAndAttachDelegation(address(new ReentrantDelegate()), ATTACKER_PK);
        vm.prank(attacker, attacker);
        (ok,) = attacker.call(abi.encodeCall(ReentrantDelegate.attack, (IWithdrawable(vault))));
        require(attacker.balance <= 1 ether, "H04: tx.origin guard bypassed by a delegated EOA; vault drained");
    }

    function test_Hazard04_TxOriginGuardBroken() public {
        this.hazard04_TxOriginGuard(address(new GuardedVault()));
    }

    function test_Hazard04_TxOriginGuardBroken_FailsOnVulnerableBaseline() public {
        OriginGuardedVault vault = new OriginGuardedVault();
        vm.expectRevert(bytes("H04: tx.origin guard bypassed by a delegated EOA; vault drained"));
        this.hazard04_TxOriginGuard(address(vault));
    }

    /// @dev Linear sweep of runtime bytecode (PUSH immediates skipped): does any instruction read ORIGIN (0x32)?
    function _readsOrigin(bytes memory code) internal pure returns (bool) {
        for (uint256 pc = 0; pc < code.length; ++pc) {
            uint8 op = uint8(code[pc]);
            if (op == 0x32) return true;
            if (op >= 0x60 && op <= 0x7f) pc += op - 0x5f;
        }
        return false;
    }

    function hazard04_NoOriginOpcode(address[] calldata targets) external view {
        for (uint256 i = 0; i < targets.length; ++i) {
            require(targets[i].code.length > 0, "setup: no code");
            require(!_readsOrigin(targets[i].code), "H04: production contract reads tx.origin");
        }
    }

    function test_Hazard04_NoTxOriginInProductionBytecode() public {
        address[] memory targets = new address[](5);
        targets[0] = address(implementation);
        targets[1] = address(factory);
        targets[2] = address(paymaster);
        targets[3] = address(usd);
        targets[4] = address(_createAccount(PASSKEY_PK)); // the clone proxy an account actually is
        this.hazard04_NoOriginOpcode(targets);
    }

    function test_Hazard04_NoTxOriginInProductionBytecode_FailsOnVulnerableBaseline() public {
        address[] memory targets = new address[](2);
        targets[0] = address(implementation);
        targets[1] = address(new OriginGuardedVault());
        vm.expectRevert(bytes("H04: production contract reads tx.origin"));
        this.hazard04_NoOriginOpcode(targets);
    }

    // =================================================================================================================
    // H05: ERC-1271 replay across accounts. The same passkey controls a factory account and an upgraded EOA; a
    // signature over a raw application hash would validate on both. Fix: ERC-7739 nests the account's own domain.
    // =================================================================================================================

    function hazard05_CrossAccountReplay(address accountA, address accountB, bytes calldata sigForA, bytes32 appHash)
        external
        view
    {
        require(IErc1271(accountA).isValidSignature(appHash, sigForA) == 0x1626ba7e, "setup: signature invalid on A");
        require(
            IErc1271(accountB).isValidSignature(appHash, sigForA) != 0x1626ba7e,
            "H05: signature for account A replayed on account B"
        );
    }

    function test_Hazard05_Erc7739ReplayAcrossAccounts() public {
        PasskeyAccount a = _createAccount(PASSKEY_PK);
        address b = _delegate(VICTIM_PK);
        IPasskeyAccount.InitParams memory p = _initParams(PASSKEY_PK, _noGuardians(), 0);
        vm.prank(b);
        PasskeyAccount(payable(b)).initialize(p);

        bytes32 appSep = Erc7739Helper.appSeparator(makeAddr("permitApp"));
        bytes32 contents = Erc7739Helper.mailHash(attacker, "transfer everything");
        bytes32 appHash = MessageHashUtils.toTypedDataHash(appSep, contents);
        bytes memory inner = _webauthnSig(PASSKEY_PK, Erc7739Helper.typedDataSignDigest(address(a), appSep, contents));
        this.hazard05_CrossAccountReplay(
            address(a), b, Erc7739Helper.wrapTypedDataSig(inner, appSep, contents), appHash
        );
    }

    function test_Hazard05_Erc7739ReplayAcrossAccounts_FailsOnVulnerableBaseline() public {
        IPasskeyAccount.Passkey memory key = _passkey(PASSKEY_PK);
        NaiveErc1271Account a = new NaiveErc1271Account(key.qx, key.qy);
        NaiveErc1271Account b = new NaiveErc1271Account(key.qx, key.qy);
        bytes32 appHash = MessageHashUtils.toTypedDataHash(
            Erc7739Helper.appSeparator(makeAddr("permitApp")), Erc7739Helper.mailHash(attacker, "transfer everything")
        );
        bytes memory sig = _webauthnSig(PASSKEY_PK, appHash);
        vm.expectRevert(bytes("H05: signature for account A replayed on account B"));
        this.hazard05_CrossAccountReplay(address(a), address(b), sig, appHash);
    }

    // silence unused-import lint for PackedUserOperation in some toolchains
    function _unused(PackedUserOperation memory) internal pure {}
}

interface IErc1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}
