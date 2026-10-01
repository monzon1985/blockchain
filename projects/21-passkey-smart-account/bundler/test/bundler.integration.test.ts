// SPDX-License-Identifier: MIT
// bundler-lite against a real anvil (osaka) with EntryPoint v0.9, the passkey account and the TestUSD paymaster.
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  concat,
  encodeFunctionData,
  keccak256,
  numberToHex,
  parseAbi,
  parseEther,
  toHex,
  type Address,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { createBundlerClient, entryPoint09Abi } from 'viem/account-abstraction'
import { http } from 'viem'

import { classifyDelegationTarget } from '../src/classifier/index.ts'
import { RpcErrorCode } from '../src/errors.ts'
import { loadArtifact } from '../src/devnet/artifacts.ts'
import { parseRpcUserOperation } from '../src/userop.ts'
import { createSoftPasskey, type SoftPasskey } from './helpers/passkey.ts'
import {
  accountAbi,
  encodeBatch,
  erc20Abi,
  factoryAbi,
  guaranteedPaymasterData,
  hashOp,
  MAX_UINT256,
  mintUsd,
  nonceOf,
  rpc,
  RpcFailure,
  sponsorSignature,
  startStack,
  toRpc,
  type Op,
  type Stack,
} from './helpers/stack.ts'

const FEES = { maxFeePerGas: 2_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n }
const STUB_PM_SIG: Hex = `0x${'11'.repeat(65)}`

let stack: Stack
let url: string
let passkey: SoftPasskey
let account: Address
const bob = '0x000000000000000000000000000000000000b0b0' as Address

function initParams(key: SoftPasskey, guardians: readonly Address[] = [], threshold = 0) {
  return {
    passkey: { qx: toHex(key.x, { size: 32 }), qy: toHex(key.y, { size: 32 }), rpIdHash: key.rpIdHash },
    guardians: [...guardians],
    threshold,
  }
}

/** Estimate with stub signatures, fill the gas fields, then sign for real (passkey + optional sponsor). */
async function estimateAndSign(
  op: Op,
  sign: (hash: Hex) => Promise<Hex>,
  options: { guaranteed?: { validUntil: number } } = {},
): Promise<Op> {
  const stub = await sign(keccak256('0x01'))
  const draft: Op = {
    ...op,
    signature: stub,
    ...(options.guaranteed !== undefined ? { paymasterSignature: STUB_PM_SIG } : {}),
  }
  const gas = await rpc<Record<string, Hex>>(url, 'eth_estimateUserOperationGas', [toRpc(draft), stack.deployment.entryPoint])
  const filled: Op = {
    ...op,
    preVerificationGas: BigInt(gas['preVerificationGas'] as Hex),
    verificationGasLimit: BigInt(gas['verificationGasLimit'] as Hex),
    callGasLimit: BigInt(gas['callGasLimit'] as Hex),
    ...(op.paymaster !== undefined
      ? { paymasterVerificationGasLimit: BigInt(gas['paymasterVerificationGasLimit'] as Hex) }
      : {}),
  }
  if (options.guaranteed !== undefined) {
    // The v0.9 hash covers everything but the paymaster signature itself, so both parties sign the same hash.
    const hash = hashOp({ ...filled, paymasterSignature: STUB_PM_SIG }, stack.deployment.entryPoint)
    const pmSig = await sponsorSignature(stack, hash, options.guaranteed.validUntil)
    return { ...filled, paymasterSignature: pmSig, signature: await sign(hash) }
  }
  return { ...filled, signature: await sign(hashOp(filled, stack.deployment.entryPoint)) }
}

async function send(op: Op): Promise<Hex> {
  return rpc<Hex>(url, 'eth_sendUserOperation', [toRpc(op), stack.deployment.entryPoint])
}

async function expectRpcError(promise: Promise<unknown>, code: number, messagePart?: string): Promise<RpcFailure> {
  try {
    await promise
  } catch (error) {
    expect(error).toBeInstanceOf(RpcFailure)
    const failure = error as RpcFailure
    expect(failure.code).toBe(code)
    if (messagePart !== undefined) expect(failure.message).toContain(messagePart)
    return failure
  }
  throw new Error('expected an RPC error')
}

