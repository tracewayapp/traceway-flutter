import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as proto;
import 'package:fixnum/fixnum.dart';

import 'aggregator.dart';
import 'histogram.dart';

typedef MetricResource = Map<String, Object>;

proto.AnyValue _anyValue(Object value) {
  final out = proto.AnyValue();
  if (value is String) {
    out.stringValue = value;
  } else if (value is bool) {
    out.boolValue = value;
  } else if (value is int) {
    out.intValue = Int64(value);
  } else if (value is num) {
    out.doubleValue = value.toDouble();
  } else {
    out.stringValue = value.toString();
  }
  return out;
}

List<proto.KeyValue> keyValues(Map<String, Object> attrs) => [
      for (final entry in attrs.entries)
        proto.KeyValue(key: entry.key, value: _anyValue(entry.value)),
    ];

Int64 _nanos(int ms) => Int64(ms < 0 ? 0 : ms) * 1000000;

/// Renders a batch as an OTLP `ExportMetricsServiceRequest`: exponential
/// histograms and monotonic sums, both with delta temporality, which is what
/// the server takes from a client (a cumulative series would need an
/// identity per device).
proto.ExportMetricsServiceRequest encodeMetrics(
  MetricBatch batch,
  MetricResource resource, {
  required String scopeName,
  required String scopeVersion,
}) {
  final start = _nanos(batch.startMs);
  final end = _nanos(batch.endMs);
  final metrics = <String, proto.Metric>{};

  for (final point in batch.histograms) {
    final metric = metrics.putIfAbsent(
      'h:${point.name}',
      () => proto.Metric(
        name: point.name,
        unit: point.unit,
        exponentialHistogram: proto.ExponentialHistogram(
          aggregationTemporality:
              proto.AggregationTemporality.AGGREGATION_TEMPORALITY_DELTA,
        ),
      ),
    );
    final h = point.histogram;
    final dataPoint = proto.ExponentialHistogramDataPoint(
      attributes: keyValues(point.dims),
      startTimeUnixNano: start,
      timeUnixNano: end,
      count: Int64(h.count),
      sum: h.sum,
      scale: histogramScale,
      zeroCount: Int64(h.zeroCount),
      min: h.min,
      max: h.max,
    );
    if (h.buckets.isNotEmpty) {
      var low = h.buckets.keys.first, high = low;
      for (final index in h.buckets.keys) {
        if (index < low) low = index;
        if (index > high) high = index;
      }
      final counts = List<Int64>.filled(high - low + 1, Int64.ZERO);
      h.buckets.forEach((index, n) => counts[index - low] = Int64(n));
      dataPoint.positive = proto.ExponentialHistogramDataPoint_Buckets(
          offset: low, bucketCounts: counts);
    }
    for (final e in point.exemplars) {
      dataPoint.exemplars.add(proto.Exemplar(
        timeUnixNano: _nanos(e.timeMs),
        asDouble: e.value,
        filteredAttributes: keyValues({
          'session.id': e.sessionId,
          if (e.target != null) 'traceway.target': e.target!,
        }),
      ));
    }
    metric.exponentialHistogram.dataPoints.add(dataPoint);
  }

  for (final point in batch.sums) {
    final metric = metrics.putIfAbsent(
      's:${point.name}',
      () => proto.Metric(
        name: point.name,
        sum: proto.Sum(
          aggregationTemporality:
              proto.AggregationTemporality.AGGREGATION_TEMPORALITY_DELTA,
          isMonotonic: true,
        ),
      ),
    );
    metric.sum.dataPoints.add(proto.NumberDataPoint(
      attributes: keyValues(point.dims),
      startTimeUnixNano: start,
      timeUnixNano: end,
      asDouble: point.value,
    ));
  }

  return proto.ExportMetricsServiceRequest(resourceMetrics: [
    proto.ResourceMetrics(
      resource: proto.Resource(attributes: keyValues(resource)),
      scopeMetrics: [
        proto.ScopeMetrics(
          scope: proto.InstrumentationScope(
              name: scopeName, version: scopeVersion),
          metrics: metrics.values,
        ),
      ],
    ),
  ]);
}
