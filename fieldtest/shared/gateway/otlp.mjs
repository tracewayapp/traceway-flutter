// OTLP/HTTP request bodies, protobuf or JSON, flattened into plain records for the checkers:
//   logs:    {resource, scope, timeUnixNano, observedTimeUnixNano, severityNumber, severityText, body, attributes, eventName, traceId, spanId}
//   spans:   {resource, scope, name, kind, startUnixNano, endUnixNano, attributes, status: {code, message}, traceId, spanId, parentSpanId}
//   metrics: {resource, scope, name, unit, type, points: [{attributes, timeUnixNano, value?, count?, sum?}]}
// Times are decimal strings of nanoseconds; attribute values are strings, numbers, booleans or arrays.
// Only the protobuf fields the checkers need are read; unknown fields are skipped.

function varint(buf, i) {
  let result = 0n, shift = 0n;
  for (;;) {
    if (i >= buf.length) throw new Error('truncated varint');
    const b = buf[i++];
    result |= BigInt(b & 0x7f) << shift;
    if (!(b & 0x80)) return [result, i];
    shift += 7n;
  }
}

function* fields(buf) {
  let i = 0;
  while (i < buf.length) {
    const [key, j] = varint(buf, i);
    i = j;
    const no = Number(key >> 3n), wt = Number(key & 7n);
    if (wt === 0) {
      const [v, k] = varint(buf, i);
      i = k;
      yield { no, wt, v };
    } else if (wt === 1) {
      yield { no, wt, v: buf.subarray(i, i + 8) };
      i += 8;
    } else if (wt === 2) {
      const [len, k] = varint(buf, i);
      const n = Number(len);
      yield { no, wt, v: buf.subarray(k, k + n) };
      i = k + n;
    } else if (wt === 5) {
      yield { no, wt, v: buf.subarray(i, i + 4) };
      i += 4;
    } else {
      throw new Error(`wire type ${wt} not supported`);
    }
  }
}

const str = (b) => Buffer.from(b).toString('utf8');
const hex = (b) => Buffer.from(b).toString('hex');
const fixed64 = (b) => Buffer.from(b).readBigUInt64LE(0).toString();
const double = (b) => Buffer.from(b).readDoubleLE(0);
const sfixed64 = (b) => Number(Buffer.from(b).readBigInt64LE(0));
const signed = (v) => Number(BigInt.asIntN(64, v));

function anyValue(buf) {
  for (const f of fields(buf)) {
    switch (f.no) {
      case 1: return str(f.v);
      case 2: return f.v !== 0n;
      case 3: return signed(f.v);
      case 4: return double(f.v);
      case 5: return [...fields(f.v)].filter((x) => x.no === 1).map((x) => anyValue(x.v));
      case 6: return Object.fromEntries([...fields(f.v)].filter((x) => x.no === 1).map((x) => keyValue(x.v)));
      case 7: return hex(f.v);
    }
  }
  return null;
}

function keyValue(buf) {
  let key = '', value = null;
  for (const f of fields(buf)) {
    if (f.no === 1) key = str(f.v);
    else if (f.no === 2) value = anyValue(f.v);
  }
  return [key, value];
}

const attrs = (list) => Object.fromEntries(list.map((b) => keyValue(b)));

function resource(buf) {
  return attrs([...fields(buf)].filter((f) => f.no === 1).map((f) => f.v));
}

function scope(buf) {
  const out = { name: '', version: '' };
  for (const f of fields(buf)) {
    if (f.no === 1) out.name = str(f.v);
    else if (f.no === 2) out.version = str(f.v);
  }
  return out;
}

/** Walks resource -> scope -> items of a protobuf export request. */
function walk(buf, onItem) {
  for (const r of fields(buf)) {
    if (r.no !== 1) continue;
    let res = {};
    const scopes = [];
    for (const f of fields(r.v)) {
      if (f.no === 1) res = resource(f.v);
      else if (f.no === 2) scopes.push(f.v);
    }
    for (const s of scopes) {
      let sc = { name: '', version: '' };
      const items = [];
      for (const f of fields(s)) {
        if (f.no === 1) sc = scope(f.v);
        else if (f.no === 2) items.push(f.v);
      }
      for (const item of items) onItem(res, sc, item);
    }
  }
}

function protoLogs(buf) {
  const out = [];
  walk(buf, (res, sc, b) => {
    const rec = { resource: res, scope: sc, timeUnixNano: '0', observedTimeUnixNano: '0', severityNumber: 0, severityText: '', body: null, attributes: {}, eventName: '', traceId: '', spanId: '' };
    const list = [];
    for (const f of fields(b)) {
      if (f.no === 1) rec.timeUnixNano = fixed64(f.v);
      else if (f.no === 11) rec.observedTimeUnixNano = fixed64(f.v);
      else if (f.no === 2) rec.severityNumber = Number(f.v);
      else if (f.no === 3) rec.severityText = str(f.v);
      else if (f.no === 5) rec.body = anyValue(f.v);
      else if (f.no === 6) list.push(f.v);
      else if (f.no === 9) rec.traceId = hex(f.v);
      else if (f.no === 10) rec.spanId = hex(f.v);
      else if (f.no === 12) rec.eventName = str(f.v);
    }
    rec.attributes = attrs(list);
    out.push(rec);
  });
  return out;
}

