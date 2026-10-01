// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Builds ERC-7739 nested hashes the way a 7739-aware wallet does off-chain.
library Erc7739Helper {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERSONAL_SIGN_TYPEHASH = keccak256("PersonalSign(bytes prefixed)");

    string internal constant CONTENTS_NAME = "Mail";
    string internal constant CONTENTS_TYPE = "Mail(address to,string contents)";

    /// @dev An application's EIP-712 domain (the dApp that calls `isValidSignature` on the account).
    function appSeparator(address app) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Mail App"), keccak256("1"), block.chainid, app));
    }

    function mailHash(address to, string memory contents) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256(bytes(CONTENTS_TYPE)), to, keccak256(bytes(contents))));
    }

    /// @dev The account's EIP-712 domain fields as ERC-7739 encodes them (salt = 0, `PasskeyAccount` v1).
    function accountDomainBytes(address account) internal view returns (bytes memory) {
        return abi.encode(keccak256("PasskeyAccount"), keccak256("1"), block.chainid, account, bytes32(0));
    }

    function accountSeparator(address account) internal view returns (bytes32) {
        return
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("PasskeyAccount"), keccak256("1"), block.chainid, account));
    }

    /// @dev Digest the signer actually signs for a nested typed-data signature on `account`.
    function typedDataSignDigest(address account, bytes32 appSep, bytes32 contentsHash)
        internal
        view
        returns (bytes32)
    {
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "TypedDataSign(",
                CONTENTS_NAME,
                " contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)",
                CONTENTS_TYPE
            )
        );
        bytes32 structHash = keccak256(abi.encodePacked(typehash, contentsHash, accountDomainBytes(account)));
        return MessageHashUtils.toTypedDataHash(appSep, structHash);
    }

    /// @dev `signature ‖ appSeparator ‖ contentsHash ‖ contentsDescr ‖ uint16(len)` (implicit descriptor mode).
    function wrapTypedDataSig(bytes memory innerSig, bytes32 appSep, bytes32 contentsHash)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(innerSig, appSep, contentsHash, CONTENTS_TYPE, uint16(bytes(CONTENTS_TYPE).length));
    }

    /// @dev Digest the signer signs for a nested personal-sign signature on `account`.
    function personalSignDigest(address account, bytes32 erc191Hash) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(
            accountSeparator(account), keccak256(abi.encode(PERSONAL_SIGN_TYPEHASH, erc191Hash))
        );
    }
}
