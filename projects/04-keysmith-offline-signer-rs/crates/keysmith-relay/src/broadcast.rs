// SPDX-License-Identifier: MIT
//! Broadcasting `keysmith/signed-tx@1` envelopes.
//!
//! The online machine is not trusted to have carried the envelope faithfully, and the node is
//! not trusted to be on the right chain. Before `eth_sendRawTransaction`:
//!
//! 1. the raw bytes are strictly decoded and the envelope's `type`, `hash` and `from` are
//!    recomputed from them ([`SignedEnvelope::verify`]);
//! 2. the transaction's chain id must equal the node's `eth_chainId` (pre-EIP-155 legacy
//!    transactions have none and are reported as replayable);
//! 3. the hash the node returns must equal the one recomputed offline.

use crate::error::RelayError;
use crate::rpc::{Receipt, RpcClient, Transport};
use keysmith_core::envelope::SignedEnvelope;
use keysmith_core::tx::TxType;
use keysmith_core::{Address, hex};
use std::time::{Duration, Instant};

/// What was sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BroadcastOutcome {
    /// Transaction hash (confirmed by the node).
    pub hash: String,
    /// Recovered sender.
    pub signer: Address,
    /// Envelope type.
    pub tx_type: TxType,
    /// Chain id (`None` for pre-EIP-155 legacy).
    pub chain_id: Option<u64>,
}

/// Verifies `env` offline, checks the node's chain and submits the transaction.
pub fn broadcast<T: Transport>(
    rpc: &RpcClient<T>,
    env: &SignedEnvelope,
) -> Result<BroadcastOutcome, RelayError> {
    let signed = env.verify()?;
    let node_chain = rpc.chain_id()?;
    let chain_id = signed.tx.chain_id();
    if let Some(id) = chain_id
        && id != node_chain
    {
        return Err(RelayError::ChainMismatch {
            envelope: id,
            node: node_chain,
        });
    }
    let expected = hex::encode_prefixed(&signed.hash());
    let returned = rpc.send_raw_transaction(&hex::encode_prefixed(&signed.encoded()))?;
    if returned != expected {
        return Err(RelayError::HashMismatch {
            expected,
            node: returned,
        });
    }
    Ok(BroadcastOutcome {
        hash: expected,
        signer: env.from,
        tx_type: signed.tx.tx_type(),
        chain_id,
    })
}

/// Polls `eth_getTransactionReceipt` until the transaction is mined or `timeout` elapses.
pub fn wait_for_receipt<T: Transport>(
    rpc: &RpcClient<T>,
    hash: &str,
    timeout: Duration,
    poll: Duration,
) -> Result<Receipt, RelayError> {
    let start = Instant::now();
    loop {
        if let Some(receipt) = rpc.receipt(hash)? {
            return Ok(receipt);
        }
        if start.elapsed() >= timeout {
            return Err(RelayError::ReceiptTimeout {
                hash: hash.to_owned(),
                seconds: timeout.as_secs(),
            });
        }
        std::thread::sleep(poll);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use keysmith_core::PrivateKey;
    use keysmith_core::envelope::{UnsignedEnvelope, sign_envelope};
    use serde_json::{Value, json};
    use std::cell::{Cell, RefCell};

    fn signed_envelope(chain: u64) -> SignedEnvelope {
        let key = PrivateKey::from_bytes(&[0x11; 32]).unwrap();
        let env = UnsignedEnvelope::from_json_str(&format!(
            r#"{{"format":"keysmith/unsigned-tx@1","tx":{{"type":"eip1559","chainId":"{chain}","nonce":"0",
                "gasLimit":"21000","maxFeePerGas":"2","maxPriorityFeePerGas":"1",
                "to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":"1"}}}}"#
        ))
        .unwrap();
        sign_envelope(&env, &key, None).unwrap().envelope
    }

    fn node<'a>(
        chain: &'static str,
        sent: &'a RefCell<Vec<String>>,
        echo: Option<&'static str>,
    ) -> RpcClient<impl Fn(&Value) -> Result<Value, RelayError> + 'a> {
        RpcClient::new(move |req: &Value| {
            let result = match req["method"].as_str().unwrap() {
                "eth_chainId" => json!(chain),
                "eth_sendRawTransaction" => {
                    let raw = req["params"][0].as_str().unwrap().to_owned();
                    sent.borrow_mut().push(raw.clone());
                    let bytes = hex::decode(&raw).unwrap();
                    match echo {
                        Some(h) => json!(h),
                        None => json!(hex::encode_prefixed(&keysmith_core::hash::keccak256(
                            &bytes
                        ))),
                    }
                }
                other => panic!("unexpected {other}"),
            };
            Ok(json!({"result": result}))
        })
    }

    #[test]
    fn sends_verified_bytes_and_checks_the_hash() {
        let env = signed_envelope(31_337);
        let sent = RefCell::new(Vec::new());
        let out = broadcast(&node("0x7a69", &sent, None), &env).unwrap();
        assert_eq!(out.hash, env.hash);
        assert_eq!(out.chain_id, Some(31_337));
        assert_eq!(out.tx_type, TxType::Eip1559);
        assert_eq!(sent.borrow().as_slice(), std::slice::from_ref(&env.raw));
    }

    #[test]
    fn refuses_wrong_chain_and_tampered_envelopes_before_sending() {
        let sent = RefCell::new(Vec::new());
        let env = signed_envelope(1);
        assert!(matches!(
            broadcast(&node("0x7a69", &sent, None), &env),
            Err(RelayError::ChainMismatch {
                envelope: 1,
                node: 31_337
            })
        ));
        let mut forged = signed_envelope(31_337);
        forged.from = Address([9; 20]);
        assert!(matches!(
            broadcast(&node("0x7a69", &sent, None), &forged),
            Err(RelayError::Envelope(_))
        ));
        assert!(
            sent.borrow().is_empty(),
            "nothing reached eth_sendRawTransaction"
        );
    }

    #[test]
    fn detects_a_node_reporting_another_hash() {
        let sent = RefCell::new(Vec::new());
        let other = "0x1111111111111111111111111111111111111111111111111111111111111111";
        let err = broadcast(
            &node("0x7a69", &sent, Some(other)),
            &signed_envelope(31_337),
        )
        .unwrap_err();
        assert!(matches!(err, RelayError::HashMismatch { .. }));
    }

    #[test]
    fn waits_for_the_receipt_or_times_out() {
        let polls = Cell::new(0);
        let rpc = RpcClient::new(|_: &Value| {
            polls.set(polls.get() + 1);
            let result = if polls.get() < 3 {
                Value::Null
            } else {
                json!({"transactionHash": "0xaa", "status": "0x1", "type": "0x2",
                       "from": "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
                       "gasUsed": "0x5208", "effectiveGasPrice": "0x2", "blockNumber": "0x1"})
            };
            Ok(json!({"result": result}))
        });
        let receipt = wait_for_receipt(
            &rpc,
            "0xaa",
            Duration::from_secs(5),
            Duration::from_millis(1),
        )
        .unwrap();
        assert!(receipt.status);
        assert_eq!(polls.get(), 3);
        let never = RpcClient::new(|_: &Value| Ok(json!({"result": null})));
        let err =
            wait_for_receipt(&never, "0xbb", Duration::ZERO, Duration::from_millis(1)).unwrap_err();
        assert_eq!(err.to_string(), "no receipt for 0xbb after 0 s");
    }
}
