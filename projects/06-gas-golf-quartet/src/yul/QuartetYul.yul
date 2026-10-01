// SPDX-License-Identifier: MIT
//
// QuartetYul: fixed-supply ERC-20 with EIP-2612 permit as a standalone Yul object.
//
// Compiled by scripts/build-yul.mjs (npm solc@0.8.37, standard JSON, language "Yul", EVM osaka,
// optimizer runs 1000000) into src/generated/YulBytecode.sol. There is no Solidity dispatcher and
// no ABI decoder here, so this object re-implements exactly the calldata rules Solidity enforces:
//   * every function is non-payable        -> revert(0, 0) on callvalue
//   * unknown selector                      -> revert(0, 0)
//   * calldata shorter than the arguments   -> revert(0, 0), checked by every function with arguments
//   * an address word with bits above 160, or a uint8 word above 255 -> revert(0, 0)
// There is no separate "calldata < 4 bytes" check. CALLDATALOAD zero-pads, so a 1-3 byte calldata reads
// as a selector ending in zero bytes, and it does match one: nonces(address) is 0x7ecebe00, so the
// calldata 0x7ecebe dispatches to nonces(). What rejects it is the per-function length check: every
// function that takes arguments requires its full calldata size first, and no zero-argument selector of
// this surface ends in 0x00. A new zero-argument function whose selector ends in 0x00 would break this;
// test_RevertWhen_SelectorIsUnknownOrShort sends every 1-3 byte prefix of every selector.
//
// Storage layout ("identity-keyed", no hashing for balances and nonces):
//   balanceOf[owner]          at slot owner                     (slot < 2**160)
//   nonces[owner]             at slot owner + 2**160            (2**160 <= slot < 2**161)
//   allowance[owner][spender] at slot keccak256(owner ‖ spender) (64-byte preimage)
// An allowance slot aliases a balance or nonce slot only if the keccak256 output is below 2**161
// (probability 2**-95 per pair). Work to make an allowance write land on:
//   * some unowned account's balance or nonce: ~2**95 hash evaluations (any output below 2**161);
//   * an account the attacker controls: ~2**128 (meet in the middle: many attacker keys, many hashes);
//   * a chosen victim's balance: ~2**256 (the full 256-bit word is fixed: 96 zero bits + the address).
// See docs/THREAT_MODEL.md ("Storage aliasing").
//
// Memory: this object owns all of memory (no free memory pointer), so scratch writes anywhere are
// safe by construction.
//
// Revert data: selector-only errors from IQuartetGolfErrors (shared with QuartetAssembly).
object "QuartetYul" {
    code {
        // Constructor(address holder, uint256 supply). The ABI-encoded arguments are appended to the
        // creation code, i.e. they start right after this object (datasize of the whole object).
        if callvalue() { revert(0, 0) }
        let argsOffset := datasize("QuartetYul")
        if lt(sub(codesize(), argsOffset), 0x40) { revert(0, 0) }
        codecopy(0x00, argsOffset, 0x40)
        let holder := mload(0x00)
        let supply := mload(0x20)
        if shr(160, holder) { revert(0, 0) }
        if iszero(holder) {
            mstore(0x00, 0x1e4ec46b) // InvalidReceiver()
            revert(0x1c, 0x04)
        }
        sstore(holder, supply)
        mstore(0x00, supply)
        // Transfer(address(0), holder, supply)
        log3(0x00, 0x20, 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef, 0, holder)

        // EIP-712 domain separator for the deployment chain id and address.
        mstore(0x00, 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f)
        mstore(0x20, 0x619f0bf9dd1dedf7488dd2c44b804ed93c46a2b3b9e993f2e6dce40929fc7c50) // keccak256("Gas Golf Quartet")
        mstore(0x40, 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6) // keccak256("1")
        mstore(0x60, chainid())
        mstore(0x80, address())
        let separator := keccak256(0x00, 0xa0)

        let size := datasize("runtime")
        datacopy(0x00, dataoffset("runtime"), size)
        setimmutable(0x00, "totalSupply", supply)
        setimmutable(0x00, "separator", separator)
        setimmutable(0x00, "chainId", chainid())
        setimmutable(0x00, "self", address())
        return(0x00, size)
    }

