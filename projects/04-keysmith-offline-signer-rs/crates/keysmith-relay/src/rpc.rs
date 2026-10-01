// SPDX-License-Identifier: MIT
//! A minimal, blocking Ethereum JSON-RPC client.
//!
//! The wire is abstracted behind [`Transport`] so that everything above it (quantity parsing,
//! error mapping, `prepare`, `broadcast`) is unit-tested against canned responses, while
//! [`HttpTransport`] (ureq) is exercised end to end against anvil.

use crate::error::RelayError;
use keysmith_core::quantity::{u64_str, u128_str};
use keysmith_core::{Address, U256, hex};
use serde_json::{Value, json};
use std::cell::Cell;
use std::time::Duration;

/// Sends one JSON-RPC request object and returns the response object.
pub trait Transport {
    /// Posts `request` and returns the decoded JSON response.
    fn post(&self, request: &Value) -> Result<Value, RelayError>;
}

impl<F> Transport for F
where
    F: Fn(&Value) -> Result<Value, RelayError>,
{
    fn post(&self, request: &Value) -> Result<Value, RelayError> {
        self(request)
    }
}

/// JSON-RPC over HTTP(S) with a global per-request timeout.
pub struct HttpTransport {
    agent: ureq::Agent,
    url: String,
}

impl HttpTransport {
    /// Creates a transport for `url` (`http://` or `https://`).
    pub fn new(url: &str, timeout: Duration) -> Result<Self, RelayError> {
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(RelayError::Input(
                "RPC URL must start with http:// or https://".into(),
            ));
        }
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .build();
        Ok(Self {
            agent: config.into(),
            url: url.to_owned(),
        })
    }
}

impl Transport for HttpTransport {
    fn post(&self, request: &Value) -> Result<Value, RelayError> {
        let mut response = self
            .agent
            .post(&self.url)
            .send_json(request)
            .map_err(|e| RelayError::Transport(e.to_string()))?;
        response
            .body_mut()
            .read_json::<Value>()
            .map_err(|e| RelayError::Transport(e.to_string()))
    }
}

/// A mined transaction receipt (the fields Keysmith reports and asserts on).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    /// Transaction hash.
    pub transaction_hash: String,
    /// `true` if execution succeeded (`status == 0x1`).
    pub status: bool,
    /// EIP-2718 type byte (`0` for legacy).
    #[serde(rename = "type")]
    pub tx_type: u8,
    /// Sender.
    pub from: Address,
    /// Recipient (`None` for contract creation).
    pub to: Option<Address>,
    /// Deployed contract, for creations.
    pub contract_address: Option<Address>,
    /// Gas consumed by this transaction.
    #[serde(with = "u64_str")]
    pub gas_used: u64,
    /// Price paid per gas.
    #[serde(with = "u128_str")]
    pub effective_gas_price: u128,
    /// Block that included the transaction.
    #[serde(with = "u64_str")]
    pub block_number: u64,
}

fn bad(method: &'static str, reason: impl Into<String>) -> RelayError {
    RelayError::BadResponse {
        method,
        reason: reason.into(),
    }
}

/// Parses a `0x`-hex quantity.
pub fn quantity(method: &'static str, v: &Value) -> Result<U256, RelayError> {
    let s = v
        .as_str()
        .filter(|s| s.starts_with("0x"))
        .ok_or_else(|| bad(method, "expected a 0x-hex quantity"))?;
    U256::parse(s).map_err(|e| bad(method, e.to_string()))
}

fn quantity_u64(method: &'static str, v: &Value) -> Result<u64, RelayError> {
    quantity(method, v)?
        .to_u64()
        .ok_or_else(|| bad(method, "quantity does not fit in 64 bits"))
}

fn quantity_u128(method: &'static str, v: &Value) -> Result<u128, RelayError> {
    quantity(method, v)?
        .to_u128()
        .ok_or_else(|| bad(method, "quantity does not fit in 128 bits"))
}

fn data(method: &'static str, v: &Value) -> Result<Vec<u8>, RelayError> {
    let s = v
        .as_str()
        .ok_or_else(|| bad(method, "expected 0x-hex data"))?;
    hex::decode(s).map_err(|e| bad(method, e.to_string()))
}

