// SPDX-License-Identifier: MIT
//! End-to-end: networked DKG → threshold-signed withdrawal settled on anvil →
//! group-key rotation authorised by the current group → the retired key can
//! no longer move funds.
//!
//! Requires `anvil` on PATH and `forge build` artifacts in `contracts/out`.
//! Run with `cargo test -p e2e --features anvil -- --test-threads=1`.
#![cfg(feature = "anvil")]
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use alloy::{
    network::TransactionBuilder,
    node_bindings::Anvil,
    primitives::{Address, Bytes, U256, address},
    providers::{Provider, ProviderBuilder},
    rpc::types::TransactionRequest,
    signers::local::PrivateKeySigner,
    sol,
    sol_types::SolConstructor,
};
use custody_net::{cluster::LocalCluster, coordinator::Coordinator};
use custody_protocol::{
    intent::{self as custody_intent, CustodyAction, VaultDomain},
    keygen::{KeygenOutcome, group_key_bytes},
    messages::GroupKeyBytes,
    signing::SigningOutcome,
};
use frost_keccak::evm::{EvmGroupKey, EvmSignature};

sol! {
    #[sol(rpc)]
    contract SchnorrVault {
        struct WithdrawalIntent { address to; address token; uint256 amount; uint256 nonce; uint256 deadline; }
        struct KeyRotation { uint256 newPubKeyX; uint8 newPubKeyYParity; uint256 nonce; uint256 deadline; }
        struct Signature { address rAddr; uint256 z; }

        error InvalidSignature(bytes32 digest);

        constructor(uint256 pubKeyX, uint8 pubKeyYParity, address initialGuardian, address[] tokens, uint256[] limits);

        function withdraw(WithdrawalIntent intent, Signature signature) external;
        function rotateGroupKey(KeyRotation rotation, Signature currentKeySignature, Signature newKeySignature) external;
        function groupKey() external view returns (uint256 x, uint8 yParity, uint64 epoch);
        function hashWithdrawal(WithdrawalIntent intent) external view returns (bytes32);
        function hashKeyRotation(KeyRotation rotation) external view returns (bytes32);
        function isNonceUsed(uint256 nonce) external view returns (bool);
        function retiredKey(bytes32 keyId) external view returns (bool);
        function keyId(uint256 x, uint8 yParity) external pure returns (bytes32);
    }
}

const RECIPIENT: Address = address!("000000000000000000000000000000000000bEEF");
const ETHER: u128 = 1_000_000_000_000_000_000;

fn vault_bytecode() -> Bytes {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/out/SchnorrVault.sol/SchnorrVault.json");
    let json = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "{}: {e}. Run `forge build` in contracts/ first.",
            path.display()
        )
    });
    let artifact: serde_json::Value = serde_json::from_str(&json).unwrap();
    let object = artifact["bytecode"]["object"].as_str().unwrap();
    Bytes::from(alloy::hex::decode(object).unwrap())
}

fn signature(sig: &EvmSignature) -> SchnorrVault::Signature {
    SchnorrVault::Signature {
        rAddr: Address::from(sig.r_address),
        z: U256::from_be_bytes(sig.z),
    }
}

async fn dkg(
    coordinator: &mut Coordinator,
    ids: &[custody_protocol::ParticipantId],
) -> (GroupKeyBytes, EvmGroupKey) {
    match coordinator.dkg(3, ids).await.unwrap() {
        KeygenOutcome::Committed { public_key_package } => (
            group_key_bytes(&public_key_package).unwrap(),
            EvmGroupKey::from_verifying_key(public_key_package.verifying_key()).unwrap(),
        ),
        KeygenOutcome::Aborted(report) => panic!("DKG aborted: {report:?}"),
    }
}

