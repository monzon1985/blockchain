// SPDX-License-Identifier: MIT
//! Keccak-256 helpers and the ERC-7201 namespace formula.

use ruint::aliases::U256;
use tiny_keccak::{Hasher, Keccak};

/// Keccak-256 of `data` (the Ethereum variant, not NIST SHA3-256).
pub fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    hasher.update(data);
    let mut out = [0u8; 32];
    hasher.finalize(&mut out);
    out
}

/// Base slot of an ERC-7201 namespace:
/// `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`.
///
/// `abi.encode` of a single `uint256` is its 32-byte big-endian encoding. The subtraction wraps only for
/// `keccak256(id) == 0`, which has no known preimage.
pub fn erc7201_slot(id: &str) -> U256 {
    let inner = U256::from_be_bytes(keccak256(id.as_bytes()));
    let minus_one = inner.wrapping_sub(U256::from(1u8));
    let outer = U256::from_be_bytes(keccak256(&minus_one.to_be_bytes::<32>()));
    outer & !U256::from(0xffu8)
}

/// Four-byte function selector of a canonical signature such as `transfer(address,uint256)`.
pub fn selector(signature: &str) -> [u8; 4] {
    let hash = keccak256(signature.as_bytes());
    [hash[0], hash[1], hash[2], hash[3]]
}

/// Formats a slot as `0x` followed by 64 lowercase hex digits.
pub fn hex_slot(value: U256) -> String {
    format!("{value:#066x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eip_example_value() {
        // ERC-7201, "Rationale": the namespace id "example.main".
        assert_eq!(
            hex_slot(erc7201_slot("example.main")),
            "0x183a6125c38840424c4a85fa12bab2ab606c4b6d0e7cc73c0c06ba5300eab500"
        );
    }

    #[test]
    fn openzeppelin_constants() {
        // Constants hard-coded in OpenZeppelin Contracts(-Upgradeable) 5.7.0.
        let cases = [
            (
                "openzeppelin.storage.Initializable",
                "0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00",
            ),
            (
                "openzeppelin.storage.Ownable",
                "0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300",
            ),
            (
                "openzeppelin.storage.Ownable2Step",
                "0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00",
            ),
            (
                "openzeppelin.storage.Pausable",
                "0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300",
            ),
            (
                "openzeppelin.storage.AccessManaged",
                "0xf3177357ab46d8af007ab3fdb9af81da189e1068fefdc0073dca88a2cab40a00",
            ),
            (
                "openzeppelin.storage.ReentrancyGuard",
                "0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00",
            ),
        ];
        for (id, expected) in cases {
            assert_eq!(hex_slot(erc7201_slot(id)), expected, "{id}");
        }
    }

    #[test]
    fn lab_namespaces_match_the_solidity_builtin() {
        // Same values as test/uups/Erc7201Formula.t.sol (computed there by solc's `erc7201` builtin).
        let cases = [
            (
                "upgradelab.storage.SubscriptionRegistry",
                "0xb4bb17120a8e44106124fda25af4145500ca9108cc41e1baa7fd32e47222d800",
            ),
            (
                "upgradelab.storage.Diamond",
                "0x9d0b67c2da79ec3af17c43bb85ef3b6146c19eb61c4203de6bfaed592a4f0100",
            ),
            (
                "upgradelab.storage.DiamondOwnership",
                "0xae3a6b50b5fc26224cb55a9b0086ac3427c5c05685780b3dc3016495a458ad00",
            ),
            (
                "upgradelab.storage.DiamondRegistry",
                "0xd98e97910f38ac455dd0f5c3a6749a71611cf333ff2249e8b62580866e5fba00",
            ),
        ];
        for (id, expected) in cases {
            assert_eq!(hex_slot(erc7201_slot(id)), expected, "{id}");
        }
    }

    #[test]
    fn selectors() {
        assert_eq!(selector("transfer(address,uint256)"), [0xa9, 0x05, 0x9c, 0xbb]);
        // The classic 4-byte collision used by the selector-clash fixture.
        assert_eq!(
            selector("burn(uint256)"),
            selector("collate_propagate_storage(bytes16)")
        );
    }

    #[test]
    fn hex_formatting_is_fixed_width() {
        assert_eq!(hex_slot(U256::ZERO), format!("0x{}", "0".repeat(64)));
        assert_eq!(hex_slot(U256::from(0xabu8)).len(), 66);
    }
}
