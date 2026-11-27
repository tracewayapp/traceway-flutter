final _framePattern = RegExp(
  r'#(\d+)\s+(.+?)\s+\((.+?)(?::(\d+)(?::(\d+))?)?\)',
);

/// A frame as `package:stack_trace` prints it (`Trace.current()`,
/// `Chain.capture`): `package:app/cart.dart 12:5  Cart.add`.
final _packageFramePattern = RegExp(
  r'^((?:package|dart|file|https?|org-dartlang-[a-z-]+):\S+)(?: (\d+)(?::(\d+))?)?\s+(\S.*)$',
);

final _nonSymbolicFramePattern = RegExp(r'SnapshotInstructions\+0x');
final _buildIdPattern = RegExp(r"build_id:\s*'([0-9a-fA-F]+)'");

bool isNonSymbolicTrace(String raw) => _nonSymbolicFramePattern.hasMatch(raw);

String? extractBuildId(String raw) =>
    _buildIdPattern.firstMatch(raw)?.group(1)?.toLowerCase();

String formatException(Object error, StackTrace stackTrace,
    {String? message}) {
  final errorType = error.runtimeType.toString();
  final errorMessage = message ?? error.toString();

  final buffer = StringBuffer();
  buffer.writeln('$errorType: $errorMessage');

  final raw = stackTrace.toString();
  var frames = 0;
  void frame(String function_, String file, String? lineNum, String? col) {
    frames++;
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

  for (final line in raw.split('\n')) {
    final match = _framePattern.firstMatch(line);
    if (match != null) {
      frame(match.group(2) ?? '<unknown>', match.group(3) ?? '<unknown>',
          match.group(4), match.group(5));
      continue;
    }
    final package = _packageFramePattern.firstMatch(line.trimRight());
    if (package != null) {
      frame(package.group(4)!, package.group(1)!, package.group(2),
          package.group(3));
    }
  }
  // A trace in a format of its own keeps its lines rather than none, so
  // issues still tell one crash site from another.
  if (frames == 0 && raw.trim().isNotEmpty) buffer.writeln(raw.trimRight());

  return buffer.toString().trimRight();
}
