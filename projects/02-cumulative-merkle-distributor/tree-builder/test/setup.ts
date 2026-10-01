// SPDX-License-Identifier: MIT
import fc from 'fast-check';

// Deterministic in CI: FC_SEED pins every property's random stream (the workflow sets it); locally each run explores
// new inputs. A failing seed is printed by fast-check and can be replayed by exporting FC_SEED.
const seed = process.env.FC_SEED === undefined ? undefined : Number(process.env.FC_SEED);
fc.configureGlobal({ numRuns: 200, ...(seed === undefined ? {} : { seed }) });
