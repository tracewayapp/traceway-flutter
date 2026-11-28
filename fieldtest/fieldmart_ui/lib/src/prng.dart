/// The seeded generator every Fieldmart build shares (02-APP-SPEC.md §3.4),
/// so the chart and the watchlist show the same numbers on every platform.
library;

const int _mask32 = 0xFFFFFFFF;

/// 32-bit wrapping multiplication, as JavaScript's `Math.imul` (unsigned).
int imul32(int a, int b) {
  a &= _mask32;
  b &= _mask32;
  // Split to stay exact in 64-bit integers (and in JS doubles on the web).
  final aHi = (a >> 16) & 0xFFFF, aLo = a & 0xFFFF;
  final lo = aLo * b;
  final hi = ((aHi * b) & 0xFFFF) << 16;
  return (lo + hi) & _mask32;
}

class FmRandom {
  FmRandom(int seed) : _state = seed & _mask32;

  int _state;

  /// The next value in [0, 1).
  double next() {
    _state = (_state + 0x6D2B79F5) & _mask32;
    var t = _state;
    t = imul32(t ^ (t >> 15), t | 1);
    t = (t ^ ((t + imul32(t ^ (t >> 7), t | 61)) & _mask32)) & _mask32;
    return ((t ^ (t >> 14)) & _mask32) / 4294967296.0;
  }
}

const int fmTickSeed = 20261128;

/// The seed of symbol [k] (0-based): `20261128 XOR (k × 2654435761 mod 2^32)`.
int symbolSeed(int k) => (fmTickSeed ^ ((k * 2654435761) & _mask32)) & _mask32;

/// One symbol's price as ticks arrive: integer cents, never floating text.
class TickModel {
  TickModel(int symbolIndex, int startCents)
      : _random = FmRandom(symbolSeed(symbolIndex)),
        _cents = startCents;

  final FmRandom _random;
  int _cents;
  int _ticks = 0;

  int get cents => _cents;

  /// How many ticks have been applied.
  int get ticks => _ticks;

  /// Applies one tick and returns the new price in cents.
  int tick() {
    final u = _random.next();
    final value = _cents * (1 + (u - 0.5) * 0.004);
    // JavaScript's Math.round: halves go up. Prices are positive.
    final rounded = (value + 0.5).floor();
    _cents = rounded < 1 ? 1 : rounded;
    _ticks++;
    return _cents;
  }

  /// Applies ticks until [ticks] have been applied in total.
  int advanceTo(int ticks) {
    while (_ticks < ticks) {
      tick();
    }
    return _cents;
  }
}

/// `123.45` from 12345 cents, without going through a double.
String formatCents(int cents) {
  final negative = cents < 0;
  final abs = negative ? -cents : cents;
  final whole = abs ~/ 100;
  final frac = (abs % 100).toString().padLeft(2, '0');
  final grouped = _group(whole);
  return '${negative ? '-' : ''}$grouped.$frac';
}

String _group(int whole) {
  final s = whole.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
