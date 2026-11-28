// The seeded generator every Fieldmart build implements (02-APP-SPEC.md §3.4), and the tick model of the
// Markets screen. Keep this file tiny: it is the reference the Dart, Kotlin and Swift ports are checked against
// (fixtures/reference/ticks.json).
//
//   state = seed (unsigned 32-bit)
//   next():
//     state = (state + 0x6D2B79F5) mod 2^32
//     t = state
//     t = imul(t XOR (t >>> 15), t OR 1)
//     t = t XOR (t + imul(t XOR (t >>> 7), t OR 61))      (the sum is taken mod 2^32)
//     return ((t XOR (t >>> 14)) as unsigned 32-bit) / 4294967296
//
// Tick model for symbol k (0-based), generator seeded (20261128 XOR (k * 2654435761 mod 2^32)):
//   u     = next()
//   cents = max(1, round(cents * (1 + (u - 0.5) * 0.004)))
// evaluated in exactly this order: a = u - 0.5; b = a * 0.004; c = 1 + b; d = cents * c; round half up.
// ticks[n] is the price after the n-th update (n = 0 is the first tick, 0 ms after Markets first appears).

export const DEFAULT_SEED = 20261128;

export function mulberry32(seed) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  next.state = () => state;
  return next;
}

export function symbolSeed(k, seed = DEFAULT_SEED) {
  return (seed ^ Math.imul(k, 2654435761)) >>> 0;
}

/** The generator of symbol [k]'s live ticks. */
export function tickGenerator(k, startCents, seed = DEFAULT_SEED) {
  const next = mulberry32(symbolSeed(k, seed));
  let cents = startCents;
  return () => {
    const u = next();
    cents = Math.max(1, Math.round(cents * (1 + (u - 0.5) * 0.004)));
    return cents;
  };
}

export function ticks(k, startCents, count, seed = DEFAULT_SEED) {
  const step = tickGenerator(k, startCents, seed);
  const out = [];
  for (let i = 0; i < count; i++) out.push(step());
  return out;
}

/** Integer in [lo, hi] (inclusive) from a generator. */
export const intIn = (next, lo, hi) => lo + Math.floor(next() * (hi - lo + 1));
export const pick = (next, list) => list[Math.floor(next() * list.length)];