function protoSpans(buf) {
  const out = [];
  walk(buf, (res, sc, b) => {
    const span = { resource: res, scope: sc, name: '', kind: 0, startUnixNano: '0', endUnixNano: '0', attributes: {}, status: { code: 0, message: '' }, traceId: '', spanId: '', parentSpanId: '' };
    const list = [];
    for (const f of fields(b)) {
      if (f.no === 1) span.traceId = hex(f.v);
      else if (f.no === 2) span.spanId = hex(f.v);
      else if (f.no === 4) span.parentSpanId = hex(f.v);
      else if (f.no === 5) span.name = str(f.v);
      else if (f.no === 6) span.kind = Number(f.v);
      else if (f.no === 7) span.startUnixNano = fixed64(f.v);
      else if (f.no === 8) span.endUnixNano = fixed64(f.v);
      else if (f.no === 9) list.push(f.v);
      else if (f.no === 15) {
        for (const s of fields(f.v)) {
          if (s.no === 2) span.status.message = str(s.v);
          else if (s.no === 3) span.status.code = Number(s.v);
        }
      }
    }
    span.attributes = attrs(list);
    out.push(span);
  });
  return out;
}

function point(buf, kind) {
  const p = { attributes: {}, timeUnixNano: '0' };
  const list = [];
  for (const f of fields(buf)) {
    if (kind === 'number') {
      if (f.no === 7) list.push(f.v);
      else if (f.no === 3) p.timeUnixNano = fixed64(f.v);
      else if (f.no === 4) p.value = double(f.v);
      else if (f.no === 6) p.value = sfixed64(f.v);
    } else {
      if ((kind === 'histogram' && f.no === 9) || (kind === 'exponentialHistogram' && f.no === 1)) list.push(f.v);
      else if (f.no === 3) p.timeUnixNano = fixed64(f.v);
      else if (f.no === 4) p.count = Number(Buffer.from(f.v).readBigUInt64LE(0));
      else if (f.no === 5) p.sum = double(f.v);
    }
  }
  p.attributes = attrs(list);
  return p;
}

function protoMetrics(buf) {
  const out = [];
  walk(buf, (res, sc, b) => {
    const m = { resource: res, scope: sc, name: '', unit: '', type: '', points: [] };
    for (const f of fields(b)) {
      if (f.no === 1) m.name = str(f.v);
      else if (f.no === 3) m.unit = str(f.v);
      else if ([5, 7, 9, 10, 11].includes(f.no)) {
        const type = { 5: 'gauge', 7: 'sum', 9: 'histogram', 10: 'exponentialHistogram', 11: 'summary' }[f.no];
        m.type = type;
        const kind = type === 'gauge' || type === 'sum' ? 'number' : type;
        for (const d of fields(f.v)) if (d.no === 1 && kind !== 'summary') m.points.push(point(d.v, kind));
      }
    }
    out.push(m);
  });
  return out;
}

// ---- JSON --------------------------------------------------------------------------------------------------

function jsonValue(v) {
  if (!v || typeof v !== 'object') return v ?? null;
  if ('stringValue' in v) return v.stringValue;
  if ('boolValue' in v) return v.boolValue;
  if ('intValue' in v) return Number(v.intValue);
  if ('doubleValue' in v) return Number(v.doubleValue);
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(jsonValue);
  if ('kvlistValue' in v) return jsonAttrs(v.kvlistValue.values || []);
  if ('bytesValue' in v) return v.bytesValue;
  return null;
}
const jsonAttrs = (list) => Object.fromEntries((list || []).map((kv) => [kv.key, jsonValue(kv.value)]));
const jsonScope = (s) => ({ name: s?.name || '', version: s?.version || '' });
const ns = (v) => (v === undefined || v === null ? '0' : String(v));

function jsonLogs(obj) {
  const out = [];
  for (const rl of obj.resourceLogs || []) {
    const res = jsonAttrs(rl.resource?.attributes);
    for (const sl of rl.scopeLogs || []) {
      for (const r of sl.logRecords || []) {
        out.push({
          resource: res, scope: jsonScope(sl.scope), timeUnixNano: ns(r.timeUnixNano), observedTimeUnixNano: ns(r.observedTimeUnixNano),
          severityNumber: r.severityNumber || 0, severityText: r.severityText || '', body: jsonValue(r.body), attributes: jsonAttrs(r.attributes),
          eventName: r.eventName || '', traceId: r.traceId || '', spanId: r.spanId || '',
        });
      }
    }
  }
  return out;
}

