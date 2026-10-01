// SPDX-License-Identifier: MIT
/**
 * End-to-end demo on a throwaway local anvil node (random free port, killed on exit):
 *
 *   1. deploys the distributor with the production script (script/Deploy.s.sol, `--unlocked`, no keys in this repo),
 *   2. builds two cumulative epochs from CSVs with the tree-builder CLI,
 *   3. proposes, vetoes, re-proposes and accepts roots through the 24 h timelock,
 *   4. claims directly, through `claimFor` signed by an EOA (eth_signTypedData_v4) and by an ERC-1271 wallet, and in
 *      one `claimMany` multiproof batch,
 *   5. checks that every leaf ends fully claimed and the vault ends exactly empty.
 *
 *   npm run demo        (needs forge and anvil on PATH; runs `forge build` itself)
 *
 * Every step asserts its outcome and the script exits non-zero on the first surprise, so CI runs it as a test.
 */
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createTestClient,
  createWalletClient,
  formatEther,
  getAddress,
  http,
  keccak256,
  parseEther,
  stringToBytes,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from 'viem';
import { foundry } from 'viem/chains';
import {
  CLAIM_AUTHORIZATION_TYPES,
  claimAuthorizationDomain,
  claimAuthorizationDomainSeparator,
  hashClaimAuthorization,
  type ClaimAuthorization,
} from '../src/claim-authorization.ts';
import { runCli } from '../src/cli.ts';
import type { Manifest, ProofsFile } from '../src/cumulative.ts';
import { CumulativeMerkleTree, type StandardTreeDump } from '../src/tree.ts';

const PROJECT = resolve(import.meta.dirname, '../..');
const DAY = 24n * 60n * 60n;

class DemoError extends Error {
  override name = 'DemoError';
}

function check(condition: boolean, message: string): asserts condition {
  if (!condition) throw new DemoError(message);
}

// ------------------------------------------------------------------------------------------------ processes

function run(cmd: string, args: readonly string[], env: Record<string, string> = {}): string {
  const res = spawnSync(cmd, args, { cwd: PROJECT, encoding: 'utf8', env: { ...process.env, ...env } });
  if (res.status !== 0) {
    throw new DemoError(`${cmd} ${args.join(' ')} failed (${String(res.status)}):\n${res.stdout}\n${res.stderr}`);
  }
  return res.stdout;
}

/** Starts anvil on a port the OS picks (`--port 0`) and resolves with its URL once it listens. */
function startAnvil(): Promise<{ url: string; child: ChildProcess }> {
  const child = spawn('anvil', ['--port', '0', '--hardfork', 'osaka', '--chain-id', String(foundry.id)], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return new Promise((resolvePromise, reject) => {
    let buffer = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new DemoError(`anvil did not start within 30 s:\n${buffer}`));
    }, 30_000);
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.stdout.on('data', (chunk: Buffer) => {
      buffer += chunk.toString();
      const match = /Listening on (\S+)/.exec(buffer);
      if (match?.[1] !== undefined) {
        clearTimeout(timer);
        resolvePromise({ url: `http://${match[1]}`, child });
      }
    });
  });
}

// ------------------------------------------------------------------------------------------------ artifacts

interface Artifact {
  readonly abi: Abi;
  readonly bytecode: Hex;
}

function artifact(file: string, name: string): Artifact {
  const json = JSON.parse(readFileSync(join(PROJECT, 'out', file, `${name}.json`), 'utf8')) as {
    abi: Abi;
    bytecode: { object: Hex };
  };
  return { abi: json.abi, bytecode: json.bytecode.object };
}

// ------------------------------------------------------------------------------------------------ demo

