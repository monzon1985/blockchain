// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ISchnorrVault} from "../../src/ISchnorrVault.sol";
import {SchnorrSecp256k1} from "../../src/SchnorrSecp256k1.sol";
import {SchnorrVault} from "../../src/SchnorrVault.sol";

/// @notice Mintable ERC-20 used as a custody asset in tests.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    /// @notice Mints `amount` to `to`.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ETH recipient that always reverts.
contract RejectingRecipient {
    /// @notice Error raised on every ETH transfer.
    error NoEth();

    receive() external payable {
        revert NoEth();
    }
}

/// @notice ETH recipient that tries to re-enter the vault with a second signed
///         withdrawal while the first one is still executing.
contract ReentrantRecipient {
    SchnorrVault internal vault;
    ISchnorrVault.WithdrawalIntent internal next;
    SchnorrSecp256k1.Signature internal nextSig;
    /// @notice Revert data of the re-entrant call.
    bytes public reentryError;

    /// @notice Arms the re-entrant withdrawal.
    function arm(
        SchnorrVault vault_,
        ISchnorrVault.WithdrawalIntent calldata next_,
        SchnorrSecp256k1.Signature calldata sig
    ) external {
        vault = vault_;
        next = next_;
        nextSig = sig;
    }

    receive() external payable {
        if (address(vault) == address(0)) return;
        try vault.withdraw(next, nextSig) {}
        catch (bytes memory reason) {
            reentryError = reason;
        }
    }
}
