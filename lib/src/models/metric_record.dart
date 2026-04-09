class MetricRecord {
  final String name;
  final double value;
  final DateTime recordedAt;
  final Map<String, String>? tags;

  const MetricRecord({
    required this.name,
    required this.value,
    required this.recordedAt,
    this.tags,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    if (tags != null) 'tags': tags,
  };
}
