// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Deliberately broken (and two deliberately safe) upgrade pairs for the layout gate.
//
// Each `*Old` / `*New` pair is compiled by forge, snapshotted by scripts/check-layouts.mjs into
// layout-diff/tests/fixtures/snapshots/, golden-tested by layout-diff (insta), and re-checked by the gate on every
// run: each broken pair must make `layout-diff diff` exit non-zero, each safe pair must pass.
//
// The ERC-7201 fixtures carry real accessors (`$.slot := ...`), because the gate reads the slot each accessor
// assigns from the AST. Every probe below sits where `erc7201(id)` says, as a reviewer would write it, so the
// broken namespace fixtures fail on what the production-style code does, not on a wrong probe.
//
// These contracts only exist for their storage layout; they are never deployed.

// ---------------------------------------------------------------- 1. reorder
contract ReorderOld {
    address internal owner_;
    uint256 internal total;
}

contract ReorderNew {
    uint256 internal total;
    address internal owner_;
}

// ---------------------------------------------------------------- 2. removed variable
contract RemovedOld {
    uint256 internal a;
    uint256 internal b;
    uint256 internal c;
}

contract RemovedNew {
    uint256 internal a;
    uint256 internal c;
}

// ---------------------------------------------------------------- 3. type change (packing)
contract RetypedOld {
    uint64 internal counter;
    uint64 internal limit;
}

contract RetypedNew {
    uint128 internal counter;
    uint64 internal limit;
}

// ---------------------------------------------------------------- 4. variable inserted before existing ones
contract InsertedOld {
    uint256 internal a;
    uint256 internal b;
}

contract InsertedNew {
    uint256 internal inserted;
    uint256 internal a;
    uint256 internal b;
}

// ---------------------------------------------------------------- 5. __gap shrunk by more than it gave away
abstract contract GapParentOld {
    uint256 internal p;
    uint256[49] private __gap;
}

contract GapChildOld is GapParentOld {
    uint256 internal c;
}

abstract contract GapParentNew {
    uint256 internal p;
    uint256 internal q;
    uint256[47] private __gap; // should be 48: one slot was used by `q`
}

contract GapChildNew is GapParentNew {
    uint256 internal c;
}

// Safe control: the gap gives exactly one slot to `q`.
abstract contract GapParentSafe {
    uint256 internal p;
    uint256 internal q;
    uint256[48] private __gap;
}

contract GapChildSafe is GapParentSafe {
    uint256 internal c;
}

// ---------------------------------------------------------------- 6. namespace members reordered
uint256 constant VAULT_LOCATION = erc7201("upgradelab.fixture.Vault");

abstract contract VaultNamespaceOld {
    /// @custom:storage-location erc7201:upgradelab.fixture.Vault
    struct VaultStorage {
        uint256 totalAssets;
        address asset;
    }

    function _vault() internal pure returns (VaultStorage storage $) {
        uint256 location = VAULT_LOCATION;
        // Only assigns the slot of a storage pointer.
        assembly {
            $.slot := location
        }
    }
}

contract VaultOld is VaultNamespaceOld {}

abstract contract VaultNamespaceReordered {
    /// @custom:storage-location erc7201:upgradelab.fixture.Vault
    struct VaultStorage {
        address asset;
        uint256 totalAssets;
    }

    function _vault() internal pure returns (VaultStorage storage $) {
        uint256 location = VAULT_LOCATION;
        // Only assigns the slot of a storage pointer.
        assembly {
            $.slot := location
        }
    }
}

contract VaultReordered is VaultNamespaceReordered {}

// Safe control: a member appended at the end of the namespace.
abstract contract VaultNamespaceAppended {
    /// @custom:storage-location erc7201:upgradelab.fixture.Vault
    struct VaultStorage {
        uint256 totalAssets;
        address asset;
        uint256 feeBps;
    }

    function _vault() internal pure returns (VaultStorage storage $) {
        uint256 location = VAULT_LOCATION;
        // Only assigns the slot of a storage pointer.
        assembly {
            $.slot := location
        }
    }
}

contract VaultAppended is VaultNamespaceAppended {}

// ---------------------------------------------------------------- 7. ERC-7201 slot computed wrongly
// The pre-ERC-7201 habit in the accessor: keccak256(id) with neither the `- 1` nor the `& ~0xff`.
// cast keccak "upgradelab.fixture.Vault"
uint256 constant MISCOMPUTED_VAULT_LOCATION = 0x1d933e2f622d66c7bd50eded2f7da1ae266141266f51fd0f712d64fabd14cc25;

