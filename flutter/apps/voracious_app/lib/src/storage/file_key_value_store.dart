/// A [KeyValueStore] kept in a JSON file under Application Support.
///
/// Everything persisted is small — a profile and one integer per watched video
/// — so a single file read at startup and a debounced write afterwards is
/// enough, and it avoids adding a database to a desktop app that does not need
/// one. Writes go to a temporary file and are renamed over the original, so an
/// interrupted write cannot leave a half-written profile behind.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:voracious_core/voracious_core.dart';

class FileKeyValueStore implements KeyValueStore {
  FileKeyValueStore._(this._file, this._values);

  final File _file;
  final Map<String, String> _values;

  Timer? _pendingWrite;

  /// Opens the store in [directory], reading whatever is already there.
  ///
  /// A file that cannot be parsed is treated as empty rather than as an error:
  /// starting with default preferences beats refusing to start.
  static Future<FileKeyValueStore> open(String directory) async {
    final file = File(p.join(directory, 'voracious.json'));
    final values = <String, String>{};

    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.value is String) {
              values[entry.key as String] = entry.value as String;
            }
          }
        }
      } on Object {
        // Fall through with an empty store.
      }
    }

    return FileKeyValueStore._(file, values);
  }

  @override
  Future<String?> get(String key) async => _values[key];

  @override
  Future<void> set(String key, String value) async {
    _values[key] = value;
    _scheduleWrite();
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
    _scheduleWrite();
  }

  @override
  Future<List<String>> keys({String prefix = ''}) async =>
      _values.keys.where((key) => key.startsWith(prefix)).toList()..sort();

  @override
  Future<Map<String, String>> getAll(Iterable<String> keys) async => {
        for (final key in keys)
          if (_values.containsKey(key)) key: _values[key]!,
      };

  /// Playback position is written on every position update while watching, so
  /// the writes are coalesced rather than hitting the disk continuously.
  void _scheduleWrite() {
    _pendingWrite?.cancel();
    _pendingWrite = Timer(const Duration(milliseconds: 400), flush);
  }

  /// Writes immediately. Called on shutdown, where waiting for the timer would
  /// lose the last few seconds of progress.
  Future<void> flush() async {
    _pendingWrite?.cancel();
    _pendingWrite = null;

    final parent = _file.parent;
    if (!parent.existsSync()) await parent.create(recursive: true);

    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(jsonEncode(_values));
    await temporary.rename(_file.path);
  }
}
