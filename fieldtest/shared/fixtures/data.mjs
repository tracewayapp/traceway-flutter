// The Fieldmart data set (02-APP-SPEC.md §3.1), built from one seed. Pure functions: the generator writes the
// result to fixtures/api/, the gateway serves those files and computes the few routes that depend on a query
// (pages, search, promos) from them.
import { mulberry32, intIn, pick, ticks, DEFAULT_SEED } from './prng.mjs';
import * as W from './words.mjs';

export const PRODUCT_COUNT = 2000;
export const FEED_COUNT = 10000;
export const SYMBOL_COUNT = 300;
export const CANDLE_COUNT = 5000;
export const BASE_PICTURES = 240;
export const HERO_COUNT = 8;
export const AVATAR_COUNT = 64;
export const PRODUCT_17 = 17;
export const PRODUCT_17_REVIEWS = 500;
export const OTHER_REVIEWS = 20;
export const TIMEFRAMES = { '1H': 60, '1D': 300, '1W': 3600, '1M': 14400, '1Y': 86400 };
export const DEAL_PERCENTS = [10, 15, 20, 25, 30, 40];
/** Symbols whose candle series are written to files; the gateway computes the others the same way. */
export const CANDLE_FILE_SYMBOLS = [0, 1];

/** No sentinel may occur anywhere in the fixtures (02-APP-SPEC.md §3.3); numbers step past the CVV. */
export const SENTINELS = [
  '5105 1051 0510 5100', '5105105105105100', 'Zx9!fieldmart-PW', 'Ada Fieldtest', 'ada.fieldtest@example.test',
  '77 Sentinel Quay, Flat 12', 'LOY-88442211',
];
export const SENTINEL_DIGITS = '7391';
export const safeInt = (n) => {
  while (String(n).includes(SENTINEL_DIGITS)) n++;
  return n;
};

/** Image index i of product p shows base picture (p * 7 + i) mod 240. */
export const basePictureOf = (productId, index) => (productId * 7 + index) % BASE_PICTURES;

const money = (cents) => `${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, '0')}`;

