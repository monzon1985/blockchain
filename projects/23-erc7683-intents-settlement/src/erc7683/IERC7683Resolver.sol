// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// ERC-7683 "Cross Chain Intents", resolver-centric redesign, transcribed from
// ethereum/ERCs@96d110fbbe7042b061064833edaf8fa2cf5db195 (ERCS/erc-7683.md, 2026-05-13, status Draft).
// The step/variable/payment/attribute/formula "interfaces" are never called: they only give each
// variant a selector and an ABI, so that a resolved order is a list of self-describing calldata blobs.
// Function names are PascalCase because the ERC defines them that way.

/// @title IResolver
/// @notice Translates a protocol-specific payload into solver instructions.
interface IResolver {
    /// @notice An order as a list of steps, variables and payments, plus named assumptions.
    /// @param steps Array of `IStep` ABI calldata.
    /// @param variables Array of `IVariableRole` ABI calldata.
    /// @param payments Array of `IPayment` ABI calldata.
    /// @param assumptions Conditions the resolver cannot check and the solver must validate.
    struct ResolvedOrder {
        bytes[] steps;
        bytes[] variables;
        bytes[] payments;
        Assumption[] assumptions;
    }

    /// @notice A named, parameterized assumption.
    /// @param name Identifier of the assumption.
    /// @param data ABI-encoded parameters.
    struct Assumption {
        string name;
        bytes data;
    }

    /// @notice Decodes and validates `payload` into solver instructions.
    /// @param payload Protocol-specific encoding of the order.
    /// @return The resolved order.
    function resolve(bytes calldata payload) external view returns (ResolvedOrder memory);
}

/// @notice Step variants.
interface IStep {
    /// @notice Call `target` (ERC-7930 address) with `selector` and `arguments`.
    /// @param target ERC-7930 interoperable address of the callee.
    /// @param selector Function selector.
    /// @param arguments Each element is an ABI-encoded variable index, or a framed ABI encoding of a value.
    /// @param attributes Each element is `IAttribute` ABI calldata.
    // forge-lint: disable-next-line(mixed-case-function)
    function Call(bytes calldata target, bytes4 selector, bytes[] calldata arguments, bytes[] calldata attributes)
        external;
}

/// @notice Variable roles.
interface IVariableRole {
    /// @notice Account where the solver prefers to receive payment.
    // forge-lint: disable-next-line(mixed-case-function)
    function PaymentRecipient() external;
    /// @notice Chain where the solver prefers to receive payment.
    // forge-lint: disable-next-line(mixed-case-function)
    function PaymentChain() external;
    /// @notice Account used as the caller of step `stepIdx`.
    /// @param stepIdx Index of the step.
    // forge-lint: disable-next-line(mixed-case-function)
    function StepCaller(uint256 stepIdx) external;
    /// @notice Value observed when executing step `stepIdx` (e.g. "block.number").
    /// @param field Execution field identifier.
    /// @param stepIdx Index of the step.
    // forge-lint: disable-next-line(mixed-case-function)
    function ExecutionOutput(string calldata field, uint256 stepIdx) external;
    /// @notice Value produced by an off-chain procedure identified by `kind`.
    /// @param kind Identifier of the witness procedure.
    /// @param data Procedure input.
    /// @param variables Indices of variables the procedure depends on.
    // forge-lint: disable-next-line(mixed-case-function)
    function Witness(string calldata kind, bytes calldata data, uint256[] calldata variables) external;
    /// @notice Result of an `eth_call`.
    /// @param target ERC-7930 address of the callee.
    /// @param selector Function selector.
    /// @param arguments Each element is a variable index or a framed ABI encoding.
    /// @param blockNumber Block to query; `type(uint256).max` means none (latest).
    // forge-lint: disable-next-line(mixed-case-function)
    function Query(bytes calldata target, bytes4 selector, bytes[] calldata arguments, uint256 blockNumber) external;
    /// @notice Result of an `eth_getLogs`.
    /// @param emitter ERC-7930 address of the emitter.
    /// @param topicMatch Bitmask of the topics to filter by.
    /// @param topic0 Topic 0 filter.
    /// @param topic1 Topic 1 filter.
    /// @param topic2 Topic 2 filter.
    /// @param topic3 Topic 3 filter.
    /// @param blockNumber Block to query; `type(uint256).max` means none (latest).
    // forge-lint: disable-next-line(mixed-case-function)
    function QueryEvents(
        bytes calldata emitter,
        bytes1 topicMatch,
        bytes32 topic0,
        bytes32 topic1,
        bytes32 topic2,
        bytes32 topic3,
        uint256 blockNumber
    ) external;
}

