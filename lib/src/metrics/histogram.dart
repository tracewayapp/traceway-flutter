import 'dart:math' as math;
import 'dart:typed_data';

/// The one scale every histogram uses, the server's included
/// (`backend/app/repositories/telemetry/shared/histogram.go`): bucket `i`
/// holds the values in (2^(i/8), 2^((i+1)/8)], about 9% wide, so a
/// percentile read from it is within about 4.5% of the true value. One scale
/// everywhere means histograms from different devices add up bucket by
/// bucket.
const int histogramScale = 3;

const int _bucketsPerDoubling = 1 << histogramScale;
const double _zeroThreshold = 1e-6;
const double _maxValue = 1e12;

int bucketIndex(double value) =>
    (_log2(value) * _bucketsPerDoubling).ceil() - 1;

final ByteData _bits = ByteData(8);
const double _invLn2 = 1 / math.ln2;

/// log2 the way Go computes it: exact for powers of two, where
/// `log(x) / ln2` is not, so a value on a bucket boundary lands in the
/// bucket the server would put it in.
double _log2(double x) {
  _bits.setFloat64(0, x);
  final raw = _bits.getUint64(0);
  final exp = ((raw >> 52) & 0x7ff) - 1022;
  _bits.setUint64(0, (raw & ~(0x7ff << 52)) | (1022 << 52));
  final frac = _bits.getFloat64(0);
  if (frac == 0.5) return (exp - 1).toDouble();
  return math.log(frac) * _invLn2 + exp;
}

/// A base-2 exponential histogram at [histogramScale], the shape OTLP calls
/// `ExponentialHistogram`, as the browser SDK builds it.
class Histogram {
  int count = 0;
  double sum = 0;
  double min = double.infinity;
  double max = double.negativeInfinity;
  int zeroCount = 0;
  final Map<int, int> buckets = {};

  /// Returns false for a value a histogram cannot hold (negative, NaN,
  /// infinite).
  bool record(double value) {
    if (!value.isFinite || value < 0) return false;
    final v = value > _maxValue ? _maxValue : value;
    count++;
    sum += v;
    if (v < min) min = v;
    if (v > max) max = v;
    if (v < _zeroThreshold) {
      zeroCount++;
    } else {
      final index = bucketIndex(v);
      buckets[index] = (buckets[index] ?? 0) + 1;
    }
    return true;
  }
}
