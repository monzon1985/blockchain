// SPDX-License-Identifier: MIT
/**
 * The three priced services. They are pure and deterministic on purpose: a validator can re-execute any call from
 * its input alone and compare outputs byte for byte (ERC-8004 validation by re-execution). No LLM, no clock, no
 * randomness, no locale-dependent formatting.
 */
import { encodePacked, keccak256, toBytes, type Hex } from 'viem';
import { z } from 'zod';

// ------------------------------------------------------------------------------------------------ sentiment

const POSITIVE = new Set([
  'good',
  'great',
  'excellent',
  'fast',
  'reliable',
  'love',
  'happy',
  'secure',
  'cheap',
  'clear',
  'helpful',
  'robust',
  'efficient',
  'elegant',
  'accurate',
  'stable',
  'smooth',
  'win',
  'best',
  'safe',
]);
const NEGATIVE = new Set([
  'bad',
  'poor',
  'slow',
  'broken',
  'hate',
  'sad',
  'insecure',
  'expensive',
  'confusing',
  'useless',
  'buggy',
  'fragile',
  'wasteful',
  'wrong',
  'unstable',
  'fail',
  'worst',
  'unsafe',
  'scam',
  'lost',
]);
const NEGATORS = new Set(['not', 'never', 'no', "isn't", "don't", "doesn't", "wasn't"]);

export const sentimentInputSchema = z.strictObject({ text: z.string().min(1).max(4_000) });
export type SentimentInput = z.infer<typeof sentimentInputSchema>;

export interface SentimentOutput {
  readonly label: 'positive' | 'negative' | 'neutral';
  /** Score in basis points, -10000..10000. */
  readonly scoreBps: number;
  readonly positive: number;
  readonly negative: number;
  readonly tokens: number;
}

function tokenize(text: string): string[] {
  return text.toLowerCase().match(/[a-z']+/g) ?? [];
}

/** Lexicon sentiment with one-word negation ("not good" counts as negative). */
export function sentiment(input: SentimentInput): SentimentOutput {
  const tokens = tokenize(input.text);
  let positive = 0;
  let negative = 0;
  tokens.forEach((token, i) => {
    const negated = i > 0 && NEGATORS.has(tokens[i - 1] ?? '');
    if (POSITIVE.has(token)) {
      if (negated) negative += 1;
      else positive += 1;
    } else if (NEGATIVE.has(token)) {
      if (negated) positive += 1;
      else negative += 1;
    }
  });
  const total = positive + negative;
  const scoreBps = total === 0 ? 0 : Math.trunc(((positive - negative) * 10_000) / total);
  const label = scoreBps > 1_000 ? 'positive' : scoreBps < -1_000 ? 'negative' : 'neutral';
  return { label, scoreBps, positive, negative, tokens: tokens.length };
}

// ------------------------------------------------------------------------------------------------ keywords

const STOPWORDS = new Set([
  'the',
  'a',
  'an',
  'and',
  'or',
  'but',
  'of',
  'to',
  'in',
  'on',
  'for',
  'with',
  'is',
  'are',
  'was',
  'were',
  'be',
  'it',
  'this',
  'that',
  'as',
  'at',
  'by',
  'from',
  'we',
  'you',
  'they',
  'i',
  'our',
  'your',
  'their',
  'its',
  'not',
]);

export const keywordsInputSchema = z.strictObject({
  text: z.string().min(1).max(8_000),
  k: z.number().int().min(1).max(20).default(5),
});
export type KeywordsInput = z.input<typeof keywordsInputSchema>;

export interface KeywordsOutput {
  readonly keywords: readonly { readonly term: string; readonly count: number }[];
  readonly distinctTerms: number;
}

/** Term-frequency keywords: stopwords removed, ties broken alphabetically. */
export function keywords(raw: KeywordsInput): KeywordsOutput {
  const input = keywordsInputSchema.parse(raw);
  const counts = new Map<string, number>();
  for (const token of tokenize(input.text)) {
    if (token.length < 3 || STOPWORDS.has(token)) continue;
    counts.set(token, (counts.get(token) ?? 0) + 1);
  }
  const ranked = [...counts.entries()]
    .sort(([ta, ca], [tb, cb]) => (cb !== ca ? cb - ca : ta < tb ? -1 : ta > tb ? 1 : 0))
    .slice(0, input.k)
    .map(([term, count]) => ({ term, count }));
  return { keywords: ranked, distinctTerms: counts.size };
}

// ------------------------------------------------------------------------------------------------ merkle report

export const reportInputSchema = z.strictObject({
  items: z.array(z.string().min(1).max(256)).min(1).max(1_024),
});
export type ReportInput = z.infer<typeof reportInputSchema>;

export interface ReportOutput {
  readonly algorithm: 'keccak256-sorted-pairs';
  readonly leafCount: number;
  readonly root: Hex;
}

function hashPair(a: Hex, b: Hex): Hex {
  return BigInt(a) < BigInt(b)
    ? keccak256(encodePacked(['bytes32', 'bytes32'], [a, b]))
    : keccak256(encodePacked(['bytes32', 'bytes32'], [b, a]));
}

/**
 * Merkle root over `keccak256(item)` leaves with sorted-pair hashing (the OpenZeppelin `MerkleProof` convention);
 * an odd node is promoted to the next level unchanged.
 */
export function merkleReport(input: ReportInput): ReportOutput {
  let level: Hex[] = input.items.map((item) => keccak256(toBytes(item)));
  const leafCount = level.length;
  while (level.length > 1) {
    const next: Hex[] = [];
    for (let i = 0; i < level.length; i += 2) {
      const left = level[i] as Hex;
      const right = level[i + 1];
      next.push(right === undefined ? left : hashPair(left, right));
    }
    level = next;
  }
  return { algorithm: 'keccak256-sorted-pairs', leafCount, root: level[0] as Hex };
}

// ------------------------------------------------------------------------------------------------ catalogue

/** Canonical JSON (sorted keys, no whitespace): the byte string that is hashed and re-executed. */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

/** keccak256 of the canonical JSON of a result: the delivery hash posted to the escrow. */
export function resultHash(result: unknown): Hex {
  return keccak256(toBytes(canonicalJson(result)));
}

export type ServiceId = 'sentiment' | 'keywords' | 'merkle-report';

/** Path each service is sold at. Validators check that a work document's resource is the claimed service's path. */
export const SERVICE_PATHS: Readonly<Record<ServiceId, string>> = {
  sentiment: '/api/v1/sentiment',
  keywords: '/api/v1/keywords',
  'merkle-report': '/api/v1/reports',
};

/** Re-executes a service by id from raw JSON input (used by the validator). */
export function executeService(service: ServiceId, input: unknown): unknown {
  switch (service) {
    case 'sentiment':
      return sentiment(sentimentInputSchema.parse(input));
    case 'keywords':
      return keywords(keywordsInputSchema.parse(input));
    case 'merkle-report':
      return merkleReport(reportInputSchema.parse(input));
  }
}