async fn threshold_sign(
    coordinator: &mut Coordinator,
    group: GroupKeyBytes,
    action: CustodyAction,
    domain: VaultDomain,
) -> EvmSignature {
    let report = coordinator
        .sign_with_retry(group, action, domain)
        .await
        .unwrap();
    match report.outcome {
        SigningOutcome::Signed { evm, .. } => evm,
        SigningOutcome::Aborted(report) => panic!("signing aborted: {report:?}"),
    }
}

fn withdrawal_intent(nonce: u64, amount: u128, deadline: u64) -> custody_intent::WithdrawalIntent {
    custody_intent::WithdrawalIntent {
        to: RECIPIENT,
        token: Address::ZERO,
        amount: U256::from(amount),
        nonce: U256::from(nonce),
        deadline: U256::from(deadline),
    }
}

fn onchain_intent(i: &custody_intent::WithdrawalIntent) -> SchnorrVault::WithdrawalIntent {
    SchnorrVault::WithdrawalIntent {
        to: i.to,
        token: i.token,
        amount: i.amount,
        nonce: i.nonce,
        deadline: i.deadline,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dkg_sign_settle_and_rotate_on_anvil() {
    // Fresh chain on an OS-assigned port; dropped (and killed) at the end.
    let anvil = Anvil::new().try_spawn().expect("`anvil` must be on PATH");
    let relayer: PrivateKeySigner = anvil.keys()[0].clone().into();
    let deployer = relayer.address();
    let guardian = anvil.addresses()[1];
    let provider = ProviderBuilder::new()
        .wallet(relayer)
        .connect_http(anvil.endpoint_url());
    let chain_id = provider.get_chain_id().await.unwrap();

    // The signers pin the vault's EIP-712 domain, so the address is predicted
    // from the deployer's nonce before the DKG runs.
    let nonce = provider.get_transaction_count(deployer).await.unwrap();
    let vault_address = deployer.create(nonce);
    let domain = VaultDomain {
        chain_id,
        vault: vault_address,
    };

    // 1. Coordinator + 5 participants over loopback TCP; Pedersen DKG (3-of-5).
    let mut cluster = LocalCluster::start(5, domain, Duration::from_secs(10))
        .await
        .unwrap();
    let ids = cluster.ids();
    let (group_1, key_1) = dkg(&mut cluster.coordinator, &ids).await;

    // 2. Deploy the vault for the DKG's group key and fund it.
    let args = SchnorrVault::constructorCall {
        pubKeyX: U256::from_be_bytes(key_1.x),
        pubKeyYParity: key_1.y_parity,
        initialGuardian: guardian,
        tokens: vec![Address::ZERO],
        limits: vec![U256::from(10 * ETHER)],
    }
    .abi_encode();
    let deploy =
        TransactionRequest::default().with_deploy_code([vault_bytecode().to_vec(), args].concat());
    let receipt = provider
        .send_transaction(deploy)
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    assert_eq!(receipt.contract_address, Some(vault_address));
    let fund = TransactionRequest::default()
        .with_to(vault_address)
        .with_value(U256::from(5 * ETHER));
    assert!(
        provider
            .send_transaction(fund)
            .await
            .unwrap()
            .get_receipt()
            .await
            .unwrap()
            .status()
    );
    let vault = SchnorrVault::new(vault_address, &provider);
    let (x, parity, epoch) = {
        let k = vault.groupKey().call().await.unwrap();
        (k.x, k.yParity, k.epoch)
    };
    assert_eq!(
        (x, parity, epoch),
        (U256::from_be_bytes(key_1.x), key_1.y_parity, 0)
    );

    // 3. Threshold-sign a withdrawal and settle it.
    let deadline = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 3_600;
    let intent = withdrawal_intent(1, ETHER, deadline);
    let action = CustodyAction::Withdrawal(intent.clone());
    let digest = vault
        .hashWithdrawal(onchain_intent(&intent))
        .call()
        .await
        .unwrap();
    assert_eq!(
        digest.0,
        action.signing_hash(&domain),
        "Rust and Solidity EIP-712 digests agree"
    );
    let sig = threshold_sign(&mut cluster.coordinator, group_1, action, domain).await;
    let before = provider.get_balance(RECIPIENT).await.unwrap();
    let receipt = vault
        .withdraw(onchain_intent(&intent), signature(&sig))
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    assert_eq!(
        provider.get_balance(RECIPIENT).await.unwrap() - before,
        U256::from(ETHER)
    );
    assert!(vault.isNonceUsed(U256::from(1)).call().await.unwrap());

    // Replaying the same signed intent fails.
    assert!(
        vault
            .withdraw(onchain_intent(&intent), signature(&sig))
            .call()
            .await
            .is_err()
    );

    // 4. Second DKG (new group key), rotation signed by the current group and
    //    by the new group (proof of possession).
    let (group_2, key_2) = dkg(&mut cluster.coordinator, &ids).await;
    let rotation = custody_intent::rotation_to(&key_2, U256::from(2), U256::from(deadline));
    let rotation_action = CustodyAction::KeyRotation(rotation.clone());
    let by_current = threshold_sign(
        &mut cluster.coordinator,
        group_1,
        rotation_action.clone(),
        domain,
    )
    .await;
    let by_next = threshold_sign(
        &mut cluster.coordinator,
        group_2,
        rotation_action.clone(),
        domain,
    )
    .await;
    let onchain_rotation = SchnorrVault::KeyRotation {
        newPubKeyX: rotation.newPubKeyX,
        newPubKeyYParity: rotation.newPubKeyYParity,
        nonce: rotation.nonce,
        deadline: rotation.deadline,
    };
    assert_eq!(
        vault
            .hashKeyRotation(onchain_rotation.clone())
            .call()
            .await
            .unwrap()
            .0,
        rotation_action.signing_hash(&domain)
    );
    let receipt = vault
        .rotateGroupKey(
            onchain_rotation,
            signature(&by_current),
            signature(&by_next),
        )
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());
    let k = vault.groupKey().call().await.unwrap();
    assert_eq!(
        (k.x, k.yParity, k.epoch),
        (U256::from_be_bytes(key_2.x), key_2.y_parity, 1)
    );
    let old_id = vault
        .keyId(U256::from_be_bytes(key_1.x), key_1.y_parity)
        .call()
        .await
        .unwrap();
    assert!(vault.retiredKey(old_id).call().await.unwrap());

    // 5. The new group withdraws; the retired group cannot.
    let fresh = withdrawal_intent(3, ETHER / 2, deadline);
    let fresh_sig = threshold_sign(
        &mut cluster.coordinator,
        group_2,
        CustodyAction::Withdrawal(fresh.clone()),
        domain,
    )
    .await;
    let receipt = vault
        .withdraw(onchain_intent(&fresh), signature(&fresh_sig))
        .send()
        .await
        .unwrap()
        .get_receipt()
        .await
        .unwrap();
    assert!(receipt.status());

    let stale = withdrawal_intent(4, ETHER / 2, deadline);
    let stale_action = CustodyAction::Withdrawal(stale.clone());
    let stale_sig = threshold_sign(
        &mut cluster.coordinator,
        group_1,
        stale_action.clone(),
        domain,
    )
    .await;
    let Err(err) = vault
        .withdraw(onchain_intent(&stale), signature(&stale_sig))
        .call()
        .await
    else {
        panic!("the retired key must not authorise a withdrawal");
    };
    let decoded = err
        .as_decoded_error::<SchnorrVault::InvalidSignature>()
        .expect("InvalidSignature revert");
    assert_eq!(decoded.digest.0, stale_action.signing_hash(&domain));

    assert_eq!(
        provider.get_balance(RECIPIENT).await.unwrap() - before,
        U256::from(ETHER + ETHER / 2)
    );
    cluster.shutdown().await.unwrap();
    drop(anvil);
}
