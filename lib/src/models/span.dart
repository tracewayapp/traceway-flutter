class Span {
  final String id;
  final String name;
  final DateTime startTime;
  final int duration;

  const Span({
    required this.id,
    required this.name,
    required this.startTime,
    required this.duration,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'startTime': startTime.toUtc().toIso8601String(),
    'duration': duration,
  };
}
