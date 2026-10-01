// SPDX-License-Identifier: MIT
import { describe, expect, it } from "vitest";

import { createLogger } from "../src/log.ts";

describe("logger", () => {
  it("writes one JSON line per message at or above the minimum level, with bigints and errors rendered", () => {
    const lines: string[] = [];
    const log = createLogger({ role: "test" }, "info", (line) => lines.push(line));
    log.debug("hidden");
    log.info("hello", { amount: 10n ** 20n });
    log.warn("careful", { error: new RangeError("boom") });
    log.error("broken");
    const parsed = lines.map((l) => JSON.parse(l) as Record<string, unknown>);
    expect(parsed.map((p) => p.level)).toEqual(["info", "warn", "error"]);
    expect(parsed[0]).toMatchObject({ msg: "hello", role: "test", amount: "100000000000000000000" });
    expect(parsed[1]?.error).toEqual({ name: "RangeError", message: "boom" });
    expect(typeof parsed[2]?.t).toBe("string");
  });

  it("child loggers add their fields and keep the level and sink", () => {
    const lines: string[] = [];
    const child = createLogger({ role: "solver" }, "debug", (line) => lines.push(line)).child({ orderId: "0x01" });
    child.debug("step");
    expect(JSON.parse(lines[0] ?? "{}")).toMatchObject({ level: "debug", msg: "step", role: "solver", orderId: "0x01" });
  });
});
