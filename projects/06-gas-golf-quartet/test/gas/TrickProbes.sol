// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPointGolf} from "../../src/math/FixedPointGolf.sol";

/// @notice A/B probes that isolate one trick each; the trick numbers are those of docs/TRICKS.md. Every
///         `...Gas` function returns the gas of the code under test between two GAS reads, and everything
///         the variant needs (immutables, arguments) is read inside that window, so both variants pay for
///         the same work. The same probe contract holds both variants, so the measurement overhead is
///         identical and cancels in the difference.

/// @notice T1/T2: deriving a balance slot and reading it (a cold SLOAD in every variant).
contract SlotProbe {
    mapping(address => uint256) internal balances;

    function mappingGas(address owner) external view returns (uint256 v, uint256 g) {
        uint256 g0 = gasleft();
        v = balances[owner];
        g = g0 - gasleft();
    }

    function seededGas(address owner) external view returns (uint256 v, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: scratch space only.
        assembly ("memory-safe") {
            mstore(0x0c, 0x87a211a2)
            mstore(0x00, owner)
            v := sload(keccak256(0x0c, 0x20))
        }
        g = g0 - gasleft();
    }

    function identityGas(address owner) external view returns (uint256 v, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            v := sload(owner)
        }
        g = g0 - gasleft();
    }
}

/// @notice Measures the gas a calling contract spends on one call (cold account access included, identical
///         for both variants). Used where a whole transaction would hit the EIP-7623 calldata floor, and for
///         dispatch, which happens before any code a GAS window could wrap.
contract CallMeter {
    function meter(address target, bytes calldata data) external returns (bool ok, uint256 g) {
        uint256 g0 = gasleft();
        (ok,) = target.call(data);
        g = g0 - gasleft();
    }
}

/// @notice T3 (A): an ERC-6093 error carrying three values.
contract ErrorWithArgsProbe {
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    function spend(uint256 balance, uint256 amount) external view {
        if (amount > balance) revert ERC20InsufficientBalance(msg.sender, balance, amount);
    }
}

/// @notice T3 (B): the same check with a selector-only error.
contract ErrorSelectorOnlyProbe {
    function spend(uint256 available, uint256 amount) external pure {
        // Memory-safe: scratch space only, then revert.
        assembly ("memory-safe") {
            if gt(amount, available) {
                mstore(0x00, 0xf4d678b8) // InsufficientBalance()
                revert(0x1c, 0x04)
            }
        }
    }
}

/// @notice T4 (A): `return true` through the ABI encoder.
contract ReturnAbiProbe {
    function ok() external pure returns (bool) {
        return true;
    }
}

