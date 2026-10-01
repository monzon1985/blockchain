// SPDX-License-Identifier: MIT
//! The coordinator and every participant as separate OS processes, configured
//! from a static roster file and per-party key files. The coordinator binds an
//! OS-assigned port and publishes it through a file; participants exit when
//! the coordinator closes their connection. The address file starts out stale
//! (left by an earlier run), as it would on a second run of the README steps.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use alloy_primitives::{Address, U256};
use custody_protocol::intent::{CustodyAction, VaultDomain, WithdrawalIntent};
use frost_keccak::evm::{self, EvmGroupKey, EvmSignature};

/// Kills (by handle, i.e. by PID) and reaps a child process on drop.
struct Reaped(Child);

impl Drop for Reaped {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn scratch_dir() -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("frost-custody-mp-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn word<const N: usize>(v: &serde_json::Value) -> [u8; N] {
    let s = v.as_str().unwrap();
    hex::decode(s.trim_start_matches("0x"))
        .unwrap()
        .try_into()
        .unwrap()
}

#[test]
fn coordinator_and_participants_run_as_separate_processes() {
    let bin = env!("CARGO_BIN_EXE_frost-custody");
    let dir = scratch_dir();
    let status = Command::new(bin)
        .args(["roster", "--participants", "3", "--out"])
        .arg(&dir)
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    let roster = dir.join("roster.json");
    let addr_file = dir.join("coordinator.addr");
    // A previous coordinator's address: nothing listens there any more.
    let stale = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    std::fs::write(&addr_file, stale.local_addr().unwrap().to_string()).unwrap();
    drop(stale);

    let participants: Vec<Reaped> = (1..=3)
        .map(|i| {
            Reaped(
                Command::new(bin)
                    .arg("participant")
                    .arg("--roster")
                    .arg(&roster)
                    .arg("--key")
                    .arg(dir.join(format!("participant-{i}.key.json")))
                    .arg("--addr-file")
                    .arg(&addr_file)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            )
        })
        .collect();

    let output = Command::new(bin)
        .arg("coordinator")
        .arg("--roster")
        .arg(&roster)
        .arg("--key")
        .arg(dir.join("coordinator.key.json"))
        .args(["--threshold", "2", "--connect-timeout-secs", "60"])
        .arg("--addr-file")
        .arg(&addr_file)
        .stderr(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "coordinator failed");
    assert!(
        !addr_file.exists(),
        "the coordinator withdraws its address on exit"
    );
    let doc: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();

    // The printed signature verifies under the printed group key, over the
    // EIP-712 digest recomputed here from the printed intent and domain.
    let domain: VaultDomain = serde_json::from_value(doc["domain"].clone()).unwrap();
    let intent: WithdrawalIntent = serde_json::from_value(doc["intent"].clone()).unwrap();
    assert_eq!(intent.token, Address::ZERO);
    assert_eq!(intent.nonce, U256::from(1));
    let digest = CustodyAction::Withdrawal(intent).signing_hash(&domain);
    assert_eq!(word::<32>(&doc["digest"]), digest);
    let key = EvmGroupKey {
        x: word(&doc["groupKey"]["x"]),
        y_parity: u8::try_from(doc["groupKey"]["yParity"].as_u64().unwrap()).unwrap(),
    };
    let signature = EvmSignature {
        r_address: word(&doc["signature"]["rAddr"]),
        z: word(&doc["signature"]["z"]),
    };
    assert!(evm::verify(&key, &digest, &signature));
    assert_eq!(doc["signers"].as_array().unwrap().len(), 2);

    // Every participant exits cleanly once the coordinator is gone.
    let deadline = Instant::now() + Duration::from_secs(30);
    for mut p in participants {
        loop {
            if let Some(status) = p.0.try_wait().unwrap() {
                assert!(status.success(), "participant exited with {status}");
                break;
            }
            assert!(Instant::now() < deadline, "participant did not exit");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    std::fs::remove_dir_all(&dir).unwrap();
}
