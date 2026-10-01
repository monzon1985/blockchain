// SPDX-License-Identifier: MIT
//! Solidity ABI types shared with `contracts/src/lib/Types.sol` and `contracts/src/interfaces/IOneStepVM.sol`.
#![allow(missing_docs)]

use alloy_sol_types::sol;

sol! {
    /// Commitment-level view of the machine; `keccak256(abi.encode(machine))` is the per-step state hash.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct Machine {
        uint8 status;
        uint32 pc;
        uint32 stackDepth;
        bytes32 stackHash;
        bytes32 stateRoot;
        bytes32 codeRoot;
        uint32 codeSize;
        bytes32 inputRoot;
        uint32 inputSize;
    }

    /// Witness for executing exactly one instruction on-chain.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct StepProof {
        uint8 opcode;
        uint256 imm;
        bytes32[] codeProof;
        bytes32[] stack;
        bytes32 stackRest;
        bytes32 leafValue;
        uint256 siblingBitmap;
        bytes32[] siblings;
        bytes tape;
    }

    /// The on-chain one-step verifier.
    interface IOneStepVM {
        function step(Machine calldata pre, StepProof calldata proof) external pure returns (Machine memory post);
        function stepHash(Machine calldata pre, StepProof calldata proof) external pure returns (bytes32);
    }
}

impl Machine {
    /// `keccak256(abi.encode(self))`, the state hash the bisection game compares.
    pub fn hash(&self) -> alloy_primitives::B256 {
        alloy_primitives::keccak256(alloy_sol_types::SolValue::abi_encode(self))
    }
}