fn address_field(
    method: &'static str,
    v: &Value,
    field: &str,
) -> Result<Option<Address>, RelayError> {
    match v.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Address::parse(s)
            .map(Some)
            .map_err(|e| bad(method, format!("{field}: {e}"))),
        Some(_) => Err(bad(method, format!("{field} must be a string"))),
    }
}

fn parse_receipt(v: &Value) -> Result<Receipt, RelayError> {
    const M: &str = "eth_getTransactionReceipt";
    let field = |name: &str| v.get(name).ok_or_else(|| bad(M, format!("missing {name}")));
    let status = quantity_u64(M, field("status")?)?;
    // Pre-Byzantium receipts have no status; every node Keysmith targets reports it.
    let tx_type = quantity(M, field("type")?)?
        .to_u64()
        .and_then(|t| u8::try_from(t).ok())
        .ok_or_else(|| bad(M, "type does not fit in a byte"))?;
    Ok(Receipt {
        transaction_hash: field("transactionHash")?
            .as_str()
            .ok_or_else(|| bad(M, "transactionHash must be a string"))?
            .to_ascii_lowercase(),
        status: status == 1,
        tx_type,
        from: address_field(M, v, "from")?.ok_or_else(|| bad(M, "missing from"))?,
        to: address_field(M, v, "to")?,
        contract_address: address_field(M, v, "contractAddress")?,
        gas_used: quantity_u64(M, field("gasUsed")?)?,
        effective_gas_price: quantity_u128(M, field("effectiveGasPrice")?)?,
        block_number: quantity_u64(M, field("blockNumber")?)?,
    })
}

/// Typed wrappers around the handful of RPC methods Keysmith needs.
pub struct RpcClient<T> {
    transport: T,
    next_id: Cell<u64>,
}

impl<T: Transport> RpcClient<T> {
    /// Wraps a transport.
    pub fn new(transport: T) -> Self {
        Self {
            transport,
            next_id: Cell::new(1),
        }
    }

