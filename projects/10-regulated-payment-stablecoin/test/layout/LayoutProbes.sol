// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {
    ERC3009Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/draft-ERC3009Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {ComplianceControls} from "../../src/modules/ComplianceControls.sol";
import {ReserveGate} from "../../src/modules/ReserveGate.sol";
import {MintController} from "../../src/modules/MintController.sol";
import {TestPaymentDollarV2} from "../../src/TestPaymentDollarV2.sol";

// Layout probes: each contract places one ERC-7201 namespace struct at slot 0 so that `forge inspect <probe>
// storageLayout` reveals the member layout of that namespace (solc's layout output does not describe namespaced
// storage directly). `scripts/check-storage-layout.mjs` compares them against the committed baselines in
// storage-layout/. They are never deployed.

/// @dev erc7201:tpd.storage.Compliance
contract ComplianceLayoutProbe {
    ComplianceControls.ComplianceStorage internal s;
}

/// @dev erc7201:tpd.storage.Reserves
contract ReservesLayoutProbe {
    ReserveGate.ReservesStorage internal s;
}

/// @dev erc7201:tpd.storage.Minting
contract MintingLayoutProbe {
    MintController.MintingStorage internal s;
}

/// @dev erc7201:tpd.storage.TransferCaps (added in v2)
contract TransferCapsLayoutProbe {
    TestPaymentDollarV2.TransferCapStorage internal s;
}

/// @dev erc7201:openzeppelin.storage.ERC20
contract OzERC20LayoutProbe {
    ERC20Upgradeable.ERC20Storage internal s;
}

/// @dev erc7201:openzeppelin.storage.EIP712
contract OzEIP712LayoutProbe {
    EIP712Upgradeable.EIP712Storage internal s;
}

/// @dev erc7201:openzeppelin.storage.Nonces
contract OzNoncesLayoutProbe {
    NoncesUpgradeable.NoncesStorage internal s;
}

/// @dev erc7201:openzeppelin.storage.Pausable
contract OzPausableLayoutProbe {
    PausableUpgradeable.PausableStorage internal s;
}

/// @dev erc7201:openzeppelin.storage.AccessManaged
contract OzAccessManagedLayoutProbe {
    AccessManagedUpgradeable.AccessManagedStorage internal s;
}

/// @dev erc7201:openzeppelin.storage.ERC3009
contract OzERC3009LayoutProbe {
    ERC3009Upgradeable.ERC3009Storage internal s;
}

/// @dev erc7201:openzeppelin.storage.Initializable
contract OzInitializableLayoutProbe {
    Initializable.InitializableStorage internal s;
}

