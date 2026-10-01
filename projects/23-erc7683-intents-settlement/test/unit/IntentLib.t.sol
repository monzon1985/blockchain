// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {GaslessCrossChainOrder} from "../../src/erc7683/IERC7683.sol";
import {Intent, IntentLib, IntentOrderData} from "../../src/libraries/IntentLib.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";

/// @notice EIP-712 and identifier derivation, differentially checked against Foundry's own EIP-712 encoder.
contract IntentLibTest is IntentTestBase {
    function test_typehashes_matchFoundryEncoder() public pure {
        assertEq(IntentLib.INTENT_ORDER_DATA_TYPEHASH, vm.eip712HashType(IntentLib.INTENT_ORDER_DATA_TYPE));
        assertEq(IntentLib.GASLESS_ORDER_TYPEHASH, vm.eip712HashType(IntentLib.GASLESS_ORDER_TYPE));
    }

    /// @dev The witness type string must be "<Type> witness)" + the witness type + every referenced type, sorted,
    ///      with TokenPermissions last among them (it sorts after GaslessCrossChainOrder and IntentOrderData).
    function test_witnessTypeString_isWellFormed() public pure {
        string memory expected = string.concat(
            "GaslessCrossChainOrder witness)",
            IntentLib.GASLESS_ORDER_TYPE,
            "TokenPermissions(address token,uint256 amount)"
        );
        assertEq(IntentLib.PERMIT2_WITNESS_TYPE_STRING, expected);
        // The full Permit2 type is a valid EIP-712 type whose hash Foundry reproduces.
        string memory fullType = string.concat(PERMIT_WITNESS_STUB, IntentLib.PERMIT2_WITNESS_TYPE_STRING);
        assertEq(keccak256(bytes(fullType)), vm.eip712HashType(fullType));
    }

    function testFuzz_hashOrderData_matchesFoundryEncoder(IntentOrderData memory data) public pure {
        assertEq(IntentLib.hashOrderData(data), vm.eip712HashStruct(IntentLib.INTENT_ORDER_DATA_TYPE, abi.encode(data)));
    }

    function testFuzz_witnessHash_matchesFoundryEncoder(
        address originSettler,
        address owner,
        uint256 nonce,
        uint256 originChainId,
        uint32 openDeadline,
        uint32 fillDeadline,
        IntentOrderData memory data
    ) public view {
        GaslessCrossChainOrder memory order = GaslessCrossChainOrder({
            originSettler: originSettler,
            user: owner,
            nonce: nonce,
            originChainId: originChainId,
            openDeadline: openDeadline,
            fillDeadline: fillDeadline,
            orderDataType: IntentLib.INTENT_ORDER_DATA_TYPEHASH,
            orderData: abi.encode(data)
        });
        bytes32 viaFoundry = vm.eip712HashStruct(
            IntentLib.GASLESS_ORDER_TYPE,
            abi.encode(
                originSettler,
                owner,
                nonce,
                originChainId,
                openDeadline,
                fillDeadline,
                IntentLib.INTENT_ORDER_DATA_TYPEHASH,
                data
            )
        );
        assertEq(origin.witnessHash(order), viaFoundry);
    }

    /// @dev The Permit2 digest the fixture signs equals Foundry's full EIP-712 typed-data digest.
    function test_permit2Digest_matchesTypedDataJson() public {
        vm.chainId(ORIGIN);
        GaslessCrossChainOrder memory order = _gaslessOrder(_params(address(mailboxModule)), 3);
        IntentOrderData memory d = abi.decode(order.orderData, (IntentOrderData));
        string memory json = string.concat(
            '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"chainId","type":"uint256"},',
            '{"name":"verifyingContract","type":"address"}],',
            '"PermitWitnessTransferFrom":[{"name":"permitted","type":"TokenPermissions"},{"name":"spender","type":"address"},',
            '{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"},{"name":"witness","type":"GaslessCrossChainOrder"}],',
            '"TokenPermissions":[{"name":"token","type":"address"},{"name":"amount","type":"uint256"}],',
            '"GaslessCrossChainOrder":[{"name":"originSettler","type":"address"},{"name":"user","type":"address"},',
            '{"name":"nonce","type":"uint256"},{"name":"originChainId","type":"uint256"},{"name":"openDeadline","type":"uint32"},',
            '{"name":"fillDeadline","type":"uint32"},{"name":"orderDataType","type":"bytes32"},{"name":"orderData","type":"IntentOrderData"}],',
            _orderDataTypeJson(),
            '},"primaryType":"PermitWitnessTransferFrom",',
            _domainJson(),
            _messageJson(order, d),
            "}"
        );
        assertEq(vm.eip712HashTypedData(json), _permit2Digest(order));
    }

    function test_orderId_bindsChainSettlerAndPayload() public view {
        Intent memory intent = _onchainIntent(_params(address(mailboxModule)), user, 0);
        bytes memory originData = IntentLib.encodeOriginData(intent);
        assertEq(originData, abi.encode(intent));
        bytes32 fillHash = keccak256(originData);
        bytes32 id = IntentLib.orderId(ORIGIN, address(origin), fillHash);
        assertEq(id, keccak256(abi.encode(ORIGIN, address(origin), fillHash)));
        assertTrue(id != IntentLib.orderId(DEST, address(origin), fillHash));
        assertTrue(id != IntentLib.orderId(ORIGIN, address(dest), fillHash));
        Intent memory decoded = abi.decode(originData, (Intent));
        assertEq(keccak256(abi.encode(decoded)), fillHash);
    }

    function _orderDataTypeJson() internal pure returns (string memory) {
        return string.concat(
            '"IntentOrderData":[{"name":"inputToken","type":"address"},{"name":"inputAmount","type":"uint256"},',
            '{"name":"outputToken","type":"address"},{"name":"outputStartAmount","type":"uint256"},',
            '{"name":"outputEndAmount","type":"uint256"},{"name":"recipient","type":"address"},',
            '{"name":"destinationChainId","type":"uint256"},{"name":"destinationSettler","type":"address"},',
            '{"name":"exclusiveFiller","type":"address"},{"name":"exclusivityDeadline","type":"uint32"},',
            '{"name":"settlementModule","type":"address"}]'
        );
    }

    function _domainJson() internal view returns (string memory) {
        return string.concat(
            '"domain":{"name":"Permit2","chainId":',
            vm.toString(block.chainid),
            ',"verifyingContract":"',
            vm.toString(PERMIT2_ADDRESS),
            '"},'
        );
    }

    function _messageJson(GaslessCrossChainOrder memory order, IntentOrderData memory d)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '"message":{"permitted":{"token":"',
            vm.toString(d.inputToken),
            '","amount":"',
            vm.toString(d.inputAmount),
            '"},"spender":"',
            vm.toString(address(origin)),
            '","nonce":"',
            vm.toString(order.nonce),
            '","deadline":"',
            vm.toString(uint256(order.openDeadline)),
            '","witness":',
            _witnessJson(order, d),
            "}"
        );
    }

    function _witnessJson(GaslessCrossChainOrder memory order, IntentOrderData memory d)
        internal
        pure
        returns (string memory)
    {
        string memory head = string.concat(
            '{"originSettler":"',
            vm.toString(order.originSettler),
            '","user":"',
            vm.toString(order.user),
            '","nonce":"',
            vm.toString(order.nonce),
            '","originChainId":"',
            vm.toString(order.originChainId),
            '","openDeadline":"',
            vm.toString(uint256(order.openDeadline)),
            '","fillDeadline":"',
            vm.toString(uint256(order.fillDeadline)),
            '","orderDataType":"',
            vm.toString(order.orderDataType),
            '","orderData":'
        );
        string memory data1 = string.concat(
            '{"inputToken":"',
            vm.toString(d.inputToken),
            '","inputAmount":"',
            vm.toString(d.inputAmount),
            '","outputToken":"',
            vm.toString(d.outputToken),
            '","outputStartAmount":"',
            vm.toString(d.outputStartAmount),
            '","outputEndAmount":"',
            vm.toString(d.outputEndAmount),
            '","recipient":"',
            vm.toString(d.recipient)
        );
        string memory data2 = string.concat(
            '","destinationChainId":"',
            vm.toString(d.destinationChainId),
            '","destinationSettler":"',
            vm.toString(d.destinationSettler),
            '","exclusiveFiller":"',
            vm.toString(d.exclusiveFiller),
            '","exclusivityDeadline":"',
            vm.toString(uint256(d.exclusivityDeadline)),
            '","settlementModule":"',
            vm.toString(d.settlementModule),
            '"}}'
        );
        return string.concat(head, data1, data2);
    }
}
