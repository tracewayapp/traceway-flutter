import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Small key-value state the SDK keeps between app starts: the OpAMP instance
/// uid, the last applied remote config and the current session. One JSON
/// file; with no directory it only lives in memory.
class StateStore {
  StateStore(this._directory);

  final Directory? _directory;
  Map<String, dynamic> _values = {};
  Timer? _writeTimer;

  File? get _file {
    final directory = _directory;
    return directory == null
        ? null
        : File('${directory.path}${Platform.pathSeparator}state.json');
  }

  Future<void> load() async {
    final file = _file;
    if (file == null) return;
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) _values = decoded.cast<String, dynamic>();
      }
    } catch (_) {
      _values = {};
    }
  }

  dynamic get(String key) => _values[key];

  void set(String key, Object? value) {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    _writeTimer ??= Timer(const Duration(milliseconds: 250), flush);
  }

  Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_values));
      await tmp.rename(file.path);
    } catch (_) {
      // State is a convenience; losing it only costs a fresh id or config.
    }
  }
}
