// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

import { network } from "hardhat";

import { assertWellFormedSvg, attribute, decodeTokenUri, svgTexts } from "../support/metadata.js";
import { buildGoldenScenario } from "../support/scenario.js";

const GOLDEN_DIR = path.join(import.meta.dirname, "..", "golden");
/** `npm run golden:update` (or UPDATE_GOLDEN=1) rewrites the fixtures instead of comparing against them. */
const UPDATE = process.env.UPDATE_GOLDEN === "1" || process.env.npm_lifecycle_event === "golden:update";

const kebab = (name: string) => name.replace(/[A-Z0-9]+/g, (m) => `-${m.toLowerCase()}`);

describe("tokenURI golden files", async () => {
  const connection = await network.create();
  const scenario = await buildGoldenScenario(connection);
  const { vesting, renderer, ids } = scenario;

  for (const [name, streamId] of Object.entries(ids)) {
    const file = kebab(name);

    it(`stream #${streamId} (${name}) renders exactly test/golden/${file}.svg`, async () => {
      const { metadata, svg } = decodeTokenUri(await vesting.read.tokenURI([streamId]));
      assertWellFormedSvg(svg);
      assert.equal(
        await renderer.read.svgOf([vesting.address, streamId]),
        svg,
        "svgOf differs from the tokenURI image",
      );

      const json = `${JSON.stringify({ ...metadata, image: `<test/golden/${file}.svg>` }, null, 2)}\n`;
      const svgPath = path.join(GOLDEN_DIR, `${file}.svg`);
      const jsonPath = path.join(GOLDEN_DIR, `${file}.json`);
      if (UPDATE) {
        await mkdir(GOLDEN_DIR, { recursive: true });
        await writeFile(svgPath, `${svg}\n`);
        await writeFile(jsonPath, json);
        return;
      }
      assert.equal(svg, (await readFile(svgPath, "utf8")).trimEnd(), `SVG drifted from ${svgPath}`);
      assert.equal(json, await readFile(jsonPath, "utf8"), `metadata drifted from ${jsonPath}`);
    });
  }

  it("reports the lifecycle status of every scenario stream in the metadata", async () => {
    const expected: Record<keyof typeof ids, string> = {
      linearCliff: "Streaming",
      linearSettled: "Settled",
      segmented16: "Streaming",
      linearPending: "Pending",
      tranched12: "Streaming",
      segmentedCanceled: "Canceled",
      tranched32: "Streaming",
      linearDepleted: "Depleted",
      hostileSymbol: "Streaming",
      linearDust: "Streaming",
      canceledDust: "Canceled",
    };
    for (const [name, status] of Object.entries(expected)) {
      const { metadata } = decodeTokenUri(await vesting.read.tokenURI([ids[name as keyof typeof ids]]));
      assert.equal(attribute(metadata, "Status"), status, name);
    }
  });

  it("renders amounts with the token decimals, rounded down, and the live withdrawable amount", async () => {
    // Linear with cliff: 120,000 mUSD over 12 months (360 days), rendered 225 days in, 20,000 withdrawn.
    // Streamed = floor(120,000e6 * 225 / 360... in seconds) = 75,000 mUSD exactly at 7.5 of 12 months.
    const { svg } = decodeTokenUri(await vesting.read.tokenURI([ids.linearCliff]));
    const texts = svgTexts(svg);
    assert.ok(texts.includes("120,000 mUSD"), "deposit row");
    assert.ok(texts.includes("20,000 mUSD"), "withdrawn row");
    const streamed = await vesting.read.streamedAmountOf([ids.linearCliff]);
    const whole = streamed / 1_000_000n;
    const fraction = (streamed % 1_000_000n) / 100n;
    const formatted = `${whole.toLocaleString("en-US")}${fraction === 0n ? "" : `.${fraction.toString().padStart(4, "0").replace(/0+$/, "")}`} mUSD`;
    assert.ok(texts.includes(formatted), `streamed row ${formatted} not in ${texts.join(" | ")}`);
  });

  it("escapes dust amounts, displayed as `<0.0001`, in the SVG", async () => {
    const live = decodeTokenUri(await vesting.read.tokenURI([ids.linearDust])).svg;
    // STREAMED and WITHDRAWABLE rows: 0.00008 DEMO, one second into a four-year stream.
    assert.equal(svgTexts(live).filter((t) => t === "<0.0001 DEMO").length, 2, "streamed and withdrawable rows");
    const canceled = decodeTokenUri(await vesting.read.tokenURI([ids.canceledDust])).svg;
    // REFUNDED row: canceled one second before the end of a 100 DEMO, two-month stream.
    assert.ok(svgTexts(canceled).includes("<0.0001 DEMO"), "refunded row");
    for (const svg of [live, canceled]) {
      assert.ok(svg.includes(">&lt;0.0001 DEMO</text>"), "dust row is not escaped");
      assert.ok(!svg.includes("<0.0001"), "raw '<0.0001' in the SVG");
    }
  });

  it("escapes a hostile symbol in both the SVG and the JSON", async () => {
    const { metadata, svg } = decodeTokenUri(await vesting.read.tokenURI([ids.hostileSymbol]));
    assert.equal(attribute(metadata, "Token"), '<b>"Q&A\'s"</b>');
    assert.ok(svg.includes("&lt;b&gt;&quot;Q&amp;A&#39;s&quot;&lt;/b&gt;"));
    assert.ok(
      svgTexts(svg).some((t) => t.endsWith(' <b>"Q&A\'s"</b>')),
      "symbol does not round-trip through XML",
    );
  });
});