/// @notice T4 (B): `return true` straight from scratch space.
contract ReturnScratchProbe {
    function ok() external pure returns (bool) {
        // Memory-safe: scratch space only, then return.
        assembly ("memory-safe") {
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }
}

/// @notice T11 (A): a hand-written dispatcher without call-frequency knowledge. The twelve selectors of the
///         token surface in ascending order (so `transfer` is tenth and `DOMAIN_SEPARATOR` sixth), each case
///         with its own non-payable check, the way Solidity checks per function. Bodies return a distinct
///         word so the optimizer cannot merge them.
contract DispatchSortedProbe {
    fallback() external payable {
        // Memory-safe: scratch space only, then return or revert.
        assembly ("memory-safe") {
            function ret(v) {
                mstore(0x00, v)
                return(0x00, 0x20)
            }
            switch shr(224, calldataload(0x00))
            case 0x06fdde03 {
                if callvalue() { revert(0, 0) }
                ret(1)
            }
            case 0x095ea7b3 {
                if callvalue() { revert(0, 0) }
                ret(2)
            }
            case 0x18160ddd {
                if callvalue() { revert(0, 0) }
                ret(3)
            }
            case 0x23b872dd {
                if callvalue() { revert(0, 0) }
                ret(4)
            }
            case 0x313ce567 {
                if callvalue() { revert(0, 0) }
                ret(5)
            }
            case 0x3644e515 {
                if callvalue() { revert(0, 0) }
                ret(6)
            }
            case 0x70a08231 {
                if callvalue() { revert(0, 0) }
                ret(7)
            }
            case 0x7ecebe00 {
                if callvalue() { revert(0, 0) }
                ret(8)
            }
            case 0x95d89b41 {
                if callvalue() { revert(0, 0) }
                ret(9)
            }
            case 0xa9059cbb {
                if callvalue() { revert(0, 0) }
                ret(10)
            }
            case 0xd505accf {
                if callvalue() { revert(0, 0) }
                ret(11)
            }
            case 0xdd62ed3e {
                if callvalue() { revert(0, 0) }
                ret(12)
            }
            default { revert(0, 0) }
        }
    }
}

/// @notice T11 (B): the Yul object's dispatcher. One `callvalue` check for every function, then the cases
///         in expected call frequency (`transfer` first, `DOMAIN_SEPARATOR` last), same bodies as (A).
contract DispatchFrequencyProbe {
    fallback() external payable {
        // Memory-safe: scratch space only, then return or revert.
        assembly ("memory-safe") {
            function ret(v) {
                mstore(0x00, v)
                return(0x00, 0x20)
            }
            if callvalue() { revert(0, 0) }
            switch shr(224, calldataload(0x00))
            case 0xa9059cbb { ret(10) }
            case 0x70a08231 { ret(7) }
            case 0x23b872dd { ret(4) }
            case 0x095ea7b3 { ret(2) }
            case 0xdd62ed3e { ret(12) }
            case 0xd505accf { ret(11) }
            case 0x7ecebe00 { ret(8) }
            case 0x18160ddd { ret(3) }
            case 0x313ce567 { ret(5) }
            case 0x06fdde03 { ret(1) }
            case 0x95d89b41 { ret(9) }
            case 0x3644e515 { ret(6) }
            default { revert(0, 0) }
        }
    }
}

/// @notice T5-T10, T13, T15: branch and check shapes, measured inside one function each.
contract BranchProbe {
    uint256 internal immutable cachedChainId = block.chainid;
    uint256 internal immutable cachedThis = uint256(uint160(address(this)));

    /// T5 (A): branch on "allowance is finite" written as a comparison with 2**256 - 1.
    function infiniteLtGas(uint256 allowed) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            if lt(allowed, not(0)) { r := 1 }
        }
        g = g0 - gasleft();
    }

    /// T5 (B): the same branch on `not(allowed)`, as in the token code.
    function infiniteNotGas(uint256 allowed) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            if not(allowed) { r := 1 }
        }
        g = g0 - gasleft();
    }

    /// T6 (A): signer != 0 && signer == owner, as two tests.
    function signerTwoTestsGas(uint256 signer, uint256 owner) external view returns (uint256 bad, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            bad := or(iszero(signer), iszero(eq(signer, owner)))
        }
        g = g0 - gasleft();
    }

    /// T6 (B): the same predicate as one multiplication.
    function signerMulGas(uint256 signer, uint256 owner) external view returns (uint256 bad, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            bad := iszero(mul(signer, eq(signer, owner)))
        }
        g = g0 - gasleft();
    }

    /// T7 (A): domain-separator cache check, idiomatic `&&`.
    function cacheAndGas() external view returns (bool stale, uint256 g) {
        uint256 g0 = gasleft();
        stale = !(address(this) == address(uint160(cachedThis)) && block.chainid == cachedChainId);
        g = g0 - gasleft();
    }

    /// T7 (B): one xor-or test. Both immutables are read inside the window, as in (A).
    function cacheXorGas() external view returns (bool stale, uint256 g) {
        uint256 g0 = gasleft();
        uint256 t = cachedThis;
        uint256 c = cachedChainId;
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            stale := iszero(iszero(or(xor(address(), t), xor(chainid(), c))))
        }
        g = g0 - gasleft();
    }

    /// T8 (A): address validation of two arguments, one shift each.
    function validateTwoGas(uint256 a, uint256 b) external view returns (uint256 bad, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            bad := or(shr(160, a), shr(160, b))
        }
        g = g0 - gasleft();
    }

    /// T8 (B): one shift over the OR of both.
    function validateOrGas(uint256 a, uint256 b) external view returns (uint256 bad, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            bad := shr(160, or(a, b))
        }
        g = g0 - gasleft();
    }

    /// T9 (A): log2 via CLZ with an explicit zero branch.
    function log2BranchGas(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            if x { r := sub(255, clz(x)) }
        }
        g = g0 - gasleft();
    }

    /// T9 (B): log2 via CLZ with `x | 1`.
    function log2OrOneGas(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            r := sub(255, clz(or(x, 1)))
        }
        g = g0 - gasleft();
    }

    /// T10 (A): `transferFrom`'s zero-`from` checks where OpenZeppelin has them: one inside the finite-allowance
    ///          branch (`_approve` raises InvalidApprover) and one before the balance update (`_transfer`
    ///          raises InvalidSender). Hot path: non-zero `from`, finite allowance.
    function fromCheckTwiceGas(uint256 from, uint256 allowed, uint256 amount)
        external
        view
        returns (uint256 left, uint256 g)
    {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            left := allowed
            if not(allowed) {
                if gt(amount, allowed) { revert(0, 0) }
                if iszero(from) { revert(0, 0) }
                left := sub(allowed, amount)
            }
            if iszero(from) { revert(0, 0) }
        }
        g = g0 - gasleft();
    }

    /// T10 (B): one zero-`from` check after the allowance update, as in the golfed tokens (a revert rolls
    ///          the allowance write back, and the error class is chosen inside the cold branch).
    function fromCheckOnceGas(uint256 from, uint256 allowed, uint256 amount)
        external
        view
        returns (uint256 left, uint256 g)
    {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            left := allowed
            if not(allowed) {
                if gt(amount, allowed) { revert(0, 0) }
                left := sub(allowed, amount)
            }
            if iszero(from) { revert(0, 0) }
        }
        g = g0 - gasleft();
    }

    /// T13 (A): the CLZ opcode inline.
    function clzInlineGas(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            r := clz(x)
        }
        g = g0 - gasleft();
    }

    /// T13 (B): the same count through the kernel's public API, FixedPointGolf.clz, which reaches the opcode
    ///          via the `clz/` proof seam (two internal calls the legacy optimizer does not inline).
    function clzSeamGas(uint256 x) external view returns (uint256 r, uint256 g) {
        uint256 g0 = gasleft();
        r = FixedPointGolf.clz(x);
        g = g0 - gasleft();
    }

    /// T15 (A): the `msg.sender != address(0)` check OpenZeppelin makes in `transfer` and `approve`.
    function senderCheckGas() external view returns (uint256 g) {
        uint256 g0 = gasleft();
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            if iszero(caller()) { revert(0, 0) }
        }
        g = g0 - gasleft();
    }

    /// T15 (B): no check (the golfed tokens): an empty window.
    function noSenderCheckGas() external view returns (uint256 g) {
        uint256 g0 = gasleft();
        g = g0 - gasleft();
    }
}
