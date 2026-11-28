/// What [TracewayOptions.beforeCapture] sees of an exception or a message
/// before it is recorded.
class TracewayCapturedError {
  const TracewayCapturedError({
    required this.message,
    this.error,
    this.stackTrace,
    this.type,
    this.isMessage = false,
    this.attributes = const {},
  });

  /// The object thrown, or null for a [TracewayClient.captureMessage].
  final Object? error;
  final StackTrace? stackTrace;

  /// The error's type, e.g. `SocketException`; null for a message.
  final String? type;

  /// The error's text (`error.toString()`), or the message.
  final String message;

  /// A message from `captureMessage`, not an exception.
  final bool isMessage;

  /// The attributes it will carry: the app's and the screen it happened on.
  final Map<String, Object> attributes;
}

/// Errors not reported unless [TracewayOptions.ignoreErrors] says otherwise:
/// a phone losing its connection, a request timing out or a server saying
/// no is the network's doing, not a bug in the app. Matched against
/// `Type: message`; a [String] matches if it occurs in it.
final List<Pattern> defaultIgnoreErrors = List.unmodifiable(<Pattern>[
  'SocketException',
  'ClientException',
  'HandshakeException',
  'Failed host lookup',
  'Connection closed before full header was received',
  'Connection reset by peer',
  'Connection refused',
  'Network is unreachable',
  RegExp('timeout', caseSensitive: false),
  RegExp(r'status code (of )?4\d{2}'),
  RegExp(r'failed: 4\d{2}'),
  RegExp(r'statusCode: 4\d{2}'),
]);
