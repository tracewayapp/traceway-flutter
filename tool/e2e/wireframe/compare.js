// Image comparison for the wireframe suite, run inside Chromium by
// replay.mjs: window.twCompare(...) compares the replay of a checkpoint with
// the picture the app took of itself (fidelity) and with the accepted
// baseline rendering (changes).
//
// Fidelity is three numbers, each 1 for identical images:
// - ssim: structural similarity of the brightness at half size, the usual
//   8x8 windows; the browser's font against Flutter's costs a little.
// - edges: how well the outlines line up (F1 of Sobel edges, 2 px slack at
//   half size); a missing or misplaced element costs a lot.
// - color: how close the colors are at an eighth of the size (CIE76 ΔE,
//   50 counting as entirely different).
// Changes are the share of pixels that differ from the baseline by more
// than a little, leaving out differences an anti-aliased edge one pixel
// over explains.
(() => {
  const load = (src) =>
    new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('cannot load ' + src));
      img.src = src;
    });

  function rgba(img, w, h) {
    const c = document.createElement('canvas');
    c.width = w;
    c.height = h;
    const ctx = c.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(img, 0, 0, w, h);
    return ctx.getImageData(0, 0, w, h).data;
  }

  function mask(d, w, h, rects) {
    for (const [x0, y0, rw, rh] of rects) {
      const xa = Math.max(0, Math.floor(x0)), ya = Math.max(0, Math.floor(y0));
      const xb = Math.min(w, Math.ceil(x0 + rw)), yb = Math.min(h, Math.ceil(y0 + rh));
      for (let y = ya; y < yb; y++) {
        for (let x = xa; x < xb; x++) {
          const o = (y * w + x) * 4;
          d[o] = d[o + 1] = d[o + 2] = 128;
          d[o + 3] = 255;
        }
      }
    }
  }

  /** Brightness, box-averaged down by [f]. */
  function gray(d, w, h, f) {
    const gw = Math.floor(w / f), gh = Math.floor(h / f);
    const g = new Float32Array(gw * gh);
    for (let y = 0; y < gh; y++) {
      for (let x = 0; x < gw; x++) {
        let s = 0;
        for (let j = 0; j < f; j++) {
          for (let i = 0; i < f; i++) {
            const o = ((y * f + j) * w + x * f + i) * 4;
            s += 0.299 * d[o] + 0.587 * d[o + 1] + 0.114 * d[o + 2];
          }
        }
        g[y * gw + x] = s / (f * f);
      }
    }
    return { g, w: gw, h: gh };
  }

  function ssim(a, b) {
    const C1 = (0.01 * 255) ** 2, C2 = (0.03 * 255) ** 2;
    const win = 8, step = 4, N = win * win, w = a.w, h = a.h;
    let total = 0, n = 0;
    for (let y0 = 0; y0 + win <= h; y0 += step) {
      for (let x0 = 0; x0 + win <= w; x0 += step) {
        let sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
        for (let j = 0; j < win; j++) {
          let o = (y0 + j) * w + x0;
          for (let i = 0; i < win; i++, o++) {
            const p = a.g[o], q = b.g[o];
            sx += p; sy += q; sxx += p * p; syy += q * q; sxy += p * q;
          }
        }
        const mx = sx / N, my = sy / N;
        const vx = sxx / N - mx * mx, vy = syy / N - my * my, cxy = sxy / N - mx * my;
        total += ((2 * mx * my + C1) * (2 * cxy + C2)) / ((mx * mx + my * my + C1) * (vx + vy + C2));
        n++;
      }
    }
    return n ? total / n : 1;
  }

  function sobel(a) {
    const { g, w, h } = a;
    const e = new Uint8Array(w * h);
    for (let y = 1; y < h - 1; y++) {
      for (let x = 1; x < w - 1; x++) {
        const o = y * w + x;
        const gx = g[o - w + 1] + 2 * g[o + 1] + g[o + w + 1] - g[o - w - 1] - 2 * g[o - 1] - g[o + w - 1];
        const gy = g[o + w - 1] + 2 * g[o + w] + g[o + w + 1] - g[o - w - 1] - 2 * g[o - w] - g[o - w + 1];
        e[o] = Math.hypot(gx, gy) > 60 ? 1 : 0;
      }
    }
    return e;
  }

  function dilate(e, w, h, r) {
    const rows = new Uint8Array(w * h), out = new Uint8Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let v = 0;
        for (let i = Math.max(0, x - r); i <= Math.min(w - 1, x + r) && !v; i++) v = e[y * w + i];
        rows[y * w + x] = v;
      }
    }
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let v = 0;
        for (let j = Math.max(0, y - r); j <= Math.min(h - 1, y + r) && !v; j++) v = rows[j * w + x];
        out[y * w + x] = v;
      }
    }
    return out;
  }

  function edgeF1(a, b) {
    const w = a.w, h = a.h;
    const ea = sobel(a), eb = sobel(b);
    const da = dilate(ea, w, h, 2), db = dilate(eb, w, h, 2);
    let na = 0, nb = 0, hitA = 0, hitB = 0;
    for (let i = 0; i < w * h; i++) {
      if (ea[i]) { na++; if (db[i]) hitA++; }
      if (eb[i]) { nb++; if (da[i]) hitB++; }
    }
    if (na === 0 && nb === 0) return 1;
    const recall = na ? hitA / na : 0, precision = nb ? hitB / nb : 0;
    return recall + precision ? (2 * recall * precision) / (recall + precision) : 0;
  }

  function lab(r, g, b) {
    const lin = (c) => ((c /= 255) <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    const R = lin(r), G = lin(g), B = lin(b);
    const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
    const x = f((0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047);
    const y = f(0.2126 * R + 0.7152 * G + 0.0722 * B);
    const z = f((0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883);
    return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
  }

  function color(a, b, w, h) {
    const f = 8, cw = Math.floor(w / f), ch = Math.floor(h / f);
    let total = 0;
    for (let y = 0; y < ch; y++) {
      for (let x = 0; x < cw; x++) {
        const sa = [0, 0, 0], sb = [0, 0, 0];
        for (let j = 0; j < f; j++) {
          for (let i = 0; i < f; i++) {
            const o = ((y * f + j) * w + x * f + i) * 4;
            for (let k = 0; k < 3; k++) { sa[k] += a[o + k]; sb[k] += b[o + k]; }
          }
        }
        const la = lab(...sa.map((v) => v / (f * f))), lb = lab(...sb.map((v) => v / (f * f)));
        const de = Math.hypot(la[0] - lb[0], la[1] - lb[1], la[2] - lb[2]);
        total += Math.max(0, 1 - de / 50);
      }
    }
    return total / (cw * ch);
  }

  function png(d, w, h) {
    const c = document.createElement('canvas');
    c.width = w;
    c.height = h;
    c.getContext('2d').putImageData(new ImageData(d, w, h), 0, 0);
    return c.toDataURL('image/png');
  }

  /** Where the app and the replay differ: brighter red is more. */
  function delta(a, b, w, h) {
    const out = new Uint8ClampedArray(w * h * 4);
    for (let i = 0; i < w * h; i++) {
      const o = i * 4;
      const d = Math.max(Math.abs(a[o] - b[o]), Math.abs(a[o + 1] - b[o + 1]), Math.abs(a[o + 2] - b[o + 2]));
      const base = 255 - (255 - (0.299 * b[o] + 0.587 * b[o + 1] + 0.114 * b[o + 2])) * 0.2;
      out[o] = 255;
      out[o + 1] = out[o + 2] = Math.max(0, base - d * 1.5);
      out[o + 3] = 255;
    }
    return png(out, w, h);
  }

  const T = 40;
  const differ = (a, i, b, j) =>
    Math.abs(a[i] - b[j]) > T || Math.abs(a[i + 1] - b[j + 1]) > T || Math.abs(a[i + 2] - b[j + 2]) > T;

  /** Whether pixel [x, y] of [a] matches a pixel of [b] next to it. */
  function near(a, b, w, h, x, y) {
    const i = (y * w + x) * 4;
    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        const X = x + dx, Y = y + dy;
        if (X < 0 || Y < 0 || X >= w || Y >= h) continue;
        if (!differ(a, i, b, (Y * w + X) * 4)) return true;
      }
    }
    return false;
  }

  function changes(r, b, w, h) {
    const out = new Uint8ClampedArray(w * h * 4);
    let strict = 0, changed = 0;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const o = (y * w + x) * 4;
        const g = 255 - (255 - (0.299 * r[o] + 0.587 * r[o + 1] + 0.114 * r[o + 2])) * 0.25;
        out[o] = out[o + 1] = out[o + 2] = g;
        out[o + 3] = 255;
        if (!differ(r, o, b, o)) continue;
        strict++;
        if (near(r, b, w, h, x, y) && near(b, r, w, h, x, y)) {
          out[o] = 255; out[o + 1] = 200; out[o + 2] = 0;
        } else {
          changed++;
          out[o] = 230; out[o + 1] = 0; out[o + 2] = 0;
        }
      }
    }
    return { changed: changed / (w * h), strict: strict / (w * h), png: png(out, w, h) };
  }

  window.twCompare = async ({ app, replay, baseline, ignore, appIgnore }) => {
    const [a, r] = await Promise.all([load(app), load(replay)]);
    const b = baseline ? await load(baseline).catch(() => null) : null;
    const w = r.width, h = r.height;
    const A = rgba(a, w, h), R = rgba(r, w, h);
    const fa = A.slice(), fr = R.slice();
    mask(fa, w, h, [...ignore, ...appIgnore]);
    mask(fr, w, h, [...ignore, ...appIgnore]);
    const ga = gray(fa, w, h, 2), gr = gray(fr, w, h, 2);
    const result = {
      size: [a.width, a.height, w, h],
      fidelity: {
        ssim: +ssim(ga, gr).toFixed(4),
        edges: +edgeF1(ga, gr).toFixed(4),
        color: +color(fa, fr, w, h).toFixed(4),
      },
      delta: delta(fa, fr, w, h),
      golden: null,
    };
    if (b) {
      if (b.width !== w || b.height !== h) {
        result.golden = { changed: 1, strict: 1, sizeMismatch: [b.width, b.height] };
      } else {
        const B = rgba(b, w, h), gr2 = R.slice();
        mask(gr2, w, h, ignore);
        mask(B, w, h, ignore);
        const c = changes(gr2, B, w, h);
        result.golden = { changed: +c.changed.toFixed(5), strict: +c.strict.toFixed(5) };
        result.diff = c.png;
      }
    }
    return result;
  };
})();
