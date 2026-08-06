/// Owns the profile and the scanned collections.
///
/// A [ChangeNotifier] rather than a state-management package: the app has two
/// screens and one long-lived object per screen, and the rules that matter all
/// live in `voracious_core` behind plain method calls. Adding a framework here
/// would only move the same calls somewhere less obvious.
library;

import 'package:flutter/foundation.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_core/voracious_core_io.dart';

/// Where a collection is in its scan.
enum ScanStatus { idle, scanning, ready, failed }

class LibraryController extends ChangeNotifier {
  LibraryController({required this.profiles});

  final ProfileRepository profiles;

  static const MediaFileSystem _fileSystem = LocalFileSystem();

  Profile _profile = const Profile();
  Profile get profile => _profile;

  Preferences get preferences => _profile.preferences;
  List<MediaCollection> get collections => _profile.collections;

  MediaCollection? _selected;
  MediaCollection? get selected => _selected;

  MediaCollectionIndex _index = MediaCollectionIndex.empty;
  MediaCollectionIndex get index => _index;

  ScanStatus _status = ScanStatus.idle;
  ScanStatus get status => _status;

  ScanProgress? _progress;
  ScanProgress? get progress => _progress;

  String? _error;
  String? get error => _error;

  /// Resume positions for the selected collection, keyed by video id.
  Map<String, Duration> _positions = const {};
  Map<String, Duration> get positions => _positions;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    _profile = await profiles.loadProfile();
    _loaded = true;
    notifyListeners();

    if (_profile.collections.isNotEmpty) {
      await select(_profile.collections.first);
    }
  }

  Future<void> addCollection(String rootPath, {String? name}) async {
    final collection = MediaCollection(
      name: name ?? rootPath.split('/').where((s) => s.isNotEmpty).last,
      rootPath: rootPath,
    );

    // Re-adding a folder should select it, not duplicate it.
    if (!_profile.collections.contains(collection)) {
      _profile = _profile.copyWith(
        collections: [..._profile.collections, collection],
      );
      await profiles.saveProfile(_profile);
    }

    await select(collection);
  }

  Future<void> removeCollection(MediaCollection collection) async {
    _profile = _profile.copyWith(
      collections: _profile.collections.where((c) => c != collection).toList(),
    );
    await profiles.saveProfile(_profile);

    if (_selected == collection) {
      _selected = null;
      _index = MediaCollectionIndex.empty;
      _status = ScanStatus.idle;
    }
    notifyListeners();
  }

  Future<void> select(MediaCollection collection) async {
    _selected = collection;
    await rescan();
  }

  Future<void> rescan() async {
    final collection = _selected;
    if (collection == null) return;

    _status = ScanStatus.scanning;
    _error = null;
    _progress = null;
    notifyListeners();

    try {
      final scanner = MediaScanner(fileSystem: _fileSystem);
      _index = await scanner.scan(
        collection.rootPath,
        onProgress: (progress) {
          _progress = progress;
          notifyListeners();
        },
      );
      _positions = await profiles.loadCollectionPositions(
        collection.rootPath,
        _index.videos.map((v) => v.id),
      );
      _status = ScanStatus.ready;
    } on Object catch (error) {
      _error = error.toString();
      _status = ScanStatus.failed;
    }

    _progress = null;
    notifyListeners();
  }

  Future<void> updatePreferences(Preferences preferences) async {
    _profile = _profile.copyWith(preferences: preferences);
    await profiles.saveProfile(_profile);
    notifyListeners();
  }

  /// Records where the user got to, so the library can show progress and the
  /// player can resume.
  Future<void> recordPosition(String videoId, Duration position) async {
    final collection = _selected;
    if (collection == null) return;

    await profiles.savePlaybackPosition(
      collection.rootPath,
      videoId,
      position,
    );
    _positions = {..._positions, videoId: position};
    notifyListeners();
  }

  Future<Duration> resumePositionFor(String videoId) async {
    final collection = _selected;
    if (collection == null || !preferences.resumePlayback) {
      return Duration.zero;
    }
    return profiles.loadPlaybackPosition(collection.rootPath, videoId);
  }
}
