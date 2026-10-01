// SPDX-License-Identifier: MIT
// Order encoding shared with the contracts (src/libraries/IntentLib.sol). Every function here has a Solidity twin,
// and the unit tests plus the e2e run check that both sides agree byte for byte.
import {
  type Address,
  type Hex,
  decodeAbiParameters,
  encodeAbiParameters,
  keccak256,
  toHex,
  zeroAddress,
} from "viem";

/** ERC-7683 `orderData` sub-type of this protocol. */
export interface IntentOrderData {
  inputToken: Address;
  inputAmount: bigint;
  outputToken: Address;
  outputStartAmount: bigint;
  outputEndAmount: bigint;
  recipient: Address;
  destinationChainId: bigint;
  destinationSettler: Address;
  exclusiveFiller: Address;
  exclusivityDeadline: number;
  settlementModule: Address;
}

/** Normalized order; `abi.encode(Intent)` is the ERC-7683 `originData`. */
export interface Intent {
  originSettler: Address;
  user: Address;
  nonce: bigint;
  originChainId: bigint;
  openDeadline: number;
  fillDeadline: number;
  data: IntentOrderData;
}

/** ERC-7683 GaslessCrossChainOrder. */
export interface GaslessCrossChainOrder {
  originSettler: Address;
  user: Address;
  nonce: bigint;
  originChainId: bigint;
  openDeadline: number;
  fillDeadline: number;
  orderDataType: Hex;
  orderData: Hex;
}

/** ABI tuple components of IntentOrderData, shared by the encoder and the EIP-712 types. */
export const orderDataComponents = [
  { name: "inputToken", type: "address" },
  { name: "inputAmount", type: "uint256" },
  { name: "outputToken", type: "address" },
  { name: "outputStartAmount", type: "uint256" },
  { name: "outputEndAmount", type: "uint256" },
  { name: "recipient", type: "address" },
  { name: "destinationChainId", type: "uint256" },
  { name: "destinationSettler", type: "address" },
  { name: "exclusiveFiller", type: "address" },
  { name: "exclusivityDeadline", type: "uint32" },
  { name: "settlementModule", type: "address" },
] as const;

const intentParameter = {
  type: "tuple",
  components: [
    { name: "originSettler", type: "address" },
    { name: "user", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "originChainId", type: "uint256" },
    { name: "openDeadline", type: "uint32" },
    { name: "fillDeadline", type: "uint32" },
    { name: "data", type: "tuple", components: orderDataComponents },
  ],
} as const;

const orderDataParameter = { type: "tuple", components: orderDataComponents } as const;

/** EIP-712 type string of IntentOrderData (IntentLib.INTENT_ORDER_DATA_TYPE). */
export const INTENT_ORDER_DATA_TYPE =
  "IntentOrderData(address inputToken,uint256 inputAmount,address outputToken,uint256 outputStartAmount,uint256 outputEndAmount,address recipient,uint256 destinationChainId,address destinationSettler,address exclusiveFiller,uint32 exclusivityDeadline,address settlementModule)";

/** `orderDataType` accepted by the OriginSettler. */
export const INTENT_ORDER_DATA_TYPEHASH: Hex = keccak256(toHex(INTENT_ORDER_DATA_TYPE));

/** ABI-encodes an IntentOrderData (the ERC-7683 `orderData`). */
export function encodeOrderData(data: IntentOrderData): Hex {
  return encodeAbiParameters([orderDataParameter], [data]);
}

/** Decodes an ERC-7683 `orderData` of this protocol. */
export function decodeOrderData(encoded: Hex): IntentOrderData {
  const [data] = decodeAbiParameters([orderDataParameter], encoded);
  return { ...data };
}

/** `originData = abi.encode(Intent)`, what the destination is filled against. */
export function encodeOriginData(intent: Intent): Hex {
  return encodeAbiParameters([intentParameter], [intent]);
}

/** Decodes an `originData` back into its Intent. */
export function decodeOriginData(originData: Hex): Intent {
  const [decoded] = decodeAbiParameters([intentParameter], originData);
  return { ...decoded, data: { ...decoded.data } };
}

