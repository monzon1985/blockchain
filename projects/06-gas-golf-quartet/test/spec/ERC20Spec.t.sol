// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Impl} from "../utils/RevertClassifier.sol";
import {ERC20Spec} from "./ERC20Spec.sol";

/// @notice The specification run against unmodified OpenZeppelin 5.7 ERC20Permit: proof that the
///         specification is OpenZeppelin's behaviour, not something invented for the quartet.
contract ERC20SpecOpenZeppelinTest is ERC20Spec {
    function _impl() internal pure override returns (Impl) {
        return Impl.OpenZeppelin;
    }
}

/// @notice The specification run against the idiomatic Solidity implementation.
contract ERC20SpecSolidityTest is ERC20Spec {
    function _impl() internal pure override returns (Impl) {
        return Impl.Solidity;
    }
}

/// @notice The specification run against the Solady-style inline-assembly implementation.
contract ERC20SpecAssemblyTest is ERC20Spec {
    function _impl() internal pure override returns (Impl) {
        return Impl.Assembly;
    }
}

/// @notice The specification run against the standalone Yul object.
contract ERC20SpecYulTest is ERC20Spec {
    function _impl() internal pure override returns (Impl) {
        return Impl.Yul;
    }
}

/// @notice The specification run against the Vyper 0.4.3 implementation.
contract ERC20SpecVyperTest is ERC20Spec {
    function _impl() internal pure override returns (Impl) {
        return Impl.Vyper;
    }
}