async function demo(url: string, workDir: string): Promise<void> {
  const transport = http(url);
  const publicClient = createPublicClient({ chain: foundry, transport });
  const testClient = createTestClient({ chain: foundry, mode: 'anvil', transport });
  const walletClient = createWalletClient({ chain: foundry, transport });

  const accounts = await walletClient.getAddresses();
  const at = (i: number): Address => {
    const a = accounts[i];
    if (a === undefined) throw new DemoError(`anvil exposes no account #${i}`);
    return a;
  };
  const [owner, updater, guardian, alice, bob, walletOwner, relayer, treasury, keeper, dave] = Array.from(
    { length: 10 },
    (_, i) => at(i),
  ) as [Address, Address, Address, Address, Address, Address, Address, Address, Address, Address];

  const gas: [string, bigint][] = [];
  const DISTRIBUTOR = artifact('CumulativeMerkleDistributor.sol', 'CumulativeMerkleDistributor');
  const ERC20 = artifact('MockERC20.sol', 'MockERC20');
  const WALLET = artifact('MockERC1271Wallet.sol', 'MockERC1271Wallet');

  async function mined(label: string, hash: Hex): Promise<TransactionReceipt> {
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    check(receipt.status === 'success', `${label}: transaction reverted`);
    gas.push([label, receipt.gasUsed]);
    return receipt;
  }

  async function deploy(label: string, a: Artifact, args: readonly unknown[]): Promise<Address> {
    const hash = await walletClient.deployContract({ account: owner, abi: a.abi, bytecode: a.bytecode, args });
    const receipt = await mined(label, hash);
    check(receipt.contractAddress != null, `${label}: no contract address`);
    return getAddress(receipt.contractAddress);
  }

  // ---------------------------------------------------------------------------------------- 1. deployment
  console.log(`anvil at ${url}, chain id ${foundry.id}`);
  run(
    'forge',
    ['script', 'script/Deploy.s.sol:Deploy', '--rpc-url', url, '--broadcast', '--unlocked', '--sender', owner],
    { DISTRIBUTOR_OWNER: owner, DISTRIBUTOR_UPDATER: updater, DISTRIBUTOR_GUARDIAN: guardian },
  );
  const broadcast = JSON.parse(
    readFileSync(join(PROJECT, 'broadcast', 'Deploy.s.sol', String(foundry.id), 'run-latest.json'), 'utf8'),
  ) as { transactions: { contractName: string | null; contractAddress: Address | null }[] };
  const deployed = broadcast.transactions.find((t) => t.contractName === 'CumulativeMerkleDistributor');
  check(deployed?.contractAddress != null, 'Deploy.s.sol did not deploy the distributor');
  const distributor = getAddress(deployed.contractAddress);
  console.log(`1. Deploy.s.sol deployed the distributor at ${distributor}`);

  const read = async (functionName: string, args: readonly unknown[] = []): Promise<unknown> =>
    publicClient.readContract({ address: distributor, abi: DISTRIBUTOR.abi, functionName, args });
  const readBig = async (functionName: string, args: readonly unknown[] = []): Promise<bigint> => {
    const v = await read(functionName, args);
    check(typeof v === 'bigint', `${functionName} did not return an integer`);
    return v;
  };
  const send = async (label: string, from: Address, functionName: string, args: readonly unknown[]) =>
    mined(
      label,
      await walletClient.writeContract({
        account: from,
        address: distributor,
        abi: DISTRIBUTOR.abi,
        functionName,
        args,
      }),
    );
  const expectRevert = async (from: Address, functionName: string, args: readonly unknown[], errorName: string) => {
    try {
      await publicClient.simulateContract({
        account: from,
        address: distributor,
        abi: DISTRIBUTOR.abi,
        functionName,
        args,
      });
    } catch (err) {
      const revert = err instanceof BaseError ? err.walk((e) => e instanceof ContractFunctionRevertedError) : null;
      if (revert instanceof ContractFunctionRevertedError && revert.data?.errorName === errorName) return;
      throw err;
    }
    throw new DemoError(`${functionName} was expected to revert with ${errorName}`);
  };

  check((await read('owner')) === owner && (await read('updater')) === updater, 'roles not wired');
  check((await read('guardian')) === guardian, 'guardian not wired');

  const rwa = await deploy('deploy Reward A', ERC20, ['Reward A', 'RWA']);
  const rwb = await deploy('deploy Reward B', ERC20, ['Reward B', 'RWB']);
  const wallet = await deploy('deploy ERC-1271 wallet', WALLET, [walletOwner]);
  const balanceOf = async (token: Address, who: Address): Promise<bigint> => {
    const v = await publicClient.readContract({
      address: token,
      abi: ERC20.abi,
      functionName: 'balanceOf',
      args: [who],
    });
    check(typeof v === 'bigint', 'balanceOf did not return an integer');
    return v;
  };

  // ---------------------------------------------------------------------------------------- 2. epochs
  const e = (n: string): string => parseEther(n).toString();
  const csv = (rows: [Address, Address, string][]): string =>
    ['account,token,amount', ...rows.map(([a, t, amount]) => `${a},${t},${amount}`)].join('\n') + '\n';
  const epochFiles = [
    csv([
      [alice, rwa, e('100')],
      [bob, rwa, e('40')],
      [wallet, rwb, e('25')],
      [alice, rwb, e('10')],
    ]),
    csv([
      [alice, rwa, e('60')],
      [bob, rwa, e('20')],
      [dave, rwb, e('5')],
      [wallet, rwb, e('5')],
    ]),
    // A fat-fingered epoch 2 (an extra zero on bob's row): the guardian vetoes it.
    csv([
      [alice, rwa, e('60')],
      [bob, rwa, e('200')],
      [dave, rwb, e('5')],
      [wallet, rwb, e('5')],
    ]),
  ].map((text, i) => {
    const path = join(workDir, `in-${i + 1}.csv`);
    writeFileSync(path, text);
    return path;
  });
  const [epoch1Csv, epoch2Csv, badEpoch2Csv] = epochFiles as [string, string, string];
  const cli = (args: string[]): void => {
    const lines: string[] = [];
    const code = runCli(args, { log: (l) => lines.push(l), error: (l) => lines.push(l) });
    check(code === 0, `tree-builder ${args.join(' ')} failed:\n${lines.join('\n')}`);
  };
  cli(['build', '--out', join(workDir, 'good'), epoch1Csv, epoch2Csv]);
  cli(['build', '--out', join(workDir, 'bad'), epoch1Csv, badEpoch2Csv]);
  console.log('2. tree-builder built epochs 1-2 (and a faulty epoch 2) from CSV');

  const load = (set: string, epoch: number) => {
    const dir = join(workDir, set, `epoch-${String(epoch).padStart(3, '0')}`);
    const manifestJson = readFileSync(join(dir, 'manifest.json'), 'utf8');
    return {
      tree: CumulativeMerkleTree.load(JSON.parse(readFileSync(join(dir, 'tree.json'), 'utf8')) as StandardTreeDump),
      proofs: JSON.parse(readFileSync(join(dir, 'proofs.json'), 'utf8')) as ProofsFile,
      manifest: JSON.parse(manifestJson) as Manifest,
      metadataHash: keccak256(stringToBytes(manifestJson)),
    };
  };
  const epoch1 = load('good', 1);
  const epoch2 = load('good', 2);
  const badEpoch2 = load('bad', 2);
  const entry = (p: ProofsFile, account: Address, token: Address) => {
    const found = p.claims[account]?.[token];
    check(found !== undefined, `no leaf for ${account} / ${token}`);
    return { cumulativeAmount: BigInt(found.cumulativeAmount), proof: found.proof };
  };

  /** Mints whatever the distributor still needs to cover `manifest`'s cumulative totals. */
  const funded = new Map<string, bigint>();
  const fund = async (manifest: Manifest) => {
    for (const t of manifest.tokens) {
      const needed = BigInt(t.cumulativeTotal) - (funded.get(t.token) ?? 0n);
      if (needed <= 0n) continue;
      const hash = await walletClient.writeContract({
        account: owner,
        address: t.token,
        abi: ERC20.abi,
        functionName: 'mint',
        args: [distributor, needed],
      });
      await mined(`fund ${t.token.slice(0, 8)}`, hash);
      funded.set(t.token, BigInt(t.cumulativeTotal));
    }
  };

  // ---------------------------------------------------------------------------------------- 3. epoch 1
  await fund(epoch1.manifest);
  await send('proposeRoot', updater, 'proposeRoot', [epoch1.manifest.root, epoch1.metadataHash]);
  await expectRevert(keeper, 'acceptRoot', [], 'RootTimelocked');
  await testClient.increaseTime({ seconds: Number(DAY) });
  await testClient.mine({ blocks: 1 });
  await send('acceptRoot', keeper, 'acceptRoot', []);
  check((await read('root')) === epoch1.manifest.root, 'epoch 1 root not active');
  check((await read('metadataHash')) === epoch1.metadataHash, 'metadataHash != keccak256(manifest.json)');
  console.log(`3. epoch 1 root ${epoch1.manifest.root} accepted after the 24 h timelock (early accept reverted)`);

  const a1 = entry(epoch1.proofs, alice, rwa);
  await send('claim', alice, 'claim', [alice, rwa, a1.cumulativeAmount, a1.proof]);
  check((await balanceOf(rwa, alice)) === parseEther('100'), 'alice was not paid 100 RWA');

  // claimFor: the TypeScript EIP-712 digest must equal the contract's on this live chain.
  const domain = claimAuthorizationDomain(foundry.id, distributor);
  check(
    (await read('DOMAIN_SEPARATOR')) === claimAuthorizationDomainSeparator(domain),
    'TS and Solidity domain separators differ',
  );
  const authorize = async (signer: Address, account: Address, token: Address, cumulativeAmount: bigint) => {
    const latest = await publicClient.getBlock();
    const message: ClaimAuthorization = {
      account,
      token,
      cumulativeAmount,
      recipient: treasury,
      nonce: await readBig('nonces', [account]),
      deadline: latest.timestamp + 3600n,
    };
    const onChain = await read('hashClaimAuthorization', [
      message.account,
      message.token,
      message.cumulativeAmount,
      message.recipient,
      message.nonce,
      message.deadline,
    ]);
    check(onChain === hashClaimAuthorization(domain, message), 'TS and Solidity EIP-712 digests differ');
    const signature = await walletClient.signTypedData({
      account: signer,
      domain,
      types: CLAIM_AUTHORIZATION_TYPES,
      primaryType: 'ClaimAuthorization',
      message,
    });
    return { message, signature };
  };

  const b1 = entry(epoch1.proofs, bob, rwa);
  const bobAuth = await authorize(bob, bob, rwa, b1.cumulativeAmount);
  await send('claimFor (EOA)', relayer, 'claimFor', [
    bob,
    rwa,
    b1.cumulativeAmount,
    b1.proof,
    treasury,
    bobAuth.message.deadline,
    bobAuth.signature,
  ]);
  // The same signature cannot be replayed: its nonce is spent.
  await expectRevert(
    relayer,
    'claimFor',
    [bob, rwa, b1.cumulativeAmount, b1.proof, treasury, bobAuth.message.deadline, bobAuth.signature],
    'InvalidSignature',
  );

  const w1 = entry(epoch1.proofs, wallet, rwb);
  const walletAuth = await authorize(walletOwner, wallet, rwb, w1.cumulativeAmount);
  await send('claimFor (ERC-1271)', relayer, 'claimFor', [
    wallet,
    rwb,
    w1.cumulativeAmount,
    w1.proof,
    treasury,
    walletAuth.message.deadline,
    walletAuth.signature,
  ]);
  check((await balanceOf(rwa, treasury)) === parseEther('40'), "treasury did not receive bob's 40 RWA");
  check((await balanceOf(rwb, treasury)) === parseEther('25'), "treasury did not receive the wallet's 25 RWB");
  check((await balanceOf(rwa, relayer)) === 0n, 'the relayer must not be paid');
  console.log('   claim (alice), claimFor signed by an EOA (bob) and by an ERC-1271 wallet; replay rejected');

  // ---------------------------------------------------------------------------------------- 4. epoch 2
  await send('proposeRoot (faulty)', updater, 'proposeRoot', [badEpoch2.manifest.root, badEpoch2.metadataHash]);
  await expectRevert(keeper, 'revokePendingRoot', [], 'NotGuardian');
  await send('revokePendingRoot', guardian, 'revokePendingRoot', []);
  await testClient.increaseTime({ seconds: Number(DAY) });
  await testClient.mine({ blocks: 1 });
  await expectRevert(keeper, 'acceptRoot', [], 'NoPendingRoot');
  console.log('4. the faulty epoch-2 root was vetoed by the guardian and can never be accepted');

  await fund(epoch2.manifest);
  await send('proposeRoot', updater, 'proposeRoot', [epoch2.manifest.root, epoch2.metadataHash]);
  await testClient.increaseTime({ seconds: Number(DAY) });
  await testClient.mine({ blocks: 1 });
  await send('acceptRoot', keeper, 'acceptRoot', []);
  check((await readBig('epoch')) === 2n, 'epoch counter != 2');

  // Old proofs die with the old root; the top-up pays only the delta.
  await expectRevert(alice, 'claim', [alice, rwa, a1.cumulativeAmount, a1.proof], 'InvalidProof');
  const a2 = entry(epoch2.proofs, alice, rwa);
  await send('claim (top-up)', alice, 'claim', [alice, rwa, a2.cumulativeAmount, a2.proof]);
  check((await balanceOf(rwa, alice)) === parseEther('160'), 'alice top-up did not pay exactly 60 RWA');
  console.log("   epoch 2 accepted; alice's top-up paid only the 60 RWA delta; her epoch-1 proof is dead");

  // Everything still owed goes out in one multiproof transaction.
  const owed: number[] = [];
  for (let i = 0; i < epoch2.tree.length; i++) {
    const a = epoch2.tree.allocationAt(i);
    if (a.cumulativeAmount > (await readBig('claimed', [a.account, a.token]))) owed.push(i);
  }
  const mp = epoch2.tree.getMultiProof(owed);
  const leaves = mp.values.map(([account, token, cumulativeAmount]) => ({
    account,
    token,
    cumulativeAmount: BigInt(cumulativeAmount),
  }));
  await send(`claimMany (${leaves.length} leaves)`, keeper, 'claimMany', [leaves, mp.proof, mp.proofFlags]);
  const hashes = `${mp.proof.length} proof hash${mp.proof.length === 1 ? '' : 'es'}`;
  console.log(`   claimMany paid the remaining ${leaves.length} leaves in one transaction with ${hashes}`);

  // ---------------------------------------------------------------------------------------- 5. final state
  for (let i = 0; i < epoch2.tree.length; i++) {
    const a = epoch2.tree.allocationAt(i);
    check(
      (await readBig('claimed', [a.account, a.token])) === a.cumulativeAmount,
      `${a.account} / ${a.token} is not fully claimed`,
    );
  }
  for (const t of epoch2.manifest.tokens) {
    check((await balanceOf(t.token, distributor)) === 0n, `the vault still holds ${t.token}`);
  }
  console.log(
    `5. every leaf fully claimed, vault empty (RWA ${formatEther(BigInt(epoch2.manifest.tokens.find((t) => t.token === rwa)?.cumulativeTotal ?? '0'))}` +
      `, RWB ${formatEther(BigInt(epoch2.manifest.tokens.find((t) => t.token === rwb)?.cumulativeTotal ?? '0'))} distributed)`,
  );

  console.log('\nGas used (anvil receipts):');
  const width = Math.max(...gas.map(([l]) => l.length));
  for (const [label, used] of gas) {
    if (label.startsWith('deploy') || label.startsWith('fund')) continue;
    console.log(`  ${label.padEnd(width)}  ${used.toLocaleString('en-US')}`);
  }
}

async function main(): Promise<number> {
  run('forge', ['build']);
  const workDir = mkdtempSync(join(tmpdir(), 'cmd-demo-'));
  const { url, child } = await startAnvil();
  try {
    await demo(url, workDir);
    console.log('\ndemo ok');
    return 0;
  } catch (err) {
    console.error(`demo failed: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}`);
    return 1;
  } finally {
    child.kill();
    rmSync(workDir, { recursive: true, force: true });
  }
}

process.exitCode = await main();
