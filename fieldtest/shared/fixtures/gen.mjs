#!/usr/bin/env node
// Fieldmart fixture generator (AGENT-1-shared-tooling.md §3).
//
//   node tools/fixtures/gen.mjs --out fixtures/ [--seed 20261128] [--only data|img] [--docs shared/fixtures-api.md]
//   node tools/fixtures/gen.mjs --check fixtures/ [--lock other/fixtures.lock.json]
//
// Pure JavaScript, no dependencies: the same seed gives byte-identical files on any machine with Node 18+.
// Writes api/*.json (the data the gateway serves under /fx/api/), img/ (the pictures under /fx/img/),
// reference/ticks.json and fixtures.lock.json (path -> sha256, plus one hash over all of them).
// Fails if a sentinel of 02-APP-SPEC.md §3.3, or a run of the digits 7391, occurs in any generated file.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { pathToFileURL } from 'node:url';
import { DEFAULT_SEED } from './prng.mjs';
import * as D from './data.mjs';
import { basePicture, heroPicture, avatarPicture, badgePicture, BADGES } from './images.mjs';

const LOCK = 'fixtures.lock.json';
export const PICTURE_SIZES = [160, 320, 800];

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
    args[key] = value;
  }
  return args;
}

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const json = (value) => Buffer.from(JSON.stringify(value) + '\n');

/** Every file of the fixture set as [relative path, () => Buffer], in a fixed order. */
export function plan(seed = DEFAULT_SEED, only = null) {
  const files = [];
  const data = D.buildData(seed);
  if (only !== 'img') {
    files.push(['api/categories.json', () => json(data.categories)]);
    files.push(['api/products.json', () => json(data.products)]);
    files.push(['api/product-details.json', () => json(data.details)]);
    files.push(['api/reviews-17.json', () => json(data.reviews17)]);
    files.push(['api/reviews-pool.json', () => json(data.reviewPool)]);
    files.push(['api/deals.json', () => json(data.deals)]);
    files.push(['api/hero.json', () => json(data.hero)]);
    files.push(['api/feed.json', () => json(data.feed)]);
    files.push(['api/symbols.json', () => json(data.symbols)]);
    files.push(['api/countries.json', () => json(data.countries)]);
    files.push(['api/promos.json', () => json(data.promos)]);
    files.push(['api/terms.json', () => json(data.terms)]);
    files.push(['api/meta.json', () => json({ seed, candleEnd: data.candleEnd, timeframes: D.TIMEFRAMES, candleFileSymbols: D.CANDLE_FILE_SYMBOLS.map((k) => data.symbols[k].symbol) })]);
    for (const [name, series] of Object.entries(data.candleFiles)) files.push([`api/candles/${name}.json`, () => json(series)]);
    files.push(['reference/ticks.json', () => json(D.referenceTicks(data))]);
  }
  if (only !== 'data') {
    for (let b = 0; b < D.BASE_PICTURES; b++) {
      for (const size of PICTURE_SIZES) files.push([`img/base/${b}/${size}.jpg`, () => basePicture(b, size)]);
    }
    for (let n = 1; n <= D.HERO_COUNT; n++) files.push([`img/hero/${n}/1600.jpg`, () => heroPicture(n)]);
    for (let n = 1; n <= D.AVATAR_COUNT; n++) files.push([`img/avatar/${n}/96.jpg`, () => avatarPicture(n)]);
    for (const name of Object.keys(BADGES)) files.push([`img/badge/${name}.png`, () => badgePicture(name)]);
  }
  return { data, files };
}

/** Offsets of [needle] in [buf]; for the CVV digits only runs of exactly those four digits count. */
export function sentinelHits(buf, needles = [...D.SENTINELS, D.SENTINEL_DIGITS]) {
  const hits = [];
  for (const needle of needles) {
    const n = Buffer.from(needle);
    const digits = /^\d+$/.test(needle);
    for (let at = buf.indexOf(n); at >= 0; at = buf.indexOf(n, at + 1)) {
      if (digits) {
        const before = at > 0 ? buf[at - 1] : 0, after = buf[at + n.length] ?? 0;
        // inside a longer run of digits it is part of another number, not the CVV
        if ((before >= 0x30 && before <= 0x39) || (after >= 0x30 && after <= 0x39)) continue;
      }
      hits.push({ needle, at });
    }
  }
  return hits;
}

function lockHash(files) {
  const keys = Object.keys(files).sort();
  return sha256(keys.map((k) => `${k} ${files[k]}\n`).join(''));
}

function walk(dir, base = dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, base, out);
    else out.push(path.relative(base, full).split(path.sep).join('/'));
  }
  return out;
}

export function check(dir, lockPath = path.join(dir, LOCK)) {
  const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
  const problems = [];
  const present = new Set(walk(dir).filter((f) => f !== LOCK));
  for (const [file, hash] of Object.entries(lock.files)) {
    if (!present.has(file)) {
      problems.push(`missing ${file}`);
      continue;
    }
    present.delete(file);
    const got = sha256(fs.readFileSync(path.join(dir, file)));
    if (got !== hash) problems.push(`differs ${file}`);
  }
  for (const extra of present) problems.push(`not in the lock ${extra}`);
  return { ok: problems.length === 0, problems, hash: lock.hash, files: Object.keys(lock.files).length };
}

