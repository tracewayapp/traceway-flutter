// A small baseline JPEG (JFIF) encoder written for the fixture generator, so the pictures come out
// byte-identical on every machine without native code or third-party files.
//
// YCbCr with 4:2:0 chroma subsampling, the IJG quality scaling of the Annex K quantisation tables, the
// floating-point AAN forward DCT (IJG jfdctflt.c) and the Annex K Huffman tables. Only additions,
// multiplications and Math.round/Math.floor are used, so results do not depend on the platform's libm.
//
// encodeJpeg(rgb, width, height, quality) -> Buffer; rgb is a Uint8Array of width*height*3 bytes.
// SPDX-License-Identifier: MIT (part of the Traceway SDK field test tools)

const ZIGZAG = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
  28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61,
  54, 47, 55, 62, 63,
];

const LUMA_Q = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29,
  51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121,
  120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];
const CHROMA_Q = [
  17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
];

const DC_LUMA_BITS = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const DC_LUMA_VALS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const DC_CHROMA_BITS = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const DC_CHROMA_VALS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const AC_LUMA_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const AC_LUMA_VALS = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71,
  0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
  0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37,
  0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83,
  0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
  0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
];
const AC_CHROMA_BITS = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const AC_CHROMA_VALS = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22,
  0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
  0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36,
  0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
  0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
  0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
  0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
  0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
];

const AAN = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.5411961, 0.275899379];

/** Huffman codes per symbol: [code, length] arrays of 256. */
function huffman(bits, vals) {
  const code = new Uint16Array(256), size = new Uint8Array(256);
  let c = 0, k = 0;
  for (let len = 1; len <= 16; len++) {
    for (let i = 0; i < bits[len - 1]; i++) {
      code[vals[k]] = c;
      size[vals[k]] = len;
      c++;
      k++;
    }
    c <<= 1;
  }
  return { code, size };
}

const DC_LUMA = huffman(DC_LUMA_BITS, DC_LUMA_VALS);
const DC_CHROMA = huffman(DC_CHROMA_BITS, DC_CHROMA_VALS);
const AC_LUMA = huffman(AC_LUMA_BITS, AC_LUMA_VALS);
const AC_CHROMA = huffman(AC_CHROMA_BITS, AC_CHROMA_VALS);

function scaledTable(base, quality) {
  const q = Math.min(100, Math.max(1, quality | 0));
  const scale = q < 50 ? Math.floor(5000 / q) : 200 - q * 2;
  const out = new Uint8Array(64);
  for (let i = 0; i < 64; i++) out[i] = Math.min(255, Math.max(1, Math.floor((base[i] * scale + 50) / 100)));
  return out; // natural order
}

/** Multipliers that undo the AAN scaling and quantise, natural order. */
function divisors(table) {
  const out = new Float64Array(64);
  for (let row = 0; row < 8; row++) {
    for (let col = 0; col < 8; col++) {
      const i = row * 8 + col;
      out[i] = 1 / (table[i] * AAN[row] * AAN[col] * 8);
    }
  }
  return out;
}

class Bits {
  constructor(capacity) {
    this.buf = Buffer.alloc(capacity);
    this.pos = 0;
    this.acc = 0;
    this.n = 0;
  }
  ensure(extra) {
    if (this.pos + extra <= this.buf.length) return;
    const next = Buffer.alloc(Math.max(this.buf.length * 2, this.pos + extra));
    this.buf.copy(next, 0, 0, this.pos);
    this.buf = next;
  }
  byte(b) {
    this.ensure(1);
    this.buf[this.pos++] = b;
  }
  bytes(list) {
    for (const b of list) this.byte(b);
  }
  word(w) {
    this.byte((w >> 8) & 0xff);
    this.byte(w & 0xff);
  }
  put(code, len) {
    // acc holds at most 7 pending bits plus len <= 16 new ones
    this.acc = (this.acc << len) | (code & ((1 << len) - 1));
    this.n += len;
    while (this.n >= 8) {
      const b = (this.acc >> (this.n - 8)) & 0xff;
      this.ensure(2);
      this.buf[this.pos++] = b;
      if (b === 0xff) this.buf[this.pos++] = 0;
      this.n -= 8;
    }
    this.acc &= (1 << this.n) - 1;
  }
  flushBits() {
    if (this.n > 0) this.put((1 << (8 - this.n)) - 1, 8 - this.n);
  }
}

