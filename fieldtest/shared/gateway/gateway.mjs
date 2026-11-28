#!/usr/bin/env node
// The field-test gateway (AGENT-1-shared-tooling.md §2). One Node process, no dependencies.
//
//   node tools/gateway/gateway.mjs --mode live|capture [--port 18190] [--host 127.0.0.1]
//        [--upstream http://127.0.0.1:18182] --fixtures fixtures/ --ledger <dir>
//        [--fx-latency-ms 40] [--fx-kbps 8000]
//   node tools/gateway/gateway.mjs forward --ledger <dir> [--run <id>] [--upstream http://127.0.0.1:18182]
//        [--speed 1] [--concurrency 20]
//
// SDK routes (/api/…): `live` forwards to the upstream and returns its answer; `capture` stores the request and
// answers itself. Every SDK request becomes one line of <ledger>/<run>.jsonl and a body file under
// <ledger>/bodies/<run>/. Fixture routes (/fx/…) serve the generated data and pictures, shaped like a phone
// network, and are logged to <ledger>/<run>.fx.jsonl. Control routes (/ctl/…) answer loopback callers only.
//
// `forward` replays captured requests, unchanged and in order, to the upstream and writes <run>.forward.jsonl.
// With --speed 1 (the default) requests keep their original spacing, as the backend's per-30 s log limit and
// per-minute metric limit count by arrival time; --speed 0 sends them as fast as --concurrency allows.
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath, pathToFileURL } from 'node:url';
import * as D from '../fixtures/data.mjs';

const HOP_BY_HOP = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'host']);
const KEPT_HEADERS = ['authorization', 'content-type', 'content-encoding', 'user-agent', 'accept', 'traceparent'];
const RUN_ID = /^[A-Za-z0-9][A-Za-z0-9-]{0,127}$/;
export const SDK_PATHS = ['/api/otel/v1/logs', '/api/otel/v1/traces', '/api/otel/v1/metrics', '/api/otel/v1/opamp', '/api/recordings'];

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) {
      args._.push(a);
      continue;
    }
    const key = a.slice(2);
    args[key] = argv[i + 1] !== undefined && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  }
  return args;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isLoopback = (addr) => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(addr) || String(addr).startsWith('127.');
const tokenHash = (auth) => {
  const token = String(auth || '').replace(/^Bearer\s+/i, '');
  return token ? crypto.createHash('sha256').update(token).digest('hex').slice(0, 8) : null;
};

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function decodedLength(buf, encoding) {
  try {
    const enc = String(encoding || '').toLowerCase();
    if (enc.includes('gzip')) return zlib.gunzipSync(buf).length;
    if (enc.includes('br')) return zlib.brotliDecompressSync(buf).length;
    if (enc.includes('deflate')) return zlib.inflateSync(buf).length;
  } catch {
    return null;
  }
  return buf.length;
}

// ---- the ledger ---------------------------------------------------------------------------------------------

class Ledger {
  constructor(dir) {
    this.dir = dir;
    fs.mkdirSync(path.join(dir, 'bodies'), { recursive: true });
    this.seqs = new Map();
    this.lastSdk = new Map();
    this.fxCounts = new Map();
  }
  nextSeq(run) {
    if (!this.seqs.has(run)) {
      // continue a run whose file exists (a restarted gateway)
      let last = 0;
      const file = path.join(this.dir, `${run}.jsonl`);
      if (fs.existsSync(file)) {
        for (const l of fs.readFileSync(file, 'utf8').split('\n')) {
          if (!l) continue;
          try {
            last = Math.max(last, JSON.parse(l).seq || 0);
          } catch {}
        }
      }
      this.seqs.set(run, last);
    }
    const seq = this.seqs.get(run) + 1;
    this.seqs.set(run, seq);
    return seq;
  }
  saveBody(run, seq, body) {
    const rel = `bodies/${run}/${String(seq).padStart(6, '0')}.bin`;
    fs.mkdirSync(path.join(this.dir, 'bodies', run), { recursive: true });
    fs.writeFileSync(path.join(this.dir, rel), body);
    return rel;
  }
  append(run, line, suffix = '') {
    fs.appendFileSync(path.join(this.dir, `${run}${suffix}.jsonl`), JSON.stringify(line) + '\n');
  }
  lines(run, suffix = '') {
    const file = path.join(this.dir, `${run}${suffix}.jsonl`);
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  }
}