function apiDocs(data) {
  const p17 = data.products[D.PRODUCT_17 - 1];
  const ex = (v) => '```json\n' + JSON.stringify(v, null, 1).slice(0, 900) + '\n```\n';
  return `# Fieldmart data API (generated by tools/fixtures/gen.mjs, seed ${data.seed})

Served by the gateway under \`/fx/api/\`; pictures under \`/fx/img/\`. Base URL in the apps: \`fmFixtures\`
(default \`http://127.0.0.1:18190/fx\`). Prices are integer cents; show them as \`$<dollars>.<cents>\`
(\`${p17.priceCents}\` is \`$${D.money(p17.priceCents)}\`). Pages are 0-based.

| Route | Returns |
|---|---|
| \`GET /fx/api/products?page=<n>&size=40&category=<id>\` | \`{page, size, total, items[], next}\`; items are product summaries |
| \`GET /fx/api/products/<id>\` | summary + \`description\`, \`sizes[]\`, \`colours[]\` (\`{name, hex}\`), \`stock\` |
| \`GET /fx/api/products/<id>/reviews?page=<n>&size=50\` | \`{productId, page, size, total, items[], next}\`; product 17 has 500, the others 20 |
| \`GET /fx/api/categories\` | 12 \`{id, name, productCount}\`; chip \`fm-home-chip-<i>\` is category \`i\` |
| \`GET /fx/api/deals\` | 20 \`{productId, pct, badge}\`; deal 0 is product 17; \`badge\` names \`/fx/img/badge/<badge>.png\` |
| \`GET /fx/api/hero\` | 8 \`{id, title, subtitle, image}\` (\`image\` is relative to \`fmFixtures\`) |
| \`GET /fx/api/feed?cursor=<n>&size=100\` | \`{cursor, size, total, rows[], next}\`; 10,000 rows; \`type\` is header, order, shipment, alert or message; \`label\` is the row's main text |
| \`GET /fx/api/symbols\` | 300 \`{symbol, name, seedIndex, startCents}\` |
| \`GET /fx/api/candles?symbol=<s>&tf=<1H\\|1D\\|1W\\|1M\\|1Y>\` | 5,000 \`[t, o, h, l, c]\` (epoch seconds, cents); the last close is the symbol's \`startCents\` |
| \`GET /fx/api/quotes?since=<n>\` | \`{n, count: 300}\`; \`n\` is the gateway's 100 ms tick |
| \`GET /fx/api/search?q=<text>\` | \`{q, items[]}\`: up to 50 summaries whose title contains the text (case-insensitive) |
| \`GET /fx/api/promos?q=<text>\` | \`{q, items[]}\`: up to 8 \`{code, description}\` whose code starts with the text, sorted |
| \`GET /fx/api/countries\` | 200 names, sorted |
| \`GET /fx/api/terms\` | \`{title, text}\`: about 3,000 characters for the terms dialog |
| \`POST /fx/api/checkout\` | \`{order: "FM-<6 digits>"}\` |
| \`GET /fx/api/fail/500\` | status 500 |
| \`GET /fx/api/slow?ms=<n>\` | status 200 after the delay |

Pictures: \`/fx/img/p/<productId>/<index>/<160|320|800>.jpg\` (index 0-based, below \`imageCount\`; shows base
picture \`(productId × 7 + index) mod 240\`), \`/fx/img/hero/<1..8>/1600.jpg\`, \`/fx/img/avatar/<1..64>/96.jpg\`,
\`/fx/img/badge/<${Object.keys(BADGES).join('|')}>.png\` (96 × 96 with transparency). Each picture shows its
number in large digits in the top-left corner.

Product 17 (\`fm-home-product-17\`, deal 0):
${ex(p17)}
A feed row of each type:
${ex(['header', 'order', 'shipment', 'alert', 'message'].map((t) => data.feed.find((r) => r.type === t)))}
`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.check) {
    const dir = path.resolve(String(args.check));
    const result = check(dir, args.lock ? path.resolve(String(args.lock)) : undefined);
    for (const p of result.problems.slice(0, 20)) console.log(`  ${p}`);
    console.log(result.ok ? `fixtures OK: ${result.files} files match the lock, hash ${result.hash}` : `fixtures DIFFER: ${result.problems.length} problem(s)`);
    process.exit(result.ok ? 0 : 1);
  }
  if (!args.out) {
    console.error('usage: gen.mjs --out DIR [--seed N] [--only data|img] [--docs FILE] | --check DIR [--lock FILE]');
    process.exit(2);
  }
  const out = path.resolve(String(args.out));
  const seed = args.seed ? Number(args.seed) >>> 0 : DEFAULT_SEED;
  const only = args.only || null;
  const started = Date.now();
  const { data, files } = plan(seed, only);
  const lock = {};
  let bytes = 0;
  const problems = [];
  for (const [rel, make] of files) {
    const buf = make();
    const hits = sentinelHits(buf);
    if (hits.length) problems.push(`${rel}: ${hits.map((h) => `${JSON.stringify(h.needle)} at ${h.at}`).join(', ')}`);
    if (rel.endsWith('.png')) zlib.inflateSync(buf.subarray(buf.indexOf('IDAT') + 4, buf.indexOf('IEND') - 8)); // throws if the stream is not valid zlib
    const full = path.join(out, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, buf);
    lock[rel] = sha256(buf);
    bytes += buf.length;
  }
  if (problems.length) {
    console.error(`sentinel found in generated data:\n  ${problems.join('\n  ')}`);
    process.exit(1);
  }
  const content = { version: 1, seed, only, files: lock, fileCount: files.length, totalBytes: bytes, hash: lockHash(lock) };
  fs.writeFileSync(path.join(out, LOCK), JSON.stringify(content, null, 1) + '\n');
  if (args.docs) fs.writeFileSync(path.resolve(String(args.docs)), apiDocs(data));
  console.log(`fixtures: ${files.length} files, ${(bytes / 1048576).toFixed(1)} MB, hash ${content.hash}, ${((Date.now() - started) / 1000).toFixed(1)} s`);
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) await main();
