// SPDX-License-Identifier: MIT
// The actor factory shared by src/main.ts and e2e/crash-solver.ts: role parsing, key handling, the run loop.
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { type Actor, ROLES, buildActor, parseRole, runActor } from "../src/actors.ts";
import { silentLogger } from "../src/log.ts";
import { FakeWorld, keyOf } from "./fakeworld.ts";

const dirs: string[] = [];
const saved = { ...process.env };
afterEach(() => {
  process.env = { ...saved };
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("actors", () => {
  it("parses the four roles and rejects anything else", () => {
    for (const role of ROLES) expect(parseRole(role)).toBe(role);
    expect(() => parseRole("liquidator")).toThrow(/unknown role liquidator/);
  });

  it("builds every role from the environment's keys, and refuses a missing or malformed key", () => {
    const dir = mkdtempSync(join(tmpdir(), "actors-"));
    dirs.push(dir);
    const config = new FakeWorld().config("0x0000000000000000000000000000000000000001", join(dir, "solver.db"));
    process.env.SOLVER_PRIVATE_KEY = keyOf("solver");
    process.env.RELAYER_PRIVATE_KEY = keyOf("relayer");
    process.env.WATCHER_PRIVATE_KEY = keyOf("watcher");
    for (const role of ROLES) {
      const actor = buildActor(role, config, silentLogger);
      expect(typeof actor.tick).toBe("function");
      actor.close();
    }
    process.env.WATCHER_PRIVATE_KEY = "0x1234";
    expect(() => buildActor("watchtower", config, silentLogger)).toThrow(/WATCHER_PRIVATE_KEY/);
  });

  it("runs an actor for the requested number of ticks, logs tick failures, and closes it", async () => {
    const config = new FakeWorld().config("0x0000000000000000000000000000000000000001", ":memory:");
    let ticks = 0;
    let closed = false;
    const lines: string[] = [];
    const log = {
      ...silentLogger,
      error: (msg: string) => {
        lines.push(msg);
      },
    };
    const actor: Actor = {
      tick: () => {
        ticks++;
        return ticks === 2 ? Promise.reject(new Error("rpc down")) : Promise.resolve();
      },
      close: () => {
        closed = true;
      },
    };
    await runActor(actor, config, log, 3);
    expect(ticks).toBe(3);
    expect(closed).toBe(true);
    expect(lines).toEqual(["tick failed"]);
  });
});