/// @notice Payment variants.
interface IPayment {
    /// @notice ERC-20 payment made when step `onStepIdx` executes.
    /// @param token ERC-7930 address of the token.
    /// @param sender ERC-7930 address of the payer.
    /// @param amountFormula `IFormula` ABI calldata.
    /// @param recipientVarIdx Index of a `PaymentRecipient` variable.
    /// @param onStepIdx Index of the step that triggers the payment.
    /// @param estimatedDelaySeconds Expected delay between the step and the payment.
    // forge-lint: disable-next-line(mixed-case-function)
    function ERC20(
        bytes calldata token,
        bytes calldata sender,
        bytes calldata amountFormula,
        uint256 recipientVarIdx,
        uint256 onStepIdx,
        uint256 estimatedDelaySeconds
    ) external;
}

/// @notice Step attributes.
interface IAttribute {
    /// @notice The call may pull up to `amountFormula` of `token` via `spender`.
    /// @param token ERC-7930 address of the token.
    /// @param amountFormula `IFormula` ABI calldata.
    /// @param spender ERC-7930 address of the spender.
    /// @param recipient ERC-7930 address of the receiver.
    // forge-lint: disable-next-line(mixed-case-function)
    function SpendsERC20(
        bytes calldata token,
        bytes calldata amountFormula,
        bytes calldata spender,
        bytes calldata recipient
    ) external;
    /// @notice The call may consume up to `amountFormula` gas.
    /// @param amountFormula `IFormula` ABI calldata.
    // forge-lint: disable-next-line(mixed-case-function)
    function SpendsGas(bytes calldata amountFormula) external;
    /// @notice Inclusion bounds on "block.number" or "block.timestamp".
    /// @param field Timing field.
    /// @param lowerBound Empty, or `IFormula` ABI calldata.
    /// @param upperBound Empty, or `IFormula` ABI calldata.
    // forge-lint: disable-next-line(mixed-case-function)
    function TimingBounds(string calldata field, bytes calldata lowerBound, bytes calldata upperBound) external;
    /// @notice Hard dependency on step `stepIdx`.
    /// @param stepIdx Index of the step.
    // forge-lint: disable-next-line(mixed-case-function)
    function NeedsStep(uint256 stepIdx) external;
    /// @notice Hard dependency on variable `varIdx`.
    /// @param varIdx Index of the variable.
    // forge-lint: disable-next-line(mixed-case-function)
    function NeedsVariable(uint256 varIdx) external;
    /// @notice The call may revert with data starting with `expectedReason`; `policy` is "ignore" or "abort".
    /// @param policy Revert policy identifier.
    /// @param expectedReason Revert data prefix.
    // forge-lint: disable-next-line(mixed-case-function)
    function RevertPolicy(string calldata policy, bytes calldata expectedReason) external;
}

/// @notice Amount formulas.
interface IFormula {
    /// @notice A constant.
    /// @param val The value.
    // forge-lint: disable-next-line(mixed-case-function)
    function Constant(uint256 val) external;
    /// @notice The value of a variable.
    /// @param varIdx Index of the variable.
    // forge-lint: disable-next-line(mixed-case-function)
    function Variable(uint256 varIdx) external;
}
