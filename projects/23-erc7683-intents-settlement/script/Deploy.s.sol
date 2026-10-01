// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {AccessManager} from "@openzeppelin-contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {DestinationSettler} from "../src/DestinationSettler.sol";
import {OriginSettler} from "../src/OriginSettler.sol";
import {ERC7683ResolverAdapter} from "../src/adapters/ERC7683ResolverAdapter.sol";
import {IEscrowSettler} from "../src/interfaces/IEscrowSettler.sol";
import {IMailbox} from "../src/interfaces/IMailbox.sol";
import {MailboxFillReporter} from "../src/settlement/mailbox/MailboxFillReporter.sol";
import {MailboxSettlementModule} from "../src/settlement/mailbox/MailboxSettlementModule.sol";
import {MockMailbox} from "../src/settlement/mailbox/MockMailbox.sol";
import {OptimisticSettlementModule} from "../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {HeaderStore} from "../src/settlement/proof/HeaderStore.sol";
import {StorageProofSettlementModule} from "../src/settlement/proof/StorageProofSettlementModule.sol";

/// @notice Role ids used in both AccessManagers.
library Roles {
    uint64 internal constant HEADER_RELAYER = 1;
    uint64 internal constant MAILBOX_RELAYER = 2;
}

/// @notice Who administers a chain's AccessManager once deployment is done, and how slowly.
/// @param admin Final ADMIN_ROLE holder: a timelock or multisig. The deployer renounces the role when it differs.
/// @param adminExecutionDelay Execution delay of `admin`: every admin operation (granting a relayer role, re-pointing
///        a function to another role, moving a target to another authority, ...) must be scheduled this many
///        seconds before it can run, publicly (OperationScheduled). Applies immediately.
/// @param relayerGrantDelay Grant delay of the relayer roles: a new relayer only becomes effective this many
///        seconds after it is granted. AccessManager applies an increase only after `minSetback()` (5 days).
/// @dev Users are protected against a compromised admin only if `adminExecutionDelay` exceeds the longest order
///      lifetime (open to `fillDeadline`) plus `REFUND_GRACE`: a malicious relayer grant must stay visible long
///      enough for every open order to be refunded before the new relayer can forge a header or a message.
struct Governance {
    address admin;
    uint32 adminExecutionDelay;
    uint32 relayerGrantDelay;
}

/// @notice Shared end-of-deployment step: slow down the relayer roles and hand ADMIN_ROLE to the final admin.
library Handover {
    /// @notice Sets the relayer grant delays, grants ADMIN_ROLE to `g.admin` with its execution delay and, when the
    /// final admin is not the deployer, makes the deployer renounce ADMIN_ROLE. Must run inside a broadcast from
    /// `deployer`, the current admin.
    /// @param manager The AccessManager.
    /// @param deployer The current admin.
    /// @param g Final governance settings.
    /// @param relayerRoles Relayer roles of this manager.
    function run(AccessManager manager, address deployer, Governance memory g, uint64[] memory relayerRoles) internal {
        for (uint256 i = 0; i < relayerRoles.length; ++i) {
            manager.setGrantDelay(relayerRoles[i], g.relayerGrantDelay);
        }
        uint64 adminRole = manager.ADMIN_ROLE();
        manager.grantRole(adminRole, g.admin, g.adminExecutionDelay);
        if (g.admin != deployer) manager.renounceRole(adminRole, deployer);
    }

    /// @notice Governance settings from the environment: ADMIN (defaults to `deployer`), ADMIN_EXECUTION_DELAY and
    /// RELAYER_GRANT_DELAY (seconds, default 3 days each).
    /// @param deployer Fallback admin.
    /// @return g The settings.
    function fromEnv(address deployer) internal view returns (Governance memory g) {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        g.admin = vm.envOr("ADMIN", deployer);
        g.adminExecutionDelay = SafeCast.toUint32(vm.envOr("ADMIN_EXECUTION_DELAY", uint256(3 days)));
        g.relayerGrantDelay = SafeCast.toUint32(vm.envOr("RELAYER_GRANT_DELAY", uint256(3 days)));
    }
}

