// SPDX-License-Identifier: MIT
//! Building `keysmith/unsigned-tx@1` envelopes from live chain state.
//!
//! Everything the offline signer needs but cannot know is filled in here: chain id, account
//! nonce, fee parameters and the gas limit. Values the operator passes explicitly always win
//! over node-provided ones, and the result is validated with the same
//! [`TxRequest::to_transaction`] the signer will run, so a malformed envelope is caught before
//! it is carried across the air gap.
//!
//! EIP-7702 gas is not estimated: the authorizations the sender signs for itself only exist
//! after the offline step, and an estimate without the delegation in place measures the wrong
//! code. The operator must pass an explicit gas limit (the signer still enforces the intrinsic
//! minimum, including 25 000 gas per authorization).

use crate::error::RelayError;
use crate::rpc::{RpcClient, Transport};
use keysmith_core::authorization::SignedAuthorization;
use keysmith_core::envelope::{SelfAuthorization, TxRequest, UNSIGNED_FORMAT, UnsignedEnvelope};
use keysmith_core::tx::{AccessListItem, TxType};
use keysmith_core::{Address, U256, hex};
use serde_json::{Value, json};

/// What the operator wants to send. `None` fields are filled from the node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrepareRequest {
    /// Envelope type.
    pub tx_type: TxType,
    /// Sender (the offline key's address).
    pub from: Address,
    /// Recipient; `None` deploys a contract.
    pub to: Option<Address>,
    /// Value in wei.
    pub value: U256,
    /// Calldata or initcode.
    pub input: Vec<u8>,
    /// EIP-2930 access list.
    pub access_list: Vec<AccessListItem>,
    /// Authorizations already signed by other authorities (sponsored EIP-7702).
    pub authorizations: Vec<SignedAuthorization>,
    /// Delegations the sender will sign offline for itself (nonce = tx nonce + 1).
    pub self_authorizations: Vec<SelfAuthorization>,
    /// Explicit nonce (default: the node's pending nonce).
    pub nonce: Option<u64>,
    /// Explicit gas limit (default: `eth_estimateGas`; mandatory for EIP-7702).
    pub gas_limit: Option<u64>,
    /// Legacy / EIP-2930 gas price (default: `eth_gasPrice`).
    pub gas_price: Option<u128>,
    /// Fee cap (default: `2 * baseFee + tip`).
    pub max_fee_per_gas: Option<u128>,
    /// Tip cap (default: `eth_maxPriorityFeePerGas`).
    pub max_priority_fee_per_gas: Option<u128>,
    /// Abort unless the node serves this chain.
    pub expected_chain_id: Option<u64>,
    /// `false` produces a pre-EIP-155 legacy transaction (replayable on every chain).
    pub replay_protected: bool,
    /// Free-form note shown by the signer.
    pub note: Option<String>,
}

impl PrepareRequest {
    /// A request with every optional field unset.
    pub fn new(tx_type: TxType, from: Address, to: Option<Address>) -> Self {
        Self {
            tx_type,
            from,
            to,
            value: U256::ZERO,
            input: Vec::new(),
            access_list: Vec::new(),
            authorizations: Vec::new(),
            self_authorizations: Vec::new(),
            nonce: None,
            gas_limit: None,
            gas_price: None,
            max_fee_per_gas: None,
            max_priority_fee_per_gas: None,
            expected_chain_id: None,
            replay_protected: true,
            note: None,
        }
    }

    fn check_shape(&self) -> Result<(), RelayError> {
        let ty = self.tx_type;
        let fail = |m: &str| Err(RelayError::Input(format!("{ty} transactions {m}")));
        if ty != TxType::Legacy && !self.replay_protected {
            return fail("are always replay-protected (only legacy can omit the chain id)");
        }
        if ty != TxType::Eip7702
            && (!self.authorizations.is_empty() || !self.self_authorizations.is_empty())
        {
            return fail("cannot carry EIP-7702 authorizations");
        }
        if ty == TxType::Eip7702 {
            if self.to.is_none() {
                return fail("cannot create contracts");
            }
            if self.gas_limit.is_none() {
                return fail(
                    "need an explicit gas limit: the delegation does not exist until the \
                     authorizations are signed offline, so eth_estimateGas would measure the wrong code",
                );
            }
        }
        if ty == TxType::Legacy && !self.access_list.is_empty() {
            return fail("cannot carry an access list");
        }
        let typed_fees = self.max_fee_per_gas.is_some() || self.max_priority_fee_per_gas.is_some();
        match ty {
            TxType::Legacy | TxType::Eip2930 if typed_fees => {
                fail("use a gas price, not max fee / priority fee")
            }
            TxType::Eip1559 | TxType::Eip7702 if self.gas_price.is_some() => {
                fail("use max fee / priority fee, not a gas price")
            }
            _ => Ok(()),
        }
    }

    fn estimate_call(&self) -> Value {
        let mut call = json!({
            "from": hex::encode_prefixed(&self.from.0),
            "value": self.value.to_hex_quantity(),
            "data": hex::encode_prefixed(&self.input),
        });
        if let Some(to) = &self.to {
            call["to"] = json!(hex::encode_prefixed(&to.0));
        }
        if !self.access_list.is_empty() {
            call["accessList"] = json!(self.access_list);
        }
        call
    }
}