beforeAll(async () => {
  stack = await startStack()
  url = stack.server.url
  passkey = await createSoftPasskey()
  account = await stack.publicClient.readContract({
    address: stack.deployment.factory,
    abi: factoryAbi,
    functionName: 'getAddress',
    args: [initParams(passkey), toHex(0, { size: 32 })],
  })
  await mintUsd(stack, account, 1_000_000_000n) // 1,000 TUSD
})

afterAll(async () => {
  await stack.stop()
})

describe('JSON-RPC surface', () => {
  it('reports chain id and the single supported EntryPoint', async () => {
    expect(await rpc(url, 'eth_chainId')).toBe('0x7a69')
    const eps = await rpc<string[]>(url, 'eth_supportedEntryPoints')
    expect(eps.map((e) => e.toLowerCase())).toEqual([stack.deployment.entryPoint.toLowerCase()])
  })

  it('rejects unknown methods and wrong EntryPoints', async () => {
    await expectRpcError(rpc(url, 'eth_sendRawTransaction', ['0x']), RpcErrorCode.MethodNotFound)
    await expectRpcError(
      rpc(url, 'eth_sendUserOperation', [{}, '0x0000000000000000000000000000000000000001']),
      RpcErrorCode.InvalidParams,
      'unsupported EntryPoint',
    )
  })

  it('validates the user operation shape', async () => {
    await expectRpcError(
      rpc(url, 'eth_sendUserOperation', [{ sender: 'nope' }, stack.deployment.entryPoint]),
      RpcErrorCode.InvalidParams,
    )
  })

  it('answers JSON-RPC batches and unknown receipts', async () => {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify([
        { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] },
        { jsonrpc: '2.0', id: 2, method: 'eth_getUserOperationReceipt', params: [keccak256('0x')] },
      ]),
    })
    const body = (await response.json()) as { id: number; result: unknown }[]
    expect(body.map((r) => r.result)).toEqual(['0x7a69', null])
  })
})

describe('factory account: sponsor-guaranteed first operation', () => {
  it('deploys the account, approves the paymaster and pays in TestUSD without holding ETH', async () => {
    expect(await stack.publicClient.getBalance({ address: account })).toBe(0n)
    const validUntil = Math.floor(Date.now() / 1000) + 3600
    const op: Op = {
      sender: account,
      nonce: 0n,
      factory: stack.deployment.factory,
      factoryData: encodeFunctionData({
        abi: factoryAbi,
        functionName: 'createAccount',
        args: [initParams(passkey), toHex(0, { size: 32 })],
      }),
      callData: encodeBatch([
        { to: stack.deployment.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [stack.deployment.paymaster, MAX_UINT256] }) },
        { to: stack.deployment.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [bob, 5_000_000n] }) },
      ]),
      callGasLimit: 0n,
      verificationGasLimit: 0n,
      preVerificationGas: 0n,
      ...FEES,
      paymaster: stack.deployment.paymaster,
      paymasterData: guaranteedPaymasterData(validUntil),
      // Floor for the paymaster's own check: the stub sponsor signature makes the estimate short-circuit.
      paymasterVerificationGasLimit: 150_000n,
      paymasterPostOpGasLimit: 120_000n,
      signature: '0x',
    }
    const signed = await estimateAndSign(op, (h) => passkey.sign(h), { guaranteed: { validUntil } })
    const hash = await send(signed)

    const receipt = await rpc<Record<string, unknown>>(url, 'eth_getUserOperationReceipt', [hash])
    expect(receipt['success']).toBe(true)
    expect((receipt['sender'] as string).toLowerCase()).toBe(account.toLowerCase())
    expect((await stack.publicClient.getCode({ address: account }))?.length).toBeGreaterThan(2)
    expect(await stack.publicClient.readContract({ address: stack.deployment.testUsd, abi: erc20Abi, functionName: 'balanceOf', args: [bob] })).toBe(5_000_000n)
    // Hash computed locally matches the EntryPoint's own getUserOpHash.
    const onChain = await stack.publicClient.readContract({
      address: stack.deployment.entryPoint,
      abi: entryPoint09Abi,
      functionName: 'getUserOpHash',
      args: [
        {
          sender: signed.sender,
          nonce: signed.nonce,
          initCode: concat([signed.factory as Hex, signed.factoryData as Hex]),
          callData: signed.callData,
          accountGasLimits: concat([toHex(signed.verificationGasLimit, { size: 16 }), toHex(signed.callGasLimit, { size: 16 })]),
          preVerificationGas: signed.preVerificationGas,
          gasFees: concat([toHex(signed.maxPriorityFeePerGas, { size: 16 }), toHex(signed.maxFeePerGas, { size: 16 })]),
          paymasterAndData: concat([
            signed.paymaster as Hex,
            toHex(signed.paymasterVerificationGasLimit ?? 0n, { size: 16 }),
            toHex(signed.paymasterPostOpGasLimit ?? 0n, { size: 16 }),
            signed.paymasterData as Hex,
            signed.paymasterSignature as Hex,
            toHex(65, { size: 2 }),
            '0x22e325a297439656',
          ]),
          signature: signed.signature,
        },
      ],
    })
    expect(onChain).toBe(hash)
  })
})

