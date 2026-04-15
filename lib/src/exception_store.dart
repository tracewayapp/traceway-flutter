import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'models/exception_stack_trace.dart';
import 'models/session_recording_payload.dart';

const _uuid = Uuid();
const _dirName = 'traceway_pending';

class PendingEntry {
  final String id;
  final DateTime createdAt;
  final ExceptionStackTrace exception;
  final SessionRecordingPayload? recording;

  const PendingEntry({
    required this.id,
    required this.createdAt,
    required this.exception,
    this.recording,
  });
}

class ExceptionStore {
  final int maxLocalFiles;
  final int maxAgeHours;
  final bool debug;
  final Directory? testDir;

  Directory? _dir;
  bool _available = false;

  ExceptionStore({
    required this.maxLocalFiles,
    required this.maxAgeHours,
    this.debug = false,
    this.testDir,
  });

  bool get available => _available;

  Future<void> init() async {
    try {
      if (testDir != null) {
        _dir = testDir!;
      } else {
        final appDir = await getApplicationSupportDirectory();
        _dir = Directory('${appDir.path}/$_dirName');
      }
      if (!_dir!.existsSync()) {
        _dir!.createSync(recursive: true);
      }
      _available = true;
      await _pruneExpired();
      await _pruneExcess();
      if (debug) {
        print('Traceway: exception store ready at ${_dir!.path}');
      }
    } catch (e) {
      _available = false;
      if (debug) {
        print('Traceway: disk storage unavailable: $e');
      }
    }
  }

  /// Writes an exception to disk. Returns the file ID, or null on failure.
  String? write(ExceptionStackTrace exception) {
    if (!_available) return null;
    try {
      final id = _uuid.v4();
      final data = jsonEncode({
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'exception': exception.toJson(),
      });
      File('${_dir!.path}/$id.json').writeAsStringSync(data);
      if (debug) {
        print('Traceway: persisted exception $id');
      }
      return id;
    } catch (e) {
      if (debug) {
        print('Traceway: failed to write exception to disk: $e');
      }
      return null;
    }
  }

  /// Adds recording data to an existing exception file on disk.
  void writeRecording(String fileId, SessionRecordingPayload recording) {
    if (!_available) return;
    try {
      final file = File('${_dir!.path}/$fileId.json');
      if (!file.existsSync()) return;
      final data =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      data['recording'] = recording.toJson();
      file.writeAsStringSync(jsonEncode(data));
      if (debug) {
        print('Traceway: persisted recording for $fileId');
      }
    } catch (e) {
      if (debug) {
        print('Traceway: failed to write recording to disk: $e');
      }
    }
  }

  /// Removes files for the given IDs after a successful sync.
  void remove(List<String> fileIds) {
    if (!_available) return;
    for (final id in fileIds) {
      try {
        final file = File('${_dir!.path}/$id.json');
        if (file.existsSync()) {
          file.deleteSync();
          if (debug) {
            print('Traceway: removed synced file $id');
          }
        }
      } catch (e) {
        if (debug) {
          print('Traceway: failed to remove file $id: $e');
        }
      }
    }
  }

  /// Loads all pending entries from disk, ordered by creation time (oldest first).
  List<PendingEntry> loadAll() {
    if (!_available) return [];
    final entries = <PendingEntry>[];
    try {
      final files = _dir!
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();

      for (final file in files) {
        try {
          final data =
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          final createdAt = DateTime.parse(data['createdAt'] as String);
          final exception = ExceptionStackTrace.fromJson(
              data['exception'] as Map<String, dynamic>);

          SessionRecordingPayload? recording;
          if (data['recording'] != null) {
            recording = SessionRecordingPayload.fromJson(
                data['recording'] as Map<String, dynamic>);
          }

          final fileName = file.uri.pathSegments.last;
          final id = fileName.replaceAll('.json', '');
          exception.fileId = id;

          entries.add(PendingEntry(
            id: id,
            createdAt: createdAt,
            exception: exception,
            recording: recording,
          ));
        } catch (e) {
          // Corrupt file — delete it
          try {
            file.deleteSync();
          } catch (_) {}
          if (debug) {
            print('Traceway: removed corrupt file ${file.path}: $e');
          }
        }
      }

      entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } catch (e) {
      if (debug) {
        print('Traceway: failed to load pending entries: $e');
      }
    }
    return entries;
  }

  Future<void> _pruneExpired() async {
    if (!_available) return;
    try {
      final cutoff = DateTime.now().subtract(Duration(hours: maxAgeHours));
      final files = _dir!
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'));

      for (final file in files) {
        try {
          final data =
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          final createdAt = DateTime.parse(data['createdAt'] as String);
          if (createdAt.isBefore(cutoff)) {
            file.deleteSync();
            if (debug) {
              print('Traceway: pruned expired file ${file.path}');
            }
          }
        } catch (e) {
          // Corrupt or unreadable — delete it
          try {
            file.deleteSync();
          } catch (_) {}
        }
      }
    } catch (e) {
      if (debug) {
        print('Traceway: error pruning expired files: $e');
      }
    }
  }

  Future<void> _pruneExcess() async {
    if (!_available) return;
    try {
      final files = _dir!
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();

      if (files.length <= maxLocalFiles) return;

      // Sort by modified time, oldest first
      files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));

      final toRemove = files.length - maxLocalFiles;
      for (var i = 0; i < toRemove; i++) {
        try {
          files[i].deleteSync();
          if (debug) {
            print('Traceway: pruned excess file ${files[i].path}');
          }
        } catch (_) {}
      }
    } catch (e) {
      if (debug) {
        print('Traceway: error pruning excess files: $e');
      }
    }
  }
}