/// Fills in chain state and returns a validated unsigned envelope.
pub fn prepare<T: Transport>(
    rpc: &RpcClient<T>,
    req: &PrepareRequest,
) -> Result<UnsignedEnvelope, RelayError> {
    req.check_shape()?;
    let chain_id = rpc.chain_id()?;
    if let Some(expected) = req.expected_chain_id
        && expected != chain_id
    {
        return Err(RelayError::Input(format!(
            "the node serves chain {chain_id}, not the expected chain {expected}"
        )));
    }
    let nonce = match req.nonce {
        Some(n) => n,
        None => rpc.pending_nonce(&req.from)?,
    };
    let (gas_price, max_fee_per_gas, max_priority_fee_per_gas) = match req.tx_type {
        TxType::Legacy | TxType::Eip2930 => {
            let price = match req.gas_price {
                Some(p) => p,
                None => rpc.gas_price()?,
            };
            (Some(price), None, None)
        }
        TxType::Eip1559 | TxType::Eip7702 => {
            let tip = match req.max_priority_fee_per_gas {
                Some(t) => t,
                None => rpc.max_priority_fee_per_gas()?,
            };
            let cap = match req.max_fee_per_gas {
                Some(c) => c,
                None => {
                    let base = rpc.latest_base_fee()?.ok_or_else(|| {
                        RelayError::Input(
                            "the node reports no base fee (pre-London chain?); use a legacy \
                             transaction or pass an explicit max fee"
                                .into(),
                        )
                    })?;
                    base.checked_mul(2)
                        .and_then(|b| b.checked_add(tip))
                        .ok_or_else(|| RelayError::Input("fee cap overflows u128".into()))?
                }
            };
            (None, Some(cap), Some(tip))
        }
    };
    let gas_limit = match req.gas_limit {
        Some(g) => g,
        None => rpc.estimate_gas(&req.estimate_call())?,
    };
    let tx = TxRequest {
        tx_type: req.tx_type,
        chain_id: req.replay_protected.then_some(chain_id),
        nonce,
        gas_limit,
        gas_price,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        to: Some(req.to),
        value: req.value,
        input: req.input.clone(),
        access_list: req.access_list.clone(),
        authorization_list: req.authorizations.clone(),
    };
    // Same conversion the signer performs: catch schema errors before the air gap.
    tx.to_transaction()?;
    Ok(UnsignedEnvelope {
        format: UNSIGNED_FORMAT.into(),
        from: Some(req.from),
        tx,
        self_authorizations: req.self_authorizations.clone(),
        note: req.note.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    const FROM: Address = Address([0xf3; 20]);
    const TO: Address = Address([0x70; 20]);

    /// A node with fixed answers that records every method called.
    fn node(
        log: &RefCell<Vec<String>>,
    ) -> RpcClient<impl Fn(&Value) -> Result<Value, RelayError> + '_> {
        RpcClient::new(move |req: &Value| {
            let method = req["method"].as_str().unwrap().to_owned();
            let result = match method.as_str() {
                "eth_chainId" => json!("0x7a69"),
                "eth_getTransactionCount" => {
                    assert_eq!(req["params"][1], "pending");
                    json!("0x5")
                }
                "eth_gasPrice" => json!("0x77359400"),
                "eth_maxPriorityFeePerGas" => json!("0x3b9aca00"),
                "eth_getBlockByNumber" => json!({"baseFeePerGas": "0x3b9aca00"}),
                "eth_estimateGas" => {
                    assert_eq!(req["params"][0]["from"], hex::encode_prefixed(&FROM.0));
                    json!("0x5208")
                }
                other => panic!("unexpected call {other}"),
            };
            log.borrow_mut().push(method);
            Ok(json!({"jsonrpc": "2.0", "id": req["id"], "result": result}))
        })
    }

    #[test]
    fn eip1559_defaults_come_from_the_node() {
        let log = RefCell::new(Vec::new());
        let mut req = PrepareRequest::new(TxType::Eip1559, FROM, Some(TO));
        req.value = U256::from_u64(7);
        let env = prepare(&node(&log), &req).unwrap();
        assert_eq!(env.tx.chain_id, Some(31_337));
        assert_eq!(env.tx.nonce, 5);
        assert_eq!(env.tx.max_priority_fee_per_gas, Some(1_000_000_000));
        assert_eq!(
            env.tx.max_fee_per_gas,
            Some(3_000_000_000),
            "2 * base + tip"
        );
        assert_eq!(env.tx.gas_limit, 21_000);
        assert_eq!(env.from, Some(FROM));
        assert_eq!(
            *log.borrow(),
            [
                "eth_chainId",
                "eth_getTransactionCount",
                "eth_maxPriorityFeePerGas",
                "eth_getBlockByNumber",
                "eth_estimateGas"
            ]
        );
    }

    #[test]
    fn explicit_values_skip_the_node() {
        let log = RefCell::new(Vec::new());
        let mut req = PrepareRequest::new(TxType::Eip2930, FROM, None);
        req.nonce = Some(9);
        req.gas_limit = Some(90_000);
        req.gas_price = Some(3);
        req.input = vec![0x60, 0x00];
        req.note = Some("deploy".into());
        let env = prepare(&node(&log), &req).unwrap();
        assert_eq!(*log.borrow(), ["eth_chainId"]);
        assert_eq!(
            (env.tx.nonce, env.tx.gas_limit, env.tx.gas_price),
            (9, 90_000, Some(3))
        );
        assert_eq!(env.tx.to, Some(None), "contract creation is explicit");
        assert_eq!(env.note.as_deref(), Some("deploy"));
    }

    #[test]
    fn legacy_uses_gas_price_and_may_drop_replay_protection() {
        let log = RefCell::new(Vec::new());
        let mut req = PrepareRequest::new(TxType::Legacy, FROM, Some(TO));
        req.replay_protected = false;
        let env = prepare(&node(&log), &req).unwrap();
        assert_eq!(env.tx.chain_id, None);
        assert_eq!(env.tx.gas_price, Some(2_000_000_000));
    }

    #[test]
    fn shape_errors_are_reported_before_any_rpc_call() {
        let log = RefCell::new(Vec::new());
        let rpc = node(&log);
        let mut r = PrepareRequest::new(TxType::Eip1559, FROM, Some(TO));
        r.replay_protected = false;
        assert!(
            prepare(&rpc, &r)
                .unwrap_err()
                .to_string()
                .contains("replay-protected")
        );
        let mut r = PrepareRequest::new(TxType::Eip1559, FROM, Some(TO));
        r.self_authorizations.push(SelfAuthorization {
            chain_id: U256::ONE,
            address: TO,
        });
        assert!(
            prepare(&rpc, &r)
                .unwrap_err()
                .to_string()
                .contains("authorizations")
        );
        let r = PrepareRequest::new(TxType::Eip7702, FROM, None);
        assert!(
            prepare(&rpc, &r)
                .unwrap_err()
                .to_string()
                .contains("cannot create")
        );
        let r = PrepareRequest::new(TxType::Eip7702, FROM, Some(TO));
        assert!(
            prepare(&rpc, &r)
                .unwrap_err()
                .to_string()
                .contains("explicit gas limit")
        );
        let mut r = PrepareRequest::new(TxType::Legacy, FROM, Some(TO));
        r.access_list.push(AccessListItem {
            address: TO,
            storage_keys: vec![],
        });
        assert!(
            prepare(&rpc, &r)
                .unwrap_err()
                .to_string()
                .contains("access list")
        );
        let mut r = PrepareRequest::new(TxType::Legacy, FROM, Some(TO));
        r.max_fee_per_gas = Some(1);
        assert!(
            prepare(&rpc, &r)
                .unwrap_err()
                .to_string()
                .contains("gas price")
        );
        let mut r = PrepareRequest::new(TxType::Eip1559, FROM, Some(TO));
        r.gas_price = Some(1);
        assert!(
            prepare(&rpc, &r)
                .unwrap_err()
                .to_string()
                .contains("max fee")
        );
        assert!(log.borrow().is_empty());
    }

    #[test]
    fn chain_and_base_fee_guards() {
        let log = RefCell::new(Vec::new());
        let mut r = PrepareRequest::new(TxType::Eip1559, FROM, Some(TO));
        r.expected_chain_id = Some(1);
        assert!(
            prepare(&node(&log), &r)
                .unwrap_err()
                .to_string()
                .contains("not the expected chain 1")
        );
        let pre_london = RpcClient::new(|req: &Value| {
            let result = match req["method"].as_str().unwrap() {
                "eth_chainId" => json!("0x1"),
                "eth_getTransactionCount" | "eth_maxPriorityFeePerGas" => json!("0x0"),
                _ => json!({"number": "0x1"}),
            };
            Ok(json!({"result": result}))
        });
        let r = PrepareRequest::new(TxType::Eip1559, FROM, Some(TO));
        assert!(
            prepare(&pre_london, &r)
                .unwrap_err()
                .to_string()
                .contains("no base fee")
        );
    }

    #[test]
    fn eip7702_with_sponsored_and_self_authorizations() {
        let log = RefCell::new(Vec::new());
        let mut r = PrepareRequest::new(TxType::Eip7702, FROM, Some(TO));
        r.gas_limit = Some(100_000);
        r.authorizations.push(SignedAuthorization {
            chain_id: U256::from_u64(31_337),
            address: TO,
            nonce: 0,
            y_parity: 1,
            r: U256::ONE,
            s: U256::ONE,
        });
        r.self_authorizations.push(SelfAuthorization {
            chain_id: U256::from_u64(31_337),
            address: TO,
        });
        let env = prepare(&node(&log), &r).unwrap();
        assert_eq!(env.tx.authorization_list.len(), 1);
        assert_eq!(env.self_authorizations.len(), 1);
        assert!(!log.borrow().contains(&"eth_estimateGas".to_owned()));
    }
}
