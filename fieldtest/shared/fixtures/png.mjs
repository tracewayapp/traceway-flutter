// PNG (RGBA, 8 bit) with a small deflate written here: greedy LZ77 over a 32 KiB window and the fixed Huffman
// code of RFC 1951. Node's bundled zlib is the Chromium fork, which may choose different matches on different
// CPUs, so its output is not guaranteed to be byte-identical between this machine and a macOS runner. The result
// is an ordinary zlib stream (checked with zlib.inflateSync in the generator's self-check).
// SPDX-License-Identifier: MIT (part of the Traceway SDK field test tools)

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(buf, start = 0, end = buf.length) {
  let c = 0xffffffff;
  for (let i = start; i < end; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function adler32(buf) {
  let a = 1, b = 0;
  for (let i = 0; i < buf.length; i++) {
    a = (a + buf[i]) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

class BitWriter {
  constructor() {
    this.chunks = [];
    this.buf = Buffer.alloc(65536);
    this.pos = 0;
    this.acc = 0;
    this.n = 0;
  }
  pushByte(b) {
    if (this.pos === this.buf.length) {
      this.chunks.push(this.buf);
      this.buf = Buffer.alloc(65536);
      this.pos = 0;
    }
    this.buf[this.pos++] = b;
  }
  /** LSB-first bits, as deflate packs them. */
  bits(value, count) {
    this.acc |= value << this.n;
    this.n += count;
    while (this.n >= 8) {
      this.pushByte(this.acc & 0xff);
      this.acc >>>= 8;
      this.n -= 8;
    }
  }
  /** A Huffman code: written most significant bit first. */
  code(code, length) {
    let rev = 0;
    for (let i = 0; i < length; i++) rev |= ((code >> i) & 1) << (length - 1 - i);
    this.bits(rev, length);
  }
  finish() {
    if (this.n > 0) this.pushByte(this.acc & 0xff);
    this.acc = 0;
    this.n = 0;
    this.chunks.push(this.buf.subarray(0, this.pos));
    return Buffer.concat(this.chunks);
  }
}

const LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

function literal(w, sym) {
  if (sym < 144) w.code(0x30 + sym, 8);
  else if (sym < 256) w.code(0x190 + sym - 144, 9);
  else if (sym < 280) w.code(sym - 256, 7);
  else w.code(0xc0 + sym - 280, 8);
}

function length(w, len) {
  let i = LEN_BASE.length - 1;
  while (LEN_BASE[i] > len) i--;
  literal(w, 257 + i);
  if (LEN_EXTRA[i]) w.bits(len - LEN_BASE[i], LEN_EXTRA[i]);
}

function distance(w, dist) {
  let i = DIST_BASE.length - 1;
  while (DIST_BASE[i] > dist) i--;
  w.code(i, 5);
  if (DIST_EXTRA[i]) w.bits(dist - DIST_BASE[i], DIST_EXTRA[i]);
}

/** zlib stream of [data]: one final block with the fixed Huffman code. */
export function deflateFixed(data) {
  const w = new BitWriter();
  w.pushByte(0x78);
  w.pushByte(0x9c);
  w.bits(1, 1); // BFINAL
  w.bits(1, 2); // BTYPE = 01, fixed codes
  const WINDOW = 32768, HASH = 1 << 15, CHAIN = 48;
  const head = new Int32Array(HASH).fill(-1);
  const prev = new Int32Array(data.length);
  const hash = (i) => ((data[i] << 10) ^ (data[i + 1] << 5) ^ data[i + 2]) & (HASH - 1);
  let i = 0;
  while (i < data.length) {
    let bestLen = 0, bestDist = 0;
    if (i + 2 < data.length) {
      const h = hash(i);
      let j = head[h], chain = 0;
      while (j >= 0 && i - j <= WINDOW && chain++ < CHAIN) {
        let l = 0;
        const max = Math.min(258, data.length - i);
        while (l < max && data[j + l] === data[i + l]) l++;
        if (l > bestLen) {
          bestLen = l;
          bestDist = i - j;
          if (l === max) break;
        }
        j = prev[j];
      }
      prev[i] = head[h];
      head[h] = i;
    }
    if (bestLen >= 3) {
      length(w, bestLen);
      distance(w, bestDist);
      for (let k = 1; k < bestLen; k++) {
        const p = i + k;
        if (p + 2 < data.length) {
          const h = hash(p);
          prev[p] = head[h];
          head[h] = p;
        }
      }
      i += bestLen;
    } else {
      literal(w, data[i]);
      i++;
    }
  }
  literal(w, 256);
  const body = w.finish();
  const a = adler32(data);
  return Buffer.concat([body, Buffer.from([(a >>> 24) & 0xff, (a >>> 16) & 0xff, (a >>> 8) & 0xff, a & 0xff])]);
}

function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'latin1');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out, 4, 8 + data.length), 8 + data.length);
  return out;
}

/** RGBA pixels (Uint8Array, width*height*4) as a PNG, filter chosen per row by the smallest sum of magnitudes. */
export function encodePng(rgba, width, height) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  const line = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    let bestType = 0, bestSum = Infinity, best = null;
    for (let type = 0; type < 5; type++) {
      let sum = 0;
      for (let x = 0; x < stride; x++) {
        const cur = rgba[y * stride + x];
        const left = x >= 4 ? rgba[y * stride + x - 4] : 0;
        const up = y > 0 ? rgba[(y - 1) * stride + x] : 0;
        const upLeft = y > 0 && x >= 4 ? rgba[(y - 1) * stride + x - 4] : 0;
        let pred = 0;
        if (type === 1) pred = left;
        else if (type === 2) pred = up;
        else if (type === 3) pred = (left + up) >> 1;
        else if (type === 4) {
          const p = left + up - upLeft, pa = Math.abs(p - left), pb = Math.abs(p - up), pc = Math.abs(p - upLeft);
          pred = pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
        }
        const v = (cur - pred) & 0xff;
        line[x] = v;
        sum += v < 128 ? v : 256 - v;
      }
      if (sum < bestSum) {
        bestSum = sum;
        bestType = type;
        best = Buffer.from(line);
      }
    }
    raw[y * (stride + 1)] = bestType;
    best.copy(raw, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateFixed(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
