/// Persistence, reduced to the smallest interface that covers what is stored.
///
/// Everything Voracious keeps between runs is a JSON blob under a key: the
/// profile, per-video playback positions, cached analysis. That fits a
/// key/value store, which every platform already has (SQLite, SharedPreferences,
/// NSUserDefaults, a file), so nothing here needs a database layer.
library;

/// Asynchronous key/value storage.
abstract interface class KeyValueStore {
  /// Returns the value for [key], or null if absent.
  Future<String?> get(String key);

  Future<void> set(String key, String value);

  Future<void> remove(String key);

  /// Keys beginning with [prefix]. Used to enumerate playback positions.
  Future<List<String>> keys({String prefix = ''});

  /// Reads several keys at once. Implementations that can batch should.
  Future<Map<String, String>> getAll(Iterable<String> keys) async {
    final result = <String, String>{};
    for (final key in keys) {
      final value = await get(key);
      if (value != null) result[key] = value;
    }
    return result;
  }
}

/// An in-memory store, for tests and for a first run before storage is ready.
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, String>? initial])
      : _values = {...?initial};

  final Map<String, String> _values;

  /// Everything currently stored, for assertions.
  Map<String, String> get snapshot => Map.unmodifiable(_values);

  @override
  Future<String?> get(String key) async => _values[key];

  @override
  Future<void> set(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);

  @override
  Future<List<String>> keys({String prefix = ''}) async =>
      _values.keys.where((key) => key.startsWith(prefix)).toList()..sort();

  @override
  Future<Map<String, String>> getAll(Iterable<String> keys) async => {
        for (final key in keys)
          if (_values.containsKey(key)) key: _values[key]!,
      };
}
