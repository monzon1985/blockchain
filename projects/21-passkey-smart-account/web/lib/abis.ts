// SPDX-License-Identifier: MIT
import { parseAbi } from 'viem'

export const accountAbi = parseAbi([
  'struct Passkey { bytes32 qx; bytes32 qy; bytes32 rpIdHash; }',
  'struct InitParams { Passkey passkey; address[] guardians; uint8 threshold; }',
  'struct PendingRecovery { bytes32 recoveryId; uint48 executableAt; Passkey newPasskey; }',
  'function execute(bytes32 mode, bytes executionData) payable',
  'function initialize(InitParams params)',
  'function initialized() view returns (bool)',
  'function passkey() view returns (Passkey)',
  'function guardians() view returns (address[])',
  'function guardianThreshold() view returns (uint8)',
  'function addGuardian(address guardian)',
  'function setGuardianThreshold(uint8 threshold)',
  'function cancelRecovery()',
  'function approveRecovery(Passkey newPasskey)',
  'function executeRecovery()',
  'function pendingRecovery() view returns (PendingRecovery)',
  'function recoveryIdFor(Passkey newPasskey) view returns (bytes32)',
  'function recoveryApprovals(bytes32 recoveryId) view returns (uint256)',
  'function recoveryEpoch() view returns (uint64)',
  'function frozenUntil() view returns (uint48)',
])

export const factoryAbi = parseAbi([
  'struct Passkey { bytes32 qx; bytes32 qy; bytes32 rpIdHash; }',
  'struct InitParams { Passkey passkey; address[] guardians; uint8 threshold; }',
  'function createAccount(InitParams params, bytes32 salt) returns (address)',
  'function getAddress(InitParams params, bytes32 salt) view returns (address)',
])

export const erc20Abi = parseAbi([
  'function approve(address spender, uint256 amount) returns (bool)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function balanceOf(address who) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function mint(address to, uint256 amount)',
])

export const entryPointReadAbi = parseAbi([
  'function getNonce(address sender, uint192 key) view returns (uint256)',
])
