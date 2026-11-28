#!/usr/bin/env node
// Reading the gateway's ledger (AGENT-1-shared-tooling.md §2.2).
//
// A ledger is JSON lines, one per SDK request (marker lines have a `mark` field instead of `path`). A line's
// `body` is the path of the raw request body, relative to the directory holding the JSONL file.
//
//   node tools/gateway/ledger.mjs export --ledger <gateway ledger dir> --run <id> --to <run dir> [--no-bodies]
//       copies <id>.jsonl (+ .forward.jsonl, .fx.jsonl) into <run dir>/ledger.jsonl, ledger.forward.jsonl,
//       fxlog.jsonl and the bodies into <run dir>/ledger-bodies/
//   node tools/gateway/ledger.mjs summary <ledger.jsonl>
//   node tools/gateway/ledger.mjs search <ledger.jsonl> <text>...
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { pathToFileURL } from 'node:url';
import { decodeOtlp, nanosToMs } from './otlp.mjs';

export const SDK_ROUTES = ['/api/otel/v1/logs', '/api/otel/v1/traces', '/api/otel/v1/metrics', '/api/otel/v1/opamp', '/api/recordings'];

/** Lines of a ledger file (or of <dir>/<run>.jsonl), with the directory bodies are relative to. */
export function readLedger(file, run) {
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, `${run}.jsonl`);
  if (!fs.existsSync(file)) return { file, base: path.dirname(file), lines: [] };
  const lines = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  return { file, base: path.dirname(file), lines };
}

export const requestsOf = (lines) => lines.filter((l) => l.path);
export const marksOf = (lines) => lines.filter((l) => l.mark);

/** The bytes of a request exactly as received, or null when the body was not kept. */
export function rawBody(line, base) {
  if (!line.body) return null;
  const file = path.join(base, line.body);
  return fs.existsSync(file) ? fs.readFileSync(file) : null;
}

export function decodeBody(buf, encoding) {
  if (!buf) return null;
  const enc = String(encoding || '').toLowerCase();
  if (enc.includes('gzip')) return zlib.gunzipSync(buf);
  if (enc.includes('br')) return zlib.brotliDecompressSync(buf);
  if (enc.includes('deflate')) {
    try {
      return zlib.inflateSync(buf);
    } catch {
      return zlib.inflateRawSync(buf);
    }
  }
  return buf;
}

/** The decompressed body of a ledger line. */
export const decodedBody = (line, base) => decodeBody(rawBody(line, base), line.contentEncoding);

/** Replay segments in the /api/recordings bodies of a ledger, in ledger order. */
export function recordingSegments(lines, base) {
  const out = [];
  for (const line of requestsOf(lines)) {
    if (line.path !== '/api/recordings') continue;
    const body = decodedBody(line, base);
    if (!body) continue;
    let parsed;
    try {
      parsed = JSON.parse(body.toString('utf8'));
    } catch {
      continue;
    }
    for (const seg of parsed.segments || []) {
      const events = seg.events || [];
      out.push({
        seq: line.seq, recvEpochMs: line.recvEpochMs, status: line.status, sessionId: seg.sessionId || null, exceptionId: seg.exceptionId || null,
        segmentIndex: seg.segmentIndex ?? null, eventCount: events.length, startedAt: seg.startedAt || null, endedAt: seg.endedAt || null,
        firstEventMs: events.length ? events[0].timestamp : null, lastEventMs: events.length ? events[events.length - 1].timestamp : null,
        bytes: Buffer.byteLength(JSON.stringify(seg)), events,
      });
    }
  }
  return out;
}

/** Decoded OTLP records of a ledger: {logs, spans, metrics}, each item with the `seq` of its request. */
export function otlpRecords(lines, base) {
  const out = { logs: [], spans: [], metrics: [], errors: [] };
  const signal = { '/api/otel/v1/logs': 'logs', '/api/otel/v1/traces': 'traces', '/api/otel/v1/metrics': 'metrics' };
  for (const line of requestsOf(lines)) {
    const s = signal[line.path];
    if (!s) continue;
    const body = decodedBody(line, base);
    if (!body) continue;
    try {
      const items = decodeOtlp(s, body, line.contentType);
      const target = s === 'traces' ? out.spans : out[s];
      for (const item of items) target.push({ seq: line.seq, recvEpochMs: line.recvEpochMs, ...item });
    } catch (e) {
      out.errors.push(`seq ${line.seq} ${line.path}: ${e.message}`);
    }
  }
  return out;
}