    object "runtime" {
        code {
            // No function is payable: one check for all of them (Solidity checks per function, with the
            // same observable result).
            if callvalue() { revert(0, 0) }

            // Linear dispatch ordered by expected call frequency: `transfer` costs one comparison.
            switch shr(224, calldataload(0x00))
            case 0xa9059cbb { transfer() }
            case 0x70a08231 { balanceOf() }
            case 0x23b872dd { transferFrom() }
            case 0x095ea7b3 { approve() }
            case 0xdd62ed3e { allowance() }
            case 0xd505accf { permit() }
            case 0x7ecebe00 { nonces() }
            case 0x18160ddd { returnWord(loadimmutable("totalSupply")) }
            case 0x313ce567 { returnWord(18) }
            case 0x06fdde03 { returnString(16, "Gas Golf Quartet") }
            case 0x95d89b41 { returnString(4, "GOLF") }
            case 0x3644e515 { returnWord(domainSeparator()) }
            default { revert(0, 0) }

            // transfer(address to, uint256 amount) -> bool
            function transfer() {
                let to := calldataload(0x04)
                if or(lt(calldatasize(), 0x44), shr(160, to)) { revert(0, 0) }
                let amount := calldataload(0x24)
                if iszero(to) { revertWith(0x1e4ec46b) } // InvalidReceiver()
                let fromBalance := sload(caller())
                if gt(amount, fromBalance) { revertWith(0xf4d678b8) } // InsufficientBalance()
                // No underflow: amount <= fromBalance was checked above.
                sstore(caller(), sub(fromBalance, amount))
                // No overflow in any reachable state: balances sum to the fixed total supply.
                sstore(to, add(sload(to), amount))
                mstore(0x00, amount)
                log3(0x00, 0x20, 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef, caller(), to)
                returnWord(1)
            }

            // transferFrom(address from, address to, uint256 amount) -> bool
            function transferFrom() {
                let from := calldataload(0x04)
                let to := calldataload(0x24)
                // One shift validates both addresses: or(from, to) has bits above 160 iff either does.
                if or(lt(calldatasize(), 0x64), shr(160, or(from, to))) { revert(0, 0) }
                let amount := calldataload(0x44)
                mstore(0x00, from)
                mstore(0x20, caller())
                let allowanceSlot := keccak256(0x00, 0x40)
                let allowed := sload(allowanceSlot)
                // not(allowed) is zero only for the infinite allowance, which is never decreased.
                if not(allowed) {
                    if gt(amount, allowed) { revertWith(0x13be252b) } // InsufficientAllowance()
                    // No underflow: amount <= allowed. A later revert rolls this write back.
                    sstore(allowanceSlot, sub(allowed, amount))
                }
                if iszero(from) {
                    // Same class as OpenZeppelin: InvalidApprover when the allowance is finite,
                    // InvalidSender when it is infinite.
                    if not(allowed) { revertWith(0x7f1d2664) } // InvalidApprover()
                    revertWith(0xddb5de5e) // InvalidSender()
                }
                if iszero(to) { revertWith(0x1e4ec46b) } // InvalidReceiver()
                let fromBalance := sload(from)
                if gt(amount, fromBalance) { revertWith(0xf4d678b8) } // InsufficientBalance()
                // No underflow: amount <= fromBalance was checked above.
                sstore(from, sub(fromBalance, amount))
                // No overflow in any reachable state: balances sum to the fixed total supply.
                sstore(to, add(sload(to), amount))
                mstore(0x00, amount)
                log3(0x00, 0x20, 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef, from, to)
                returnWord(1)
            }

            // approve(address spender, uint256 amount) -> bool
            function approve() {
                let spender := calldataload(0x04)
                if or(lt(calldatasize(), 0x44), shr(160, spender)) { revert(0, 0) }
                if iszero(spender) { revertWith(0x5461585f) } // InvalidSpender()
                let amount := calldataload(0x24)
                mstore(0x00, caller())
                mstore(0x20, spender)
                sstore(keccak256(0x00, 0x40), amount)
                mstore(0x00, amount)
                log3(0x00, 0x20, 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925, caller(), spender)
                returnWord(1)
            }

            // permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
            function permit() {
                let owner := calldataload(0x04)
                let spender := calldataload(0x24)
                let v := calldataload(0x84)
                if or(lt(calldatasize(), 0xe4), or(shr(160, or(owner, spender)), shr(8, v))) { revert(0, 0) }
                let deadline := calldataload(0x64)
                if gt(timestamp(), deadline) { revertWith(0x1a15a3cc) } // PermitExpired()
                // Read before memory is used below: the slow path of domainSeparator() hashes in 0x00..0xa0.
                let separator := domainSeparator()
                let nonceSlot := add(0x10000000000000000000000000000000000000000, owner)
                let nonce := sload(nonceSlot)
                let value := calldataload(0x44)
                // structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
                mstore(0x00, 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9)
                mstore(0x20, owner)
                mstore(0x40, spender)
                mstore(0x60, value)
                mstore(0x80, nonce)
                mstore(0xa0, deadline)
                mstore(0x40, keccak256(0x00, 0xc0))
                // digest = keccak256("\x19\x01" ‖ separator ‖ structHash)
                mstore(0x20, separator)
                mstore(0x00, 0x1901)
                let digest := keccak256(0x1e, 0x42)
                let s := calldataload(0xc4)
                // Reject the malleable high-s twin (EIP-2), exactly like OpenZeppelin's ECDSA.
                if gt(s, 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0) {
                    revertWith(0xddafbaef) // InvalidPermit()
                }
                mstore(0x00, digest)
                mstore(0x20, v)
                calldatacopy(0x40, 0xa4, 0x40) // r, s
                // The ecrecover precompile returns no data on failure: pre-zero the output word.
                mstore(0x80, 0)
                pop(staticcall(gas(), 0x01, 0x00, 0x80, 0x80, 0x20))
                let signer := mload(0x80)
                // Passes only if signer != 0 and signer == owner.
                if iszero(mul(signer, eq(signer, owner))) { revertWith(0xddafbaef) } // InvalidPermit()
                if iszero(spender) { revertWith(0x5461585f) } // InvalidSpender()
                // No overflow: a nonce grows by one per successful permit.
                sstore(nonceSlot, add(nonce, 1))
                mstore(0x00, owner)
                mstore(0x20, spender)
                sstore(keccak256(0x00, 0x40), value)
                mstore(0x00, value)
                log3(0x00, 0x20, 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925, owner, spender)
                stop()
            }

            // balanceOf(address owner) -> uint256
            function balanceOf() {
                let owner := calldataload(0x04)
                if or(lt(calldatasize(), 0x24), shr(160, owner)) { revert(0, 0) }
                returnWord(sload(owner))
            }

            // allowance(address owner, address spender) -> uint256
            function allowance() {
                let owner := calldataload(0x04)
                let spender := calldataload(0x24)
                if or(lt(calldatasize(), 0x44), shr(160, or(owner, spender))) { revert(0, 0) }
                mstore(0x00, owner)
                mstore(0x20, spender)
                returnWord(sload(keccak256(0x00, 0x40)))
            }

            // nonces(address owner) -> uint256
            function nonces() {
                let owner := calldataload(0x04)
                if or(lt(calldatasize(), 0x24), shr(160, owner)) { revert(0, 0) }
                returnWord(sload(add(0x10000000000000000000000000000000000000000, owner)))
            }

            // Cached EIP-712 domain separator, recomputed on a chain id change (fork) or under
            // delegatecall (address(this) differs from the deployment address).
            function domainSeparator() -> separator {
                separator := loadimmutable("separator")
                if or(xor(address(), loadimmutable("self")), xor(chainid(), loadimmutable("chainId"))) {
                    mstore(0x00, 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f)
                    mstore(0x20, 0x619f0bf9dd1dedf7488dd2c44b804ed93c46a2b3b9e993f2e6dce40929fc7c50)
                    mstore(0x40, 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6)
                    mstore(0x60, chainid())
                    mstore(0x80, address())
                    separator := keccak256(0x00, 0xa0)
                }
            }

            function returnWord(value) {
                mstore(0x00, value)
                return(0x00, 0x20)
            }

            // ABI-encodes a string of at most 32 bytes: offset, length, left-aligned data.
            function returnString(length, data) {
                mstore(0x00, 0x20)
                mstore(0x20, length)
                mstore(0x40, data)
                return(0x00, 0x60)
            }

            function revertWith(selector) {
                mstore(0x00, selector)
                revert(0x1c, 0x04)
            }
        }
    }
}