// ---- fixtures -----------------------------------------------------------------------------------------------

function loadFixtures(dir) {
  const api = (name) => JSON.parse(fs.readFileSync(path.join(dir, 'api', name), 'utf8'));
  const meta = api('meta.json');
  const data = {
    seed: meta.seed, candleEnd: meta.candleEnd,
    categories: api('categories.json'), products: api('products.json'), details: api('product-details.json'),
    reviews17: api('reviews-17.json'), reviewPool: api('reviews-pool.json'), deals: api('deals.json'), hero: api('hero.json'),
    feed: api('feed.json'), symbols: api('symbols.json'), countries: api('countries.json'), promos: api('promos.json'), terms: api('terms.json'),
  };
  let lock = null;
  try {
    lock = JSON.parse(fs.readFileSync(path.join(dir, 'fixtures.lock.json'), 'utf8'));
  } catch {}
  return { dir, data, lock };
}

/** The fixture route class used for counts (E-11): /fx/api/products/:id → "/fx/api/products/:id". */
function routeClass(p) {
  return p
    .replace(/^\/fx\/img\/(p|hero|avatar|badge)\/.*/, '/fx/img/$1')
    .replace(/^\/fx\/api\/products\/\d+\/reviews$/, '/fx/api/products/:id/reviews')
    .replace(/^\/fx\/api\/products\/\d+$/, '/fx/api/products/:id')
    .replace(/^\/fx\/api\/fail\/\d+$/, '/fx/api/fail/:status');
}

// ---- the server ---------------------------------------------------------------------------------------------

