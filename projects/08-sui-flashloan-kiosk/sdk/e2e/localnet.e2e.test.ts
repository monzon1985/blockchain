// SPDX-License-Identifier: MIT
//
// End-to-end on a real Sui localnet (`sui start --force-regenesis`, free
// ports): publish both packages, run the two single-transaction PTBs built by
// the SDK, and watch the chain reject the attacks the Move tests describe.
//
// Gas of the headline transactions is checked against gas-snapshot.json:
// computation exactly (Sui charges it in buckets), storage within 1 %. Run with
// UPDATE_GAS_SNAPSHOT=1 to rewrite the snapshot after an intended change.

import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import type { SuiClientTypes } from '@mysten/sui/client';
import type { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { describeStatus, moveAbort } from '../src/errors.js';
import { buildFlashArbitrageTx } from '../src/flash-arbitrage.js';
import { buildKioskPurchaseTx } from '../src/kiosk-purchase.js';
import { type PoolSnapshot, quoteArbitrage, royaltyFee } from '../src/math.js';
import type { PoolRef, SharedRef } from '../src/refs.js';
import {
  type Executed,
  type Localnet,
  type SuiCli,
  bool,
  cliForLocalnet,
  coinDelta,
  copyPackage,
  createdOne,
  executeOk,
  executeUnchecked,
  fundedKeypair,
  gasPaid,
  publish,
  publishedPackage,
  startLocalnet,
  suiDelta,
  u64,
  upgradeWithCli,
  view,
} from './localnet.js';

const ROOT = resolve(import.meta.dirname, '..', '..');
const GAS_SNAPSHOT = resolve(ROOT, 'gas-snapshot.json');
const UPDATE_GAS_SNAPSHOT = process.env['UPDATE_GAS_SNAPSHOT'] === '1';
/** Allowed drift of `storageCost` against the snapshot, in percent. */
const STORAGE_TOLERANCE_PCT = 1n;
const PRICE = 1_000_000_000n; // 1 SUI
const ROYALTY_BPS = 500n;
const MIN_ROYALTY = 10_000_000n;
const MARKERS = ['LP_L', 'LP_X', 'LP_Y'] as const;

let net: Localnet;
let cli: SuiCli;
let deployer: Ed25519Keypair;
let trader: Ed25519Keypair;
let buyer: Ed25519Keypair;
let buyer2: Ed25519Keypair;
let pkg: string;
let alpha: string;
let beta: string;
const pools: Record<'L' | 'X' | 'Y', PoolRef> = {} as Record<'L' | 'X' | 'Y', PoolRef>;
let policy: SharedRef;
let policyAdmin: string;
let mintCap: string;
let adminCap: string;
let upgradeCap: string;
let alphaCap: string;
let coinsPkg: string;
/** The transaction that created the three pools (and their LP currencies). */
let poolCreation: Executed;
/** Teardown steps registered by beforeAll as each resource comes up. */
const cleanup: (() => Promise<void>)[] = [];
/** Gas of the headline transactions, printed once at the end of the run. */
const gasReport: Record<string, SuiClientTypes.GasCostSummary> = {};
type GasEntry = Pick<SuiClientTypes.GasCostSummary, 'computationCost' | 'storageCost' | 'storageRebate'>;
/** The committed gas-snapshot.json. */
let committedGas: Record<string, GasEntry>;

/** Records `gas` under `name` and checks it against the committed snapshot. */
function checkGas(name: string, gas: SuiClientTypes.GasCostSummary): void {
  gasReport[name] = gas;
  if (UPDATE_GAS_SNAPSHOT) return;
  const want = committedGas[name];
  if (want === undefined) throw new Error(`gas-snapshot.json has no entry "${name}" (UPDATE_GAS_SNAPSHOT=1)`);
  expect(BigInt(gas.computationCost), `${name}: computationCost`).toBe(BigInt(want.computationCost));
  const drift = BigInt(gas.storageCost) - BigInt(want.storageCost);
  const abs = drift < 0n ? -drift : drift;
  expect(abs * 100n <= BigInt(want.storageCost) * STORAGE_TOLERANCE_PCT, `${name}: storageCost`).toBe(true);
}

const itemType = (): string => `${pkg}::collectible::Collectible`;
const lpCoin = (marker: string): string => `${pkg}::pool::LpCoin<${coinsPkg}::markers::${marker}>`;

async function snapshot(pool: PoolRef): Promise<PoolSnapshot> {
  const [a, b] = await view(net, deployer.toSuiAddress(), (tx) => {
    tx.moveCall({
      target: `${pkg}::pool::reserves`,
      typeArguments: [pool.coinA, pool.coinB, pool.lp],
      arguments: [tx.object(pool.objectId)],
    });
  });
  return { reserveA: u64(a), reserveB: u64(b), swapFeeBps: 30n, flashFeeBps: 30n };
}

/** Creator mints a collectible into a fresh shared kiosk and lists it. */
async function listNewItem(name: string): Promise<{ kiosk: SharedRef; item: string }> {
  const tx = new Transaction();
  const [kiosk, cap] = tx.moveCall({ target: '0x2::kiosk::new' });
  const item = tx.moveCall({
    target: `${pkg}::collectible::mint`,
    arguments: [tx.object(mintCap), tx.pure.string(name)],
  });
  tx.moveCall({
    target: '0x2::kiosk::lock',
    typeArguments: [`${pkg}::collectible::Collectible`],
    arguments: [kiosk!, cap!, tx.object(policy.objectId), item],
  });
  tx.moveCall({
    target: '0x2::transfer::public_share_object',
    typeArguments: ['0x2::kiosk::Kiosk'],
    arguments: [kiosk!],
  });
  tx.transferObjects([cap!], deployer.toSuiAddress());
  const done = await executeOk(net, deployer, tx);
  const kioskRef = createdOne(done, /^0x2::kiosk::Kiosk$|::kiosk::Kiosk$/);
  const itemRef = createdOne(done, /::collectible::Collectible$/);
  const capRef = createdOne(done, /::kiosk::KioskOwnerCap$/);

  const list = new Transaction();
  list.moveCall({
    target: '0x2::kiosk::list',
    typeArguments: [`${pkg}::collectible::Collectible`],
    arguments: [
      list.object(kioskRef.id),
      list.object(capRef.id),
      list.pure.id(itemRef.id),
      list.pure.u64(PRICE),
    ],
  });
  await executeOk(net, deployer, list);
  return {
    kiosk: { objectId: kioskRef.id, initialSharedVersion: kioskRef.initialSharedVersion! },
    item: itemRef.id,
  };
}

beforeAll(async () => {
  committedGas = JSON.parse(await readFile(GAS_SNAPSHOT, 'utf8')) as Record<string, GasEntry>;
  net = await startLocalnet();
  cleanup.push(() => net.stop());
  // The deployer's key lives in a throw-away CLI config too, so the package
  // upgrade at the end can go through `sui client test-upgrade`.
  cli = await cliForLocalnet(net);
  cleanup.push(() => cli.dispose());
  [deployer, trader, buyer, buyer2] = await Promise.all([
    fundedKeypair(net, cli.keypair),
    fundedKeypair(net),
    fundedKeypair(net),
    fundedKeypair(net),
  ]);

  const main = await publish(net, deployer, ROOT);
  pkg = publishedPackage(main);
  const policyRef = createdOne(main, /::transfer_policy::TransferPolicy<.*::collectible::Collectible>$/);
  policy = { objectId: policyRef.id, initialSharedVersion: policyRef.initialSharedVersion! };
  policyAdmin = createdOne(main, /::collectible::PolicyAdmin$/).id;
  mintCap = createdOne(main, /::collectible::MintCap$/).id;
  adminCap = createdOne(main, /::pool::AdminCap$/).id;
  upgradeCap = createdOne(main, /::package::UpgradeCap$/).id;

  const coins = await publish(net, deployer, resolve(ROOT, 'demo', 'coins'));
  coinsPkg = publishedPackage(coins);
  alpha = `${coinsPkg}::alpha::ALPHA`;
  beta = `${coinsPkg}::beta::BETA`;
  const cap = (module: string, name: string): string =>
    createdOne(coins, new RegExp(`::coin::TreasuryCap<.*::${module}::${name}>$`)).id;
  alphaCap = cap('alpha', 'ALPHA');

  // One PTB mints both coins and creates all three pools; each `create_pool`
  // registers its pool's LP coin in the CoinRegistry (0xc).
  const tx = new Transaction();
  const specs = [
    ['L', 'LP_L', 1_000_000_000n, 1_000_000_000n],
    ['X', 'LP_X', 500_000_000n, 1_000_000_000n],
    ['Y', 'LP_Y', 1_000_000_000n, 1_000_000_000n],
  ] as const;
  for (const [, marker, a, b] of specs) {
    const coinA = tx.moveCall({
      target: '0x2::coin::mint',
      typeArguments: [alpha],
      arguments: [tx.object(cap('alpha', 'ALPHA')), tx.pure.u64(a)],
    });
    const coinB = tx.moveCall({
      target: '0x2::coin::mint',
      typeArguments: [beta],
      arguments: [tx.object(cap('beta', 'BETA')), tx.pure.u64(b)],
    });
    const [lp, poolCap] = tx.moveCall({
      target: `${pkg}::pool::create_pool`,
      typeArguments: [alpha, beta, `${coinsPkg}::markers::${marker}`],
      arguments: [tx.object('0xc'), coinA, coinB],
    });
    tx.transferObjects([lp!, poolCap!], deployer.toSuiAddress());
  }
  poolCreation = await executeOk(net, deployer, tx);
  for (const [key, marker] of specs) {
    const ref = createdOne(poolCreation, new RegExp(`::pool::Pool<.*::markers::${marker}>$`));
    pools[key] = {
      objectId: ref.id,
      initialSharedVersion: ref.initialSharedVersion!,
      coinA: alpha,
      coinB: beta,
      lp: `${coinsPkg}::markers::${marker}`,
    };
  }
}, 600_000);

afterAll(async () => {
  if (Object.keys(gasReport).length > 0) {
    console.log('Gas on localnet (MIST): computation / storage / rebate');
    for (const [name, g] of Object.entries(gasReport)) {
      console.log(`  ${name.padEnd(34)} ${g.computationCost} / ${g.storageCost} / ${g.storageRebate}`);
    }
    if (UPDATE_GAS_SNAPSHOT) {
      const entries = Object.entries(gasReport).map(([name, g]) => [
        name,
        { computationCost: g.computationCost, storageCost: g.storageCost, storageRebate: g.storageRebate },
      ]);
      await writeFile(GAS_SNAPSHOT, `${JSON.stringify(Object.fromEntries(entries), null, 2)}\n`);
      console.log(`Wrote ${GAS_SNAPSHOT}`);
    }
  }
  // Reverse order of acquisition; entries only exist for what beforeAll created.
  for (const release of cleanup.reverse()) await release();
});

describe('pool creation', () => {
  // A creator-supplied LP currency could be regulated, and its DenyCapV2 could
  // freeze every LP's withdrawal. Here each pool registered its own LP coin.
  it('registers every LP coin itself: unregulated, metadata frozen, minted to the creator', async () => {
    for (const marker of MARKERS) {
      const type = lpCoin(marker);
      const currency = createdOne(
        poolCreation,
        new RegExp(`::coin_registry::Currency<.*::pool::LpCoin<.*::markers::${marker}>>$`),
      );
      expect(currency.initialSharedVersion).toBeDefined();
      createdOne(poolCreation, new RegExp(`::coin::Coin<.*::pool::LpCoin<.*::markers::${marker}>>$`));
      const read = async (fn: string): Promise<Uint8Array | undefined> =>
        (
          await view(net, deployer.toSuiAddress(), (tx) => {
            tx.moveCall({
              target: `0x2::coin_registry::${fn}`,
              typeArguments: [type],
              arguments: [tx.object(currency.id)],
            });
          })
        )[0];
      expect(bool(await read('is_regulated'))).toBe(false);
      expect(bool(await read('is_metadata_cap_deleted'))).toBe(true);
      // Option<ID>::none serialises as a single 0 byte.
      expect(Array.from((await read('deny_cap_id')) ?? [])).toEqual([0]);
    }
  });
});

describe('flash-loan arbitrage PTB', () => {
  it('borrows, swaps on X and Y, repays and keeps exactly the quoted profit, in one transaction', async () => {
    const [lender, x, y] = await Promise.all([snapshot(pools.L), snapshot(pools.X), snapshot(pools.Y)]);
    const quote = quoteArbitrage(lender, x, y, 'A', 10_000_000n);
    // Same pools as the Move test `cross_pool_arbitrage_repays_and_keeps_the_profit`.
    expect(quote.profit).toBe(9_088_862n);

    const tx = buildFlashArbitrageTx({
      packageId: pkg,
      lender: { ...pools.L, flashFeeBps: 30n },
      sellOn: pools.X,
      buyOn: pools.Y,
      side: 'A',
      amount: quote.borrowed,
      minProfit: quote.profit,
      recipient: trader.toSuiAddress(),
    });
    const done = await executeOk(net, trader, tx);
    checkGas('flash arbitrage PTB (7 commands)', done.effects.gasUsed);

    // The trader started with zero ALPHA and ends with exactly the profit.
    expect(coinDelta(done, trader.toSuiAddress(), alpha)).toBe(quote.profit);
    const kinds = done.events.map((e) => e.eventType.split('::').slice(1).join('::'));
    expect(kinds).toEqual(
      expect.arrayContaining(['pool::FlashLoanTaken', 'pool::Swapped', 'pool::FlashLoanRepaid']),
    );
    const after = await snapshot(pools.L);
    expect(after.reserveA).toBe(lender.reserveA + quote.fee);
    expect(after.reserveB).toBe(lender.reserveB);
  });

  // Sui's PTB checker enforces the same linearity as the Move compiler: a
  // result without `drop` that is never consumed fails the whole transaction.
  it('rejects a PTB that borrows and never repays: the receipt cannot be dropped', async () => {
    const before = await snapshot(pools.L);
    const tx = new Transaction();
    const [loan] = tx.moveCall({
      target: `${pkg}::pool::flash_borrow_a`,
      typeArguments: [alpha, beta, pools.L.lp],
      arguments: [tx.object(pools.L.objectId), tx.pure.u64(1_000_000n)],
    });
    tx.transferObjects([loan!], trader.toSuiAddress());
    const done = await executeUnchecked(net, trader, tx);

    expect(done.status.success).toBe(false);
    expect(describeStatus(done.status)).toMatch(/UnusedValueWithoutDrop/);
    expect(await snapshot(pools.L)).toEqual(before);
  });

  it('rejects swapping on the lending pool while its loan is open', async () => {
    // Statically valid PTB (the receipt is consumed by a repay at the end), so
    // it really executes, and the pool's own lock stops it at the swap.
    const tx = new Transaction();
    const [loan, receipt] = tx.moveCall({
      target: `${pkg}::pool::flash_borrow_a`,
      typeArguments: [alpha, beta, pools.L.lp],
      arguments: [tx.object(pools.L.objectId), tx.pure.u64(900_000_000n)],
    });
    const out = tx.moveCall({
      target: `${pkg}::pool::swap_a_for_b`,
      typeArguments: [alpha, beta, pools.L.lp],
      arguments: [tx.object(pools.L.objectId), loan!, tx.pure.u64(0n)],
    });
    tx.transferObjects([out], trader.toSuiAddress());
    const nothing = tx.moveCall({ target: '0x2::coin::zero', typeArguments: [alpha] });
    tx.moveCall({
      target: `${pkg}::pool::flash_repay_a`,
      typeArguments: [alpha, beta, pools.L.lp],
      arguments: [tx.object(pools.L.objectId), receipt!, nothing],
    });
    const done = await executeUnchecked(net, trader, tx);

    expect(moveAbort(done.status)).toMatchObject({ module: 'pool', constant: 'EFlashLoanOpen' });
  });
});

describe('kiosk purchase PTB', () => {
  let first: { kiosk: SharedRef; item: string };
  let buyerKiosk: SharedRef;
  let buyerKioskCap: string;

  it('buys into a brand-new kiosk, pays the royalty and satisfies every rule, in one transaction', async () => {
    first = await listNewItem('Genesis');
    const royalty = royaltyFee(PRICE, ROYALTY_BPS, MIN_ROYALTY);
    const tx = buildKioskPurchaseTx({
      packageId: pkg,
      policy,
      sellerKiosk: first.kiosk,
      itemId: first.item,
      price: PRICE,
      maxRoyalty: 2n * royalty,
      buyerKiosk: 'new',
      buyer: buyer.toSuiAddress(),
    });
    const done = await executeOk(net, buyer, tx);
    checkGas('kiosk purchase PTB, new kiosk', done.effects.gasUsed);

    // Buyer paid price + exact royalty + gas; nothing else left the account.
    expect(suiDelta(done, buyer.toSuiAddress())).toBe(-(PRICE + royalty + gasPaid(done)));
    const kioskRef = createdOne(done, /::kiosk::Kiosk$/);
    buyerKiosk = { objectId: kioskRef.id, initialSharedVersion: kioskRef.initialSharedVersion! };
    buyerKioskCap = createdOne(done, /::kiosk::KioskOwnerCap$/).id;
    const [locked] = await view(net, buyer.toSuiAddress(), (v) => {
      v.moveCall({
        target: '0x2::kiosk::is_locked',
        arguments: [v.object(buyerKiosk.objectId), v.pure.id(first.item)],
      });
    });
    expect(bool(locked)).toBe(true);

    // The creator's PolicyAdmin can withdraw exactly the royalty from the policy.
    const withdraw = new Transaction();
    const coin = withdraw.moveCall({
      target: `${pkg}::collectible::withdraw_royalties`,
      arguments: [
        withdraw.object(policyAdmin),
        withdraw.object(policy.objectId),
        withdraw.pure.option('u64', null),
      ],
    });
    withdraw.transferObjects([coin], deployer.toSuiAddress());
    const paid = await executeOk(net, deployer, withdraw);
    expect(suiDelta(paid, deployer.toSuiAddress())).toBe(royalty - gasPaid(paid));
  });

  it('blocks a resale inside the cooldown window', async () => {
    const list = new Transaction();
    list.moveCall({
      target: '0x2::kiosk::list',
      typeArguments: [`${pkg}::collectible::Collectible`],
      arguments: [
        list.object(buyerKiosk.objectId),
        list.object(buyerKioskCap),
        list.pure.id(first.item),
        list.pure.u64(PRICE),
      ],
    });
    await executeOk(net, buyer, list);

    const tx = buildKioskPurchaseTx({
      packageId: pkg,
      policy,
      sellerKiosk: buyerKiosk,
      itemId: first.item,
      price: PRICE,
      maxRoyalty: PRICE,
      buyerKiosk: 'new',
      buyer: buyer2.toSuiAddress(),
    });
    const done = await executeUnchecked(net, buyer2, tx);
    expect(moveAbort(done.status)).toMatchObject({ module: 'cooldown_rule', constant: 'ECooldownActive' });
  });

  it('lets the resale through once the PolicyAdmin shortens the cooldown', async () => {
    const tx = new Transaction();
    tx.moveCall({
      target: `${pkg}::collectible::set_cooldown`,
      arguments: [tx.object(policyAdmin), tx.object(policy.objectId), tx.pure.u64(1_000n)],
    });
    await executeOk(net, deployer, tx);
    await new Promise((r) => setTimeout(r, 2_500)); // let the on-chain clock pass 1 s

    const resale = buildKioskPurchaseTx({
      packageId: pkg,
      policy,
      sellerKiosk: buyerKiosk,
      itemId: first.item,
      price: PRICE,
      maxRoyalty: PRICE,
      buyerKiosk: 'new',
      buyer: buyer2.toSuiAddress(),
    });
    const done = await executeOk(net, buyer2, resale);
    expect(describeStatus(done.status)).toBe('success');
  });

  it('aborts in confirm_request when a rule is skipped (no royalty paid)', async () => {
    const second = await listNewItem('Second');
    const tx = new Transaction();
    const [payment] = tx.splitCoins(tx.gas, [tx.pure.u64(PRICE)]);
    const [item, request] = tx.moveCall({
      target: '0x2::kiosk::purchase',
      typeArguments: [itemType()],
      arguments: [tx.object(second.kiosk.objectId), tx.pure.id(second.item), payment],
    });
    tx.moveCall({
      target: `${pkg}::collectible::prove_cooldown`,
      arguments: [item!, tx.object(policy.objectId), request!, tx.object.clock()],
    });
    const [kiosk, cap] = tx.moveCall({ target: '0x2::kiosk::new' });
    tx.moveCall({
      target: '0x2::kiosk::lock',
      typeArguments: [itemType()],
      arguments: [kiosk!, cap!, tx.object(policy.objectId), item!],
    });
    tx.moveCall({
      target: `${pkg}::kiosk_lock_rule::prove`,
      typeArguments: [itemType()],
      arguments: [request!, kiosk!],
    });
    tx.moveCall({
      target: '0x2::transfer_policy::confirm_request',
      typeArguments: [itemType()],
      arguments: [tx.object(policy.objectId), request!],
    });
    tx.moveCall({
      target: '0x2::transfer::public_share_object',
      typeArguments: ['0x2::kiosk::Kiosk'],
      arguments: [kiosk!],
    });
    tx.transferObjects([cap!], buyer.toSuiAddress());
    const done = await executeUnchecked(net, buyer, tx);

    // transfer_policy::EPolicyNotSatisfied == 0 (a plain u64 constant, no clever error).
    expect(moveAbort(done.status)).toMatchObject({ module: 'transfer_policy', code: '0' });
  });
});

describe('versioned shared objects across a real package upgrade', () => {
  /** Deployer mints 10_000 ALPHA and sells it on pool Y through package `target`. */
  const swapVia = (target: string): Transaction => {
    const tx = new Transaction();
    const coin = tx.moveCall({
      target: '0x2::coin::mint',
      typeArguments: [alpha],
      arguments: [tx.object(alphaCap), tx.pure.u64(10_000n)],
    });
    const out = tx.moveCall({
      target: `${target}::pool::swap_a_for_b`,
      typeArguments: [alpha, beta, pools.Y.lp],
      arguments: [tx.object(pools.Y.objectId), coin, tx.pure.u64(1n)],
    });
    tx.transferObjects([out], deployer.toSuiAddress());
    return tx;
  };

  it('v2 refuses a v1 pool until migrate, then v1 is locked out for good', async () => {
    const source = await copyPackage(ROOT, cli.dir, 'pool.move', (text) =>
      text.replace('const VERSION: u64 = 1;', 'const VERSION: u64 = 2;'),
    );
    const v2 = await upgradeWithCli(net, cli, { sourceDir: source, packageId: pkg, upgradeCap });
    expect(v2).not.toBe(pkg);

    // Right after the upgrade the pool is still at version 1: v1 works, v2 refuses it.
    await executeOk(net, deployer, swapVia(pkg));
    const early = await executeUnchecked(net, deployer, swapVia(v2));
    expect(moveAbort(early.status)).toMatchObject({ module: 'pool', constant: 'EWrongVersion' });

    // AdminCap-gated migration, called through the new package.
    const migrate = new Transaction();
    migrate.moveCall({
      target: `${v2}::pool::migrate`,
      typeArguments: [alpha, beta, pools.Y.lp],
      arguments: [migrate.object(pools.Y.objectId), migrate.object(adminCap)],
    });
    const migrated = await executeOk(net, deployer, migrate);
    checkGas('pool::migrate', migrated.effects.gasUsed);
    expect(migrated.events.map((e) => e.eventType)).toEqual([expect.stringMatching(/::pool::PoolMigrated$/)]);

    // The old code still exists on chain, but it can no longer touch the pool.
    const late = await executeUnchecked(net, deployer, swapVia(pkg));
    expect(moveAbort(late.status)).toMatchObject({ module: 'pool', constant: 'EWrongVersion' });
    await executeOk(net, deployer, swapVia(v2));

    const [version] = await view(net, deployer.toSuiAddress(), (tx) => {
      tx.moveCall({
        target: `${v2}::pool::version`,
        typeArguments: [alpha, beta, pools.Y.lp],
        arguments: [tx.object(pools.Y.objectId)],
      });
    });
    expect(u64(version)).toBe(2n);

    // Kiosk purchases after the upgrade, into fresh listings. Calls target v2;
    // `Collectible` keeps the id of the package that defined it, but Sui
    // resolves a type argument written with v2's id to that same type, so the
    // latest id alone is enough. `originalPackageId` emits the canonical tag.
    const purchase = async (
      name: string,
      ids: { packageId: string; originalPackageId?: string },
    ): Promise<Executed> => {
      const listed = await listNewItem(name);
      return executeOk(
        net,
        buyer,
        buildKioskPurchaseTx({
          ...ids,
          policy,
          sellerKiosk: listed.kiosk,
          itemId: listed.item,
          price: PRICE,
          maxRoyalty: PRICE,
          buyerKiosk: 'new',
          buyer: buyer.toSuiAddress(),
        }),
      );
    };
    const latestOnly = await purchase('Post-upgrade, latest id only', { packageId: v2 });
    expect(describeStatus(latestOnly.status)).toBe('success');
    const canonical = await purchase('Post-upgrade, canonical type', {
      packageId: v2,
      originalPackageId: pkg,
    });
    expect(describeStatus(canonical.status)).toBe('success');

    // Known limitation (docs/UPGRADES.md, "Rules and upgrades"): the policy
    // accepts a rule's receipt by type, and the type is the same in every
    // version, so v1's rule code still satisfies the policy after the upgrade.
    const legacy = await purchase('Post-upgrade, v1 rule code', { packageId: pkg });
    expect(describeStatus(legacy.status)).toBe('success');
  });
});
