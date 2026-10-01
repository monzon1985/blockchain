// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {InteroperableAddress} from "@openzeppelin-contracts/utils/draft-InteroperableAddress.sol";

import {DestinationSettler} from "../DestinationSettler.sol";
import {OriginSettler} from "../OriginSettler.sol";
import {GaslessCrossChainOrder, ResolvedCrossChainOrder} from "../erc7683/IERC7683.sol";
import {IAttribute, IFormula, IPayment, IResolver, IStep, IVariableRole} from "../erc7683/IERC7683Resolver.sol";
import {FillProofLib} from "../libraries/FillProofLib.sol";
import {IntentOrderData} from "../libraries/IntentLib.sol";
import {MailboxFillReporter} from "../settlement/mailbox/MailboxFillReporter.sol";
import {MailboxSettlementModule} from "../settlement/mailbox/MailboxSettlementModule.sol";
import {OptimisticSettlementModule} from "../settlement/optimistic/OptimisticSettlementModule.sol";
import {StorageProofSettlementModule} from "../settlement/proof/StorageProofSettlementModule.sol";

/// @title ERC7683ResolverAdapter
/// @notice Exposes this protocol's v1 (settler-centric) ERC-7683 orders through the resolver-centric ERC-7683 draft.
/// `resolve(abi.encode(GaslessCrossChainOrder, signature))` validates the order through the OriginSettler and returns
/// the steps, variables, payments and assumptions a programmable solver needs, for each of the three settlement modes.
/// @dev Deployed on the origin chain and queried with eth_call. Where the draft's instruction set cannot express
///      this protocol exactly, the adapter uses the closest faithful construct and `docs/spec-drift.md` records the
///      gap: opaque `fillerData` becomes the typed `fillWithRepayment`, the Dutch decay becomes a SpendsERC20 upper
///      bound, exclusivity and trust models become named assumptions, and arithmetic on execution outputs (a
///      challenge deadline) becomes a Witness of kind WITNESS_UINT256_ADD.
contract ERC7683ResolverAdapter is IResolver {
    /// @notice Witness kind: `variables[0] + abi.decode(data, (uint256))`.
    string public constant WITNESS_UINT256_ADD = "erc7683-intents/uint256-add";
    /// @notice Witness kind: smallest block number >= `variables[0]` whose header of chain `chainId` is stored in the
    /// HeaderStore; `data = abi.encode(bytes headerStore, uint256 chainId)` with an ERC-7930 headerStore address.
    string public constant WITNESS_RELAYED_HEADER = "erc7683-intents/relayed-header";
    /// @notice Witness kind: `eth_getProof(account, [slot], variables[0]).accountProof`, as `bytes[]`;
    /// `data = abi.encode(bytes account, bytes32 slot)` with an ERC-7930 account address.
    string public constant WITNESS_ACCOUNT_PROOF = "eth_getProof/accountProof";
    /// @notice Witness kind: `eth_getProof(account, [slot], variables[0]).storageProof[0].proof`, as `bytes[]`.
    string public constant WITNESS_STORAGE_PROOF = "eth_getProof/storageProof";

    /// @dev Step and variable indices shared by every mode.
    uint256 internal constant STEP_OPEN = 0;
    uint256 internal constant STEP_FILL = 1;
    uint256 internal constant STEP_SETTLE = 2;
    uint256 internal constant VAR_RECIPIENT = 0;
    uint256 internal constant VAR_FILL_TIME = 1;
    uint256 internal constant VAR_FILL_BLOCK = 2;

    /// @notice OriginSettler whose orders are resolved.
    OriginSettler public immutable ORIGIN_SETTLER;
    /// @notice Settlement mode 1.
    MailboxSettlementModule public immutable MAILBOX_MODULE;
    /// @notice Settlement mode 2.
    OptimisticSettlementModule public immutable OPTIMISTIC_MODULE;
    /// @notice Settlement mode 3.
    StorageProofSettlementModule public immutable PROOF_MODULE;
    /// @notice Advertised delay between a mailbox report and the repayment.
    uint256 public immutable MAILBOX_DELAY;
    /// @notice Advertised delay between a fill and a provable relayed header.
    uint256 public immutable PROOF_DELAY;

    /// @notice The order selects a module this adapter does not know.
    /// @param module The module.
    error UnsupportedSettlementModule(address module);

    /// @dev Everything the step builders need, kept in memory to stay clear of stack limits.
    struct Context {
        bytes32 orderId;
        bytes originData;
        bytes32 fillHash;
        uint256 originChainId;
        uint32 openDeadline;
        uint32 fillDeadline;
        IntentOrderData data;
    }

    /// @param originSettler OriginSettler whose orders are resolved.
    /// @param mailboxModule Settlement mode 1 module.
    /// @param optimisticModule Settlement mode 2 module.
    /// @param proofModule Settlement mode 3 module.
    /// @param mailboxDelay Advertised mailbox relay delay in seconds.
    /// @param proofDelay Advertised header relay delay in seconds.
    constructor(
        OriginSettler originSettler,
        MailboxSettlementModule mailboxModule,
        OptimisticSettlementModule optimisticModule,
        StorageProofSettlementModule proofModule,
        uint256 mailboxDelay,
        uint256 proofDelay
    ) {
        ORIGIN_SETTLER = originSettler;
        MAILBOX_MODULE = mailboxModule;
        OPTIMISTIC_MODULE = optimisticModule;
        PROOF_MODULE = proofModule;
        MAILBOX_DELAY = mailboxDelay;
        PROOF_DELAY = proofDelay;
    }

    /// @inheritdoc IResolver
    /// @dev `payload = abi.encode(GaslessCrossChainOrder order, bytes signature)`. Reverts if the OriginSettler would
    ///      reject the order (resolveFor validates it).
    function resolve(bytes calldata payload) external view returns (ResolvedOrder memory resolved) {
        (GaslessCrossChainOrder memory order, bytes memory signature) =
            abi.decode(payload, (GaslessCrossChainOrder, bytes));
        ResolvedCrossChainOrder memory v1 = ORIGIN_SETTLER.resolveFor(order, "");
        Context memory ctx = Context({
            orderId: v1.orderId,
            originData: v1.fillInstructions[0].originData,
            fillHash: keccak256(v1.fillInstructions[0].originData),
            originChainId: v1.originChainId,
            openDeadline: v1.openDeadline,
            fillDeadline: v1.fillDeadline,
            data: abi.decode(order.orderData, (IntentOrderData))
        });

        address module = ctx.data.settlementModule;
        (uint256 extraSteps, uint256 extraVars) = _modeShape(module);

        resolved.steps = new bytes[](2 + extraSteps);
        resolved.variables = new bytes[](3 + extraVars);
        resolved.payments = new bytes[](1);
        resolved.variables[VAR_RECIPIENT] = abi.encodeCall(IVariableRole.PaymentRecipient, ());
        resolved.variables[VAR_FILL_TIME] =
            abi.encodeCall(IVariableRole.ExecutionOutput, ("block.timestamp", STEP_FILL));
        resolved.variables[VAR_FILL_BLOCK] = abi.encodeCall(IVariableRole.ExecutionOutput, ("block.number", STEP_FILL));
        resolved.steps[STEP_OPEN] = _openStep(ctx, order, signature);
        resolved.steps[STEP_FILL] = _fillStep(ctx);

        Assumption[] memory modeAssumptions;
        if (module == address(MAILBOX_MODULE)) {
            modeAssumptions = _mailboxSteps(ctx, resolved);
        } else if (module == address(OPTIMISTIC_MODULE)) {
            modeAssumptions = _optimisticSteps(ctx, resolved);
        } else {
            modeAssumptions = _proofSteps(ctx, resolved);
        }
        resolved.assumptions = _withExclusivity(ctx.data, modeAssumptions);
    }

    /// @dev Steps and variables each mode adds to the common open + fill prefix; reverts for unknown modules.
    function _modeShape(address module) internal view returns (uint256 extraSteps, uint256 extraVars) {
        if (module == address(MAILBOX_MODULE)) return (1, 0);
        if (module == address(OPTIMISTIC_MODULE)) return (2, 2);
        if (module == address(PROOF_MODULE)) return (1, 3);
        revert UnsupportedSettlementModule(module);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Common steps
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Step 0: open on the origin chain. If another solver opened it first, the step counts as executed.
    function _openStep(Context memory ctx, GaslessCrossChainOrder memory order, bytes memory signature)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory args = new bytes[](3);
        args[0] = abi.encode("", order);
        args[1] = abi.encode("", signature);
        args[2] = abi.encode("", bytes(""));
        bytes[] memory attributes = new bytes[](2);
        attributes[0] = abi.encodeCall(IAttribute.TimingBounds, ("block.timestamp", "", _constant(ctx.openDeadline)));
        attributes[1] = abi.encodeCall(
            IAttribute.RevertPolicy,
            ("ignore", abi.encodeWithSelector(OriginSettler.OrderAlreadyExists.selector, ctx.orderId))
        );
        return abi.encodeCall(
            IStep.Call, (_originAddress(address(ORIGIN_SETTLER)), OriginSettler.openFor.selector, args, attributes)
        );
    }

    /// @dev Step 1: fill on the destination chain, repaying the PaymentRecipient variable.
    function _fillStep(Context memory ctx) internal pure returns (bytes memory) {
        IntentOrderData memory data = ctx.data;
        bytes[] memory args = new bytes[](3);
        args[0] = abi.encode("", ctx.orderId);
        args[1] = abi.encode("", ctx.originData);
        args[2] = _variable(VAR_RECIPIENT);
        bool exclusive = data.exclusiveFiller != address(0);
        bytes[] memory attributes = new bytes[](exclusive ? 5 : 4);
        attributes[0] = abi.encodeCall(IAttribute.NeedsStep, (STEP_OPEN));
        attributes[1] = abi.encodeCall(
            IAttribute.SpendsERC20,
            (
                InteroperableAddress.formatEvmV1(data.destinationChainId, data.outputToken),
                // Upper bound: the owed amount only decays after the exclusivity window.
                _constant(data.outputStartAmount),
                InteroperableAddress.formatEvmV1(data.destinationChainId, data.destinationSettler),
                InteroperableAddress.formatEvmV1(data.destinationChainId, data.recipient)
            )
        );
        attributes[2] = abi.encodeCall(IAttribute.TimingBounds, ("block.timestamp", "", _constant(ctx.fillDeadline)));
        attributes[3] = abi.encodeCall(
            IAttribute.RevertPolicy, ("abort", abi.encodePacked(DestinationSettler.AlreadyFilled.selector, ctx.orderId))
        );
        if (exclusive) {
            attributes[4] = abi.encodeCall(
                IAttribute.RevertPolicy,
                (
                    "abort",
                    abi.encodeWithSelector(
                        DestinationSettler.NotExclusiveFiller.selector, data.exclusiveFiller, data.exclusivityDeadline
                    )
                )
            );
        }
        return abi.encodeCall(
            IStep.Call,
            (
                InteroperableAddress.formatEvmV1(data.destinationChainId, data.destinationSettler),
                DestinationSettler.fillWithRepayment.selector,
                args,
                attributes
            )
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Settlement-mode steps
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Mode 1: report the fill through the mailbox; payment arrives when the message is delivered.
    function _mailboxSteps(Context memory ctx, ResolvedOrder memory resolved)
        internal
        view
        returns (Assumption[] memory assumptions)
    {
        uint256 chainId = ctx.data.destinationChainId;
        // Only the reporter half of the route is needed here.
        // slither-disable-start unused-return
        // forge-lint: disable-next-line(unused-return)
        (address reporter,) = MAILBOX_MODULE.routes(chainId);
        // slither-disable-end unused-return
        bytes[] memory args = new bytes[](2);
        args[0] = abi.encode("", ctx.orderId);
        args[1] = abi.encode("", ctx.originChainId);
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IAttribute.NeedsStep, (STEP_FILL));
        resolved.steps[STEP_SETTLE] = abi.encodeCall(
            IStep.Call,
            (InteroperableAddress.formatEvmV1(chainId, reporter), MailboxFillReporter.report.selector, args, attributes)
        );
        resolved.payments[0] = _payment(ctx, STEP_SETTLE, MAILBOX_DELAY);
        assumptions = new Assumption[](1);
        assumptions[0] = Assumption({
            name: "erc7683-intents/trusted-mailbox",
            data: abi.encode(_originAddress(address(MAILBOX_MODULE)), _originAddress(MAILBOX_MODULE.MAILBOX()))
        });
    }

    /// @dev Mode 2: bonded claim, then finalize once the challenge window has passed.
    function _optimisticSteps(Context memory ctx, ResolvedOrder memory resolved)
        internal
        view
        returns (Assumption[] memory assumptions)
    {
        uint256 varClaimTime = 3;
        uint256 varFinalizeAfter = 4;
        uint256 stepFinalize = STEP_SETTLE + 1;
        bytes memory module = _originAddress(address(OPTIMISTIC_MODULE));
        uint256 window = OPTIMISTIC_MODULE.CHALLENGE_WINDOW();

        resolved.variables[varClaimTime] =
            abi.encodeCall(IVariableRole.ExecutionOutput, ("block.timestamp", STEP_SETTLE));
        uint256[] memory deps = new uint256[](1);
        deps[0] = varClaimTime;
        // finalize requires block.timestamp > claimTime + window, i.e. >= claimTime + window + 1.
        resolved.variables[varFinalizeAfter] =
            abi.encodeCall(IVariableRole.Witness, (WITNESS_UINT256_ADD, abi.encode(window + 1), deps));

        bytes[] memory claimArgs = new bytes[](4);
        claimArgs[0] = abi.encode("", ctx.orderId);
        claimArgs[1] = _variable(VAR_RECIPIENT);
        claimArgs[2] = _variable(VAR_FILL_TIME);
        claimArgs[3] = abi.encode("", ctx.fillHash);
        bytes[] memory claimAttributes = new bytes[](2);
        claimAttributes[0] = abi.encodeCall(IAttribute.NeedsStep, (STEP_FILL));
        claimAttributes[1] = abi.encodeCall(
            IAttribute.SpendsERC20,
            (
                _originAddress(address(OPTIMISTIC_MODULE.BOND_TOKEN())),
                _constant(OPTIMISTIC_MODULE.BOND()),
                module,
                module
            )
        );
        resolved.steps[STEP_SETTLE] =
            abi.encodeCall(IStep.Call, (module, OptimisticSettlementModule.claim.selector, claimArgs, claimAttributes));

        // Claims are keyed by (orderId, filler, filledAt): finalize names the claim the solver posted in step 2.
        bytes[] memory finalizeArgs = new bytes[](3);
        finalizeArgs[0] = abi.encode("", ctx.orderId);
        finalizeArgs[1] = _variable(VAR_RECIPIENT);
        finalizeArgs[2] = _variable(VAR_FILL_TIME);
        bytes[] memory finalizeAttributes = new bytes[](2);
        finalizeAttributes[0] = abi.encodeCall(IAttribute.NeedsStep, (STEP_SETTLE));
        finalizeAttributes[1] = abi.encodeCall(
            IAttribute.TimingBounds, ("block.timestamp", abi.encodeCall(IFormula.Variable, (varFinalizeAfter)), "")
        );
        resolved.steps[stepFinalize] = abi.encodeCall(
            IStep.Call, (module, OptimisticSettlementModule.finalize.selector, finalizeArgs, finalizeAttributes)
        );

        resolved.payments[0] = _payment(ctx, stepFinalize, window);
        assumptions = new Assumption[](2);
        assumptions[0] = Assumption({name: "erc7683-intents/honest-watcher", data: abi.encode(module, window)});
        assumptions[1] = Assumption({
            name: "erc7683-intents/trusted-header-relayer",
            data: abi.encode(_originAddress(address(OPTIMISTIC_MODULE.HEADERS())))
        });
    }

    /// @dev Mode 3: prove the fill record against a relayed header.
    function _proofSteps(Context memory ctx, ResolvedOrder memory resolved)
        internal
        view
        returns (Assumption[] memory assumptions)
    {
        uint256 varProofBlock = 3;
        uint256 varAccountProof = 4;
        uint256 varSlotProof = 5;
        uint256 chainId = ctx.data.destinationChainId;
        bytes memory headers = _originAddress(address(PROOF_MODULE.HEADERS()));
        bytes memory settler = InteroperableAddress.formatEvmV1(chainId, PROOF_MODULE.destinationSettler(chainId));
        bytes memory proofData = abi.encode(settler, FillProofLib.fillerSlot(ctx.orderId));

        uint256[] memory afterFill = new uint256[](1);
        afterFill[0] = VAR_FILL_BLOCK;
        resolved.variables[varProofBlock] =
            abi.encodeCall(IVariableRole.Witness, (WITNESS_RELAYED_HEADER, abi.encode(headers, chainId), afterFill));
        uint256[] memory atProofBlock = new uint256[](1);
        atProofBlock[0] = varProofBlock;
        resolved.variables[varAccountProof] =
            abi.encodeCall(IVariableRole.Witness, (WITNESS_ACCOUNT_PROOF, proofData, atProofBlock));
        resolved.variables[varSlotProof] =
            abi.encodeCall(IVariableRole.Witness, (WITNESS_STORAGE_PROOF, proofData, atProofBlock));

        bytes[] memory args = new bytes[](5);
        args[0] = abi.encode("", ctx.orderId);
        args[1] = _variable(varProofBlock);
        args[2] = abi.encode("", ctx.fillHash);
        args[3] = _variable(varAccountProof);
        args[4] = _variable(varSlotProof);
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IAttribute.NeedsStep, (STEP_FILL));
        resolved.steps[STEP_SETTLE] = abi.encodeCall(
            IStep.Call,
            (_originAddress(address(PROOF_MODULE)), StorageProofSettlementModule.proveFill.selector, args, attributes)
        );

        resolved.payments[0] = _payment(ctx, STEP_SETTLE, PROOF_DELAY);
        assumptions = new Assumption[](1);
        assumptions[0] = Assumption({name: "erc7683-intents/trusted-header-relayer", data: abi.encode(headers)});
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Encoding helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The repayment of the escrowed input, made when `onStep` executes.
    function _payment(Context memory ctx, uint256 onStep, uint256 delay) internal view returns (bytes memory) {
        return abi.encodeCall(
            IPayment.ERC20,
            (
                _originAddress(ctx.data.inputToken),
                _originAddress(address(ORIGIN_SETTLER)),
                _constant(ctx.data.inputAmount),
                VAR_RECIPIENT,
                onStep,
                delay
            )
        );
    }

    /// @dev Appends the exclusivity assumption when the order has an exclusive filler.
    function _withExclusivity(IntentOrderData memory data, Assumption[] memory assumptions)
        internal
        pure
        returns (Assumption[] memory)
    {
        if (data.exclusiveFiller == address(0)) return assumptions;
        Assumption[] memory extended = new Assumption[](assumptions.length + 1);
        for (uint256 i = 0; i < assumptions.length; ++i) {
            extended[i] = assumptions[i];
        }
        extended[assumptions.length] = Assumption({
            name: "erc7683-intents/exclusive-filler", data: abi.encode(data.exclusiveFiller, data.exclusivityDeadline)
        });
        return extended;
    }

    /// @dev ERC-7930 address on the origin (current) chain.
    function _originAddress(address account) internal view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, account);
    }

    /// @dev IFormula.Constant calldata.
    function _constant(uint256 value) internal pure returns (bytes memory) {
        return abi.encodeCall(IFormula.Constant, (value));
    }

    /// @dev Argument referring to a variable: its ABI-encoded index (32 bytes). Constant arguments are framed ABI
    ///      encodings, `abi.encode("", value)` (at least 64 bytes), so the two forms cannot be confused.
    function _variable(uint256 index) internal pure returns (bytes memory) {
        return abi.encode(index);
    }
}