function shuffled(next, list) {
  const out = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(next() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

function titleFor(next, categoryId) {
  const adjective = pick(next, W.ADJECTIVES);
  const noun = pick(next, W.NOUNS[categoryId]);
  const material = next() < 0.45 ? `${pick(next, W.MATERIALS)} ` : '';
  return `${adjective} ${material}${noun}`;
}

function products(seed) {
  const next = mulberry32(seed ^ 0x50524f44);
  const list = [];
  for (let id = 1; id <= PRODUCT_COUNT; id++) {
    const categoryId = id === PRODUCT_17 ? 3 : intIn(next, 0, W.CATEGORIES.length - 1);
    let title = titleFor(next, categoryId);
    if (id === PRODUCT_17) title = 'Cedar Oak Desk Lamp';
    const dollars = intIn(next, 2, 499);
    const priceCents = safeInt(dollars * 100 + pick(next, [99, 49, 0, 95]));
    const isNew = next() < 0.1;
    const onSale = next() < 0.25;
    const compareAtCents = onSale ? safeInt(Math.round((priceCents * (100 + intIn(next, 8, 45))) / 100)) : null;
    const rating = Math.round((2.8 + next() * 2.2) * 10) / 10;
    const reviewCount = id === PRODUCT_17 ? PRODUCT_17_REVIEWS : intIn(next, OTHER_REVIEWS, 2400);
    const imageCount = id === PRODUCT_17 ? 8 : intIn(next, 4, 8);
    list.push({
      id, title, brand: pick(next, W.BRANDS), categoryId, priceCents, compareAtCents, rating, reviewCount,
      badges: [...(isNew ? ['new'] : []), ...(compareAtCents ? ['sale'] : [])], imageCount,
    });
  }
  return list;
}

function deals(seed, list) {
  const next = mulberry32(seed ^ 0x4445414c);
  const ids = [PRODUCT_17];
  while (ids.length < 20) {
    const id = intIn(next, 1, PRODUCT_COUNT);
    if (!ids.includes(id)) ids.push(id);
  }
  return ids.map((productId, i) => {
    const pct = i === 0 ? 25 : pick(next, DEAL_PERCENTS);
    const p = list[productId - 1];
    p.compareAtCents = safeInt(Math.round((p.priceCents * 100) / (100 - pct)));
    if (!p.badges.includes('sale')) p.badges.push('sale');
    return { productId, pct, badge: `pct-${pct}` };
  });
}

function description(next, p) {
  const opening = `The ${p.title} from ${p.brand} belongs to our ${W.CATEGORIES[p.categoryId].toLowerCase()} range.`;
  const parts = [opening];
  const pool = shuffled(next, W.DESCRIPTION_SENTENCES);
  let i = 0;
  while ((parts.join(' ') + ' ' + pool[i % pool.length]).length <= 1200) parts.push(pool[i++ % pool.length]);
  return parts.join(' ');
}

function details(seed, list) {
  const next = mulberry32(seed ^ 0x44455441);
  return list.map((p) => ({
    id: p.id,
    description: description(next, p),
    sizes: W.SIZES,
    colours: W.COLOURS,
    stock: p.id === PRODUCT_17 ? 42 : intIn(next, 0, 240),
  }));
}

function review(next, id) {
  const lines = intIn(next, 1, 6);
  const sentences = [];
  for (let i = 0; i < lines; i++) sentences.push(pick(next, W.REVIEW_SENTENCES));
  const day = intIn(next, 0, 300);
  const date = new Date(Date.UTC(2026, 0, 1) + day * 86400000).toISOString().slice(0, 10);
  return {
    id, author: `${pick(next, W.FIRST_NAMES)} ${pick(next, W.LAST_INITIALS)}.`, avatarId: intIn(next, 1, AVATAR_COUNT),
    date, rating: intIn(next, 1, 5), text: sentences.join(' '),
  };
}

/** Product 17's 500 reviews and a pool the other products' 20 reviews are drawn from. */
function reviewSets(seed) {
  const next = mulberry32(seed ^ 0x52455649);
  const r17 = [];
  for (let i = 0; i < PRODUCT_17_REVIEWS; i++) r17.push(review(next, `r17-${i}`));
  const pool = [];
  for (let i = 0; i < 400; i++) pool.push(review(next, `pool-${i}`));
  return { r17, pool };
}

/** The reviews of product [p], in order (product 17: 500, the others: 20 drawn from the pool). */
export function reviewsOf(data, productId) {
  if (productId === PRODUCT_17) return data.reviews17;
  const out = [];
  for (let i = 0; i < OTHER_REVIEWS; i++) {
    const base = data.reviewPool[(productId * 37 + i * 11) % data.reviewPool.length];
    out.push({ ...base, id: `r${productId}-${i}` });
  }
  return out;
}

function symbols(seed) {
  const next = mulberry32(seed ^ 0x53594d42);
  const names = [];
  for (const word of W.SYMBOL_WORDS) for (const suffix of W.SYMBOL_SUFFIXES) names.push([word, suffix]);
  const order = shuffled(next, names).slice(0, SYMBOL_COUNT);
  const used = new Set();
  return order.map(([word, suffix], k) => {
    const letters = (word + suffix).toUpperCase().replace(/[^A-Z]/g, '');
    const candidates = [
      letters.slice(0, 3) + suffix[0].toUpperCase(),
      letters[0] + letters[2] + letters[3] + suffix[0].toUpperCase(),
      letters.slice(0, 2) + letters[4] + suffix[0].toUpperCase(),
      letters[0] + letters[1] + suffix.slice(0, 2).toUpperCase(),
      letters[0] + letters[3] + letters[5] + suffix[1].toUpperCase(),
    ];
    let symbol = candidates.find((c) => !used.has(c));
    for (let n = 0; !symbol; n++) {
      const c = letters.slice(0, 3) + String.fromCharCode(65 + n);
      if (!used.has(c)) symbol = c;
    }
    used.add(symbol);
    return { symbol, name: `${word} ${suffix}`, seedIndex: k, startCents: safeInt(intIn(next, 500, 60000)) };
  });
}

/** The candle series end here (epoch seconds), chosen so that no candle time contains the CVV's digits. */
export function candleEnd() {
  let end = 1795000000 - (1795000000 % 86400);
  for (;;) {
    let clean = true;
    for (const interval of Object.values(TIMEFRAMES)) {
      for (let i = 0; i < CANDLE_COUNT && clean; i++) {
        if (String(end - (CANDLE_COUNT - 1 - i) * interval).includes(SENTINEL_DIGITS)) clean = false;
      }
    }
    if (clean) return end;
    end -= 86400;
  }
}

/** 5,000 candles [t, o, h, l, c] (seconds, cents) of symbol [k] for timeframe [tf]; the last close is its start price. */
export function candles(symbolList, k, tf, seed = DEFAULT_SEED, end = candleEnd()) {
  const sym = symbolList[k];
  const tfIndex = Object.keys(TIMEFRAMES).indexOf(tf);
  if (!sym || tfIndex < 0) return null;
  const interval = TIMEFRAMES[tf];
  const next = mulberry32((seed ^ Math.imul(k + 1, 0x85ebca6b) ^ Math.imul(tfIndex + 1, 0xc2b2ae35)) >>> 0);
  const vol = [0.002, 0.004, 0.009, 0.018, 0.03][tfIndex];
  // walk backwards from the start price, then emit in time order
  const closes = new Array(CANDLE_COUNT);
  let c = sym.startCents;
  for (let i = CANDLE_COUNT - 1; i >= 0; i--) {
    closes[i] = c;
    c = Math.max(5, Math.round(c * (1 + (next() - 0.5) * 2 * vol)));
  }
  const out = [];
  for (let i = 0; i < CANDLE_COUNT; i++) {
    const close = closes[i];
    const open = i === 0 ? Math.max(5, Math.round(close * (1 + (next() - 0.5) * vol))) : closes[i - 1];
    const high = Math.max(open, close) + Math.round(Math.max(open, close) * next() * vol * 0.8);
    const low = Math.max(1, Math.min(open, close) - Math.round(Math.min(open, close) * next() * vol * 0.8));
    out.push([end - (CANDLE_COUNT - 1 - i) * interval, safeInt(open), safeInt(high), safeInt(low), safeInt(close)]);
  }
  return out;
}

// Rows carry no index field: a row's index is its position (cursor + offset), and the number 7391 must not occur.
function feed(seed, list, symbolList) {
  const next = mulberry32(seed ^ 0x46454544);
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const rows = [];
  for (let index = 0; index < FEED_COUNT; index++) {
    const time = `${pick(next, days)} ${String(intIn(next, 6, 22)).padStart(2, '0')}:${String(intIn(next, 0, 59)).padStart(2, '0')}`;
    if (index % 50 === 0) {
      const label = `Week ${index / 50 + 1}`;
      rows.push({ type: 'header', label });
      continue;
    }
    const r = next() * 95;
    if (r < 40) {
      const order = `FM-${safeInt(intIn(next, 100000, 999999))}`;
      const label = pick(next, W.FEED_ORDER_TEXTS).replace('{order}', order);
      rows.push({ type: 'order', label, icon: pick(next, ['box', 'truck', 'check', 'card', 'undo']), time });
    } else if (r < 65) {
      const p = list[intIn(next, 0, PRODUCT_COUNT - 1)];
      const label = pick(next, W.FEED_SHIPMENT_TEXTS).replace('{title}', p.title);
      rows.push({ type: 'shipment', label, productId: p.id, detail: `${p.brand} · ${time}`, progress: intIn(next, 5, 100) });
    } else if (r < 85) {
      const s = symbolList[intIn(next, 0, SYMBOL_COUNT - 1)];
      const spark = [];
      let c = s.startCents;
      for (let i = 0; i < 16; i++) {
        c = Math.max(1, Math.round(c * (1 + (next() - 0.5) * 0.02)));
        spark.push(safeInt(c));
      }
      const changeBp = safeInt(intIn(next, 1, 900)) * (next() < 0.5 ? -1 : 1);
      rows.push({ type: 'alert', label: `${s.symbol} moved ${changeBp > 0 ? 'up' : 'down'} ${money(Math.abs(changeBp))} %`, symbol: s.symbol, priceCents: spark[15], changeBp, spark, time });
    } else {
      const lines = [];
      const n = intIn(next, 3, 8);
      for (let i = 0; i < n; i++) lines.push(pick(next, W.FEED_MESSAGE_LINES));
      const from = `${pick(next, W.FIRST_NAMES)} ${pick(next, W.LAST_INITIALS)}.`;
      rows.push({ type: 'message', label: `Message from ${from}`, from, avatarId: intIn(next, 1, AVATAR_COUNT), lines, time });
    }
  }
  return rows;
}

function terms() {
  const out = [];
  let n = 1;
  while (out.join('\n\n').length < 3000) {
    for (const p of W.TERMS_PARAGRAPHS) {
      out.push(`${n}. ${p}`);
      n++;
      if (out.join('\n\n').length >= 3000) break;
    }
  }
  return { title: 'Terms and conditions', text: out.join('\n\n') };
}

export function buildData(seed = DEFAULT_SEED) {
  const list = products(seed);
  const dealList = deals(seed, list);
  const { r17, pool } = reviewSets(seed);
  const symbolList = symbols(seed);
  const end = candleEnd();
  const categories = W.CATEGORIES.map((name, id) => ({ id, name, productCount: list.filter((p) => p.categoryId === id).length }));
  if (W.COUNTRIES.length !== 200) throw new Error(`need 200 countries, have ${W.COUNTRIES.length}`);
  const candleFiles = {};
  for (const k of CANDLE_FILE_SYMBOLS) {
    for (const tf of Object.keys(TIMEFRAMES)) candleFiles[`${symbolList[k].symbol}-${tf}`] = candles(symbolList, k, tf, seed, end);
  }
  return {
    seed,
    categories,
    products: list,
    details: details(seed, list),
    reviews17: r17,
    reviewPool: pool,
    deals: dealList,
    hero: W.HERO.map(([title, subtitle], i) => ({ id: i + 1, title, subtitle, image: `img/hero/${i + 1}/1600.jpg` })),
    feed: feed(seed, list, symbolList),
    symbols: symbolList,
    candleEnd: end,
    candleFiles,
    countries: [...W.COUNTRIES].sort(),
    promos: W.PROMO_CODES.map(([code, description]) => ({ code, description })),
    terms: terms(),
  };
}

/** The reference ticks every platform's unit test reproduces. */
export function referenceTicks(data, count = 200) {
  return {
    model: 'cents = max(1, round(cents * (1 + (u - 0.5) * 0.004))), u from mulberry32(seed XOR imul(k, 2654435761))',
    seed: data.seed,
    count,
    symbols: [0, 1, SYMBOL_COUNT - 1].map((k) => {
      const s = data.symbols[k];
      return { k, symbol: s.symbol, startCents: s.startCents, ticks: ticks(k, s.startCents, count, data.seed) };
    }),
  };
}

// ---- the query routes, shared by the gateway --------------------------------------------------------------

export function productPage(data, { page = 0, size = 40, category = null }) {
  const all = category === null || category === undefined || category === '' ? data.products : data.products.filter((p) => p.categoryId === Number(category));
  size = Math.min(100, Math.max(1, Number(size) || 40));
  page = Math.max(0, Number(page) || 0);
  const items = all.slice(page * size, page * size + size);
  return { page, size, total: all.length, items, next: (page + 1) * size < all.length ? page + 1 : null };
}

export function search(data, q) {
  const needle = String(q || '').trim().toLowerCase();
  if (!needle) return { q: '', items: [] };
  return { q: needle, items: data.products.filter((p) => p.title.toLowerCase().includes(needle)).slice(0, 50) };
}

export function promos(data, q) {
  const needle = String(q || '').trim().toUpperCase();
  const items = data.promos.filter((p) => p.code.startsWith(needle)).sort((a, b) => (a.code < b.code ? -1 : 1)).slice(0, 8);
  return { q: needle, items };
}

export function feedPage(data, { cursor = 0, size = 100 }) {
  cursor = Math.max(0, Number(cursor) || 0);
  size = Math.min(200, Math.max(1, Number(size) || 100));
  const rows = data.feed.slice(cursor, cursor + size);
  return { cursor, size, total: data.feed.length, rows, next: cursor + size < data.feed.length ? cursor + size : null };
}

export function reviewPage(data, productId, { page = 0, size = 50 }) {
  const all = reviewsOf(data, productId);
  size = Math.min(100, Math.max(1, Number(size) || 50));
  page = Math.max(0, Number(page) || 0);
  return { productId, page, size, total: all.length, items: all.slice(page * size, page * size + size), next: (page + 1) * size < all.length ? page + 1 : null };
}

export { money };