/// @title DeployDestination
/// @notice Step 1 of 3, on the destination chain: settler, mailbox, reporter. The deployer stays admin until
/// ConfigureDestination (step 3) hands the role over.
/// @dev forge script script/Deploy.s.sol:DeployDestination --rpc-url $DEST_RPC --account <keystore>
///      --sender <keystore address> --broadcast
///      Env: MAILBOX_RELAYER (address holding the relayer role on this chain's mailbox).
contract DeployDestination is Script {
    struct Deployed {
        AccessManager manager;
        DestinationSettler settler;
        MockMailbox mailbox;
        MailboxFillReporter reporter;
    }

    function run() external returns (Deployed memory d) {
        d = deploy(msg.sender, vm.envAddress("MAILBOX_RELAYER"));
        console.log("DestinationSettler", address(d.settler));
        console.log("MockMailbox", address(d.mailbox));
        console.log("MailboxFillReporter", address(d.reporter));
        console.log("AccessManager", address(d.manager));
    }

    /// @notice Deploys and wires the destination side, broadcasting from `admin` (the AccessManager admin).
    function deploy(address admin, address mailboxRelayer) public returns (Deployed memory d) {
        vm.startBroadcast(admin);
        d.manager = new AccessManager(admin);
        d.settler = new DestinationSettler();
        d.mailbox = new MockMailbox(address(d.manager));
        d.reporter = new MailboxFillReporter(d.settler, IMailbox(address(d.mailbox)), address(d.manager));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockMailbox.process.selector;
        d.manager.setTargetFunctionRole(address(d.mailbox), selectors, Roles.MAILBOX_RELAYER);
        d.manager.grantRole(Roles.MAILBOX_RELAYER, mailboxRelayer, 0);
        vm.stopBroadcast();
    }
}