const isDigit = (b) => b >= 0x30 && b <= 0x39;
const isB64 = (b) => (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || isDigit(b) || b === 0x2b || b === 0x2f || b === 0x3d;

/**
 * Occurrences of [needle] in [buf] that count as a leak of the typed value. A needle of digits only must be a
 * whole run of digits (`7391`, not part of a timestamp such as 1795907391123). Matches inside a base64 run of
 * 64 or more characters (an inlined picture), in the element id `fm-feed-row-7391`, and digit runs that are a bare
 * JSON number or an OTLP number attribute are returned with `excluded` set, so they are reported but not counted.
 */
export function findSentinel(buf, needle) {
  const n = Buffer.from(needle);
  const digits = /^\d+$/.test(needle);
  const hits = [];
  for (let at = buf.indexOf(n); at >= 0; at = buf.indexOf(n, at + 1)) {
    if (digits && ((at > 0 && isDigit(buf[at - 1])) || isDigit(buf[at + n.length] ?? 0))) continue;
    let excluded = null;
    let a = at, b = at + n.length;
    while (a > 0 && isB64(buf[a - 1])) a--;
    while (b < buf.length && isB64(buf[b])) b++;
    if (b - a >= 64 && /^[\x20-\x7e]*$/.test(needle) && [...n].every(isB64)) excluded = 'inside a base64 run (an inlined picture)';
    const before = buf.subarray(Math.max(0, at - 16), at).toString('latin1');
    const after = buf.subarray(at + n.length, at + n.length + 2).toString('latin1');
    if (before.endsWith('fm-feed-row-')) excluded = 'the element id of feed row 7391';
    // a bare JSON number (an rrweb node id, a coordinate, a count) or an OTLP number attribute is never typed text
    else if (digits && /:\s*$/.test(before) && /^\s*[,}\]]/.test(after)) excluded = 'a JSON number (a node id, a position or a count)';
    else if (digits && /"(intValue|doubleValue)"\s*:\s*"$/.test(before)) excluded = 'an OTLP number attribute';
    hits.push({ at, excluded, context: buf.subarray(Math.max(0, at - 40), Math.min(buf.length, at + n.length + 40)).toString('latin1') });
  }
  return hits;
}

/** Sentinel search over every decoded body of a ledger (check E-15). */
export function searchLedger(lines, base, needles) {
  const results = [];
  let searched = 0, missing = 0;
  for (const line of requestsOf(lines)) {
    let body;
    try {
      body = decodedBody(line, base);
    } catch (e) {
      results.push({ seq: line.seq, path: line.path, needle: null, error: `cannot decode: ${e.message}` });
      continue;
    }
    if (!body) {
      if (line.wireBytes) missing++;
      continue;
    }
    searched++;
    for (const needle of needles) {
      for (const hit of findSentinel(body, needle)) results.push({ seq: line.seq, path: line.path, needle, ...hit });
    }
  }
  return { searched, missing, hits: results.filter((r) => !r.excluded && !r.error), excluded: results.filter((r) => r.excluded), errors: results.filter((r) => r.error) };
}

export function summarize(lines) {
  const byRoute = {};
  for (const l of requestsOf(lines)) {
    const r = (byRoute[l.path] ||= { requests: 0, wireBytes: 0, decodedBytes: 0, statuses: {} });
    r.requests++;
    r.wireBytes += l.wireBytes || 0;
    r.decodedBytes += l.decodedBytes || 0;
    r.statuses[l.status] = (r.statuses[l.status] || 0) + 1;
  }
  return byRoute;
}

function copyLedger(src, dst, bodiesDir, keepBodies) {
  if (!fs.existsSync(src)) return 0;
  const base = path.dirname(src);
  const out = [];
  for (const raw of fs.readFileSync(src, 'utf8').split('\n').filter(Boolean)) {
    const line = JSON.parse(raw);
    if (line.body) {
      const from = path.join(base, line.body);
      if (keepBodies && fs.existsSync(from)) {
        const name = path.basename(line.body);
        fs.mkdirSync(path.join(path.dirname(dst), bodiesDir), { recursive: true });
        fs.copyFileSync(from, path.join(path.dirname(dst), bodiesDir, name));
        line.body = `${bodiesDir}/${name}`;
      } else {
        line.body = null;
      }
    }
    out.push(JSON.stringify(line));
  }
  fs.writeFileSync(dst, out.join('\n') + (out.length ? '\n' : ''));
  return out.length;
}

/** Copies a run's ledger slice out of the gateway's ledger directory into a run folder. */
export function exportRun({ ledger, run, to, bodies = true }) {
  fs.mkdirSync(to, { recursive: true });
  const n = copyLedger(path.join(ledger, `${run}.jsonl`), path.join(to, 'ledger.jsonl'), 'ledger-bodies', bodies);
  copyLedger(path.join(ledger, `${run}.forward.jsonl`), path.join(to, 'ledger.forward.jsonl'), 'ledger-bodies', false);
  const fx = path.join(ledger, `${run}.fx.jsonl`);
  if (fs.existsSync(fx)) fs.copyFileSync(fx, path.join(to, 'fxlog.jsonl'));
  return n;
}

export { nanosToMs };

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const opt = (name) => {
    const i = rest.indexOf(`--${name}`);
    return i >= 0 ? rest[i + 1] : undefined;
  };
  if (cmd === 'export') {
    const n = exportRun({ ledger: opt('ledger'), run: opt('run'), to: opt('to'), bodies: !rest.includes('--no-bodies') });
    console.log(`exported ${n} ledger lines of ${opt('run')} to ${opt('to')}`);
  } else if (cmd === 'summary') {
    const { lines } = readLedger(rest[0]);
    console.log(JSON.stringify(summarize(lines), null, 1));
  } else if (cmd === 'search') {
    const { lines, base } = readLedger(rest[0]);
    const r = searchLedger(lines, base, rest.slice(1));
    console.log(JSON.stringify({ searched: r.searched, hits: r.hits.map(({ seq, path, needle, context }) => ({ seq, path, needle, context })), excluded: r.excluded.length }, null, 1));
    process.exit(r.hits.length ? 1 : 0);
  } else {
    console.error('usage: ledger.mjs export|summary|search …');
    process.exit(2);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) await main();
