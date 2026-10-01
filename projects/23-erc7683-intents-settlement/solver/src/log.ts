// SPDX-License-Identifier: MIT
// Structured JSON-lines logging to stderr. BigInts are rendered as decimal strings.

/** Severity of a log line. */
export type LogLevel = "debug" | "info" | "warn" | "error";

/** Structured logger: every line is one JSON object with the message, the level and the fields. */
export interface Logger {
  debug(msg: string, fields?: Record<string, unknown>): void;
  info(msg: string, fields?: Record<string, unknown>): void;
  warn(msg: string, fields?: Record<string, unknown>): void;
  error(msg: string, fields?: Record<string, unknown>): void;
  child(fields: Record<string, unknown>): Logger;
}

const ORDER: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

function replacer(_key: string, value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (value instanceof Error) return { name: value.name, message: value.message };
  return value;
}

/** Logger writing JSON lines to `sink` (stderr by default) for lines at or above `minLevel`. */
export function createLogger(
  base: Record<string, unknown> = {},
  minLevel: LogLevel = "info",
  sink: (line: string) => void = (line) => process.stderr.write(`${line}\n`),
): Logger {
  const emit = (level: LogLevel, msg: string, fields?: Record<string, unknown>): void => {
    if (ORDER[level] < ORDER[minLevel]) return;
    sink(JSON.stringify({ t: new Date().toISOString(), level, msg, ...base, ...fields }, replacer));
  };
  return {
    debug: (msg, fields) => {
      emit("debug", msg, fields);
    },
    info: (msg, fields) => {
      emit("info", msg, fields);
    },
    warn: (msg, fields) => {
      emit("warn", msg, fields);
    },
    error: (msg, fields) => {
      emit("error", msg, fields);
    },
    child: (fields) => createLogger({ ...base, ...fields }, minLevel, sink),
  };
}

/** Logger that discards everything (tests). */
export const silentLogger: Logger = createLogger({}, "error", () => undefined);
