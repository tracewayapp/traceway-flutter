import 'histogram.dart';

typedef MetricDims = Map<String, String>;

class MetricExemplar {
  MetricExemplar(this.value, this.timeMs, this.sessionId, [this.target]);
  final double value;
  final int timeMs;
  final String sessionId;

  /// What caused the value, when known.
  final String? target;
}

class HistogramPoint {
  HistogramPoint(this.name, this.unit, this.dims);
  final String name;
  final String unit;
  final MetricDims dims;
  final Histogram histogram = Histogram();
  final List<MetricExemplar> exemplars = [];
}

class SumPoint {
  SumPoint(this.name, this.dims);
  final String name;
  final MetricDims dims;
  double value = 0;
}

/// Everything observed between two flushes. Delta temporality, so batches
/// from different devices add up.
class MetricBatch {
  MetricBatch(this.startMs, this.endMs, this.histograms, this.sums);
  final int startMs;
  final int endMs;
  final List<HistogramPoint> histograms;
  final List<SumPoint> sums;

  int get cells => histograms.length + sums.length;
}

const int _defaultMaxCells = 200;
const int _maxExemplars = 3;

/// Room for the folded cells, so folding never has to drop an observation
/// of a known metric.
const int _foldHeadroom = 50;
const String overflowValue = 'other';

/// The dimension folded to [overflowValue] when there are too many cells:
/// the screen, as the browser SDK folds the page path.
const String screenDimension = 'screen';

String _cellKey(String name, MetricDims dims) {
  final keys = dims.keys.toList()..sort();
  final out = StringBuffer(name);
  for (final key in keys) {
    out
      ..write('\u001f')
      ..write(key)
      ..write('=')
      ..write(dims[key]);
  }
  return out.toString();
}

/// The metrics of one device between two uploads. An observation increments
/// a bucket or a counter and nothing else: memory depends on the number of
/// cells, never on how long the app runs. A port of the browser SDK's
/// `MetricAggregator`.
class MetricAggregator {
  MetricAggregator({int maxCells = _defaultMaxCells, int Function()? now})
      : _maxCells = maxCells,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _startMs = _now();
  }

  final int _maxCells;
  final int Function() _now;
  Map<String, HistogramPoint> _histograms = {};
  Map<String, SumPoint> _sums = {};
  late int _startMs;

  /// Observations lost because the cell limit was reached even after
  /// folding.
  int dropped = 0;

  int get size => _histograms.length + _sums.length;

  /// [exemplarSession] is passed only for a value worth opening a session
  /// for.
  void observe(
    String name,
    double value, {
    MetricDims dims = const {},
    String unit = '',
    String? exemplarSession,
    String? exemplarTarget,
  }) {
    final cell =
        _cell(_histograms, name, dims, (d) => HistogramPoint(name, unit, d));
    if (cell == null || !cell.histogram.record(value)) return;
    if (exemplarSession != null && exemplarSession.isNotEmpty) {
      _keepExemplar(
          cell, MetricExemplar(value, _now(), exemplarSession, exemplarTarget));
    }
  }

  void count(String name, [double n = 1, MetricDims dims = const {}]) {
    if (!n.isFinite || n <= 0) return;
    final cell = _cell(_sums, name, dims, (d) => SumPoint(name, d));
    if (cell != null) cell.value += n;
  }

  /// A ratio is two counters, `<name>` and `<name>.total`, so ratios from
  /// different devices add up.
  void ratio(String name, double part, double total,
      [MetricDims dims = const {}]) {
    if (!(total > 0)) return;
    count('$name.total', total, dims);
    count(name, part.clamp(0, total).toDouble(), dims);
  }

  /// Hands over what was collected and starts a new interval. Null when
  /// nothing was observed.
  MetricBatch? drain() {
    final endMs = _now();
    final startMs = _startMs;
    _startMs = endMs;
    if (size == 0) return null;
    final batch = MetricBatch(
        startMs, endMs, _histograms.values.toList(), _sums.values.toList());
    _histograms = {};
    _sums = {};
    return batch;
  }

  T? _cell<T>(Map<String, T> cells, String name, MetricDims dims,
      T Function(MetricDims dims) create) {
    var key = _cellKey(name, dims);
    var found = cells[key];
    if (found != null) return found;
    var kept = dims;
    if (size >= _maxCells) {
      if (!dims.containsKey(screenDimension) ||
          size >= _maxCells + _foldHeadroom) {
        dropped++;
        return null;
      }
      kept = {...dims, screenDimension: overflowValue};
      key = _cellKey(name, kept);
      found = cells[key];
      if (found != null) return found;
    }
    final created = create(Map.unmodifiable(kept));
    cells[key] = created;
    return created;
  }

  /// Keeps the highest values: an exemplar is a session worth opening.
  void _keepExemplar(HistogramPoint cell, MetricExemplar exemplar) {
    final exemplars = cell.exemplars;
    if (exemplars.length < _maxExemplars) {
      exemplars.add(exemplar);
      return;
    }
    var lowest = 0;
    for (var i = 1; i < exemplars.length; i++) {
      if (exemplars[i].value < exemplars[lowest].value) lowest = i;
    }
    if (exemplars[lowest].value < exemplar.value) exemplars[lowest] = exemplar;
  }
}