export function startGateway(opts) {
  const mode = opts.mode || 'live';
  if (!['live', 'capture'].includes(mode)) throw new Error(`mode must be live or capture, not ${mode}`);
  const upstream = new URL(opts.upstream || 'http://127.0.0.1:18182');
  const ledger = new Ledger(path.resolve(opts.ledger));
  const fixtures = opts.fixtures ? loadFixtures(path.resolve(opts.fixtures)) : null;
  const latencyMs = Number(opts.fxLatencyMs ?? 40);
  const bytesPerSec = (Number(opts.fxKbps ?? 8000) * 1000) / 8;
  const started = Date.now();
  const agent = new http.Agent({ keepAlive: true, maxSockets: 32 });
  const state = { run: 'norun', fault: { mode: 'none', until: 0, ms: 0 }, orderCounter: 100000, upstreamOk: null, upstreamCheckedAt: 0 };
  const etags = new Map();
  const jsonCache = new Map();
  const log = opts.log || ((m) => process.stderr.write(`[gateway] ${m}\n`));

  const faultNow = () => (state.fault.mode !== 'none' && Date.now() < state.fault.until ? state.fault : null);

  async function upstreamHealthy() {
    if (mode !== 'live') return null;
    if (Date.now() - state.upstreamCheckedAt < 2000) return state.upstreamOk;
    state.upstreamCheckedAt = Date.now();
    state.upstreamOk = await new Promise((resolve) => {
      const r = http.get({ host: upstream.hostname, port: upstream.port, path: '/health', timeout: 2000 }, (res) => {
        res.resume();
        resolve(res.statusCode >= 200 && res.statusCode < 500);
      });
      r.on('error', () => resolve(false));
      r.on('timeout', () => {
        r.destroy();
        resolve(false);
      });
    });
    return state.upstreamOk;
  }

  function sendJson(res, status, value, extra = {}) {
    const body = Buffer.from(JSON.stringify(value));
    res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': body.length, ...extra });
    res.end(body);
  }

  // -- SDK routes ---------------------------------------------------------------------------------------------
  async function sdk(req, res, url) {
    const recvEpochMs = Date.now();
    const run = state.run;
    const body = req.method === 'OPTIONS' ? Buffer.alloc(0) : await readBody(req);
    const fault = faultNow();
    const seq = ledger.nextSeq(run);
    const headers = {};
    for (const h of KEPT_HEADERS) if (req.headers[h] !== undefined) headers[h] = req.headers[h];
    if (req.method === 'OPTIONS') {
      for (const h of ['origin', 'access-control-request-method', 'access-control-request-headers']) if (req.headers[h]) headers[h] = req.headers[h];
    }
    const line = {
      seq, run, recvEpochMs, method: req.method, path: url.pathname, ...(url.search ? { query: url.search } : {}), mode,
      status: 0, wireBytes: body.length, decodedBytes: decodedLength(body, req.headers['content-encoding']),
      contentType: req.headers['content-type'] || null, contentEncoding: req.headers['content-encoding'] || null,
      tokenHash: tokenHash(req.headers.authorization), upstreamMs: null, body: body.length ? ledger.saveBody(run, seq, body) : null, headers,
    };
    const known = SDK_PATHS.includes(url.pathname);
    if (!known) line.unexpected = true;
    state.lastSdkAt = Date.now();
    ledger.lastSdk.set(run, Date.now());
    const finish = (extra) => {
      Object.assign(line, extra);
      ledger.append(run, line);
      ledger.lastSdk.set(run, Date.now());
    };

    if (fault) {
      line.fault = fault.mode;
      if (fault.mode === 'refuse') {
        finish({ status: 0, error: 'refused (connection reset by the gateway)' });
        req.socket.resetAndDestroy ? req.socket.resetAndDestroy() : req.socket.destroy();
        return;
      }
      if (fault.mode === '503') {
        finish({ status: 503 });
        const cors = mode === 'capture' || req.headers.origin ? { 'Access-Control-Allow-Origin': '*', 'Access-Control-Expose-Headers': 'Retry-After' } : {};
        sendJson(res, 503, { error: 'fault injected by the field-test gateway' }, { 'Retry-After': '2', ...cors });
        return;
      }
      if (fault.mode === 'latency') await sleep(fault.ms || 0);
    }

    if (mode === 'capture') {
      const cors = { 'Access-Control-Allow-Origin': '*' };
      if (req.method === 'OPTIONS') {
        finish({ status: 204 });
        res.writeHead(204, {
          ...cors, 'Access-Control-Allow-Methods': req.headers['access-control-request-method'] || 'POST, OPTIONS',
          'Access-Control-Allow-Headers': req.headers['access-control-request-headers'] || 'authorization, content-type, content-encoding',
          'Access-Control-Max-Age': '600',
        });
        res.end();
        return;
      }
      if (url.pathname === '/api/otel/v1/opamp' || !known) {
        finish({ status: 404 });
        sendJson(res, 404, { error: 'not available in capture mode' }, cors);
        return;
      }
      finish({ status: 200 });
      if (/protobuf/i.test(req.headers['content-type'] || '')) {
        res.writeHead(200, { ...cors, 'Content-Type': 'application/x-protobuf', 'Content-Length': 0 });
        res.end();
      } else {
        sendJson(res, 200, {}, cors);
      }
      return;
    }

    // live: forward unchanged
    const out = {};
    for (const [k, v] of Object.entries(req.headers)) if (!HOP_BY_HOP.has(k.toLowerCase())) out[k] = v;
    out.host = upstream.host;
    if (body.length || req.method === 'POST') out['content-length'] = String(body.length);
    const t0 = Date.now();
    const upReq = http.request({ host: upstream.hostname, port: upstream.port, method: req.method, path: url.pathname + url.search, headers: out, agent }, (upRes) => {
      const back = {};
      for (const [k, v] of Object.entries(upRes.headers)) if (!HOP_BY_HOP.has(k.toLowerCase())) back[k] = v;
      res.writeHead(upRes.statusCode, back);
      let respBytes = 0;
      upRes.on('data', (c) => {
        respBytes += c.length;
        res.write(c);
      });
      upRes.on('end', () => {
        res.end();
        finish({ status: upRes.statusCode, upstreamMs: Date.now() - t0, respBytes });
      });
    });
    upReq.on('error', (e) => {
      finish({ status: 502, upstreamMs: Date.now() - t0, error: `upstream: ${e.message}` });
      if (!res.headersSent) sendJson(res, 502, { error: `upstream: ${e.message}` });
      else res.destroy();
    });
    upReq.end(body);
  }

  // -- fixture routes -----------------------------------------------------------------------------------------
  async function shapedSend(req, res, status, headers, body, run, url, t0) {
    await sleep(latencyMs);
    res.writeHead(status, { ...headers, 'Content-Length': body.length, 'Access-Control-Allow-Origin': '*', 'Timing-Allow-Origin': '*' });
    const sock = req.socket;
    const chunk = Math.max(4096, Math.round(bytesPerSec * 0.02));
    for (let i = 0; i < body.length; i += chunk) {
      const piece = body.subarray(i, i + chunk);
      const now = Date.now();
      const free = Math.max(now, sock.fmNextFree || 0);
      sock.fmNextFree = free + (piece.length / bytesPerSec) * 1000;
      if (free > now) await sleep(free - now);
      if (!res.write(piece)) await new Promise((r) => res.once('drain', r));
    }
    res.end();
    const line = { run, recvEpochMs: t0, method: req.method, path: url.pathname, route: routeClass(url.pathname), ...(url.search ? { query: url.search } : {}), status, bytes: body.length, ms: Date.now() - t0 };
    ledger.append(run, line, '.fx');
    const counts = ledger.fxCounts.get(run) || {};
    counts[line.route] = (counts[line.route] || 0) + 1;
    ledger.fxCounts.set(run, counts);
  }

  function jsonBody(req, key, make) {
    const gz = /\bgzip\b/.test(req.headers['accept-encoding'] || '');
    let entry = key ? jsonCache.get(key) : null;
    if (!entry) {
      const raw = Buffer.from(JSON.stringify(make()));
      entry = { raw, gz: raw.length > 1024 ? zlib.gzipSync(raw, { level: 6 }) : null };
      if (key) jsonCache.set(key, entry);
    }
    if (gz && entry.gz) return { body: entry.gz, headers: { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip', Vary: 'Accept-Encoding', 'Cache-Control': 'no-cache' } };
    return { body: entry.raw, headers: { 'Content-Type': 'application/json', Vary: 'Accept-Encoding', 'Cache-Control': 'no-cache' } };
  }

  async function fx(req, res, url) {
    const t0 = Date.now();
    const run = state.run;
    if (req.method === 'OPTIONS') {
      res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Allow-Headers': req.headers['access-control-request-headers'] || '*', 'Access-Control-Max-Age': '600' });
      res.end();
      return;
    }
    if (!fixtures) return sendJson(res, 503, { error: 'gateway started without --fixtures' });
    const p = url.pathname;
    const q = url.searchParams;
    const data = fixtures.data;
    const json = (key, make, status = 200) => {
      const { body, headers } = jsonBody(req, key, make);
      return shapedSend(req, res, status, headers, body, run, url, t0);
    };
    const notFound = () => shapedSend(req, res, 404, { 'Content-Type': 'application/json' }, Buffer.from('{"error":"not found"}'), run, url, t0);
    let m;
    if (p.startsWith('/fx/img/')) {
      let file = null;
      if ((m = p.match(/^\/fx\/img\/p\/(\d+)\/(\d+)\/(160|320|800)\.jpg$/))) {
        const id = Number(m[1]), index = Number(m[2]);
        const product = data.products[id - 1];
        if (product && index < product.imageCount) file = `img/base/${D.basePictureOf(id, index)}/${m[3]}.jpg`;
      } else if ((m = p.match(/^\/fx\/img\/hero\/([1-8])\/1600\.jpg$/))) file = `img/hero/${m[1]}/1600.jpg`;
      else if ((m = p.match(/^\/fx\/img\/avatar\/(\d+)\/96\.jpg$/)) && Number(m[1]) >= 1 && Number(m[1]) <= D.AVATAR_COUNT) file = `img/avatar/${Number(m[1])}/96.jpg`;
      else if ((m = p.match(/^\/fx\/img\/badge\/([a-z0-9-]+)\.png$/))) file = `img/badge/${m[1]}.png`;
      const full = file && path.join(fixtures.dir, file);
      if (!full || !fs.existsSync(full)) return notFound();
      let etag = etags.get(file);
      if (!etag) {
        const hash = fixtures.lock?.files?.[file] || crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex');
        etag = `"${hash.slice(0, 16)}"`;
        etags.set(file, etag);
      }
      const headers = { 'Content-Type': file.endsWith('.png') ? 'image/png' : 'image/jpeg', 'Cache-Control': 'public, max-age=3600', ETag: etag };
      if (req.headers['if-none-match'] === etag) return shapedSend(req, res, 304, headers, Buffer.alloc(0), run, url, t0);
      return shapedSend(req, res, 200, headers, fs.readFileSync(full), run, url, t0);
    }
    if (p === '/fx/api/products') return json(null, () => D.productPage(data, { page: q.get('page'), size: q.get('size'), category: q.get('category') }));
    if ((m = p.match(/^\/fx\/api\/products\/(\d+)$/))) {
      const id = Number(m[1]);
      if (!data.products[id - 1]) return notFound();
      return json(p, () => ({ ...data.products[id - 1], ...data.details[id - 1] }));
    }
    if ((m = p.match(/^\/fx\/api\/products\/(\d+)\/reviews$/))) {
      const id = Number(m[1]);
      if (!data.products[id - 1]) return notFound();
      return json(null, () => D.reviewPage(data, id, { page: q.get('page'), size: q.get('size') }));
    }
    if (p === '/fx/api/categories') return json(p, () => data.categories);
    if (p === '/fx/api/deals') return json(p, () => data.deals);
    if (p === '/fx/api/hero') return json(p, () => data.hero);
    if (p === '/fx/api/feed') return json(null, () => D.feedPage(data, { cursor: q.get('cursor'), size: q.get('size') }));
    if (p === '/fx/api/symbols') return json(p, () => data.symbols);
    if (p === '/fx/api/candles') {
      const k = data.symbols.findIndex((s) => s.symbol === q.get('symbol'));
      const tf = q.get('tf') || '1H';
      if (k < 0 || !D.TIMEFRAMES[tf]) return notFound();
      const file = path.join(fixtures.dir, 'api', 'candles', `${data.symbols[k].symbol}-${tf}.json`);
      return json(`candles ${k} ${tf}`, () => (fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : D.candles(data.symbols, k, tf, data.seed, data.candleEnd)));
    }
    if (p === '/fx/api/quotes') return json(null, () => ({ n: D.safeInt(Math.floor((Date.now() - started) / 100)), count: data.symbols.length }));
    if (p === '/fx/api/search') return json(null, () => D.search(data, q.get('q')));
    if (p === '/fx/api/promos') return json(null, () => D.promos(data, q.get('q')));
    if (p === '/fx/api/countries') return json(p, () => data.countries);
    if (p === '/fx/api/terms') return json(p, () => data.terms);
    if (p === '/fx/api/checkout' && req.method === 'POST') {
      await readBody(req);
      state.orderCounter = D.safeInt(state.orderCounter + 1);
      return json(null, () => ({ order: `FM-${state.orderCounter}` }));
    }
    if ((m = p.match(/^\/fx\/api\/fail\/(\d{3})$/))) return json(null, () => ({ error: 'requested failure' }), Number(m[1]));
    if (p === '/fx/api/slow') {
      const ms = Math.min(30000, Math.max(0, Number(q.get('ms')) || 0));
      await sleep(ms);
      return json(null, () => ({ ms }));
    }
    return notFound();
  }

  // -- control routes -----------------------------------------------------------------------------------------
  async function ctl(req, res, url) {
    if (!isLoopback(req.socket.remoteAddress)) return sendJson(res, 403, { error: 'control routes answer loopback callers only' });
    const body = req.method === 'POST' ? await readBody(req) : Buffer.alloc(0);
    let input = {};
    try {
      input = body.length ? JSON.parse(body.toString('utf8')) : {};
    } catch {
      return sendJson(res, 400, { error: 'body must be JSON' });
    }
    const p = url.pathname;
    if (p === '/ctl/health') return sendJson(res, 200, { mode, upstreamOk: await upstreamHealthy(), run: state.run, fault: faultNow()?.mode || 'none', fixtures: fixtures?.lock?.hash || null, uptimeMs: Date.now() - started });
    if (p === '/ctl/run' && req.method === 'POST') {
      if (!RUN_ID.test(String(input.runId || ''))) return sendJson(res, 400, { error: 'runId: letters, digits and dashes' });
      state.run = input.runId;
      ledger.append(state.run, { seq: ledger.nextSeq(state.run), run: state.run, recvEpochMs: Date.now(), mark: 'run-start', mode });
      log(`run ${state.run}`);
      return sendJson(res, 200, { run: state.run, ledger: path.join(ledger.dir, `${state.run}.jsonl`) });
    }
    if (p === '/ctl/fault' && req.method === 'POST') {
      const mode2 = input.mode || 'none';
      if (!['none', 'refuse', '503', 'latency'].includes(mode2)) return sendJson(res, 400, { error: 'mode: none, refuse, 503 or latency' });
      state.fault = { mode: mode2, until: Date.now() + (Number(input.seconds) || 0) * 1000, ms: Number(input.ms) || 0 };
      ledger.append(state.run, { seq: ledger.nextSeq(state.run), run: state.run, recvEpochMs: Date.now(), mark: `fault ${mode2} ${Number(input.seconds) || 0}s${input.ms ? ` ${input.ms}ms` : ''}` });
      log(`fault ${mode2} for ${input.seconds || 0} s`);
      return sendJson(res, 200, { fault: mode2, until: state.fault.until });
    }
    if (p === '/ctl/mark' && req.method === 'POST') {
      const line = { seq: ledger.nextSeq(state.run), run: state.run, recvEpochMs: Date.now(), mark: String(input.name || 'mark') };
      ledger.append(state.run, line);
      return sendJson(res, 200, line);
    }
    if (p === '/ctl/ledger') return sendJson(res, 200, ledger.lines(url.searchParams.get('run') || state.run));
    if (p === '/ctl/fxlog') {
      const run = url.searchParams.get('run') || state.run;
      const counts = {};
      let total = 0;
      for (const l of ledger.lines(run, '.fx')) {
        counts[l.route] = (counts[l.route] || 0) + 1;
        total++;
      }
      return sendJson(res, 200, { run, total, byRoute: counts });
    }
    if (p === '/ctl/quiet') {
      // returns once no SDK request of the run arrived for `ms` (default 5000), or after `timeout` (default 60000)
      const run = url.searchParams.get('run') || state.run;
      const ms = Number(url.searchParams.get('ms') || 5000), timeout = Number(url.searchParams.get('timeout') || 60000);
      const t0 = Date.now();
      for (;;) {
        const last = Math.max(ledger.lastSdk.get(run) || 0, state.lastSdkAt && state.run === run ? state.lastSdkAt : 0);
        const ago = Date.now() - (last || t0 - ms);
        if (ago >= ms) return sendJson(res, 200, { run, quiet: true, lastRequestAgoMs: last ? Date.now() - last : null, waitedMs: Date.now() - t0 });
        if (Date.now() - t0 > timeout) return sendJson(res, 200, { run, quiet: false, lastRequestAgoMs: Date.now() - last, waitedMs: Date.now() - t0 });
        await sleep(Math.min(250, ms - ago + 5));
      }
    }
    return sendJson(res, 404, { error: 'unknown control route' });
  }

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://gateway');
    try {
      if (url.pathname.startsWith('/api/')) return await sdk(req, res, url);
      if (url.pathname.startsWith('/fx/')) return await fx(req, res, url);
      if (url.pathname.startsWith('/ctl/')) return await ctl(req, res, url);
      // anything else (this machine probes new ports with GET /): a short answer, no ledger line
      res.writeHead(url.pathname === '/' ? 200 : 404, { 'Content-Type': 'text/plain' });
      res.end(url.pathname === '/' ? `fieldtest gateway (${mode})\n` : 'not found\n');
    } catch (e) {
      log(`error on ${req.method} ${url.pathname}: ${e.stack || e}`);
      if (!res.headersSent) sendJson(res, 500, { error: String(e.message || e) });
      else res.destroy();
    }
  });
  server.keepAliveTimeout = 65000;
  server.headersTimeout = 70000;
  server.requestTimeout = 0;
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(Number(opts.port || 18190), opts.host || '127.0.0.1', () => {
      log(`${mode} on http://${opts.host || '127.0.0.1'}:${server.address().port}${mode === 'live' ? `, upstream ${upstream.origin}` : ''}, ledger ${ledger.dir}${fixtures ? `, fixtures ${fixtures.lock?.hash?.slice(0, 12) || fixtures.dir}` : ''}`);
      resolve({ server, state, ledger, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(() => r()); }) });
    });
  });
}

