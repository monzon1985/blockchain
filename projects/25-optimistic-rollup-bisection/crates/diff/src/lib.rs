// SPDX-License-Identifier: MIT
//! # rollup-diff
//!
//! Loads the compiled `OneStepVM` runtime bytecode from `contracts/out` into an in-memory revm instance and executes
//! `step(pre, proof)` there. The differential tests in `tests/` run the Rust interpreter and this EVM side by side on
//! random programs and on real STF traces; a production fault-proof system is only sound if the two agree on every
//! instruction.

use alloy_primitives::{Address, Bytes, U256, address};
use alloy_sol_types::SolCall;
use revm::{
    Context, ExecuteEvm, MainBuilder, MainContext,
    bytecode::Bytecode,
    context::{TxEnv, result::ExecutionResult},
    database::{CacheDB, EmptyDB},
    state::AccountInfo,
};
use rollup_l1::{Artifact, L1Error, artifacts::default_out_dir};
use rollup_vm::{MachineCommitment, StepProof, abi::IOneStepVM};
use thiserror::Error;

/// Where the verifier is placed in the in-memory state.
pub const VERIFIER: Address = address!("0x00000000000000000000000000000000000057e9");
/// Caller of every call.
pub const CALLER: Address = address!("0x000000000000000000000000000000000000ca11");

/// Errors of the harness itself (never of the code under test).
#[derive(Debug, Error)]
pub enum DiffError {
    /// Could not load the compiled verifier.
    #[error(transparent)]
    Artifact(#[from] L1Error),
    /// revm refused the transaction (a harness bug, not a verifier result).
    #[error("revm: {0}")]
    Evm(String),
    /// The verifier returned data that does not decode as a machine.
    #[error("undecodable return data: {0}")]
    Decode(String),
}

/// What the on-chain verifier did with one `(pre, proof)` pair.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EvmStep {
    /// Executed; returns the post-state and the gas the transaction used.
    Ok {
        /// Post-state computed by Solidity.
        post: MachineCommitment,
        /// Gas used by the whole transaction (21k intrinsic + calldata + execution).
        gas: u64,
    },
    /// Reverted (invalid witness).
    Reverted {
        /// Revert data (a custom error).
        data: Bytes,
    },
}

/// In-memory EVM with the compiled `OneStepVM` deployed at [`VERIFIER`].
#[derive(Debug, Clone)]
pub struct OneStepVmEvm {
    db: CacheDB<EmptyDB>,
}

impl OneStepVmEvm {
    /// Loads `OneStepVM` from `contracts/out` (or `$ROLLUP_CONTRACTS_OUT`).
    ///
    /// # Errors
    /// [`DiffError::Artifact`] when the contracts were not built.
    pub fn load() -> Result<Self, DiffError> {
        let artifact = Artifact::load(&default_out_dir(), "OneStepVM")?;
        Ok(Self::from_runtime_code(artifact.deployed_bytecode))
    }

    /// Harness around arbitrary runtime bytecode implementing `IOneStepVM`.
    pub fn from_runtime_code(code: Bytes) -> Self {
        let mut db = CacheDB::new(EmptyDB::default());
        db.insert_account_info(VERIFIER, AccountInfo::from_bytecode(Bytecode::new_raw(code)));
        db.insert_account_info(CALLER, AccountInfo::from_balance(U256::from(10u64).pow(U256::from(24u64))));
        Self { db }
    }

    /// Calls `step(pre, proof)`; the state is never committed, so calls are independent.
    ///
    /// # Errors
    /// Only harness failures; a revert is a normal [`EvmStep::Reverted`] result.
    pub fn step(&self, pre: &MachineCommitment, proof: &StepProof) -> Result<EvmStep, DiffError> {
        let calldata = IOneStepVM::stepCall { pre: pre.clone(), proof: proof.clone() }.abi_encode();
        let mut evm = Context::mainnet().with_db(self.db.clone()).build_mainnet();
        let tx =
            TxEnv::builder().caller(CALLER).call(VERIFIER).data(calldata.into()).gas_limit(16_000_000).build_fill();
        let result = evm.transact(tx).map_err(|e| DiffError::Evm(format!("{e:?}")))?.result;
        let gas = result.tx_gas_used();
        match result {
            ExecutionResult::Success { output, .. } => {
                let data = output.into_data();
                let post =
                    IOneStepVM::stepCall::abi_decode_returns(&data).map_err(|e| DiffError::Decode(e.to_string()))?;
                Ok(EvmStep::Ok { post, gas })
            }
            ExecutionResult::Revert { output, .. } => Ok(EvmStep::Reverted { data: output }),
            ExecutionResult::Halt { reason, .. } => Err(DiffError::Evm(format!("halted: {reason:?}"))),
        }
    }
}