    /// Performs one call and returns its `result`, mapping JSON-RPC error objects.
    pub fn request(&self, method: &'static str, params: Value) -> Result<Value, RelayError> {
        let id = self.next_id.get();
        self.next_id.set(id.wrapping_add(1));
        let response = self.transport.post(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        }))?;
        if let Some(err) = response.get("error") {
            return Err(RelayError::Rpc {
                code: err.get("code").and_then(Value::as_i64).unwrap_or(0),
                message: err
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("(no message)")
                    .to_owned(),
            });
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| bad(method, "response has neither result nor error"))
    }

    /// `eth_chainId`.
    pub fn chain_id(&self) -> Result<u64, RelayError> {
        quantity_u64("eth_chainId", &self.request("eth_chainId", json!([]))?)
    }

    /// `eth_getTransactionCount(address, "pending")`.
    pub fn pending_nonce(&self, address: &Address) -> Result<u64, RelayError> {
        let v = self.request(
            "eth_getTransactionCount",
            json!([hex::encode_prefixed(&address.0), "pending"]),
        )?;
        quantity_u64("eth_getTransactionCount", &v)
    }

    /// `eth_gasPrice`.
    pub fn gas_price(&self) -> Result<u128, RelayError> {
        quantity_u128("eth_gasPrice", &self.request("eth_gasPrice", json!([]))?)
    }

    /// `eth_maxPriorityFeePerGas`.
    pub fn max_priority_fee_per_gas(&self) -> Result<u128, RelayError> {
        let v = self.request("eth_maxPriorityFeePerGas", json!([]))?;
        quantity_u128("eth_maxPriorityFeePerGas", &v)
    }

    /// `baseFeePerGas` of the latest block (`None` on pre-London chains).
    pub fn latest_base_fee(&self) -> Result<Option<u128>, RelayError> {
        const M: &str = "eth_getBlockByNumber";
        let block = self.request(M, json!(["latest", false]))?;
        match block.get("baseFeePerGas") {
            None | Some(Value::Null) => Ok(None),
            Some(v) => quantity_u128(M, v).map(Some),
        }
    }

    /// `eth_estimateGas(call)`.
    pub fn estimate_gas(&self, call: &Value) -> Result<u64, RelayError> {
        let v = self.request("eth_estimateGas", json!([call]))?;
        quantity_u64("eth_estimateGas", &v)
    }

    /// `eth_sendRawTransaction(raw)`; returns the hash the node reports (lowercase).
    pub fn send_raw_transaction(&self, raw: &str) -> Result<String, RelayError> {
        const M: &str = "eth_sendRawTransaction";
        let v = self.request(M, json!([raw]))?;
        let hash = v
            .as_str()
            .ok_or_else(|| bad(M, "expected a transaction hash"))?;
        hex::decode_array::<32>(hash).map_err(|e| bad(M, e.to_string()))?;
        Ok(hash.to_ascii_lowercase())
    }

    /// `eth_getTransactionReceipt(hash)` (`None` while pending).
    pub fn receipt(&self, hash: &str) -> Result<Option<Receipt>, RelayError> {
        let v = self.request("eth_getTransactionReceipt", json!([hash]))?;
        if v.is_null() {
            return Ok(None);
        }
        parse_receipt(&v).map(Some)
    }

    /// `eth_getBalance(address, "latest")`.
    pub fn balance(&self, address: &Address) -> Result<U256, RelayError> {
        let v = self.request(
            "eth_getBalance",
            json!([hex::encode_prefixed(&address.0), "latest"]),
        )?;
        quantity("eth_getBalance", &v)
    }

    /// `eth_getCode(address, "latest")`.
    pub fn code(&self, address: &Address) -> Result<Vec<u8>, RelayError> {
        let v = self.request(
            "eth_getCode",
            json!([hex::encode_prefixed(&address.0), "latest"]),
        )?;
        data("eth_getCode", &v)
    }

    /// `eth_getStorageAt(address, slot, "latest")`.
    pub fn storage_at(&self, address: &Address, slot: &U256) -> Result<[u8; 32], RelayError> {
        const M: &str = "eth_getStorageAt";
        let v = self.request(
            M,
            json!([
                hex::encode_prefixed(&address.0),
                slot.to_hex_quantity(),
                "latest"
            ]),
        )?;
        let bytes = data(M, &v)?;
        <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| bad(M, "expected 32 bytes"))
    }

    /// `eth_call({to, data}, "latest")`.
    pub fn call(&self, to: &Address, input: &[u8]) -> Result<Vec<u8>, RelayError> {
        let v = self.request(
            "eth_call",
            json!([
                {"to": hex::encode_prefixed(&to.0), "data": hex::encode_prefixed(input)},
                "latest"
            ]),
        )?;
        data("eth_call", &v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn client(result: Value) -> RpcClient<impl Fn(&Value) -> Result<Value, RelayError>> {
        RpcClient::new(move |req: &Value| {
            assert_eq!(req["jsonrpc"], "2.0");
            Ok(json!({"jsonrpc": "2.0", "id": req["id"], "result": result.clone()}))
        })
    }

    #[test]
    fn quantities_and_errors() {
        assert_eq!(client(json!("0x7a69")).chain_id().unwrap(), 31_337);
        assert!(matches!(
            client(json!("7a69")).chain_id(),
            Err(RelayError::BadResponse { .. })
        ));
        assert!(matches!(
            client(json!("0x10000000000000000")).chain_id(),
            Err(RelayError::BadResponse { .. })
        ));
        let err = RpcClient::new(|_: &Value| {
            Ok(json!({"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "nonce too low"}}))
        })
        .gas_price()
        .unwrap_err();
        assert_eq!(
            err.to_string(),
            "node returned JSON-RPC error -32000: nonce too low"
        );
        let empty = RpcClient::new(|_: &Value| Ok(json!({"jsonrpc": "2.0", "id": 1})));
        assert!(matches!(
            empty.gas_price(),
            Err(RelayError::BadResponse { .. })
        ));
    }

    #[test]
    fn request_ids_increase() {
        let seen = std::cell::RefCell::new(Vec::new());
        let rpc = RpcClient::new(|req: &Value| {
            seen.borrow_mut().push(req["id"].as_u64().unwrap());
            Ok(json!({"result": "0x1"}))
        });
        rpc.chain_id().unwrap();
        rpc.chain_id().unwrap();
        assert_eq!(*seen.borrow(), [1, 2]);
    }

    #[test]
    fn typed_wrappers() {
        assert_eq!(
            client(json!({"baseFeePerGas": "0x3b9aca00"}))
                .latest_base_fee()
                .unwrap(),
            Some(1_000_000_000)
        );
        assert_eq!(
            client(json!({"number": "0x1"})).latest_base_fee().unwrap(),
            None
        );
        assert_eq!(
            client(json!("0x5208")).estimate_gas(&json!({})).unwrap(),
            21_000
        );
        assert_eq!(
            client(json!("0x0102")).code(&Address::ZERO).unwrap(),
            [1, 2]
        );
        assert_eq!(
            client(json!("0x10")).balance(&Address::ZERO).unwrap(),
            U256::from_u64(16)
        );
        let word = format!("0x{}", "00".repeat(31) + "2a");
        assert_eq!(
            client(json!(word))
                .storage_at(&Address::ZERO, &U256::ZERO)
                .unwrap()[31],
            0x2a
        );
        assert!(
            client(json!("0x01"))
                .storage_at(&Address::ZERO, &U256::ZERO)
                .is_err()
        );
        assert_eq!(
            client(json!("0xabcd")).call(&Address::ZERO, &[]).unwrap(),
            [0xab, 0xcd]
        );
        assert_eq!(client(Value::Null).receipt("0x00").unwrap(), None);
        let hash = format!("0x{}", "AB".repeat(32));
        assert_eq!(
            client(json!(hash)).send_raw_transaction("0x").unwrap(),
            hash.to_ascii_lowercase()
        );
        assert!(client(json!("0x1234")).send_raw_transaction("0x").is_err());
        assert_eq!(
            client(json!("0x3b9aca00"))
                .max_priority_fee_per_gas()
                .unwrap(),
            1_000_000_000
        );
        assert_eq!(
            client(json!("0x2")).pending_nonce(&Address::ZERO).unwrap(),
            2
        );
    }

    #[test]
    fn receipts_parse() {
        let r = client(json!({
            "transactionHash": format!("0x{}", "CD".repeat(32)),
            "status": "0x1",
            "type": "0x4",
            "from": "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
            "to": null,
            "contractAddress": "0x5fbdb2315678afecb367f032d93f642f64180aa3",
            "gasUsed": "0xa410",
            "effectiveGasPrice": "0x3b9aca07",
            "blockNumber": "0x3"
        }))
        .receipt("0x")
        .unwrap()
        .unwrap();
        assert!(r.status);
        assert_eq!(r.tx_type, 4);
        assert_eq!(r.transaction_hash, format!("0x{}", "cd".repeat(32)));
        assert_eq!(r.to, None);
        assert_eq!(
            r.contract_address.unwrap().to_checksum(),
            "0x5FbDB2315678afecb367f032d93F642f64180aa3"
        );
        assert_eq!((r.gas_used, r.block_number), (42_000, 3));
        let failed = client(
            json!({"transactionHash": "0x00", "status": "0x0", "type": "0x0",
            "from": "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", "to": 7,
            "gasUsed": "0x1", "effectiveGasPrice": "0x1", "blockNumber": "0x1"}),
        )
        .receipt("0x");
        assert!(
            matches!(failed, Err(RelayError::BadResponse { .. })),
            "non-string `to` is rejected"
        );
        let no_status = client(json!({"transactionHash": "0x00"})).receipt("0x");
        assert!(matches!(no_status, Err(RelayError::BadResponse { .. })));
    }

    #[test]
    fn http_transport_validates_url() {
        assert!(HttpTransport::new("ftp://x", Duration::from_secs(1)).is_err());
        assert!(HttpTransport::new("http://127.0.0.1:1", Duration::from_secs(1)).is_ok());
    }
}