describe('ERC-20-paid batched transfers (user-funded paymaster, gas paid in TestUSD)', () => {
  it('pays gas in TestUSD from the allowance granted in the first op', async () => {
    const before = await stack.publicClient.readContract({ address: stack.deployment.testUsd, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
    const op: Op = {
      sender: account,
      nonce: await nonceOf(stack, account),
      callData: encodeBatch([
        { to: stack.deployment.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [bob, 1_000_000n] }) },
        { to: stack.deployment.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: ['0x000000000000000000000000000000000000c4c4', 2_000_000n] }) },
      ]),
      callGasLimit: 0n,
      verificationGasLimit: 0n,
      preVerificationGas: 0n,
      ...FEES,
      paymaster: stack.deployment.paymaster,
      paymasterData: '0x00',
      paymasterVerificationGasLimit: 0n,
      paymasterPostOpGasLimit: 80_000n,
      signature: '0x',
    }
    const hash = await send(await estimateAndSign(op, (h) => passkey.sign(h)))
    const after = await stack.publicClient.readContract({ address: stack.deployment.testUsd, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
    const fee = before - after - 3_000_000n
    expect(fee).toBeGreaterThan(0n)

    // viem's bundler client understands the receipt and the by-hash lookup.
    const client = createBundlerClient({ transport: http(url), client: stack.publicClient })
    const receipt = await client.getUserOperationReceipt({ hash })
    expect(receipt.success).toBe(true)
    expect(receipt.paymaster?.toLowerCase()).toBe(stack.deployment.paymaster.toLowerCase())
    const byHash = await client.getUserOperation({ hash })
    expect(byHash.userOperation.sender.toLowerCase()).toBe(account.toLowerCase())
  })

  it('rejects a user operation signed by another passkey (-32507)', async () => {
    const intruder = await createSoftPasskey()
    const op: Op = {
      sender: account,
      nonce: await nonceOf(stack, account),
      callData: encodeBatch([{ to: bob, value: 0n }]),
      callGasLimit: 100_000n,
      verificationGasLimit: 200_000n,
      preVerificationGas: 100_000n,
      ...FEES,
      paymaster: stack.deployment.paymaster,
      paymasterData: '0x00',
      paymasterVerificationGasLimit: 200_000n,
      paymasterPostOpGasLimit: 80_000n,
      signature: '0x',
    }
    const signed = { ...op, signature: await intruder.sign(hashOp(op, stack.deployment.entryPoint)) }
    await expectRpcError(send(signed), RpcErrorCode.InvalidSignature)
  })

  it('rejects an assertion produced for another relying party (RP id and origin) (-32507)', async () => {
    const op: Op = {
      sender: account,
      nonce: await nonceOf(stack, account),
      callData: encodeBatch([{ to: bob, value: 0n }]),
      callGasLimit: 100_000n,
      verificationGasLimit: 200_000n,
      preVerificationGas: 100_000n,
      ...FEES,
      paymaster: stack.deployment.paymaster,
      paymasterData: '0x00',
      paymasterVerificationGasLimit: 200_000n,
      paymasterPostOpGasLimit: 80_000n,
      signature: '0x',
    }
    const hash = hashOp(op, stack.deployment.entryPoint)
    const signed = { ...op, signature: await passkey.sign(hash, { rpId: 'evil.example', origin: 'https://evil.example' }) }
    await expectRpcError(send(signed), RpcErrorCode.InvalidSignature)
  })

  it('rejects a too-low preVerificationGas (-32602)', async () => {
    const op: Op = {
      sender: account,
      nonce: await nonceOf(stack, account),
      callData: encodeBatch([{ to: bob, value: 0n }]),
      callGasLimit: 100_000n,
      verificationGasLimit: 200_000n,
      preVerificationGas: 1_000n,
      ...FEES,
      signature: '0x',
    }
    const signed = { ...op, signature: await passkey.sign(hashOp(op, stack.deployment.entryPoint)) }
    await expectRpcError(send(signed), RpcErrorCode.InvalidParams, 'preVerificationGas')
  })
})

