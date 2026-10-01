// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { bytesToHex, hexToBytes, stringToBytes } from "viem";

import { assertWellFormedSvg, attribute, decodeTokenUri, expectedSymbol, svgTexts } from "../support/metadata.js";
import { E18, MONTH, T0, linearParams } from "../support/params.js";
import { Rng, runs } from "../support/random.js";

/** RawSymbolToken.SymbolMode */
const Mode = { AbiString: 0, Bytes32: 1, Revert: 2, BurnGas: 3, Empty: 4 } as const;

/** Hand-picked payloads that have broken real-world NFT renderers or XML/JSON embedders. */
const CORPUS: string[] = [
  "",
  "USDC",
  "<script>alert(1)</script>",
  '"><svg onload=alert(1)>',
  "]]><![CDATA[",
  "<!-- -->",
  "&amp;&#x41;&lt;",
  "\\u0022\\\\",
  '{"a":1}',
  "\u0000\u0001\u001f\u007f",
  "‮RTL",
  "\u{1F680}ROCKET",
  "Ωmega€",
  "a".repeat(64),
  "b".repeat(65),
  "tab\tnew\nline\r",
];

describe("untrusted token symbols (escaping fuzz against XML and JSON parsers)", async () => {
  const { viem } = await network.create();
  const [sender, recipient] = await viem.getWalletClients();
  assert.ok(sender !== undefined && recipient !== undefined);

  const renderer = await viem.deployContract("StreamRenderer");
  const vesting = await viem.deployContract("VestingStreams", [renderer.address, sender.account.address]);
  const token = await viem.deployContract("RawSymbolToken", ["0x", 18]);
  await token.write.mint([sender.account.address, 1_000n * E18]);
  await token.write.approve([vesting.address, 1_000n * E18]);
  await vesting.write.create([
    token.address,
    linearParams({ recipient: recipient.account.address, deposit: 100n * E18, start: T0, end: T0 + MONTH }),
  ]);
  const streamId = 1n;

  /** Renders the stream with the current symbol and checks both documents plus the symbol round trip. */
  async function assertRendersSafely(raw: Uint8Array, expected: string): Promise<void> {
    const { metadata, svg } = decodeTokenUri(await vesting.read.tokenURI([streamId]));
    assertWellFormedSvg(svg);
    assert.equal(attribute(metadata, "Token"), expected, "JSON value does not round-trip");
    assert.ok(
      svgTexts(svg).includes(`100 ${expected}`),
      `SVG text does not round-trip for ${bytesToHex(raw)}: expected "100 ${expected}"`,
    );
  }

  it(`renders ${CORPUS.length} hostile corpus symbols safely`, async () => {
    for (const text of CORPUS) {
      const raw = stringToBytes(text);
      await token.write.setSymbol([bytesToHex(raw), Mode.AbiString]);
      await assertRendersSafely(raw, expectedSymbol(raw));
    }
  });

  it(`renders ${runs(150)} random byte strings safely (seeded)`, async () => {
    const rng = new Rng();
    // Bias toward bytes that matter for XML/JSON: markup, quotes, escapes, controls, DEL and high bytes.
    const interesting = [
      0x00, 0x09, 0x0a, 0x0d, 0x1f, 0x22, 0x26, 0x27, 0x3c, 0x3e, 0x5c, 0x7f, 0x80, 0xc3, 0xe2, 0xff,
    ];
    for (let i = 0; i < runs(150); i++) {
      const raw = Uint8Array.from({ length: rng.int(0, 80) }, () =>
        rng.int(0, 2) === 0 ? rng.pick(interesting) : rng.int(0, 255),
      );
      await token.write.setSymbol([bytesToHex(raw), Mode.AbiString]);
      await assertRendersSafely(raw, expectedSymbol(raw));
    }
  });

  it("interprets bytes32 symbols as null-terminated strings", async () => {
    for (const text of ["MKR", "SAI\u0000JUNK", "<&>"]) {
      const raw = stringToBytes(text);
      await token.write.setSymbol([bytesToHex(raw), Mode.Bytes32]);
      const visible = raw.slice(0, raw.indexOf(0) === -1 ? raw.length : raw.indexOf(0));
      await assertRendersSafely(raw, expectedSymbol(visible));
    }
  });

  it("renders UNKNOWN when symbol() reverts, returns nothing or burns all gas", async () => {
    for (const mode of [Mode.Revert, Mode.Empty, Mode.BurnGas]) {
      await token.write.setSymbol(["0x", mode]);
      await assertRendersSafely(hexToBytes("0x"), "UNKNOWN");
    }
  });

  it("the well-formedness oracle itself rejects the documents an unescaped symbol would produce", () => {
    const wrap = (body: string) => `<svg xmlns="http://www.w3.org/2000/svg">${body}</svg>`;
    assertWellFormedSvg(wrap('<text x="1">100 A&amp;B &lt;&gt; &quot;&#39;</text>'));
    const broken = [
      wrap("<text>100 <script>alert(1)</script></text>x<b>"), // unbalanced markup
      wrap("<text>100 Q&A</text>"), // bare ampersand
      wrap('<text x="<">100</text>'), // raw '<' in an attribute
      wrap("<text>100 ]]></text>"), // CDATA terminator in text
      wrap(`<text>100 ${String.fromCharCode(1)}</text>`), // control character (0x01) in text
      wrap("<!-- a -- b --><text>100</text>"), // '--' inside a comment
    ];
    for (const svg of broken) {
      assert.throws(
        () => {
          assertWellFormedSvg(svg);
        },
        `accepted malformed SVG: ${JSON.stringify(svg)}`,
      );
    }
  });
});
