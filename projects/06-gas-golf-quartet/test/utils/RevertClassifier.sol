// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetGolfErrors} from "../../src/interfaces/IQuartetToken.sol";
import {QuartetSolidity} from "../../src/solidity/QuartetSolidity.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice The implementations under test. `OpenZeppelin` is the canonical oracle.
enum Impl {
    OpenZeppelin,
    Solidity,
    Assembly,
    Yul,
    Vyper
}

/// @notice Outcome classes shared by all implementations. `None` means success.
enum RevertClass {
    None,
    InsufficientBalance,
    InsufficientAllowance,
    InvalidSender,
    InvalidReceiver,
    InvalidApprover,
    InvalidSpender,
    PermitExpired,
    InvalidPermit,
    /// Empty revert data: ABI decoding failure, callvalue on a non-payable function, unknown selector.
    EmptyRevert,
    /// Panic(uint256). No implementation should ever produce one on the shared surface.
    Panic,
    /// Revert data that does not belong to the implementation's own encoding family.
    Unknown
}

/// @title RevertClassifier
/// @notice Maps each implementation's revert encoding to one `RevertClass`, and rejects encodings that
///         belong to another implementation's family:
///           OpenZeppelin, Solidity: ERC-6093 / ERC-2612 / ECDSA custom errors with exact argument lengths
///           Assembly, Yul:          exactly 4 bytes, an IQuartetGolfErrors selector
///           Vyper:                  Error(string) with one of the known reason strings
library RevertClassifier {
    /// @notice Classifies `data` returned by a failed call to implementation `impl`.
    function classify(Impl impl, bytes memory data) internal pure returns (RevertClass) {
        if (data.length == 0) return RevertClass.EmptyRevert;
        if (data.length < 4) return RevertClass.Unknown;
        bytes4 selector = bytes4(data);
        if (selector == 0x4e487b71 && data.length == 36) return RevertClass.Panic;
        if (impl == Impl.OpenZeppelin || impl == Impl.Solidity) return _classifyErc6093(selector, data.length);
        if (impl == Impl.Assembly || impl == Impl.Yul) return _classifyGolf(selector, data.length);
        return _classifyVyper(data);
    }

    /// @notice Human-readable name of a class, for assertion messages.
    function name(RevertClass c) internal pure returns (string memory) {
        string[12] memory names = [
            "None",
            "InsufficientBalance",
            "InsufficientAllowance",
            "InvalidSender",
            "InvalidReceiver",
            "InvalidApprover",
            "InvalidSpender",
            "PermitExpired",
            "InvalidPermit",
            "EmptyRevert",
            "Panic",
            "Unknown"
        ];
        return names[uint256(c)];
    }

    function _classifyErc6093(bytes4 selector, uint256 length) private pure returns (RevertClass) {
        // Selector plus N ABI words; a wrong length means a wrong encoding.
        if (selector == IERC20Errors.ERC20InsufficientBalance.selector && length == 100) {
            return RevertClass.InsufficientBalance;
        }
        if (selector == IERC20Errors.ERC20InsufficientAllowance.selector && length == 100) {
            return RevertClass.InsufficientAllowance;
        }
        if (selector == IERC20Errors.ERC20InvalidSender.selector && length == 36) return RevertClass.InvalidSender;
        if (selector == IERC20Errors.ERC20InvalidReceiver.selector && length == 36) return RevertClass.InvalidReceiver;
        if (selector == IERC20Errors.ERC20InvalidApprover.selector && length == 36) return RevertClass.InvalidApprover;
        if (selector == IERC20Errors.ERC20InvalidSpender.selector && length == 36) return RevertClass.InvalidSpender;
        if (selector == QuartetSolidity.ERC2612ExpiredSignature.selector && length == 36) {
            return RevertClass.PermitExpired;
        }
        if (selector == QuartetSolidity.ERC2612InvalidSigner.selector && length == 68) {
            return RevertClass.InvalidPermit;
        }
        if (selector == ECDSA.ECDSAInvalidSignature.selector && length == 4) return RevertClass.InvalidPermit;
        if (selector == ECDSA.ECDSAInvalidSignatureS.selector && length == 36) return RevertClass.InvalidPermit;
        return RevertClass.Unknown;
    }

    function _classifyGolf(bytes4 selector, uint256 length) private pure returns (RevertClass) {
        if (length != 4) return RevertClass.Unknown;
        if (selector == IQuartetGolfErrors.InsufficientBalance.selector) return RevertClass.InsufficientBalance;
        if (selector == IQuartetGolfErrors.InsufficientAllowance.selector) return RevertClass.InsufficientAllowance;
        if (selector == IQuartetGolfErrors.InvalidSender.selector) return RevertClass.InvalidSender;
        if (selector == IQuartetGolfErrors.InvalidReceiver.selector) return RevertClass.InvalidReceiver;
        if (selector == IQuartetGolfErrors.InvalidApprover.selector) return RevertClass.InvalidApprover;
        if (selector == IQuartetGolfErrors.InvalidSpender.selector) return RevertClass.InvalidSpender;
        if (selector == IQuartetGolfErrors.PermitExpired.selector) return RevertClass.PermitExpired;
        if (selector == IQuartetGolfErrors.InvalidPermit.selector) return RevertClass.InvalidPermit;
        return RevertClass.Unknown;
    }

    function _classifyVyper(bytes memory data) private pure returns (RevertClass) {
        // Error(string): selector, offset 0x20, length, padded bytes.
        if (bytes4(data) != 0x08c379a0 || data.length < 68) return RevertClass.Unknown;
        bytes memory payload = new bytes(data.length - 4);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = data[i + 4];
        }
        bytes32 reason = keccak256(bytes(abi.decode(payload, (string))));
        if (reason == keccak256("erc20: insufficient balance")) return RevertClass.InsufficientBalance;
        if (reason == keccak256("erc20: insufficient allowance")) return RevertClass.InsufficientAllowance;
        if (reason == keccak256("erc20: invalid sender")) return RevertClass.InvalidSender;
        if (reason == keccak256("erc20: invalid receiver")) return RevertClass.InvalidReceiver;
        if (reason == keccak256("erc20: invalid approver")) return RevertClass.InvalidApprover;
        if (reason == keccak256("erc20: invalid spender")) return RevertClass.InvalidSpender;
        if (reason == keccak256("erc2612: expired deadline")) return RevertClass.PermitExpired;
        if (reason == keccak256("erc2612: invalid signature")) return RevertClass.InvalidPermit;
        return RevertClass.Unknown;
    }
}
