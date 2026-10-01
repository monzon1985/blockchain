// SPDX-License-Identifier: MIT
/**
 * Mutation spot-check: injects realistic distributor bugs, one at a time, into a scratch copy of the project and
 * requires the Foundry suite to fail on every one of them. A surviving mutant means a behaviour no test pins down.
 *
 *   npm run mutation                 every mutant
 *   npm run mutation -- --only M04   a subset (comma-separated ids)
 *   npm run mutation -- --list       print the catalogue
 *
 * Each mutant is an exact text substitution that must match exactly once, so a refactor of the contract that silently
 * disarms a mutant fails this script instead. The unmutated copy must pass first (a broken harness kills everything).
 * Campaigns are lighter than the default profile (256 fuzz runs, 32 x 32 invariant calls), use the CI profile's fixed
 * seed (so a mutant that only a fuzz or invariant test kills is killed on every run, or on none) and stop at the
 * first failing test; the killing test is reported.
 */
import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const PROJECT = resolve(import.meta.dirname, '../..');
const SOURCE = 'src/CumulativeMerkleDistributor.sol';
/** Same seed as `[profile.ci.fuzz]` in foundry.toml; Foundry uses it for fuzz and invariant campaigns alike. */
export const FUZZ_SEED = '0x02c0ffee';

export interface Mutant {
  readonly id: string;
  readonly bug: string;
  readonly from: string;
  readonly to: string;
}