describe('EIP-7702 upgrade through the EntryPoint', () => {
  it('upgrades an EOA with no ETH: authorization + EOA-signed initialize, gas guaranteed by the sponsor', async () => {
    const eoa = privateKeyToAccount(generatePrivateKey())
    await mintUsd(stack, eoa.address, 50_000_000n)
    const upgradeKey = await createSoftPasskey()
    const authorization = await eoa.signAuthorization({
      contractAddress: stack.deployment.accountImplementation,
      chainId: 31337,
      nonce: 0,
    })
    const validUntil = Math.floor(Date.now() / 1000) + 3600
    const op: Op = {
      sender: eoa.address,
      nonce: 0n,
      factory: '0x7702',
      factoryData: '0x',
      authorization,
      callData: encodeBatch([
        { to: eoa.address, data: encodeFunctionData({ abi: accountAbi, functionName: 'initialize', args: [initParams(upgradeKey)] }) },
        { to: stack.deployment.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [stack.deployment.paymaster, MAX_UINT256] }) },
      ]),
      callGasLimit: 0n,
      verificationGasLimit: 0n,
      preVerificationGas: 0n,
      ...FEES,
      paymaster: stack.deployment.paymaster,
      paymasterData: guaranteedPaymasterData(validUntil),
      // Floor for the paymaster's own check: the stub sponsor signature makes the estimate short-circuit.
      paymasterVerificationGasLimit: 150_000n,
      paymasterPostOpGasLimit: 120_000n,
      signature: '0x',
    }
    const eoaSign = async (hash: Hex): Promise<Hex> => concat(['0x01', await eoa.sign({ hash })])
    const hash = await send(await estimateAndSign(op, eoaSign, { guaranteed: { validUntil } }))
    const receipt = await rpc<Record<string, unknown>>(url, 'eth_getUserOperationReceipt', [hash])
    expect(receipt['success']).toBe(true)
    expect((await stack.publicClient.getCode({ address: eoa.address }))?.toLowerCase()).toBe(
      concat(['0xef0100', stack.deployment.accountImplementation]).toLowerCase(),
    )
    expect(await stack.publicClient.readContract({ address: eoa.address, abi: accountAbi, functionName: 'initialized' })).toBe(true)
    expect(await stack.publicClient.getBalance({ address: eoa.address })).toBe(0n)
  })

  it('refuses chainId-0 authorizations (-32602)', async () => {
    const eoa = privateKeyToAccount(generatePrivateKey())
    const authorization = await eoa.signAuthorization({ contractAddress: stack.deployment.accountImplementation, chainId: 0, nonce: 0 })
    const op = {
      sender: eoa.address,
      nonce: 0n,
      factory: '0x7702',
      factoryData: '0x',
      authorization,
      callData: '0x',
      callGasLimit: 100_000n,
      verificationGasLimit: 200_000n,
      preVerificationGas: 100_000n,
      ...FEES,
      signature: '0x01',
    } as Op
    await expectRpcError(send(op), RpcErrorCode.InvalidParams, 'chainId 0')
  })

  it('refuses authorizations not signed by the sender (-32602)', async () => {
    const eoa = privateKeyToAccount(generatePrivateKey())
    const other = privateKeyToAccount(generatePrivateKey())
    const authorization = await other.signAuthorization({ contractAddress: stack.deployment.accountImplementation, chainId: 31337, nonce: 0 })
    const op = {
      sender: eoa.address,
      nonce: 0n,
      factory: '0x7702',
      factoryData: '0x',
      authorization,
      callData: '0x',
      callGasLimit: 100_000n,
      verificationGasLimit: 200_000n,
      preVerificationGas: 100_000n,
      ...FEES,
      signature: '0x01',
    } as Op
    await expectRpcError(send(op), RpcErrorCode.InvalidParams, 'not by the sender')
  })
})