// ---- forward -------------------------------------------------------------------------------------------------

export async function forward({ ledger: dir, run = null, upstream = 'http://127.0.0.1:18182', speed = 1, concurrency = 20, log = (m) => process.stderr.write(`[forward] ${m}\n`) }) {
  dir = path.resolve(dir);
  const up = new URL(upstream);
  const agent = new http.Agent({ keepAlive: true, maxSockets: concurrency });
  const runs = run ? [run] : fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl') && !/\.(forward|fx)\.jsonl$/.test(f)).map((f) => f.slice(0, -6));
  const summary = {};
  for (const r of runs) {
    const lines = fs.readFileSync(path.join(dir, `${r}.jsonl`), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const todo = lines.filter((l) => l.path && l.method === 'POST' && l.path !== '/api/otel/v1/opamp' && l.mode === 'capture' && l.status >= 200 && l.status < 300).sort((a, b) => a.seq - b.seq);
    const outFile = path.join(dir, `${r}.forward.jsonl`);
    if (fs.existsSync(outFile) && fs.readFileSync(outFile, 'utf8').trim()) {
      log(`${r}: already forwarded (${outFile}); skipped`);
      summary[r] = { skipped: true };
      continue;
    }
    const startWall = Date.now(), startCapture = todo.length ? todo[0].recvEpochMs : 0;
    let inFlight = 0, ok = 0, failed = 0;
    const waiters = [];
    const results = [];
    const send = (line) => new Promise((resolve) => {
      const body = line.body ? fs.readFileSync(path.join(dir, line.body)) : Buffer.alloc(0);
      const headers = { ...line.headers, host: up.host, 'content-length': String(body.length) };
      delete headers.origin;
      const sentEpochMs = Date.now();
      const req = http.request({ host: up.hostname, port: up.port, method: 'POST', path: line.path + (line.query || ''), headers, agent }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const entry = { seq: line.seq, run: r, path: line.path, status: res.statusCode, upstreamMs: Date.now() - sentEpochMs, sentEpochMs, captureRecvEpochMs: line.recvEpochMs, delayMs: sentEpochMs - line.recvEpochMs };
          if (res.statusCode >= 300) entry.response = Buffer.concat(chunks).toString('utf8').slice(0, 300);
          resolve(entry);
        });
      });
      req.on('error', (e) => resolve({ seq: line.seq, run: r, path: line.path, status: 0, error: e.message, sentEpochMs, captureRecvEpochMs: line.recvEpochMs, delayMs: sentEpochMs - line.recvEpochMs }));
      req.end(body);
    });
    const tasks = [];
    for (const line of todo) {
      if (speed > 0) {
        const due = startWall + (line.recvEpochMs - startCapture) / speed;
        if (due > Date.now()) await sleep(due - Date.now());
      }
      while (inFlight >= concurrency) await new Promise((r2) => waiters.push(r2));
      inFlight++;
      tasks.push(send(line).then((entry) => {
        inFlight--;
        (waiters.shift() || (() => {}))();
        if (entry.status >= 200 && entry.status < 300) ok++;
        else failed++;
        results.push(entry);
      }));
    }
    await Promise.all(tasks);
    results.sort((a, b) => a.seq - b.seq);
    fs.writeFileSync(outFile, results.map((e) => JSON.stringify(e)).join('\n') + (results.length ? '\n' : ''));
    summary[r] = { forwarded: todo.length, ok, failed, seconds: (Date.now() - startWall) / 1000 };
    log(`${r}: ${todo.length} request(s) forwarded, ${ok} ok, ${failed} failed, ${summary[r].seconds.toFixed(1)} s`);
  }
  agent.destroy();
  return summary;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args._[0] === 'forward') {
    if (!args.ledger) throw new Error('forward needs --ledger');
    const summary = await forward({ ledger: args.ledger, run: args.run || null, upstream: args.upstream, speed: args.speed !== undefined ? Number(args.speed) : 1, concurrency: Number(args.concurrency || 20) });
    console.log(JSON.stringify(summary));
    process.exit(Object.values(summary).some((s) => s.failed) ? 1 : 0);
  }
  if (!args.ledger) throw new Error('--ledger <dir> is required');
  const g = await startGateway({
    mode: args.mode || 'live', port: args.port || 18190, host: args.host || '127.0.0.1', upstream: args.upstream || 'http://127.0.0.1:18182',
    fixtures: args.fixtures || path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'fixtures'), ledger: args.ledger,
    fxLatencyMs: args['fx-latency-ms'] ?? 40, fxKbps: args['fx-kbps'] ?? 8000,
  });
  const stop = () => g.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  main().catch((e) => {
    console.error(e.stack || String(e));
    process.exit(1);
  });
}
