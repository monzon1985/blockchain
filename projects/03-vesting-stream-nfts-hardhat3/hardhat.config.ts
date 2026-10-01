// SPDX-License-Identifier: MIT
import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

const compiler = {
  version: "0.8.37",
  settings: {
    evmVersion: "osaka",
    optimizer: { enabled: true, runs: 10_000 },
  },
};

/** Fixed fuzz seed: every profile replays the same input sequence, so CI is deterministic and failures reproduce. */
const FUZZ_SEED = "0x3e57ed";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    profiles: {
      default: compiler,
      production: compiler,
    },
  },
  networks: {
    // The in-process simulated chain used by `network.create()`. Pinning its genesis date keeps every scenario
    // (golden SVGs, gas table) reproducible: tests anchor their timestamps on 2026-03-01.
    default: {
      type: "edr-simulated",
      chainType: "l1",
      hardfork: "osaka",
      initialDate: "2026-01-01T00:00:00Z",
    },
    // Optional public testnet. Nothing here is read unless `--network sepolia` is used, and both values come from
    // the encrypted Hardhat keystore (`npx hardhat keystore set SEPOLIA_PRIVATE_KEY`), never from the repository.
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
  },
  paths: {
    tests: {
      solidity: "./test/solidity",
      nodejs: "./test/integration",
    },
  },
  test: {
    solidity: {
      profiles: {
        // Local default: fast enough to run on every change. `.gas-snapshot` is recorded with this profile.
        default: {
          fuzz: { runs: 256, seed: FUZZ_SEED },
          // failOnRevert: every handler action is pre-conditioned to succeed, so any revert is a bug.
          invariant: { runs: 64, depth: 64, failOnRevert: true },
        },
        // CI (`--test-profile ci`): a deeper campaign with the same seed.
        ci: {
          fuzz: { runs: 5_000, seed: FUZZ_SEED },
          invariant: { runs: 256, depth: 128, failOnRevert: true },
        },
        // Mutation campaign (`scripts/mutation.ts`): the default profile plus a finite per-call gas limit. The default
        // limit is effectively unbounded, so a mutant that hands the gas-guzzling hook all remaining gas (M12) would
        // make every invariant call loop for a very long time. 100M gas is ~25x the most expensive test call.
        mutation: {
          gasLimit: 100_000_000n,
          fuzz: { runs: 256, seed: FUZZ_SEED },
          invariant: { runs: 64, depth: 64, failOnRevert: true },
        },
      },
    },
  },
  coverage: {
    // Test-only tokens and recipients are not production code.
    skipFiles: ["contracts/mocks/**"],
  },
});