describe('validity windows are checked at validation (-32503)', () => {
  it('rejects every operation of a frozen account in validate(), not only in the final handleOps simulation', async () => {
    const key = await createSoftPasskey()
    const guardian = stack.deployment.guardians[0] as Address
    const params = initParams(key, [guardian], 1)
    const salt = toHex(77, { size: 32 })
    const frozen = await stack.publicClient.readContract({
      address: stack.deployment.factory,
      abi: factoryAbi,
      functionName: 'getAddress',
      args: [params, salt],
    })
    const chain = stack.walletClient.chain
    for (const request of [
      { address: stack.deployment.factory, abi: factoryAbi, functionName: 'createAccount', args: [params, salt], account: stack.deployment.admin },
      { address: frozen, abi: parseAbi(['function freeze()']), functionName: 'freeze', args: [], account: guardian },
    ] as const) {
      const hash = await stack.walletClient.writeContract({ ...request, chain } as never)
      expect((await stack.publicClient.waitForTransactionReceipt({ hash })).status).toBe('success')
    }
    const fund = await stack.walletClient.sendTransaction({ to: frozen, value: parseEther('1'), account: stack.deployment.admin, chain })
    await stack.publicClient.waitForTransactionReceipt({ hash: fund })

    const op: Op = {
      sender: frozen,
      nonce: 0n,
      callData: encodeBatch([{ to: bob, value: 1n }]),
      callGasLimit: 100_000n,
      verificationGasLimit: 400_000n,
      preVerificationGas: 100_000n,
      ...FEES,
      signature: '0x',
    }
    const signed = { ...op, signature: await key.sign(hashOp(op, stack.deployment.entryPoint)) }
    // The signature is valid; only the freeze (validAfter = frozenUntil) makes it invalid.
    await expect(stack.bundler.validate(parseRpcUserOperation(toRpc(signed)))).rejects.toMatchObject({
      code: RpcErrorCode.OutOfTimeRange,
    })
    await expectRpcError(send(signed), RpcErrorCode.OutOfTimeRange, 'account validity starts after timestamp')
  })

  it('rejects a sponsor guarantee that has already expired (paymaster window)', async () => {
    const head = await stack.publicClient.getBlock()
    const validUntil = Number(head.timestamp) - 10
    const op: Op = {
      sender: account,
      nonce: await nonceOf(stack, account),
      callData: encodeBatch([{ to: bob, value: 0n }]),
      callGasLimit: 100_000n,
      verificationGasLimit: 400_000n,
      preVerificationGas: 150_000n,
      ...FEES,
      paymaster: stack.deployment.paymaster,
      paymasterData: guaranteedPaymasterData(validUntil),
      paymasterVerificationGasLimit: 150_000n,
      paymasterPostOpGasLimit: 120_000n,
      paymasterSignature: STUB_PM_SIG,
      signature: '0x',
    }
    const hash = hashOp(op, stack.deployment.entryPoint)
    const signed = { ...op, paymasterSignature: await sponsorSignature(stack, hash, validUntil), signature: await passkey.sign(hash) }
    await expect(stack.bundler.validate(parseRpcUserOperation(toRpc(signed)))).rejects.toMatchObject({
      code: RpcErrorCode.OutOfTimeRange,
    })
    await expectRpcError(send(signed), RpcErrorCode.OutOfTimeRange, 'paymaster validity ends')
  })
})

describe('delegation-target classifier on deployed code', () => {
  it('rates the deployed PasskeyAccount safe once the local EntryPoint is trusted, and refuses it otherwise', async () => {
    const code = (await stack.publicClient.getCode({ address: stack.deployment.accountImplementation })) ?? '0x'
    // The devnet EntryPoint is compiled from source, so its address is not a canonical one: to a wallet that does not
    // know it, the account is an executor controlled by an unknown hardcoded address.
    const unknown = classifyDelegationTarget(code)
    expect(unknown.verdict).toBe('malicious')
    expect(unknown.findings.every((f) => f.guard === 'foreign')).toBe(true)
    expect(classifyDelegationTarget(code, { trustedCallers: [stack.deployment.entryPoint] })).toMatchObject({
      verdict: 'safe',
      findings: [],
    })
  })
})

