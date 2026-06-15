final _framePattern = RegExp(
  r'#(\d+)\s+(.+?)\s+\((.+?)(?::(\d+)(?::(\d+))?)?\)',
);

final _nonSymbolicFramePattern = RegExp(r'SnapshotInstructions\+0x');
final _buildIdPattern = RegExp(r"build_id:\s*'([0-9a-fA-F]+)'");

bool isNonSymbolicTrace(String raw) => _nonSymbolicFramePattern.hasMatch(raw);

String? extractBuildId(String raw) =>
    _buildIdPattern.firstMatch(raw)?.group(1)?.toLowerCase();

String formatException(Object error, StackTrace stackTrace) {
  final errorType = error.runtimeType.toString();
  final errorMessage = error.toString();

  final buffer = StringBuffer();
  buffer.writeln('$errorType: $errorMessage');

  final lines = stackTrace.toString().split('\n');
  for (final line in lines) {
    final match = _framePattern.firstMatch(line);
    if (match != null) {
      final function_ = match.group(2) ?? '<unknown>';
      final file = match.group(3) ?? '<unknown>';
      final lineNum = match.group(4);
      final col = match.group(5);

      buffer.write(function_);
      buffer.writeln();
      buffer.write('    $file');
      if (lineNum != null) {
        buffer.write(':$lineNum');
        if (col != null) {
          buffer.write(':$col');
        }
      }
      buffer.writeln();
    }
  }

  return buffer.toString().trimRight();
}

String formatFlutterError(Object error, StackTrace? stackTrace) {
  if (stackTrace == null) {
    return '${error.runtimeType}: $error';
  }
  final raw = stackTrace.toString();
  if (isNonSymbolicTrace(raw)) {
    return '${error.runtimeType}: $error\n$raw';
  }
  return formatException(error, stackTrace);
}
