// Generated pictures: layered gradients, soft shapes and value noise with fine grain, so JPEG sizes resemble
// photos, plus the picture's number in large digits in the top-left corner. Every size is painted from the same
// description in picture coordinates (not downscaled), so the fine grain is per pixel at every size.
// Only + - * /, Math.floor/round/sqrt/min/max are used: the bytes do not depend on the platform's libm.
import { mulberry32 } from './prng.mjs';
import { makeCoverage, textCells } from './font.mjs';
import { encodeJpeg } from './jpeg.mjs';
import { encodePng } from './png.mjs';

export const JPEG_QUALITY = 82;

/** Tuning, chosen so a 320 px picture is about 15 KB and an 800 px one about 90 KB at quality 82. */
export const DETAIL = { grain: 8.6, grainSmall: 6, texture: 22, octaves: [[1 / 5, 46], [1 / 16, 26], [1 / 48, 16], [1 / 140, 8]] };

function hash3(x, y, z) {
  let h = Math.imul(x | 0, 0x27d4eb2d) ^ Math.imul(y | 0, 0x165667b1) ^ Math.imul(z | 0, 0x2545f491);
  h = Math.imul(h ^ (h >>> 15), 0x85ebca6b);
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

const smooth = (t) => t * t * (3 - 2 * t);

/** Value noise in [-0.5, 0.5) at picture coordinate (u, v) with lattice cells of [cell] (picture units). */
function valueNoise(u, v, cell, salt) {
  const fx = u / cell, fy = v / cell;
  const ix = Math.floor(fx), iy = Math.floor(fy);
  const tx = smooth(fx - ix), ty = smooth(fy - iy);
  const a = hash3(ix, iy, salt), b = hash3(ix + 1, iy, salt);
  const c = hash3(ix, iy + 1, salt), d = hash3(ix + 1, iy + 1, salt);
  const top = a + (b - a) * tx, bottom = c + (d - c) * tx;
  return top + (bottom - top) * ty - 0.5;
}

/** HSV (h in [0, 6), s, v in [0, 1]) to RGB 0..255, the piecewise-linear way. */
function hsv(h, s, v) {
  h = ((h % 6) + 6) % 6;
  const i = Math.floor(h), f = h - i;
  const p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
  const [r, g, b] = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][i];
  return [r * 255, g * 255, b * 255];
}

const clamp = (x) => (x < 0 ? 0 : x > 255 ? 255 : Math.round(x));

/** The description of picture [id] (an integer), independent of size. */
function describe(id, salt) {
  const next = mulberry32((Math.imul(id + 1, 0x9e3779b1) ^ salt) >>> 0);
  const h0 = next() * 6;
  const a = hsv(h0, 0.35 + next() * 0.45, 0.45 + next() * 0.45);
  const b = hsv(h0 + 0.5 + next() * 2, 0.3 + next() * 0.5, 0.3 + next() * 0.5);
  let dx = next() - 0.5, dy = next() - 0.5;
  const len = Math.sqrt(dx * dx + dy * dy) || 1;
  dx /= len;
  dy /= len;
  const blobs = [];
  const count = 4 + Math.floor(next() * 4);
  for (let i = 0; i < count; i++) {
    blobs.push({
      cx: next(), cy: next(), rx: 0.08 + next() * 0.3, ry: 0.08 + next() * 0.3,
      color: hsv(h0 + (next() - 0.5) * 3, 0.25 + next() * 0.6, 0.25 + next() * 0.75),
      strength: 0.45 + next() * 0.5,
      ring: next() < 0.35,
    });
  }
  return { a, b, dx, dy, blobs, salt: (id * 7919 + salt) | 0 };
}

