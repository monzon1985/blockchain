// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetGolfErrors, IQuartetToken} from "../interfaces/IQuartetToken.sol";

/// @title QuartetAssembly
/// @author Gas Golf Quartet
/// @notice Fixed-supply ERC-20 with EIP-2612 permit whose function bodies are inline assembly, in the
///         style of Solady's ERC20. Solidity still provides the dispatcher and the ABI decoder, so the
///         calldata validation (dirty address bits, short calldata, non-payable) is the compiler's.
/// @dev Storage layout (Solady-style seeded slots, one 32- or 52-byte keccak per access instead of
///      Solidity's 64-byte mapping hashes):
///        balance slot   = keccak256(owner ‖ 0x00{8} ‖ _BALANCE_SLOT_SEED{4})              (32 bytes)
///        nonce slot     = keccak256(owner ‖ 0x00{8} ‖ _NONCES_SLOT_SEED{4})               (32 bytes)
///        allowance slot = keccak256(owner ‖ 0x00{8} ‖ _ALLOWANCE_SLOT_SEED{4} ‖ spender) (52 bytes)
///      The seeds differ and the allowance preimage is longer, so the three key spaces cannot collide
///      short of a keccak256 collision.
///
///      Memory-safety convention for every `assembly ("memory-safe")` block in this file: a block only
///      writes the scratch space [0x00, 0x40) or memory at and above the free memory pointer without
///      moving it. Nothing written there is read back by compiler-generated code, which is exactly the
///      condition the Solidity documentation sets for the "memory-safe" annotation.
///      Semantics (check order, error classes, events) are equivalent to QuartetSolidity; see
///      test/differential and test/halmos for the evidence.
contract QuartetAssembly is IQuartetToken, IQuartetGolfErrors {
    /// @dev Seed mixed into balance slots.
    uint256 private constant _BALANCE_SLOT_SEED = 0x87a211a2;
    /// @dev Seed mixed into allowance slots.
    uint256 private constant _ALLOWANCE_SLOT_SEED = 0x7f5e9f20;
    /// @dev Seed mixed into nonce slots.
    uint256 private constant _NONCES_SLOT_SEED = 0x38377508;

    /// @dev keccak256("Transfer(address,address,uint256)")
    uint256 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    /// @dev keccak256("Approval(address,address,uint256)")
    uint256 private constant _APPROVAL_EVENT_SIGNATURE =
        0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;
    /// @dev keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    uint256 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    uint256 private constant _DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    /// @dev keccak256("Gas Golf Quartet")
    uint256 private constant _HASHED_NAME = 0x619f0bf9dd1dedf7488dd2c44b804ed93c46a2b3b9e993f2e6dce40929fc7c50;
    /// @dev keccak256("1")
    uint256 private constant _HASHED_VERSION = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;
    /// @dev secp256k1n / 2. Larger `s` values are the malleable twin of a valid signature (EIP-2).
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    /// @dev Selectors of IQuartetGolfErrors, usable from assembly.
    uint256 private constant _INSUFFICIENT_BALANCE = 0xf4d678b8;
    uint256 private constant _INSUFFICIENT_ALLOWANCE = 0x13be252b;
    uint256 private constant _INVALID_SENDER = 0xddb5de5e;
    uint256 private constant _INVALID_RECEIVER = 0x1e4ec46b;
    uint256 private constant _INVALID_APPROVER = 0x7f1d2664;
    uint256 private constant _INVALID_SPENDER = 0x5461585f;
    uint256 private constant _PERMIT_EXPIRED = 0x1a15a3cc;
    uint256 private constant _INVALID_PERMIT = 0xddafbaef;

    /// @dev Total supply, minted once in the constructor.
    uint256 private immutable _totalSupply;
    /// @dev Domain separator computed at deployment.
    uint256 private immutable _cachedDomainSeparator;
    /// @dev Chain id at deployment.
    uint256 private immutable _cachedChainId;
    /// @dev Deployment address.
    uint256 private immutable _cachedThis;

    /// @notice Deploys the token and mints the whole supply to `holder`.
    /// @param holder Receiver of the initial supply. Must not be the zero address.
    /// @param supply Total supply to mint.
    constructor(address holder, uint256 supply) {
        if (holder == address(0)) revert InvalidReceiver();
        _totalSupply = supply;
        _cachedChainId = block.chainid;
        _cachedThis = uint256(uint160(address(this)));
        _cachedDomainSeparator = _buildDomainSeparator();
        // Memory-safe: scratch space only.
        assembly ("memory-safe") {
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, holder)
            sstore(keccak256(0x0c, 0x20), supply)
            mstore(0x00, supply)
            log3(0x00, 0x20, _TRANSFER_EVENT_SIGNATURE, 0, holder)
        }
    }

    /// @notice Token name, also used as the EIP-712 domain name.
    /// @return The ABI-encoded string "Gas Golf Quartet".
    function name() external pure override returns (string memory) {
        // Memory-safe: writes three words at the free memory pointer without moving it, then returns.
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x20)
            mstore(add(m, 0x20), 16)
            mstore(add(m, 0x40), "Gas Golf Quartet")
            return(m, 0x60)
        }
    }

    /// @notice Token symbol.
    /// @return The ABI-encoded string "GOLF".
    function symbol() external pure override returns (string memory) {
        // Memory-safe: writes three words at the free memory pointer without moving it, then returns.
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x20)
            mstore(add(m, 0x20), 4)
            mstore(add(m, 0x40), "GOLF")
            return(m, 0x60)
        }
    }

    /// @notice Number of decimals used for display purposes.
    /// @return Always 18.
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @notice Total supply, fixed at construction.
    /// @return The supply minted to the initial holder.
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    /// @notice Balance of `owner`.
    /// @param owner Account to query.
    /// @return result The balance.
    function balanceOf(address owner) external view override returns (uint256 result) {
        // Memory-safe: scratch space only.
        assembly ("memory-safe") {
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    /// @notice Remaining amount `spender` may move out of `owner`'s balance.
    /// @param owner Token owner.
    /// @param spender Approved spender.
    /// @return result The allowance.
    function allowance(address owner, address spender) external view override returns (uint256 result) {
        // Memory-safe: scratch space only.
        assembly ("memory-safe") {
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x34))
        }
    }

    /// @notice Next EIP-2612 nonce of `owner`.
    /// @param owner Account to query.
    /// @return result The nonce the next permit must be signed with.
    function nonces(address owner) external view override returns (uint256 result) {
        // Memory-safe: scratch space only.
        assembly ("memory-safe") {
            mstore(0x0c, _NONCES_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    /// @notice Moves `amount` tokens from the caller to `to`.
    /// @param to Recipient. Must not be the zero address.
    /// @param amount Amount to move.
    /// @return Always true; failures revert.
    function transfer(address to, uint256 amount) external override returns (bool) {
        // Memory-safe: scratch space only; returns straight from scratch space.
        assembly ("memory-safe") {
            if iszero(to) {
                mstore(0x00, _INVALID_RECEIVER)
                revert(0x1c, 0x04)
            }
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, caller())
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            if gt(amount, fromBalance) {
                mstore(0x00, _INSUFFICIENT_BALANCE)
                revert(0x1c, 0x04)
            }
            // No underflow: `amount <= fromBalance` was checked above.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // The seed word at 0x0c..0x2c is intact; only the owner word changes.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // No overflow in any reachable state: balances sum to the fixed total supply.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, caller(), to)
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }

    /// @notice Sets `spender`'s allowance over the caller's tokens to `amount`.
    /// @param spender Account allowed to spend. Must not be the zero address.
    /// @param amount New allowance. `type(uint256).max` is an infinite allowance.
    /// @return Always true; failures revert.
    function approve(address spender, uint256 amount) external override returns (bool) {
        // Memory-safe: scratch space only; returns straight from scratch space.
        assembly ("memory-safe") {
            if iszero(spender) {
                mstore(0x00, _INVALID_SPENDER)
                revert(0x1c, 0x04)
            }
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, caller())
            sstore(keccak256(0x0c, 0x34), amount)
            mstore(0x00, amount)
            log3(0x00, 0x20, _APPROVAL_EVENT_SIGNATURE, caller(), spender)
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }

    /// @notice Moves `amount` tokens from `from` to `to` using the caller's allowance.
    /// @param from Account debited.
    /// @param to Recipient. Must not be the zero address.
    /// @param amount Amount to move.
    /// @return Always true; failures revert.
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        // Memory-safe: scratch space only; returns straight from scratch space.
        assembly ("memory-safe") {
            mstore(0x20, caller())
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, from)
            let allowanceSlot := keccak256(0x0c, 0x34)
            let allowed := sload(allowanceSlot)
            // `not(allowed)` is zero only for the infinite allowance, which is never decreased.
            if not(allowed) {
                if gt(amount, allowed) {
                    mstore(0x00, _INSUFFICIENT_ALLOWANCE)
                    revert(0x1c, 0x04)
                }
                // No underflow: `amount <= allowed` was checked above. If `from` is zero the revert
                // below rolls this write back, so the zero check can stay off the hot path.
                sstore(allowanceSlot, sub(allowed, amount))
            }
            if iszero(from) {
                // OpenZeppelin raises InvalidApprover inside `_approve` when the allowance is finite and
                // InvalidSender inside `_transfer` when it is infinite; keep the same class.
                mstore(0x00, _INVALID_SENDER)
                if not(allowed) { mstore(0x00, _INVALID_APPROVER) }
                revert(0x1c, 0x04)
            }
            if iszero(to) {
                mstore(0x00, _INVALID_RECEIVER)
                revert(0x1c, 0x04)
            }
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, from)
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            if gt(amount, fromBalance) {
                mstore(0x00, _INSUFFICIENT_BALANCE)
                revert(0x1c, 0x04)
            }
            // No underflow: `amount <= fromBalance` was checked above.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // No overflow in any reachable state: balances sum to the fixed total supply.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, from, to)
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }

    /// @notice Sets `spender`'s allowance over `owner`'s tokens from an EIP-712 signature.
    /// @param owner Token owner who signed the permit.
    /// @param spender Account allowed to spend. Must not be the zero address.
    /// @param value New allowance.
    /// @param deadline Last timestamp at which the signature is valid.
    /// @param v Signature recovery byte.
    /// @param r Signature `r` value.
    /// @param s Signature `s` value; must be in the lower half of the curve order.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        uint256 separator = _domainSeparator();
        // Memory-safe: scratch space plus 0xc0 bytes at the free memory pointer, which is not moved and
        // not read by compiler-generated code (the function ends inside this block).
        assembly ("memory-safe") {
            if gt(timestamp(), deadline) {
                mstore(0x00, _PERMIT_EXPIRED)
                revert(0x1c, 0x04)
            }
            mstore(0x0c, _NONCES_SLOT_SEED)
            mstore(0x00, owner)
            let nonceSlot := keccak256(0x0c, 0x20)
            let nonce := sload(nonceSlot)
            let m := mload(0x40)
            // structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            mstore(m, _PERMIT_TYPEHASH)
            mstore(add(m, 0x20), owner)
            mstore(add(m, 0x40), spender)
            mstore(add(m, 0x60), value)
            mstore(add(m, 0x80), nonce)
            mstore(add(m, 0xa0), deadline)
            let structHash := keccak256(m, 0xc0)
            // digest = keccak256("\x19\x01" ‖ separator ‖ structHash): 0x1901 lands in bytes m+0x1e..m+0x20.
            mstore(m, 0x1901)
            mstore(add(m, 0x20), separator)
            mstore(add(m, 0x40), structHash)
            let digest := keccak256(add(m, 0x1e), 0x42)
            // Reject the malleable high-s twin, exactly like OpenZeppelin's ECDSA.
            if gt(s, _HALF_CURVE_ORDER) {
                mstore(0x00, _INVALID_PERMIT)
                revert(0x1c, 0x04)
            }
            mstore(m, digest)
            mstore(add(m, 0x20), v)
            mstore(add(m, 0x40), r)
            mstore(add(m, 0x60), s)
            // The ecrecover precompile returns no data on failure, so pre-zero the output word.
            mstore(0x00, 0)
            pop(staticcall(gas(), 0x01, m, 0x80, 0x00, 0x20))
            let signer := mload(0x00)
            // Passes only if signer != 0 and signer == owner (mul is zero if either factor is).
            if iszero(mul(signer, eq(signer, owner))) {
                mstore(0x00, _INVALID_PERMIT)
                revert(0x1c, 0x04)
            }
            if iszero(spender) {
                mstore(0x00, _INVALID_SPENDER)
                revert(0x1c, 0x04)
            }
            // No overflow: a nonce grows by one per successful permit.
            sstore(nonceSlot, add(nonce, 1))
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, owner)
            sstore(keccak256(0x0c, 0x34), value)
            mstore(0x00, value)
            log3(0x00, 0x20, _APPROVAL_EVENT_SIGNATURE, owner, spender)
            return(0x00, 0x00)
        }
    }

    /// @notice EIP-712 domain separator used by `permit`.
    /// @return The separator for the current chain id and contract address.
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return bytes32(_domainSeparator());
    }

    /// @dev Returns the cached separator unless the chain id or the executing address changed.
    function _domainSeparator() private view returns (uint256 separator) {
        separator = _cachedDomainSeparator;
        uint256 cachedThis = _cachedThis;
        uint256 cachedChainId = _cachedChainId;
        bool stale;
        // Memory-safe: no memory access.
        assembly ("memory-safe") {
            // One branch instead of two: the xor-or is zero only if both values match.
            stale := iszero(iszero(or(xor(address(), cachedThis), xor(chainid(), cachedChainId))))
        }
        if (stale) separator = _buildDomainSeparator();
    }

    /// @dev EIP-712 domain separator for the current chain id and executing address.
    function _buildDomainSeparator() private view returns (uint256 separator) {
        // Memory-safe: five words at the free memory pointer, which is not moved; hashed, then abandoned.
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, _DOMAIN_TYPEHASH)
            mstore(add(m, 0x20), _HASHED_NAME)
            mstore(add(m, 0x40), _HASHED_VERSION)
            mstore(add(m, 0x60), chainid())
            mstore(add(m, 0x80), address())
            separator := keccak256(m, 0xa0)
        }
    }
}
