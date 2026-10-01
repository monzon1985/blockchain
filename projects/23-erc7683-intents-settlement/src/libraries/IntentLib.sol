// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {GaslessCrossChainOrder} from "../erc7683/IERC7683.sol";

/// @notice The ERC-7683 `orderData` sub-type of this protocol: one ERC-20 in on the origin, one ERC-20 out on the
/// destination, priced by an exclusivity window followed by a linear Dutch decay.
/// @param inputToken ERC-20 escrowed on the origin chain.
/// @param inputAmount Amount escrowed; this is exactly what the filler is repaid.
/// @param outputToken ERC-20 delivered on the destination chain.
/// @param outputStartAmount Amount owed until `exclusivityDeadline` (the top of the auction).
/// @param outputEndAmount Amount owed at `fillDeadline` (the user's floor).
/// @param recipient Receiver of the output on the destination chain.
/// @param destinationChainId Chain id of the destination chain.
/// @param destinationSettler DestinationSettler that must record the fill.
/// @param exclusiveFiller Only filler allowed until `exclusivityDeadline`; address(0) disables exclusivity.
/// @param exclusivityDeadline End of the exclusivity window and start of the Dutch decay.
/// @param settlementModule Origin-chain module that may release the escrow to the filler.
struct IntentOrderData {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputStartAmount;
    uint256 outputEndAmount;
    address recipient;
    uint256 destinationChainId;
    address destinationSettler;
    address exclusiveFiller;
    uint32 exclusivityDeadline;
    address settlementModule;
}

/// @notice Normalized order. `abi.encode(Intent)` is the ERC-7683 `originData`, and its hash is the `fillHash`
/// that `orderId` commits to. Gasless and on-chain orders normalize to the same shape.
/// @param originSettler OriginSettler holding the escrow.
/// @param user Owner of the escrowed input.
/// @param nonce Permit2 nonce (gasless) or per-user sequential nonce (on-chain).
/// @param originChainId Chain id of the origin chain.
/// @param openDeadline Permit2 deadline (gasless) or type(uint32).max (on-chain).
/// @param fillDeadline Last timestamp at which the destination accepts a fill.
/// @param data The decoded order data.
struct Intent {
    address originSettler;
    address user;
    uint256 nonce;
    uint256 originChainId;
    uint32 openDeadline;
    uint32 fillDeadline;
    IntentOrderData data;
}

/// @title IntentLib
/// @notice EIP-712 types, Permit2 witness string and identifier derivation shared by both chains.
/// @dev Identifier scheme:
///      originData = abi.encode(Intent)
///      fillHash   = keccak256(originData)
///      orderId    = keccak256(abi.encode(originChainId, originSettler, fillHash))
///      Because the destination recomputes `orderId` from `originData`, a fill can only ever be recorded under the
///      id of the exact order it paid for, and the origin can check any claimed `fillHash` against `orderId`.
library IntentLib {
    /// @notice EIP-712 type string of IntentOrderData.
    string internal constant INTENT_ORDER_DATA_TYPE =
        "IntentOrderData(address inputToken,uint256 inputAmount,address outputToken,uint256 outputStartAmount,uint256 outputEndAmount,address recipient,uint256 destinationChainId,address destinationSettler,address exclusiveFiller,uint32 exclusivityDeadline,address settlementModule)";

    /// @notice EIP-712 typehash of IntentOrderData; also the ERC-7683 `orderDataType` this protocol accepts.
    bytes32 internal constant INTENT_ORDER_DATA_TYPEHASH = keccak256(bytes(INTENT_ORDER_DATA_TYPE));

    /// @notice EIP-712 type string of the witness: the full GaslessCrossChainOrder with `orderData` decoded, as the
    /// ERC recommends, so wallets can display every field the user signs.
    string internal constant GASLESS_ORDER_TYPE =
        "GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint32 openDeadline,uint32 fillDeadline,bytes32 orderDataType,IntentOrderData orderData)IntentOrderData(address inputToken,uint256 inputAmount,address outputToken,uint256 outputStartAmount,uint256 outputEndAmount,address recipient,uint256 destinationChainId,address destinationSettler,address exclusiveFiller,uint32 exclusivityDeadline,address settlementModule)";

    /// @notice EIP-712 typehash of the witness struct.
    bytes32 internal constant GASLESS_ORDER_TYPEHASH = keccak256(bytes(GASLESS_ORDER_TYPE));

    /// @notice Witness type string handed to Permit2: the witness member declaration followed by every referenced
    /// struct in alphabetical order (GaslessCrossChainOrder, IntentOrderData, TokenPermissions).
    string internal constant PERMIT2_WITNESS_TYPE_STRING =
        "GaslessCrossChainOrder witness)GaslessCrossChainOrder(address originSettler,address user,uint256 nonce,uint256 originChainId,uint32 openDeadline,uint32 fillDeadline,bytes32 orderDataType,IntentOrderData orderData)IntentOrderData(address inputToken,uint256 inputAmount,address outputToken,uint256 outputStartAmount,uint256 outputEndAmount,address recipient,uint256 destinationChainId,address destinationSettler,address exclusiveFiller,uint32 exclusivityDeadline,address settlementModule)TokenPermissions(address token,uint256 amount)";

    /// @notice EIP-712 struct hash of `data`.
    /// @dev Every member is a static type, so `abi.encode(typehash, data)` is exactly `typeHash || encodeData`.
    /// @param data The order data.
    /// @return The struct hash.
    function hashOrderData(IntentOrderData memory data) internal pure returns (bytes32) {
        return keccak256(abi.encode(INTENT_ORDER_DATA_TYPEHASH, data));
    }

    /// @notice EIP-712 struct hash of a gasless order whose `orderData` decodes to `data`; this is the Permit2 witness.
    /// @param order The ERC-7683 gasless order.
    /// @param data `order.orderData`, decoded.
    /// @return The witness hash.
    function hashGaslessOrder(GaslessCrossChainOrder calldata order, IntentOrderData memory data)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                GASLESS_ORDER_TYPEHASH,
                order.originSettler,
                order.user,
                order.nonce,
                order.originChainId,
                order.openDeadline,
                order.fillDeadline,
                order.orderDataType,
                hashOrderData(data)
            )
        );
    }

    /// @notice ERC-7683 `originData` of an intent.
    /// @param intent The normalized order.
    /// @return The ABI encoding of `intent`.
    function encodeOriginData(Intent memory intent) internal pure returns (bytes memory) {
        return abi.encode(intent);
    }

    /// @notice Order identifier: keccak256(originChainId, originSettler, fillHash).
    /// @param originChainId Chain id of the origin chain.
    /// @param originSettler OriginSettler address.
    /// @param fillHash keccak256 of the order's `originData`.
    /// @return The order id.
    function orderId(uint256 originChainId, address originSettler, bytes32 fillHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(originChainId, originSettler, fillHash));
    }
}