export const MUTANTS: readonly Mutant[] = [
  {
    id: 'M01',
    bug: 'Single-hashed leaf (no longer StandardMerkleTree-compatible)',
    from: 'keccak256(bytes.concat(keccak256(abi.encode(account, token, cumulativeAmount))))',
    to: 'keccak256(abi.encode(account, token, cumulativeAmount))',
  },
  {
    id: 'M02',
    bug: 'Timelock off by one second (`>` instead of `>=`)',
    from: 'require(block.timestamp >= pending.validAt,',
    to: 'require(block.timestamp > pending.validAt,',
  },
  {
    id: 'M03',
    bug: 'No timelock at all: proposals are acceptable immediately',
    from: 'uint64 validAt = uint64(block.timestamp + ROOT_TIMELOCK);',
    to: 'uint64 validAt = uint64(block.timestamp);',
  },
  {
    id: 'M04',
    bug: 'A replacement proposal inherits the displaced deadline (shortens the veto window)',
    from: 'uint64 validAt = uint64(block.timestamp + ROOT_TIMELOCK);',
    to: 'uint64 validAt = displaced.validAt != 0 ? displaced.validAt : uint64(block.timestamp + ROOT_TIMELOCK);',
  },
  {
    id: 'M05',
    bug: 'Guardian veto does not clear the pending root',
    from: 'delete pendingRoot;\n        emit RootRevoked(pending.root, msg.sender);',
    to: 'emit RootRevoked(pending.root, msg.sender);',
  },
  {
    id: 'M06',
    bug: 'acceptRoot leaves the pending root in place (re-acceptable, epoch inflates)',
    from: 'delete pendingRoot;\n        emit RootAccepted(',
    to: 'emit RootAccepted(',
  },
  {
    id: 'M07',
    bug: 'Updater can also veto (role confusion in onlyGuardian)',
    from: 'require(msg.sender == guardian, NotGuardian(msg.sender));',
    to: 'require(msg.sender == guardian || msg.sender == updater, NotGuardian(msg.sender));',
  },
  {
    id: 'M08',
    bug: 'Zero root accepted by proposeRoot',
    from: 'require(newRoot != bytes32(0), ZeroRoot());',
    to: '',
  },
  {
    id: 'M09',
    bug: 'Epoch counter not incremented',
    from: 'uint64 newEpoch = epoch + 1;',
    to: 'uint64 newEpoch = epoch;',
  },
  {
    id: 'M10',
    bug: 'Claim pays the whole cumulative amount instead of the delta',
    from: 'amount = cumulativeAmount - alreadyClaimed;',
    to: 'amount = cumulativeAmount;',
  },
  {
    id: 'M11',
    bug: 'Claimed total not recorded',
    from: 'claimed[account][token] = cumulativeAmount;',
    to: 'claimed[account][token] = alreadyClaimed;',
  },
  {
    id: 'M12',
    bug: 'Permissionless claim pays the caller instead of the account',
    from: 'amount = _claim(account, token, cumulativeAmount, proof, account);',
    to: 'amount = _claim(account, token, cumulativeAmount, proof, msg.sender);',
  },
  {
    id: 'M13',
    bug: 'Reentrancy guard dropped from claim',
    from: 'external\n        nonReentrant\n        returns (uint256 amount)\n    {\n        amount = _claim(',
    to: 'external\n        returns (uint256 amount)\n    {\n        amount = _claim(',
  },
  {
    id: 'M14',
    bug: 'claimFor deadline off by one second (`<` instead of `<=`)',
    from: 'require(block.timestamp <= deadline,',
    to: 'require(block.timestamp < deadline,',
  },
  {
    id: 'M15',
    bug: 'claimFor reads the nonce without consuming it (signatures replayable)',
    from: 'uint256 nonce = _useNonce(account);',
    to: 'uint256 nonce = nonces(account);',
  },
  {
    id: 'M16',
    bug: 'Any valid ECDSA signature accepted, whoever signed it',
    from: 'if (err == ECDSA.RecoverError.NoError && recovered == account) return true;',
    to: 'if (err == ECDSA.RecoverError.NoError && recovered != address(0)) return true;',
  },
  {
    id: 'M17',
    bug: 'Stock SignatureChecker routing: ECDSA only for code-less accounts (breaks EIP-7702 accounts)',
    from: 'if (err == ECDSA.RecoverError.NoError && recovered == account) return true;',
    to: 'if (account.code.length == 0 && err == ECDSA.RecoverError.NoError && recovered == account) return true;',
  },
  {
    id: 'M18',
    bug: 'claimFor recipient not validated (tokens can be burnt to address(0) or locked in the vault)',
    from: 'require(recipient != address(0) && recipient != address(this), InvalidRecipient(recipient));',
    to: '',
  },
  {
    id: 'M19',
    bug: 'claimMany accepts an empty batch',
    from: 'require(count != 0, EmptyClaimBatch());',
    to: '',
  },
  {
    id: 'M20',
    bug: 'claimMany drops its skip guard (zero payouts for claimed leaves, underflow for lowered ones)',
    from: 'if (c.cumulativeAmount > alreadyClaimed) {',
    to: 'if (true) {',
  },
  {
    id: 'M21',
    bug: 'claimMany pays the caller instead of each leaf account',
    from: 'amounts[i] = _pay(c.account, c.token, c.cumulativeAmount, alreadyClaimed, c.account);',
    to: 'amounts[i] = _pay(c.account, c.token, c.cumulativeAmount, alreadyClaimed, msg.sender);',
  },
  {
    id: 'M22',
    bug: 'claimFor signature does not bind the recipient (a relayer can redirect the payout)',
    from: 'abi.encode(CLAIM_AUTHORIZATION_TYPEHASH, account, token, cumulativeAmount, recipient, nonce, deadline)',
    to: 'abi.encode(CLAIM_AUTHORIZATION_TYPEHASH, account, token, cumulativeAmount, account, nonce, deadline)',
  },
  {
    id: 'M23',
    bug: 'Reentrancy guard dropped from claimFor',
    from: ') external nonReentrant returns (uint256 amount) {',
    to: ') external returns (uint256 amount) {',
  },
  {
    id: 'M24',
    bug: 'Reentrancy guard dropped from claimMany',
    from: 'external\n        nonReentrant\n        returns (uint256[] memory amounts)',
    to: 'external\n        returns (uint256[] memory amounts)',
  },
  {
    id: 'M25',
    bug: 'ECDSA recovery error ignored (a garbage signature "recovers" to address(0) and authorizes its leaf)',
    from: 'if (err == ECDSA.RecoverError.NoError && recovered == account) return true;',
    to: 'if (recovered == account) return true;',
  },
];