function jsonSpans(obj) {
  const out = [];
  for (const rs of obj.resourceSpans || []) {
    const res = jsonAttrs(rs.resource?.attributes);
    for (const ss of rs.scopeSpans || []) {
      for (const s of ss.spans || []) {
        out.push({
          resource: res, scope: jsonScope(ss.scope), name: s.name || '', kind: s.kind || 0, startUnixNano: ns(s.startTimeUnixNano), endUnixNano: ns(s.endTimeUnixNano),
          attributes: jsonAttrs(s.attributes), status: { code: s.status?.code || 0, message: s.status?.message || '' }, traceId: s.traceId || '', spanId: s.spanId || '', parentSpanId: s.parentSpanId || '',
        });
      }
    }
  }
  return out;
}

function jsonMetrics(obj) {
  const out = [];
  for (const rm of obj.resourceMetrics || []) {
    const res = jsonAttrs(rm.resource?.attributes);
    for (const sm of rm.scopeMetrics || []) {
      for (const m of sm.metrics || []) {
        const type = ['gauge', 'sum', 'histogram', 'exponentialHistogram', 'summary'].find((t) => m[t]);
        const points = ((type && m[type].dataPoints) || []).map((d) => ({
          attributes: jsonAttrs(d.attributes), timeUnixNano: ns(d.timeUnixNano),
          ...(d.asDouble !== undefined ? { value: Number(d.asDouble) } : d.asInt !== undefined ? { value: Number(d.asInt) } : {}),
          ...(d.count !== undefined ? { count: Number(d.count) } : {}), ...(d.sum !== undefined ? { sum: Number(d.sum) } : {}),
        }));
        out.push({ resource: res, scope: jsonScope(sm.scope), name: m.name || '', unit: m.unit || '', type: type || '', points });
      }
    }
  }
  return out;
}

/** Decodes an OTLP body of [signal] ('logs' | 'traces' | 'metrics'); [contentType] picks protobuf or JSON. */
export function decodeOtlp(signal, body, contentType = '') {
  const isJson = /json/i.test(contentType) || (body.length && (body[0] === 0x7b || body[0] === 0x5b));
  if (isJson) {
    const obj = JSON.parse(body.toString('utf8'));
    if (signal === 'logs') return jsonLogs(obj);
    if (signal === 'traces') return jsonSpans(obj);
    if (signal === 'metrics') return jsonMetrics(obj);
  } else {
    if (signal === 'logs') return protoLogs(body);
    if (signal === 'traces') return protoSpans(body);
    if (signal === 'metrics') return protoMetrics(body);
  }
  throw new Error(`unknown signal ${signal}`);
}

/** Nanoseconds (decimal string) to epoch milliseconds. */
export const nanosToMs = (ns) => Number(BigInt(ns || '0') / 1000000n);

// ---- encoding, for the synthetic client's protobuf mode ---------------------------------------------------

function encVarint(n) {
  let v = BigInt(n);
  const out = [];
  do {
    let b = Number(v & 0x7fn);
    v >>= 7n;
    if (v) b |= 0x80;
    out.push(b);
  } while (v);
  return Buffer.from(out);
}
const tag = (no, wt) => encVarint((no << 3) | wt);
const lenField = (no, buf) => Buffer.concat([tag(no, 2), encVarint(buf.length), buf]);
const strField = (no, s) => lenField(no, Buffer.from(String(s), 'utf8'));
const fixed64Field = (no, ns) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(ns));
  return Buffer.concat([tag(no, 1), b]);
};
function encAny(v) {
  if (typeof v === 'string') return strField(1, v);
  if (typeof v === 'boolean') return Buffer.concat([tag(2, 0), encVarint(v ? 1 : 0)]);
  if (Number.isInteger(v)) return Buffer.concat([tag(3, 0), encVarint(BigInt.asUintN(64, BigInt(v)))]);
  const b = Buffer.alloc(8);
  b.writeDoubleLE(v);
  return Buffer.concat([tag(4, 1), b]);
}
const encKv = (k, v) => Buffer.concat([strField(1, k), lenField(2, encAny(v))]);
const encAttrs = (no, obj) => Buffer.concat(Object.entries(obj).map(([k, v]) => lenField(no, encKv(k, v))));

/** A protobuf ExportLogsServiceRequest of one resource and one scope. */
export function encodeLogsProto({ resource = {}, scope = { name: '', version: '' }, records = [] }) {
  const recs = records.map((r) => lenField(2, Buffer.concat([
    fixed64Field(1, r.timeUnixNano), fixed64Field(11, r.observedTimeUnixNano || r.timeUnixNano),
    Buffer.concat([tag(2, 0), encVarint(r.severityNumber || 9)]), strField(3, r.severityText || 'INFO'),
    lenField(5, encAny(r.body ?? '')), encAttrs(6, r.attributes || {}), r.eventName ? strField(12, r.eventName) : Buffer.alloc(0),
  ])));
  const sc = lenField(1, Buffer.concat([strField(1, scope.name), strField(2, scope.version)]));
  const scopeLogs = lenField(2, Buffer.concat([sc, ...recs]));
  const res = lenField(1, encAttrs(1, resource));
  return lenField(1, Buffer.concat([res, scopeLogs]));
}