describe('ERC-7562 opcode rules on real traces', () => {
  async function deployViolator(
    name: 'TimestampAccount' | 'ValueLeakAccount' | 'EntryPointToucherAccount' | 'DepositToAccount',
  ): Promise<Address> {
    const artifact = loadArtifact('Erc7562Violators.sol', name)
    const hash = await stack.walletClient.deployContract({
      abi: artifact.abi,
      bytecode: artifact.bytecode,
      args: [stack.deployment.entryPoint],
      account: stack.deployment.admin,
      chain: stack.walletClient.chain,
    })
    const receipt = await stack.publicClient.waitForTransactionReceipt({ hash })
    const address = receipt.contractAddress as Address
    const fund = await stack.walletClient.sendTransaction({
      to: address,
      value: parseEther('1'),
      account: stack.deployment.admin,
      chain: stack.walletClient.chain,
    })
    await stack.publicClient.waitForTransactionReceipt({ hash: fund })
    return address
  }

  function plainOp(sender: Address): Op {
    return {
      sender,
      nonce: 0n,
      callData: '0x',
      callGasLimit: 50_000n,
      verificationGasLimit: 200_000n,
      preVerificationGas: 100_000n,
      ...FEES,
      signature: '0x',
    }
  }

  it('rejects TIMESTAMP in account validation (OP-011, -32502)', async () => {
    const sender = await deployViolator('TimestampAccount')
    const failure = await expectRpcError(send(plainOp(sender)), RpcErrorCode.BannedOpcode, 'OP-011')
    const violations = (failure.data as { violations: { rule: string; opcode: string; entity: string }[] }).violations
    expect(violations).toContainEqual(expect.objectContaining({ rule: 'OP-011', opcode: 'TIMESTAMP', entity: 'account' }))
  })

  it('rejects value transfers to non-EntryPoint addresses (OP-061, -32502)', async () => {
    const sender = await deployViolator('ValueLeakAccount')
    const failure = await expectRpcError(send(plainOp(sender)), RpcErrorCode.BannedOpcode, 'OP-061')
    const rules = (failure.data as { violations: { rule: string }[] }).violations.map((v) => v.rule)
    expect(rules).toContain('OP-061')
    expect(rules).toContain('OP-041')
  })

  it('rejects EntryPoint calls other than depositTo(sender) or the fallback (OP-054, -32502)', async () => {
    const sender = await deployViolator('EntryPointToucherAccount')
    const failure = await expectRpcError(send(plainOp(sender)), RpcErrorCode.BannedOpcode, 'OP-054')
    const violations = (failure.data as { violations: { rule: string; entity: string; opcode: string }[] }).violations
    expect(violations).toContainEqual(expect.objectContaining({ rule: 'OP-054', entity: 'account', opcode: 'CALL' }))
  })

  it('accepts a prefund paid through depositTo(sender) (OP-052)', async () => {
    const sender = await deployViolator('DepositToAccount')
    const { violations } = await stack.bundler.validate(parseRpcUserOperation(toRpc(plainOp(sender))))
    expect(violations).toEqual([])
    const hash = await send(plainOp(sender))
    const receipt = await rpc<Record<string, unknown>>(url, 'eth_getUserOperationReceipt', [hash])
    expect(receipt['success']).toBe(true)
  })

  it('accepts the passkey account and the paymaster (no violation on the happy path)', async () => {
    const op: Op = {
      sender: account,
      nonce: await nonceOf(stack, account),
      callData: encodeBatch([{ to: stack.deployment.testUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [bob, 1n] }) }]),
      callGasLimit: 0n,
      verificationGasLimit: 0n,
      preVerificationGas: 0n,
      ...FEES,
      paymaster: stack.deployment.paymaster,
      paymasterData: '0x00',
      paymasterVerificationGasLimit: 0n,
      paymasterPostOpGasLimit: 80_000n,
      signature: '0x',
    }
    const signed = await estimateAndSign(op, (h) => passkey.sign(h))
    const { violations } = await stack.bundler.validate(signed)
    expect(violations).toEqual([])
    expect(numberToHex(signed.nonce)).toBe(numberToHex(await nonceOf(stack, account)))
  })
})
