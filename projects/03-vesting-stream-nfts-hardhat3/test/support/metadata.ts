// SPDX-License-Identifier: MIT
import assert from "node:assert/strict";

import { XMLParser } from "fast-xml-parser";
import { SyntaxValidator } from "fast-xml-validator";

const JSON_PREFIX = "data:application/json;base64,";
const SVG_PREFIX = "data:image/svg+xml;base64,";

/**
 * True for a UTF-16 code unit that XML 1.0 forbids anywhere in a document, even escaped: C0 controls other than
 * TAB/LF/CR, and the non-characters U+FFFE/U+FFFF.
 */
function isForbiddenXmlCodeUnit(code: number): boolean {
  return (code < 0x20 && code !== 0x09 && code !== 0x0a && code !== 0x0d) || code === 0xfffe || code === 0xffff;
}

/** XML 1.0 `Char` production: the code points a character reference may name. */
function isXmlChar(code: number): boolean {
  return (
    code === 0x09 ||
    code === 0x0a ||
    code === 0x0d ||
    (code >= 0x20 && code <= 0xd7ff) ||
    (code >= 0xe000 && code <= 0xfffd) ||
    (code >= 0x10000 && code <= 0x10ffff)
  );
}

/**
 * The only references a document without a DTD may contain: the five predefined entities and numeric character
 * references. Anything else after `&` (`&nbsp;`, `&foo;`, a bare `&`) is not well-formed XML.
 */
const REFERENCE = /&(?:amp|lt|gt|quot|apos|#([0-9]+)|#x([0-9A-Fa-f]+));/y;

export interface Attribute {
  trait_type: string;
  value: string | number;
  display_type?: string;
}

export interface Metadata {
  name: string;
  description: string;
  image: string;
  attributes: Attribute[];
}

export interface DecodedTokenUri {
  metadata: Metadata;
  svg: string;
}

/** Decodes `data:application/json;base64,...` into the metadata object and the embedded SVG. */
export function decodeTokenUri(uri: string): DecodedTokenUri {
  assert.ok(uri.startsWith(JSON_PREFIX), `unexpected tokenURI prefix: ${uri.slice(0, 40)}`);
  const jsonText = Buffer.from(uri.slice(JSON_PREFIX.length), "base64").toString("utf8");
  // JSON.parse is strict: an unescaped quote, backslash or control character in any value throws here.
  const metadata = JSON.parse(jsonText) as Metadata;
  assert.ok(metadata.image.startsWith(SVG_PREFIX), "image is not a base64 SVG data URI");
  const svg = Buffer.from(metadata.image.slice(SVG_PREFIX.length), "base64").toString("utf8");
  return { metadata, svg };
}

/**
 * Asserts that `svg` is a well-formed XML document. fast-xml-validator (the syntax validator split out of
 * fast-xml-parser by the same author) checks tag balance, attribute quoting and illegal control characters, and is
 * told to also reject `]]>` in text, `--` in comments and a raw `<` inside attribute values. Two independent scans run
 * on top, because the validator accepts any `&name;` with a word-character name: every `&` must start a predefined or
 * numeric reference to an allowed character, and every UTF-16 code unit must be in the XML 1.0 character range. (The
 * renderer emits no comments, CDATA sections or processing instructions, where `&` would be literal text.)
 */
export function assertWellFormedSvg(svg: string): void {
  assert.doesNotThrow(
    () => SyntaxValidator.validate(svg, { invalidCharSequence: { comment: true, tagValue: true, attrLt: true } }),
    "invalid XML",
  );
  for (let i = 0; i < svg.length; i++) {
    assert.ok(!isForbiddenXmlCodeUnit(svg.charCodeAt(i)), `SVG contains a character XML 1.0 forbids at index ${i}`);
  }
  for (let i = svg.indexOf("&"); i !== -1; i = svg.indexOf("&", i + 1)) {
    REFERENCE.lastIndex = i;
    const match = REFERENCE.exec(svg);
    assert.ok(
      match !== null,
      `'&' at index ${i} does not start a predefined or numeric reference: ${svg.slice(i, i + 12)}`,
    );
    const [reference, decimal, hex] = match;
    if (decimal !== undefined || hex !== undefined) {
      const code = decimal !== undefined ? Number.parseInt(decimal, 10) : Number.parseInt(hex ?? "", 16);
      assert.ok(isXmlChar(code), `${reference} references a character XML 1.0 forbids`);
    }
  }
  for (const match of svg.matchAll(/="([^"]*)"/g)) {
    const value = match[1] ?? "";
    assert.ok(!value.includes("<"), `raw '<' inside attribute value: ${value}`);
  }
  assert.ok(svg.startsWith('<svg xmlns="http://www.w3.org/2000/svg"'), "root element is not an SVG");
}

/** All text nodes of the SVG, in document order, with XML entities decoded. */
export function svgTexts(svg: string): string[] {
  const parser = new XMLParser({
    ignoreAttributes: true,
    preserveOrder: true,
    processEntities: true,
    // Also decode numeric character references such as `&#39;` (emitted by Solady's escapeHTML for `'`).
    htmlEntities: true,
    parseTagValue: false,
    trimValues: false,
  });
  const tree = parser.parse(svg) as unknown;
  const texts: string[] = [];
  const walk = (node: unknown): void => {
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    if (node !== null && typeof node === "object") {
      for (const [key, value] of Object.entries(node)) {
        if (key === "#text") texts.push(String(value));
        else walk(value);
      }
    }
  };
  walk(tree);
  return texts;
}

/** Value of a metadata attribute by trait type. */
export function attribute(metadata: Metadata, trait: string): string | number {
  const found = metadata.attributes.find((a) => a.trait_type === trait);
  assert.ok(found !== undefined, `missing attribute ${trait}`);
  return found.value;
}

/**
 * Reference model of `SafeText.sanitize` applied to what `MetadataReaderLib.readSymbol(token, 64, gas)` returns for
 * an ABI-encoded string: keep the first 64 bytes, map bytes outside 0x20-0x7E to '?', cap at 16 characters
 * (13 + "..."), and render an empty result as "UNKNOWN".
 */
export function expectedSymbol(raw: Uint8Array): string {
  const bytes = raw.slice(0, 64);
  if (bytes.length === 0) return "UNKNOWN";
  const chars = Array.from(bytes, (b) => (b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : "?"));
  return chars.length > 16 ? `${chars.slice(0, 13).join("")}...` : chars.join("");
}