/** orderId = keccak256(abi.encode(originChainId, originSettler, keccak256(originData))). */
export function orderIdOf(originData: Hex): Hex {
  const intent = decodeOriginData(originData);
  return keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "bytes32" }],
      [intent.originChainId, intent.originSettler, keccak256(originData)],
    ),
  );
}

/** Intent of an on-chain `open` by `user` with on-chain nonce `nonce`. */
export function onchainIntent(
  originSettler: Address,
  originChainId: bigint,
  user: Address,
  nonce: bigint,
  fillDeadline: number,
  data: IntentOrderData,
): Intent {
  return { originSettler, user, nonce, originChainId, openDeadline: 0xffffffff, fillDeadline, data };
}

/** Intent of a gasless order. */
export function gaslessIntent(order: GaslessCrossChainOrder): Intent {
  return {
    originSettler: order.originSettler,
    user: order.user,
    nonce: order.nonce,
    originChainId: order.originChainId,
    openDeadline: order.openDeadline,
    fillDeadline: order.fillDeadline,
    data: decodeOrderData(order.orderData),
  };
}

/** Storage slot of the first FillRecord word of `orderId` in the DestinationSettler (mapping at slot 0). */
export function fillerSlot(orderId: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [orderId, 0n]));
}

/** Splits the packed first FillRecord word: bits 0..159 filler, 160..223 filledAt. */
export function unpackFillerSlot(value: bigint): { filler: Address; filledAt: bigint } {
  const filler: Address = `0x${(value & ((1n << 160n) - 1n)).toString(16).padStart(40, "0")}`;
  return { filler, filledAt: (value >> 160n) & ((1n << 64n) - 1n) };
}

/**
 * EIP-712 typed data a user signs for a gasless order: a Permit2 PermitWitnessTransferFrom whose witness is the
 * full order with `orderData` decoded, so wallets can display every field.
 */
export function permit2TypedData(order: GaslessCrossChainOrder, permit2: Address, chainId: bigint) {
  const data = decodeOrderData(order.orderData);
  return {
    domain: { name: "Permit2", chainId, verifyingContract: permit2 },
    primaryType: "PermitWitnessTransferFrom",
    types: {
      PermitWitnessTransferFrom: [
        { name: "permitted", type: "TokenPermissions" },
        { name: "spender", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "witness", type: "GaslessCrossChainOrder" },
      ],
      TokenPermissions: [
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
      ],
      GaslessCrossChainOrder: [
        { name: "originSettler", type: "address" },
        { name: "user", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "originChainId", type: "uint256" },
        { name: "openDeadline", type: "uint32" },
        { name: "fillDeadline", type: "uint32" },
        { name: "orderDataType", type: "bytes32" },
        { name: "orderData", type: "IntentOrderData" },
      ],
      IntentOrderData: [...orderDataComponents],
    },
    message: {
      permitted: { token: data.inputToken, amount: data.inputAmount },
      spender: order.originSettler,
      nonce: order.nonce,
      deadline: BigInt(order.openDeadline),
      witness: { ...order, orderData: data },
    },
  } as const;
}

/** `exclusiveFiller` of an order without an exclusivity window. */
export const NO_EXCLUSIVE_FILLER: Address = zeroAddress;

const gaslessOrderParameter = {
  type: "tuple",
  components: [
    { name: "originSettler", type: "address" },
    { name: "user", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "originChainId", type: "uint256" },
    { name: "openDeadline", type: "uint32" },
    { name: "fillDeadline", type: "uint32" },
    { name: "orderDataType", type: "bytes32" },
    { name: "orderData", type: "bytes" },
  ],
} as const;

/** Payload of ERC7683ResolverAdapter.resolve: abi.encode(GaslessCrossChainOrder, signature). */
export function encodeResolverPayload(order: GaslessCrossChainOrder, signature: Hex): Hex {
  return encodeAbiParameters([gaslessOrderParameter, { type: "bytes" }], [order, signature]);
}
