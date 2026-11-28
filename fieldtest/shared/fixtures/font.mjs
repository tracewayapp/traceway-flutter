// A 5x7 bitmap font for the numbers stamped on the fixture pictures and the badge labels.
const GLYPHS = {
  0: ['01110', '10001', '10011', '10101', '11001', '10001', '01110'],
  1: ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
  2: ['01110', '10001', '00001', '00010', '00100', '01000', '11111'],
  3: ['11111', '00010', '00100', '00010', '00001', '10001', '01110'],
  4: ['00010', '00110', '01010', '10010', '11111', '00010', '00010'],
  5: ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
  6: ['00110', '01000', '10000', '11110', '10001', '10001', '01110'],
  7: ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
  8: ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
  9: ['01110', '10001', '10001', '01111', '00001', '00010', '01100'],
  A: ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
  E: ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
  L: ['10000', '10000', '10000', '10000', '10000', '10000', '11111'],
  N: ['10001', '11001', '10101', '10011', '10001', '10001', '10001'],
  S: ['01111', '10000', '10000', '01110', '00001', '00001', '11110'],
  W: ['10001', '10001', '10001', '10101', '10101', '10101', '01010'],
  '-': ['00000', '00000', '00000', '11111', '00000', '00000', '00000'],
  '%': ['11000', '11001', '00010', '00100', '01000', '10011', '00011'],
  ' ': ['00000', '00000', '00000', '00000', '00000', '00000', '00000'],
};

/** Width in cells of [text] (5 per glyph, 1 between glyphs). */
export const textCells = (text) => text.length * 6 - 1;

/**
 * Coverage (0..1) of [text] drawn with its top-left at (x0, y0) and cells of [cell] pixels, at pixel (px, py).
 * Sampled 4x4 per pixel, so edges are smooth at any scale.
 */
export function makeCoverage(text, x0, y0, cell) {
  const w = textCells(text) * cell, h = 7 * cell;
  const on = (cx, cy) => {
    if (cx < 0 || cy < 0 || cy >= 7) return false;
    const g = Math.floor(cx / 6), col = cx - g * 6;
    if (g >= text.length || col === 5) return false;
    const rows = GLYPHS[text[g]];
    if (!rows) throw new Error(`no glyph for ${JSON.stringify(text[g])}`);
    return rows[cy][col] === '1';
  };
  return (px, py) => {
    if (px < x0 - 1 || py < y0 - 1 || px > x0 + w + 1 || py > y0 + h + 1) return 0;
    let hits = 0;
    for (let sy = 0; sy < 4; sy++) {
      for (let sx = 0; sx < 4; sx++) {
        const fx = (px + (sx + 0.5) / 4 - x0) / cell, fy = (py + (sy + 0.5) / 4 - y0) / cell;
        if (fx >= 0 && fy >= 0 && on(Math.floor(fx), Math.floor(fy))) hits++;
      }
    }
    return hits / 16;
  };
}
