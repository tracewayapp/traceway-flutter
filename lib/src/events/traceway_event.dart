/// A single entry in the breadcrumb timeline that ships with an exception.
sealed class TracewayEvent {
  final DateTime timestamp;

  TracewayEvent({DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();

  String get type;

  Map<String, dynamic> toJson() => {
        'type': type,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  static TracewayEvent fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'log':
        return LogEvent.fromJson(json);
      case 'network':
        return NetworkEvent.fromJson(json);
      case 'navigation':
        return NavigationEvent.fromJson(json);
      case 'custom':
        return CustomEvent.fromJson(json);
      default:
        throw FormatException('Unknown TracewayEvent type: $type');
    }
  }
}

class LogEvent extends TracewayEvent {
  final String level;
  final String message;

  LogEvent({
    required this.message,
    this.level = 'info',
    super.timestamp,
  });

  @override
  String get type => 'log';

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'level': level,
        'message': message,
      };

  factory LogEvent.fromJson(Map<String, dynamic> json) => LogEvent(
        timestamp: DateTime.parse(json['timestamp'] as String),
        level: json['level'] as String? ?? 'info',
        message: json['message'] as String? ?? '',
      );
}

class NetworkEvent extends TracewayEvent {
  final String method;
  final String url;
  final int? statusCode;
  final Duration duration;
  final int? requestBytes;
  final int? responseBytes;
  final String? error;

  NetworkEvent({
    required this.method,
    required this.url,
    required this.duration,
    this.statusCode,
    this.requestBytes,
    this.responseBytes,
    this.error,
    super.timestamp,
  });

  @override
  String get type => 'network';

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'method': method,
        'url': url,
        'durationMs': duration.inMilliseconds,
        if (statusCode != null) 'statusCode': statusCode,
        if (requestBytes != null) 'requestBytes': requestBytes,
        if (responseBytes != null) 'responseBytes': responseBytes,
        if (error != null) 'error': error,
      };

  factory NetworkEvent.fromJson(Map<String, dynamic> json) => NetworkEvent(
        timestamp: DateTime.parse(json['timestamp'] as String),
        method: json['method'] as String? ?? '',
        url: json['url'] as String? ?? '',
        duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
        statusCode: json['statusCode'] as int?,
        requestBytes: json['requestBytes'] as int?,
        responseBytes: json['responseBytes'] as int?,
        error: json['error'] as String?,
      );
}

class NavigationEvent extends TracewayEvent {
  /// One of: push, pop, replace, remove.
  final String action;
  final String? from;
  final String? to;

  NavigationEvent({
    required this.action,
    this.from,
    this.to,
    super.timestamp,
  });

  @override
  String get type => 'navigation';

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'action': action,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
      };

  factory NavigationEvent.fromJson(Map<String, dynamic> json) =>
      NavigationEvent(
        timestamp: DateTime.parse(json['timestamp'] as String),
        action: json['action'] as String? ?? '',
        from: json['from'] as String?,
        to: json['to'] as String?,
      );
}

class CustomEvent extends TracewayEvent {
  final String category;
  final String name;
  final Map<String, dynamic>? data;

  CustomEvent({
    required this.category,
    required this.name,
    this.data,
    super.timestamp,
  });

  @override
  String get type => 'custom';

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'category': category,
        'name': name,
        if (data != null) 'data': data,
      };

  factory CustomEvent.fromJson(Map<String, dynamic> json) => CustomEvent(
        timestamp: DateTime.parse(json['timestamp'] as String),
        category: json['category'] as String? ?? '',
        name: json['name'] as String? ?? '',
        data: (json['data'] as Map?)?.cast<String, dynamic>(),
      );
}
