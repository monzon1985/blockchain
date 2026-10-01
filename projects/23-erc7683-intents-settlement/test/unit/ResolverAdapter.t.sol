// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Bytes} from "@openzeppelin-contracts/utils/Bytes.sol";
import {InteroperableAddress} from "@openzeppelin-contracts/utils/draft-InteroperableAddress.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {OriginSettler} from "../../src/OriginSettler.sol";
import {ERC7683ResolverAdapter} from "../../src/adapters/ERC7683ResolverAdapter.sol";
import {GaslessCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {IAttribute, IFormula, IPayment, IResolver, IStep, IVariableRole} from "../../src/erc7683/IERC7683Resolver.sol";
import {IEscrowSettler, OrderStatus} from "../../src/interfaces/IEscrowSettler.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {MailboxFillReporter} from "../../src/settlement/mailbox/MailboxFillReporter.sol";
import {OptimisticSettlementModule} from "../../src/settlement/optimistic/OptimisticSettlementModule.sol";
import {StorageProofSettlementModule} from "../../src/settlement/proof/StorageProofSettlementModule.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";
import {MockERC20} from "../utils/TestTokens.sol";

/// @notice The resolver adapter, checked two ways: the shape of what it returns, and by a small generic
/// interpreter that executes the returned steps on both chains knowing nothing about this protocol beyond the
/// resolver-centric draft (plus this adapter's documented witness kinds). If the mapping were unfaithful, the
/// interpreter would not end up repaid.
contract ResolverAdapterTest is IntentTestBase {
    using Bytes for bytes;

    // ------------------------------------------------------------------------------------------------------------
    // Shape
    // ------------------------------------------------------------------------------------------------------------

    function _payload(OrderParams memory p, uint256 nonce)
        internal
        returns (GaslessCrossChainOrder memory order, bytes memory payload, bytes32 orderId, bytes memory originData)
    {
        vm.chainId(ORIGIN);
        order = _gaslessOrder(p, nonce);
        bytes memory signature = _sign(order, userKey);
        payload = abi.encode(order, signature);
        (orderId, originData) = _ids(_gaslessIntent(order));
    }

    function test_resolve_mailboxShape() public {
        (GaslessCrossChainOrder memory order, bytes memory payload, bytes32 orderId, bytes memory originData) =
            _payload(_params(address(mailboxModule)), 1);
        IResolver.ResolvedOrder memory r = adapter.resolve(payload);
        assertEq(r.steps.length, 3);
        assertEq(r.variables.length, 3);
        assertEq(r.payments.length, 1);
        assertEq(r.assumptions.length, 1);
        assertEq(r.assumptions[0].name, "erc7683-intents/trusted-mailbox");

        (bytes memory target, bytes4 selector, bytes[] memory args,) = _decodeCall(r.steps[0]);
        assertEq(target, InteroperableAddress.formatEvmV1(ORIGIN, address(origin)));
        assertEq(selector, OriginSettler.openFor.selector);
        assertEq(args[0], abi.encode("", order));

        (target, selector, args,) = _decodeCall(r.steps[1]);
        assertEq(target, InteroperableAddress.formatEvmV1(DEST, address(dest)));
        assertEq(selector, DestinationSettler.fillWithRepayment.selector);
        assertEq(args[0], abi.encode("", orderId));
        assertEq(args[1], abi.encode("", originData));
        assertEq(args[2], abi.encode(uint256(0)), "repayment is the PaymentRecipient variable");

        (target, selector,,) = _decodeCall(r.steps[2]);
        assertEq(target, InteroperableAddress.formatEvmV1(DEST, address(reporter)));
        assertEq(selector, MailboxFillReporter.report.selector);

        assertEq(r.variables[0], abi.encodeCall(IVariableRole.PaymentRecipient, ()));
        assertEq(
            r.payments[0],
            abi.encodeCall(
                IPayment.ERC20,
                (
                    InteroperableAddress.formatEvmV1(ORIGIN, address(inputToken)),
                    InteroperableAddress.formatEvmV1(ORIGIN, address(origin)),
                    abi.encodeCall(IFormula.Constant, (1000e18)),
                    0,
                    2,
                    5 minutes
                )
            )
        );
    }

    function test_resolve_optimisticShape() public {
        (GaslessCrossChainOrder memory order,, bytes memory payload,) = _payloadTuple(_params(address(optimistic)), 1);
        (, bytes memory originData) = _ids(_gaslessIntent(order));
        IResolver.ResolvedOrder memory r = adapter.resolve(payload);
        assertEq(r.steps.length, 4);
        assertEq(r.variables.length, 5);
        uint256[] memory deps = new uint256[](1);
        deps[0] = 3;
        assertEq(
            r.variables[4],
            abi.encodeCall(
                IVariableRole.Witness, (adapter.WITNESS_UINT256_ADD(), abi.encode(CHALLENGE_WINDOW + 1), deps)
            )
        );
        (, bytes4 selector, bytes[] memory args,) = _decodeCall(r.steps[2]);
        assertEq(selector, OptimisticSettlementModule.claim.selector);
        assertEq(args[3], abi.encode("", keccak256(originData)));
        (, selector, args,) = _decodeCall(r.steps[3]);
        assertEq(selector, OptimisticSettlementModule.finalize.selector);
        assertEq(args.length, 3, "finalize names the claim: order, filler, fill time");
        assertEq(args[1], abi.encode(uint256(0)), "filler is the PaymentRecipient variable");
        assertEq(args[2], abi.encode(uint256(1)), "fill time is the fill step's block.timestamp");
        assertEq(r.assumptions.length, 2);
        assertEq(r.assumptions[0].name, "erc7683-intents/honest-watcher");
        assertEq(r.assumptions[1].name, "erc7683-intents/trusted-header-relayer");
    }

    function test_resolve_proofShape() public {
        (,, bytes memory payload, bytes32 orderId) = _payloadTuple(_params(address(proofModule)), 1);
        IResolver.ResolvedOrder memory r = adapter.resolve(payload);
        assertEq(r.steps.length, 3);
        assertEq(r.variables.length, 6);
        uint256[] memory deps = new uint256[](1);
        deps[0] = 3;
        bytes memory proofData =
            abi.encode(InteroperableAddress.formatEvmV1(DEST, address(dest)), FillProofLib.fillerSlot(orderId));
        assertEq(
            r.variables[4], abi.encodeCall(IVariableRole.Witness, (adapter.WITNESS_ACCOUNT_PROOF(), proofData, deps))
        );
        (, bytes4 selector,,) = _decodeCall(r.steps[2]);
        assertEq(selector, StorageProofSettlementModule.proveFill.selector);
        assertEq(r.assumptions.length, 1);
    }

    function test_resolve_exclusivityBecomesAssumptionAndRevertPolicy() public {
        OrderParams memory p = _params(address(mailboxModule));
        p.exclusiveFiller = solver;
        (,, bytes memory payload,) = _payloadTuple(p, 1);
        IResolver.ResolvedOrder memory r = adapter.resolve(payload);
        assertEq(r.assumptions.length, 2);
        assertEq(r.assumptions[1].name, "erc7683-intents/exclusive-filler");
        assertEq(r.assumptions[1].data, abi.encode(solver, p.exclusivityDeadline));
        (,,, bytes[] memory attributes) = _decodeCall(r.steps[1]);
        assertEq(attributes.length, 5);
        assertEq(
            attributes[4],
            abi.encodeCall(
                IAttribute.RevertPolicy,
                (
                    "abort",
                    abi.encodeWithSelector(
                        DestinationSettler.NotExclusiveFiller.selector, solver, p.exclusivityDeadline
                    )
                )
            )
        );
    }

    function test_resolve_revertsOnInvalidOrder() public {
        OrderParams memory p = _params(address(mailboxModule));
        p.outputEnd = 0;
        (,, bytes memory payload,) = _payloadTuple(p, 1);
        vm.expectRevert(abi.encodeWithSelector(OriginSettler.InvalidAmounts.selector, p.inputAmount, p.outputStart, 0));
        adapter.resolve(payload);
    }

    function test_resolve_revertsOnModuleUnknownToAdapter() public {
        vm.chainId(ORIGIN);
        vm.startPrank(admin);
        StorageProofSettlementModule extra =
            new StorageProofSettlementModule(IEscrowSettler(address(origin)), headers, address(originManager));
        extra.setDestinationSettler(DEST, address(dest));
        origin.setSettlementModule(address(extra), true);
        vm.stopPrank();
        (,, bytes memory payload,) = _payloadTuple(_params(address(extra)), 1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC7683ResolverAdapter.UnsupportedSettlementModule.selector, address(extra))
        );
        adapter.resolve(payload);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Execution by a generic interpreter
    // ------------------------------------------------------------------------------------------------------------

    function test_interpreter_executesMailboxOrder() public {
        _executeAndCheck(_params(address(mailboxModule)));
    }

    function test_interpreter_executesOptimisticOrder() public {
        _executeAndCheck(_params(address(optimistic)));
    }

    function test_interpreter_executesProofOrder() public {
        _executeAndCheck(_params(address(proofModule)));
    }

    function test_interpreter_ignoresOpenAlreadyDoneByAnotherSolver() public {
        OrderParams memory p = _params(address(mailboxModule));
        _openGasless(p, 1); // a rival opened it through the ERC-7683 v1 path already
        (,, bytes memory payload, bytes32 orderId) = _payloadTuple(p, 1);
        vm.chainId(ORIGIN);
        IResolver.ResolvedOrder memory r = adapter.resolve(payload);
        _currentOrder = orderId;
        vm.recordLogs();
        bool completed = _execute(r);
        assertTrue(completed);
        _deliverMailbox();
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount);
    }

    function test_interpreter_abortsWhenAnotherSolverFilledFirst() public {
        OrderParams memory p = _params(address(mailboxModule));
        (bytes32 orderId, bytes memory originData) = _openGasless(p, 1);
        _fill(orderId, originData, rival, rival);
        (,, bytes memory payload,) = _payloadTuple(p, 1);
        vm.chainId(ORIGIN);
        IResolver.ResolvedOrder memory r = adapter.resolve(payload);
        _currentOrder = orderId;
        assertFalse(_execute(r), "AlreadyFilled must abort the order");
        assertEq(inputToken.balanceOf(solverRepayment), 0);
    }

    function _executeAndCheck(OrderParams memory p) internal {
        (,, bytes memory payload, bytes32 orderId) = _payloadTuple(p, 1);
        inputToken.mint(user, p.inputAmount);
        vm.prank(user);
        inputToken.approve(PERMIT2_ADDRESS, type(uint256).max);
        vm.chainId(ORIGIN);
        IResolver.ResolvedOrder memory r = adapter.resolve(payload);
        _currentOrder = orderId;
        trackedOrders.push(orderId);
        vm.recordLogs();
        assertTrue(_execute(r), "order aborted");
        if (p.module == address(mailboxModule)) _deliverMailbox();
        assertEq(inputToken.balanceOf(solverRepayment), p.inputAmount, "solver repaid");
        assertGe(outputToken.balanceOf(recipient), p.outputEnd, "user filled");
        vm.chainId(ORIGIN);
        assertEq(uint8(origin.escrowOf(orderId).status), uint8(OrderStatus.Repaid));
    }

    /// @dev The messaging layer, not the solver, delivers mode-1 reports ("payment arrives after the delay").
    function _deliverMailbox() internal {
        bytes memory message = _lastDispatch();
        vm.chainId(ORIGIN);
        vm.prank(mailboxRelayer);
        originMailbox.process(message);
    }

    // --- interpreter state ---
    bytes32 internal _currentOrder;
    bytes[] internal _values;
    bool[] internal _known;
    DestProof internal _proof;
    bool internal _proofReady;

    /// @dev Executes all steps in order. Returns false if a RevertPolicy aborted the order.
    function _execute(IResolver.ResolvedOrder memory r) internal returns (bool) {
        delete _values;
        delete _known;
        for (uint256 i = 0; i < r.variables.length; ++i) {
            _values.push("");
            _known.push(false);
        }
        for (uint256 s = 0; s < r.steps.length; ++s) {
            (bytes memory target, bytes4 selector, bytes[] memory args, bytes[] memory attributes) =
                _decodeCall(r.steps[s]);
            (uint256 chainId, address to) = InteroperableAddress.parseEvmV1(target);
            vm.chainId(chainId);
            _applyPreconditions(r, attributes);
            bytes memory callData = _assemble(r, selector, args);
            vm.prank(solver);
            (bool ok, bytes memory ret) = to.call(callData);
            if (!ok) {
                string memory policy = _policyFor(attributes, ret);
                if (keccak256(bytes(policy)) == keccak256("abort")) return false;
                require(keccak256(bytes(policy)) == keccak256("ignore"), "unexpected revert");
            }
            _recordOutputs(r, s);
        }
        return true;
    }

    function _applyPreconditions(IResolver.ResolvedOrder memory r, bytes[] memory attributes) internal {
        for (uint256 a = 0; a < attributes.length; ++a) {
            bytes4 kind = bytes4(attributes[a]);
            bytes memory body = attributes[a].slice(4);
            if (kind == IAttribute.SpendsERC20.selector) {
                (bytes memory token, bytes memory formula, bytes memory spenderAddress,) =
                    abi.decode(body, (bytes, bytes, bytes, bytes));
                (, address tokenAddress) = InteroperableAddress.parseEvmV1(token);
                (, address spender) = InteroperableAddress.parseEvmV1(spenderAddress);
                uint256 amount = _formula(r, formula);
                MockERC20(tokenAddress).mint(solver, amount);
                vm.prank(solver);
                MockERC20(tokenAddress).approve(spender, amount);
            } else if (kind == IAttribute.TimingBounds.selector) {
                (string memory field, bytes memory lower, bytes memory upper) = abi.decode(body, (string, bytes, bytes));
                assertEq(field, "block.timestamp");
                if (lower.length != 0) {
                    uint256 bound = _formula(r, lower);
                    if (block.timestamp < bound) vm.warp(bound);
                }
                if (upper.length != 0) assertLe(block.timestamp, _formula(r, upper), "upper timing bound");
            }
        }
    }

    function _policyFor(bytes[] memory attributes, bytes memory revertData) internal pure returns (string memory) {
        for (uint256 a = 0; a < attributes.length; ++a) {
            if (bytes4(attributes[a]) != IAttribute.RevertPolicy.selector) continue;
            (string memory policy, bytes memory prefix) = abi.decode(attributes[a].slice(4), (string, bytes));
            if (
                revertData.length >= prefix.length && keccak256(revertData.slice(0, prefix.length)) == keccak256(prefix)
            ) {
                return policy;
            }
        }
        return "";
    }

    /// @dev Builds call data from framed constants and variables (resolver draft, "Call Data Encoding").
    function _assemble(IResolver.ResolvedOrder memory r, bytes4 selector, bytes[] memory args)
        internal
        returns (bytes memory)
    {
        bytes[] memory framed = new bytes[](args.length);
        uint256 headSize = 0;
        for (uint256 i = 0; i < args.length; ++i) {
            framed[i] = args[i].length == 32 ? _variable(r, abi.decode(args[i], (uint256))) : args[i];
            headSize += _isDynamic(framed[i]) ? 32 : framed[i].length - 64;
        }
        bytes memory head;
        bytes memory tail;
        for (uint256 i = 0; i < args.length; ++i) {
            if (_isDynamic(framed[i])) {
                head = bytes.concat(head, abi.encode(headSize + tail.length));
                tail = bytes.concat(tail, framed[i].slice(96));
            } else {
                head = bytes.concat(head, framed[i].slice(32, framed[i].length - 32));
            }
        }
        return bytes.concat(selector, head, tail);
    }

    function _isDynamic(bytes memory framed) internal pure returns (bool) {
        return framed.length >= 96 && bytes32(framed.slice(0, 32)) == bytes32(uint256(0x40))
            && bytes32(framed.slice(32, 64)) == bytes32(uint256(0x60)) && bytes32(framed.slice(64, 96)) == bytes32(0);
    }

    function _formula(IResolver.ResolvedOrder memory r, bytes memory formula) internal returns (uint256) {
        bytes4 kind = bytes4(formula);
        uint256 arg = abi.decode(formula.slice(4), (uint256));
        if (kind == IFormula.Constant.selector) return arg;
        return abi.decode(_variable(r, arg).slice(32, 64), (uint256));
    }

    /// @dev Framed value of a variable, evaluating it on first use.
    function _variable(IResolver.ResolvedOrder memory r, uint256 index) internal returns (bytes memory) {
        if (_known[index]) return _values[index];
        bytes memory role = r.variables[index];
        bytes4 kind = bytes4(role);
        bytes memory value;
        if (kind == IVariableRole.PaymentRecipient.selector) {
            value = abi.encode("", solverRepayment);
        } else if (kind == IVariableRole.Witness.selector) {
            (string memory witness, bytes memory data, uint256[] memory deps) =
                abi.decode(role.slice(4), (string, bytes, uint256[]));
            value = _witness(r, witness, data, deps);
        } else {
            revert("variable not yet available");
        }
        _values[index] = value;
        _known[index] = true;
        return value;
    }

    function _witness(IResolver.ResolvedOrder memory r, string memory kind, bytes memory data, uint256[] memory deps)
        internal
        returns (bytes memory)
    {
        bytes32 k = keccak256(bytes(kind));
        if (k == keccak256(bytes(adapter.WITNESS_UINT256_ADD()))) {
            uint256 base = abi.decode(_variable(r, deps[0]).slice(32, 64), (uint256));
            return abi.encode("", base + abi.decode(data, (uint256)));
        }
        if (!_proofReady) {
            // Stand-in for "wait until a header at or after the fill block is relayed, then eth_getProof it".
            _proof = _relayDestState(_currentOrder);
            _proofReady = true;
        }
        if (k == keccak256(bytes(adapter.WITNESS_RELAYED_HEADER()))) return abi.encode("", _proof.blockNumber);
        if (k == keccak256(bytes(adapter.WITNESS_ACCOUNT_PROOF()))) return abi.encode("", _proof.accountProof);
        if (k == keccak256(bytes(adapter.WITNESS_STORAGE_PROOF()))) return abi.encode("", _proof.slotProof);
        revert("unknown witness kind");
    }

    /// @dev Captures ExecutionOutput variables of step `s`.
    function _recordOutputs(IResolver.ResolvedOrder memory r, uint256 s) internal {
        for (uint256 i = 0; i < r.variables.length; ++i) {
            if (bytes4(r.variables[i]) != IVariableRole.ExecutionOutput.selector) continue;
            (string memory field, uint256 stepIdx) = abi.decode(r.variables[i].slice(4), (string, uint256));
            if (stepIdx != s) continue;
            uint256 observed = keccak256(bytes(field)) == keccak256("block.number") ? block.number : block.timestamp;
            _values[i] = abi.encode("", observed);
            _known[i] = true;
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------------------------

    function _payloadTuple(OrderParams memory p, uint256 nonce)
        internal
        returns (GaslessCrossChainOrder memory order, bytes memory signature, bytes memory payload, bytes32 orderId)
    {
        vm.chainId(ORIGIN);
        order = _gaslessOrder(p, nonce);
        signature = _sign(order, userKey);
        payload = abi.encode(order, signature);
        (orderId,) = _ids(_gaslessIntent(order));
    }

    function _decodeCall(bytes memory step)
        internal
        pure
        returns (bytes memory target, bytes4 selector, bytes[] memory args, bytes[] memory attributes)
    {
        require(bytes4(step) == IStep.Call.selector, "not a Call step");
        return abi.decode(step.slice(4), (bytes, bytes4, bytes[], bytes[]));
    }
}