/** RGB pixels of a picture of [width] x [height] from [desc], with [label] stamped top-left (or no label). */
function paint(desc, width, height, label, detail = DETAIL) {
  const rgb = new Uint8Array(width * height * 3);
  const aspect = width / height;
  const cell = Math.max(4, Math.round(Math.min(width, height) * 0.03));
  const pad = Math.round(cell * 1.2);
  const lw = label ? textCells(label) * cell : 0, lh = 7 * cell;
  const box = label ? { x: pad, y: pad, w: lw + pad * 2, h: lh + pad * 2 } : null;
  const cover = label ? makeCoverage(label, pad * 2, pad * 2, cell) : null;
  const radius = pad;
  // per-pixel grain is a little weaker on small pictures, as a phone camera's downscaled output is
  const grain = Math.min(width, height) <= 320 && detail.grainSmall !== undefined ? detail.grainSmall : detail.grain;
  for (let y = 0; y < height; y++) {
    const v = (y + 0.5) / height;
    for (let x = 0; x < width; x++) {
      const u = ((x + 0.5) / width) * aspect;
      // gradient
      let t = (u / aspect - 0.5) * desc.dx + (v - 0.5) * desc.dy + 0.5;
      t = t < 0 ? 0 : t > 1 ? 1 : t;
      let r = desc.a[0] + (desc.b[0] - desc.a[0]) * t;
      let g = desc.a[1] + (desc.b[1] - desc.a[1]) * t;
      let b = desc.a[2] + (desc.b[2] - desc.a[2]) * t;
      // soft shapes
      for (const blob of desc.blobs) {
        const ex = (u / aspect - blob.cx) / blob.rx, ey = (v - blob.cy) / blob.ry;
        let d = ex * ex + ey * ey;
        if (d >= 1) continue;
        let w = blob.ring ? 1 - Math.abs(d - 0.6) * 2.5 : 1 - d;
        if (w <= 0) continue;
        w = smooth(w > 1 ? 1 : w) * blob.strength;
        r += (blob.color[0] - r) * w;
        g += (blob.color[1] - g) * w;
        b += (blob.color[2] - b) * w;
      }
      // texture: several octaves of value noise, then per-pixel grain
      let n = 0;
      for (let o = 0; o < detail.octaves.length; o++) {
        const [scale, amp] = detail.octaves[o];
        n += valueNoise(u, v, scale, desc.salt + o * 101) * amp;
      }
      const tint = valueNoise(u, v, 1 / 9, desc.salt + 977) * detail.texture;
      n += (hash3(x, y, desc.salt + width) - 0.5) * grain * 2;
      r += n + tint;
      g += n;
      b += n - tint;
      if (box && x >= box.x - 1 && y >= box.y - 1 && x <= box.x + box.w + 1 && y <= box.y + box.h + 1) {
        // rounded dark backdrop and white digits
        const qx = Math.max(box.x + radius - x, 0, x - (box.x + box.w - radius));
        const qy = Math.max(box.y + radius - y, 0, y - (box.y + box.h - radius));
        const inside = qx * qx + qy * qy <= radius * radius && x >= box.x && y >= box.y && x < box.x + box.w && y < box.y + box.h;
        if (inside) {
          r *= 0.35;
          g *= 0.35;
          b *= 0.35;
        }
        const c = cover(x, y);
        if (c > 0) {
          r += (250 - r) * c;
          g += (250 - g) * c;
          b += (246 - b) * c;
        }
      }
      const p = (y * width + x) * 3;
      rgb[p] = clamp(r);
      rgb[p + 1] = clamp(g);
      rgb[p + 2] = clamp(b);
    }
  }
  return rgb;
}

const SALT = { base: 0x1f0d, hero: 0x2e1a, avatar: 0x3c27 };

export function basePicture(index, size, detail) {
  return encodeJpeg(paint(describe(index, SALT.base), size, size, String(index), detail), size, size, JPEG_QUALITY);
}

export function heroPicture(n) {
  return encodeJpeg(paint(describe(n, SALT.hero), 1600, 900, String(n)), 1600, 900, JPEG_QUALITY);
}

export function avatarPicture(n) {
  const size = 96;
  const desc = describe(n, SALT.avatar);
  const next = mulberry32((n * 2654435761) >>> 0);
  const skin = hsv(0.25 + next() * 0.35, 0.25 + next() * 0.35, 0.45 + next() * 0.5);
  const shirt = hsv(next() * 6, 0.4 + next() * 0.5, 0.35 + next() * 0.5);
  desc.blobs = [
    { cx: 0.5, cy: 1.05, rx: 0.42, ry: 0.36, color: shirt, strength: 0.98, ring: false },
    { cx: 0.5, cy: 0.42, rx: 0.21, ry: 0.24, color: skin, strength: 0.98, ring: false },
  ];
  const detail = { grain: 5, texture: 8, octaves: [[1 / 4, 18], [1 / 12, 8]] };
  return encodeJpeg(paint(desc, size, size, String(n), detail), size, size, JPEG_QUALITY);
}

export const BADGES = {
  new: { label: 'NEW', color: [46, 160, 90] },
  sale: { label: 'SALE', color: [214, 48, 49] },
  'pct-10': { label: '-10%', color: [232, 120, 22] },
  'pct-15': { label: '-15%', color: [232, 120, 22] },
  'pct-20': { label: '-20%', color: [226, 98, 18] },
  'pct-25': { label: '-25%', color: [220, 80, 16] },
  'pct-30': { label: '-30%', color: [214, 62, 14] },
  'pct-40': { label: '-40%', color: [200, 40, 12] },
};

/** A round badge with its label, on a transparent background, 96 x 96 RGBA. */
export function badgePicture(name) {
  const { label, color } = BADGES[name];
  const size = 96;
  const rgba = new Uint8Array(size * size * 4);
  const cell = label.length > 3 ? 3 : 4;
  const tw = textCells(label) * cell, th = 7 * cell;
  const cover = makeCoverage(label, Math.round((size - tw) / 2), Math.round((size - th) / 2), cell);
  const R = 44, C = 48;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let inside = 0;
      for (let sy = 0; sy < 4; sy++) {
        for (let sx = 0; sx < 4; sx++) {
          const dx = x + (sx + 0.5) / 4 - C, dy = y + (sy + 0.5) / 4 - C;
          if (dx * dx + dy * dy <= R * R) inside++;
        }
      }
      const alpha = inside / 16;
      const shade = 1 - (y / size) * 0.18;
      let r = color[0] * shade, g = color[1] * shade, b = color[2] * shade;
      const c = cover(x, y);
      r += (255 - r) * c;
      g += (255 - g) * c;
      b += (255 - b) * c;
      const p = (y * size + x) * 4;
      rgba[p] = clamp(r);
      rgba[p + 1] = clamp(g);
      rgba[p + 2] = clamp(b);
      rgba[p + 3] = clamp(alpha * 255);
    }
  }
  return encodePng(rgba, size, size);
}