/// @title DeployOrigin
/// @notice Step 2 of 3, on the origin chain: settler, modules, header store, adapter; then the relayer roles get
/// their grant delay and ADMIN_ROLE moves to the final admin with its execution delay (see `Governance`).
/// @dev forge script script/Deploy.s.sol:DeployOrigin --rpc-url $ORIGIN_RPC --account <keystore>
///      --sender <keystore address> --broadcast
///      Env: PERMIT2 (0 deploys one from the artifact), REFUND_GRACE, BOND_TOKEN, BOND, CHALLENGE_WINDOW,
///      DEST_CHAIN_ID, DEST_SETTLER, DEST_REPORTER, HEADER_RELAYER, MAILBOX_RELAYER, ADMIN,
///      ADMIN_EXECUTION_DELAY, RELAYER_GRANT_DELAY.
contract DeployOrigin is Script {
    struct Config {
        address permit2;
        uint256 refundGrace;
        address bondToken;
        uint256 bond;
        uint256 challengeWindow;
        uint256 destChainId;
        address destSettler;
        address destReporter;
        address headerRelayer;
        address mailboxRelayer;
        Governance governance;
    }

    struct Deployed {
        AccessManager manager;
        OriginSettler origin;
        MockMailbox mailbox;
        MailboxSettlementModule mailboxModule;
        HeaderStore headers;
        OptimisticSettlementModule optimistic;
        StorageProofSettlementModule proofModule;
        ERC7683ResolverAdapter adapter;
    }

    function run() external returns (Deployed memory d) {
        Config memory c = Config({
            permit2: vm.envOr("PERMIT2", address(0x000000000022D473030F116dDEE9F6B43aC78BA3)),
            refundGrace: vm.envOr("REFUND_GRACE", uint256(1 hours)),
            bondToken: vm.envAddress("BOND_TOKEN"),
            bond: vm.envUint("BOND"),
            challengeWindow: vm.envOr("CHALLENGE_WINDOW", uint256(30 minutes)),
            destChainId: vm.envUint("DEST_CHAIN_ID"),
            destSettler: vm.envAddress("DEST_SETTLER"),
            destReporter: vm.envAddress("DEST_REPORTER"),
            headerRelayer: vm.envAddress("HEADER_RELAYER"),
            mailboxRelayer: vm.envAddress("MAILBOX_RELAYER"),
            governance: Handover.fromEnv(msg.sender)
        });
        d = deploy(msg.sender, c);
        console.log("OriginSettler", address(d.origin));
        console.log("MailboxSettlementModule", address(d.mailboxModule));
        console.log("OptimisticSettlementModule", address(d.optimistic));
        console.log("StorageProofSettlementModule", address(d.proofModule));
        console.log("HeaderStore", address(d.headers));
        console.log("ERC7683ResolverAdapter", address(d.adapter));
    }

    /// @notice Deploys and wires the origin side, broadcasting from `deployer` (the initial AccessManager admin),
    /// then hands ADMIN_ROLE to `c.governance.admin`.
    function deploy(address deployer, Config memory c) public returns (Deployed memory d) {
        vm.startBroadcast(deployer);
        if (c.permit2 == address(0)) c.permit2 = deployCode("Permit2.sol:Permit2");
        d.manager = new AccessManager(deployer);
        d.origin = new OriginSettler(ISignatureTransfer(c.permit2), c.refundGrace, address(d.manager));
        d.mailbox = new MockMailbox(address(d.manager));
        d.mailboxModule =
            new MailboxSettlementModule(IEscrowSettler(address(d.origin)), address(d.mailbox), address(d.manager));
        d.headers = new HeaderStore(address(d.manager));
        d.optimistic = new OptimisticSettlementModule(
            IEscrowSettler(address(d.origin)),
            d.headers,
            IERC20(c.bondToken),
            c.bond,
            c.challengeWindow,
            address(d.manager)
        );
        d.proofModule =
            new StorageProofSettlementModule(IEscrowSettler(address(d.origin)), d.headers, address(d.manager));
        d.adapter =
            new ERC7683ResolverAdapter(d.origin, d.mailboxModule, d.optimistic, d.proofModule, 5 minutes, 2 minutes);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = HeaderStore.submitHeader.selector;
        d.manager.setTargetFunctionRole(address(d.headers), selectors, Roles.HEADER_RELAYER);
        d.manager.grantRole(Roles.HEADER_RELAYER, c.headerRelayer, 0);
        selectors[0] = MockMailbox.process.selector;
        d.manager.setTargetFunctionRole(address(d.mailbox), selectors, Roles.MAILBOX_RELAYER);
        d.manager.grantRole(Roles.MAILBOX_RELAYER, c.mailboxRelayer, 0);

        d.mailboxModule.setRoute(c.destChainId, c.destReporter, c.destSettler);
        d.optimistic.setDestinationSettler(c.destChainId, c.destSettler);
        d.proofModule.setDestinationSettler(c.destChainId, c.destSettler);
        d.origin.setSettlementModule(address(d.mailboxModule), true);
        d.origin.setSettlementModule(address(d.optimistic), true);
        d.origin.setSettlementModule(address(d.proofModule), true);

        uint64[] memory relayerRoles = new uint64[](2);
        relayerRoles[0] = Roles.HEADER_RELAYER;
        relayerRoles[1] = Roles.MAILBOX_RELAYER;
        Handover.run(d.manager, deployer, c.governance, relayerRoles);
        vm.stopBroadcast();
    }
}

/// @title ConfigureDestination
/// @notice Step 3 of 3, on the destination chain: point the reporter at the origin's mailbox module, then give the
/// mailbox relayer role its grant delay and hand ADMIN_ROLE to the final admin (see `Governance`).
/// @dev Env: REPORTER, ORIGIN_CHAIN_ID, ORIGIN_MAILBOX_MODULE, ADMIN, ADMIN_EXECUTION_DELAY, RELAYER_GRANT_DELAY.
contract ConfigureDestination is Script {
    function run() external {
        configure(
            msg.sender,
            MailboxFillReporter(vm.envAddress("REPORTER")),
            vm.envUint("ORIGIN_CHAIN_ID"),
            vm.envAddress("ORIGIN_MAILBOX_MODULE"),
            Handover.fromEnv(msg.sender)
        );
    }

    /// @notice Sets the reporter's origin route and hands the destination AccessManager over, broadcasting from
    /// `deployer` (its current admin).
    function configure(
        address deployer,
        MailboxFillReporter reporter,
        uint256 originChainId,
        address originModule,
        Governance memory governance
    ) public {
        vm.startBroadcast(deployer);
        reporter.setOriginModule(originChainId, originModule);
        uint64[] memory relayerRoles = new uint64[](1);
        relayerRoles[0] = Roles.MAILBOX_RELAYER;
        Handover.run(AccessManager(reporter.authority()), deployer, governance, relayerRoles);
        vm.stopBroadcast();
    }
}