function fdct(d) {
  // rows
  for (let o = 0; o < 64; o += 8) {
    const t0 = d[o] + d[o + 7], t7 = d[o] - d[o + 7];
    const t1 = d[o + 1] + d[o + 6], t6 = d[o + 1] - d[o + 6];
    const t2 = d[o + 2] + d[o + 5], t5 = d[o + 2] - d[o + 5];
    const t3 = d[o + 3] + d[o + 4], t4 = d[o + 3] - d[o + 4];
    let t10 = t0 + t3;
    const t13 = t0 - t3;
    let t11 = t1 + t2;
    let t12 = t1 - t2;
    d[o] = t10 + t11;
    d[o + 4] = t10 - t11;
    const z1 = (t12 + t13) * 0.707106781;
    d[o + 2] = t13 + z1;
    d[o + 6] = t13 - z1;
    t10 = t4 + t5;
    t11 = t5 + t6;
    t12 = t6 + t7;
    const z5 = (t10 - t12) * 0.382683433;
    const z2 = 0.5411961 * t10 + z5;
    const z4 = 1.306562965 * t12 + z5;
    const z3 = t11 * 0.707106781;
    const z11 = t7 + z3, z13 = t7 - z3;
    d[o + 5] = z13 + z2;
    d[o + 3] = z13 - z2;
    d[o + 1] = z11 + z4;
    d[o + 7] = z11 - z4;
  }
  // columns
  for (let o = 0; o < 8; o++) {
    const t0 = d[o] + d[o + 56], t7 = d[o] - d[o + 56];
    const t1 = d[o + 8] + d[o + 48], t6 = d[o + 8] - d[o + 48];
    const t2 = d[o + 16] + d[o + 40], t5 = d[o + 16] - d[o + 40];
    const t3 = d[o + 24] + d[o + 32], t4 = d[o + 24] - d[o + 32];
    let t10 = t0 + t3;
    const t13 = t0 - t3;
    let t11 = t1 + t2;
    let t12 = t1 - t2;
    d[o] = t10 + t11;
    d[o + 32] = t10 - t11;
    const z1 = (t12 + t13) * 0.707106781;
    d[o + 16] = t13 + z1;
    d[o + 48] = t13 - z1;
    t10 = t4 + t5;
    t11 = t5 + t6;
    t12 = t6 + t7;
    const z5 = (t10 - t12) * 0.382683433;
    const z2 = 0.5411961 * t10 + z5;
    const z4 = 1.306562965 * t12 + z5;
    const z3 = t11 * 0.707106781;
    const z11 = t7 + z3, z13 = t7 - z3;
    d[o + 40] = z13 + z2;
    d[o + 24] = z13 - z2;
    d[o + 8] = z11 + z4;
    d[o + 56] = z11 - z4;
  }
}

function category(v) {
  let a = v < 0 ? -v : v, n = 0;
  while (a) {
    n++;
    a >>= 1;
  }
  return n;
}

function encodeBlock(out, block, div, prevDc, dc, ac, q) {
  fdct(block);
  for (let i = 0; i < 64; i++) q[i] = Math.round(block[ZIGZAG[i]] * div[ZIGZAG[i]]);
  const diff = q[0] - prevDc;
  const c = category(diff);
  out.put(dc.code[c], dc.size[c]);
  if (c) out.put(diff < 0 ? diff - 1 : diff, c);
  let last = 63;
  while (last > 0 && q[last] === 0) last--;
  let run = 0;
  for (let i = 1; i <= last; i++) {
    const v = q[i];
    if (v === 0) {
      run++;
      continue;
    }
    while (run >= 16) {
      out.put(ac.code[0xf0], ac.size[0xf0]);
      run -= 16;
    }
    const s = category(v);
    const sym = (run << 4) | s;
    out.put(ac.code[sym], ac.size[sym]);
    out.put(v < 0 ? v - 1 : v, s);
    run = 0;
  }
  if (last < 63) out.put(ac.code[0], ac.size[0]);
  return q[0];
}