abstract contract VaultNamespaceMiscomputed {
    /// @custom:storage-location erc7201:upgradelab.fixture.Vault
    struct VaultStorage {
        uint256 totalAssets;
        address asset;
    }

    function _vault() internal pure returns (VaultStorage storage $) {
        uint256 location = MISCOMPUTED_VAULT_LOCATION;
        // Only assigns the slot of a storage pointer.
        assembly {
            $.slot := location
        }
    }
}

contract VaultMiscomputed is VaultNamespaceMiscomputed {}

// ---------------------------------------------------------------- 8. ERC-7201 collision (copy-pasted location)
abstract contract RewardsNamespaceCollides {
    /// @custom:storage-location erc7201:upgradelab.fixture.Rewards
    struct RewardsStorage {
        uint256 rewardRate;
    }

    // The bug being modelled: the accessor reuses VAULT_LOCATION instead of the Rewards namespace's own slot.
    function _rewards() internal pure returns (RewardsStorage storage $) {
        uint256 location = VAULT_LOCATION;
        // Only assigns the slot of a storage pointer.
        assembly {
            $.slot := location
        }
    }
}

contract VaultWithRewards is VaultNamespaceOld, RewardsNamespaceCollides {}

// ---------------------------------------------------------------- 9. sequential -> namespace (OZ #6362 class)
contract OwnedSequentialOld {
    address internal _owner;
    uint256 internal value;
}

abstract contract OwnedNamespace {
    /// @custom:storage-location erc7201:upgradelab.fixture.Owned
    struct OwnedStorage {
        address _owner;
    }
}

contract OwnedNamespacedNew is OwnedNamespace {
    uint256[1] private __retiredOwnerSlot; // reserved space: `__` prefix and a uint256 array, like a __gap
    uint256 internal value;
}

// ---------------------------------------------------------------- 10. a namespace held by a library
// The namespace struct lives in a library, outside the contract's inheritance, and its accessor reuses the vault's
// location. The gate discovers it through the code that reaches it and sees where the accessor really points.
library LibFees {
    /// @custom:storage-location erc7201:upgradelab.fixture.Fees
    struct FeesStorage {
        uint256 feeBps;
    }

    function fees() internal pure returns (FeesStorage storage $) {
        uint256 location = VAULT_LOCATION; // copy-pasted: should be erc7201("upgradelab.fixture.Fees")
        // Only assigns the slot of a storage pointer.
        assembly {
            $.slot := location
        }
    }
}

contract VaultWithFeeLibrary is VaultNamespaceOld {
    function setFee(uint256 feeBps) external {
        LibFees.fees().feeBps = feeBps;
    }
}

// ---------------------------------------------------------------- 11. an accessor the gate cannot evaluate
// The right formula, but computed at run time: no static check can confirm the slot, so the gate refuses it.
abstract contract VaultNamespaceComputed {
    /// @custom:storage-location erc7201:upgradelab.fixture.Vault
    struct VaultStorage {
        uint256 totalAssets;
        address asset;
    }

    function _vault() internal pure returns (VaultStorage storage $) {
        bytes32 location =
            keccak256(abi.encode(uint256(keccak256("upgradelab.fixture.Vault")) - 1)) & ~bytes32(uint256(0xff));
        // Only assigns the slot of a storage pointer.
        assembly {
            $.slot := location
        }
    }
}

contract VaultComputed is VaultNamespaceComputed {}

// ---------------------------------------------------------------- probes of the fixture namespaces

contract VaultOldProbe layout at VAULT_LOCATION {
    VaultNamespaceOld.VaultStorage internal $;
}

contract VaultReorderedProbe layout at VAULT_LOCATION {
    VaultNamespaceReordered.VaultStorage internal $;
}

contract VaultAppendedProbe layout at VAULT_LOCATION {
    VaultNamespaceAppended.VaultStorage internal $;
}

contract VaultMiscomputedProbe layout at erc7201("upgradelab.fixture.Vault") {
    VaultNamespaceMiscomputed.VaultStorage internal $;
}

contract RewardsCollidingProbe layout at erc7201("upgradelab.fixture.Rewards") {
    RewardsNamespaceCollides.RewardsStorage internal $;
}

contract OwnedProbe layout at erc7201("upgradelab.fixture.Owned") {
    OwnedNamespace.OwnedStorage internal $;
}

contract FeesProbe layout at erc7201("upgradelab.fixture.Fees") {
    LibFees.FeesStorage internal $;
}

contract VaultComputedProbe layout at erc7201("upgradelab.fixture.Vault") {
    VaultNamespaceComputed.VaultStorage internal $;
}
