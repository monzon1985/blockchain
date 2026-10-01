// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// ERC-7683 "Cross Chain Intents", first (settler-centric) draft, transcribed from
// ethereum/ERCs@563555549226f2222de2ec3b405945c8f5d6c2b2 (ERCS/erc-7683.md, 2025-01-08).
// The ERC was later redesigned around resolvers (ethereum/ERCs@96d110fb, 2026-05-13); see
// `IERC7683Resolver.sol` and `docs/spec-drift.md` for how this project maps one onto the other.

/// @notice Standard order struct signed by users, disseminated to fillers and submitted to the origin settler.
/// @param originSettler Contract that settles the order on the origin chain.
/// @param user Account whose input tokens are taken and escrowed.
/// @param nonce Replay protection. Implementations built on Permit2 use it as the Permit2 nonce.
/// @param originChainId Chain id of the origin chain.
/// @param openDeadline Timestamp by which the order must be opened (the Permit2 deadline).
/// @param fillDeadline Timestamp by which the order must be filled on the destination chain.
/// @param orderDataType EIP-712 typehash of the implementation-specific `orderData` sub-type.
/// @param orderData Implementation-specific order data (tokens, amounts, destination, settlement parameters).
struct GaslessCrossChainOrder {
    address originSettler;
    address user;
    uint256 nonce;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    bytes32 orderDataType;
    bytes orderData;
}

/// @notice Standard order struct for orders opened on-chain by the user themselves.
/// @param fillDeadline Timestamp by which the order must be filled on the destination chain.
/// @param orderDataType EIP-712 typehash of the implementation-specific `orderData` sub-type.
/// @param orderData Implementation-specific order data.
struct OnchainCrossChainOrder {
    uint32 fillDeadline;
    bytes32 orderDataType;
    bytes orderData;
}

/// @notice Implementation-generic representation of an order, intended for filler consumption.
/// @param user Account that initiated the transfer.
/// @param originChainId Chain id of the origin chain.
/// @param openDeadline Timestamp by which the order must be opened.
/// @param fillDeadline Timestamp by which the order must be filled on the destination chain(s).
/// @param orderId Unique identifier of the order within this settlement system.
/// @param maxSpent Cap on what the filler sends (the destination amount can decay below it).
/// @param minReceived Floor on what the filler receives on settlement. Recipient 0 means "the filler, unknown yet".
/// @param fillInstructions One entry per fill leg, carrying the data the destination settler needs.
struct ResolvedCrossChainOrder {
    address user;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    bytes32 orderId;
    Output[] maxSpent;
    Output[] minReceived;
    FillInstruction[] fillInstructions;
}

/// @notice Tokens that must be sent or received for a valid order fulfilment.
/// @param token ERC-20 token address (left-padded to bytes32 for non-EVM compatibility). 0 is the native token.
/// @param amount Token amount.
/// @param recipient Receiver of the tokens (left-padded to bytes32).
/// @param chainId Chain on which the output is paid.
struct Output {
    bytes32 token;
    uint256 amount;
    bytes32 recipient;
    uint256 chainId;
}

/// @notice Parameters of a single fill leg.
/// @param destinationChainId Chain on which the leg is filled.
/// @param destinationSettler Settler contract on that chain (left-padded to bytes32).
/// @param originData Origin-generated data the destination settler needs to process the fill.
struct FillInstruction {
    uint256 destinationChainId;
    bytes32 destinationSettler;
    bytes originData;
}

/// @title IOriginSettler
/// @notice Standard ERC-7683 interface for settlement contracts on the origin chain.
interface IOriginSettler {
    /// @notice Signals that an order has been opened.
    /// @param orderId Unique order identifier within this settlement system.
    /// @param resolvedOrder Resolved order that `resolve`/`resolveFor` would have returned.
    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    /// @notice Opens a gasless cross-chain order on behalf of a user. Called by the filler.
    /// @param order The GaslessCrossChainOrder definition.
    /// @param signature The user's signature over the order.
    /// @param originFillerData Filler-defined data required by the settler.
    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external;

    /// @notice Opens a cross-chain order. Called by the user.
    /// @param order The OnchainCrossChainOrder definition.
    function open(OnchainCrossChainOrder calldata order) external;

    /// @notice Resolves a GaslessCrossChainOrder into a generic ResolvedCrossChainOrder.
    /// @param order The GaslessCrossChainOrder definition.
    /// @param originFillerData Filler-defined data required by the settler.
    /// @return The hydrated order, including inputs and outputs.
    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        returns (ResolvedCrossChainOrder memory);

    /// @notice Resolves an OnchainCrossChainOrder into a generic ResolvedCrossChainOrder.
    /// @param order The OnchainCrossChainOrder definition.
    /// @return The hydrated order, including inputs and outputs.
    function resolve(OnchainCrossChainOrder calldata order) external view returns (ResolvedCrossChainOrder memory);
}

/// @title IDestinationSettler
/// @notice Standard ERC-7683 interface for settlement contracts on the destination chain.
interface IDestinationSettler {
    /// @notice Fills a single leg of an order on the destination chain.
    /// @param orderId Unique order identifier.
    /// @param originData Data emitted on the origin chain to parameterize the fill.
    /// @param fillerData Data provided by the filler to express their preferences.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external;
}