function apply(source: string, m: Mutant): string {
  const hits = source.split(m.from).length - 1;
  if (hits !== 1) throw new Error(`${m.id}: pattern must match exactly once in ${SOURCE}, matched ${hits} times`);
  return source.replace(m.from, () => m.to);
}

interface Outcome {
  readonly status: 'killed' | 'survived' | 'does not compile';
  readonly killer: string;
}

function forgeTest(dir: string): Outcome {
  const res = spawnSync('forge', ['test', '--fail-fast'], {
    cwd: dir,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: {
      ...process.env,
      FOUNDRY_PROFILE: 'default',
      // Some mutants leave a variable or parameter unused. The question here is whether the tests catch the bug, so
      // compiler warnings must not fail the build the way `deny = "warnings"` does for the real sources.
      FOUNDRY_DENY: 'never',
      FOUNDRY_FUZZ_SEED: FUZZ_SEED,
      FOUNDRY_FUZZ_RUNS: '256',
      FOUNDRY_INVARIANT_RUNS: '32',
      FOUNDRY_INVARIANT_DEPTH: '32',
    },
  });
  const output = `${res.stdout}\n${res.stderr}`;
  if (/Compiler run failed|Error \(\d+\)/.test(output)) return { status: 'does not compile', killer: '' };
  if (res.status === 0) return { status: 'survived', killer: '' };
  const fail = /\[FAIL[^\n]*?\]\s+(\w+)\(/.exec(output);
  const suite = /failing tests? in (\S+)/.exec(output);
  const where = suite?.[1]?.split(':').at(-1) ?? '';
  return { status: 'killed', killer: fail?.[1] !== undefined ? `${where}.${fail[1]}` : '(suite failed)' };
}

function main(): number {
  const args = process.argv.slice(2);
  if (args.includes('--list')) {
    for (const m of MUTANTS) console.log(`${m.id}  ${m.bug}`);
    return 0;
  }
  const onlyArg = args[args.indexOf('--only') + 1];
  const only = args.includes('--only') && onlyArg !== undefined ? new Set(onlyArg.split(',')) : null;
  const selected = MUTANTS.filter((m) => only === null || only.has(m.id));
  if (selected.length === 0) throw new Error('no mutant selected');

  const original = readFileSync(join(PROJECT, SOURCE), 'utf8');
  // Fail on a stale catalogue before spending minutes on forge.
  const mutated = new Map(selected.map((m) => [m.id, apply(original, m)]));

  const dir = mkdtempSync(join(tmpdir(), 'cmd-mutants-'));
  try {
    for (const entry of ['foundry.toml', 'soldeer.lock', 'src', 'test', 'script', 'dependencies']) {
      cpSync(join(PROJECT, entry), join(dir, entry), { recursive: true });
    }
    console.log(`scratch copy: ${dir}`);
    const baseline = forgeTest(dir);
    if (baseline.status !== 'survived') throw new Error(`the unmutated suite must pass first (${baseline.status})`);
    console.log('baseline: unmutated suite passes\n');

    const rows: [Mutant, Outcome][] = [];
    for (const m of selected) {
      writeFileSync(join(dir, SOURCE), mutated.get(m.id) ?? original);
      const started = Date.now();
      const outcome = forgeTest(dir);
      rows.push([m, outcome]);
      const secs = ((Date.now() - started) / 1000).toFixed(0);
      console.log(`${m.id}  ${outcome.status.padEnd(16)} ${outcome.killer.padEnd(64)} ${secs}s  ${m.bug}`);
    }
    writeFileSync(join(dir, SOURCE), original);

    const killed = rows.filter(([, o]) => o.status === 'killed').length;
    console.log(`\n${killed}/${rows.length} mutants killed`);
    return killed === rows.length ? 0 : 1;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

process.exitCode = main();