function writeDht(out, cls, id, bits, vals) {
  out.word(0xffc4);
  out.word(2 + 1 + 16 + vals.length);
  out.byte((cls << 4) | id);
  out.bytes(bits);
  out.bytes(vals);
}

export function encodeJpeg(rgb, width, height, quality = 82) {
  const lumaQ = scaledTable(LUMA_Q, quality), chromaQ = scaledTable(CHROMA_Q, quality);
  const lumaDiv = divisors(lumaQ), chromaDiv = divisors(chromaQ);
  const out = new Bits(Math.max(4096, (width * height) >> 1));

  out.word(0xffd8);
  // APP0 JFIF 1.01, no density
  out.word(0xffe0);
  out.word(16);
  out.bytes([0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
  // DQT, zigzag order
  out.word(0xffdb);
  out.word(2 + 65 * 2);
  out.byte(0);
  for (let i = 0; i < 64; i++) out.byte(lumaQ[ZIGZAG[i]]);
  out.byte(1);
  for (let i = 0; i < 64; i++) out.byte(chromaQ[ZIGZAG[i]]);
  // SOF0
  out.word(0xffc0);
  out.word(17);
  out.byte(8);
  out.word(height);
  out.word(width);
  out.byte(3);
  out.bytes([1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  writeDht(out, 0, 0, DC_LUMA_BITS, DC_LUMA_VALS);
  writeDht(out, 1, 0, AC_LUMA_BITS, AC_LUMA_VALS);
  writeDht(out, 0, 1, DC_CHROMA_BITS, DC_CHROMA_VALS);
  writeDht(out, 1, 1, AC_CHROMA_BITS, AC_CHROMA_VALS);
  // SOS
  out.word(0xffda);
  out.word(12);
  out.byte(3);
  out.bytes([1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]);

  const yb = new Float64Array(64), cb = new Float64Array(64), cr = new Float64Array(64), q = new Int32Array(64);
  const cbAcc = new Float64Array(256), crAcc = new Float64Array(256);
  let dcY = 0, dcCb = 0, dcCr = 0;
  for (let my = 0; my < height; my += 16) {
    for (let mx = 0; mx < width; mx += 16) {
      // Y, Cb, Cr of the 16x16 macroblock; edge pixels repeat
      for (let j = 0; j < 16; j++) {
        const y = Math.min(height - 1, my + j);
        for (let i = 0; i < 16; i++) {
          const x = Math.min(width - 1, mx + i);
          const p = (y * width + x) * 3;
          const r = rgb[p], g = rgb[p + 1], b = rgb[p + 2];
          cbAcc[j * 16 + i] = -0.168736 * r - 0.331264 * g + 0.5 * b;
          crAcc[j * 16 + i] = 0.5 * r - 0.418688 * g - 0.081312 * b;
          // stash luma in place of a second pass: reuse q? keep a 256 buffer
          LUMA[j * 16 + i] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
        }
      }
      for (let blk = 0; blk < 4; blk++) {
        const ox = (blk & 1) * 8, oy = (blk >> 1) * 8;
        for (let j = 0; j < 8; j++) for (let i = 0; i < 8; i++) yb[j * 8 + i] = LUMA[(oy + j) * 16 + ox + i];
        dcY = encodeBlock(out, yb, lumaDiv, dcY, DC_LUMA, AC_LUMA, q);
      }
      for (let j = 0; j < 8; j++) {
        for (let i = 0; i < 8; i++) {
          const o = j * 2 * 16 + i * 2;
          cb[j * 8 + i] = (cbAcc[o] + cbAcc[o + 1] + cbAcc[o + 16] + cbAcc[o + 17]) * 0.25;
          cr[j * 8 + i] = (crAcc[o] + crAcc[o + 1] + crAcc[o + 16] + crAcc[o + 17]) * 0.25;
        }
      }
      dcCb = encodeBlock(out, cb, chromaDiv, dcCb, DC_CHROMA, AC_CHROMA, q);
      dcCr = encodeBlock(out, cr, chromaDiv, dcCr, DC_CHROMA, AC_CHROMA, q);
    }
  }
  out.flushBits();
  out.word(0xffd9);
  return Buffer.from(out.buf.subarray(0, out.pos));
}

const LUMA = new Float64Array(256);
