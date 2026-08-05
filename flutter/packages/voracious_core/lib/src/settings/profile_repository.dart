/// Loads and saves the user's profile.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../library/media_library.dart';
import 'key_value_store.dart';
import 'preferences.dart';

/// The user's collections and preferences.
@immutable
class Profile {
  const Profile({
    this.collections = const [],
    this.preferences = const Preferences(),
  });

  final List<MediaCollection> collections;
  final Preferences preferences;

  Profile copyWith({
    List<MediaCollection>? collections,
    Preferences? preferences,
  }) =>
      Profile(
        collections: collections ?? this.collections,
        preferences: preferences ?? this.preferences,
      );

  Map<String, Object?> toJson() => {
        'collections': [for (final c in collections) c.toJson()],
        'preferences': preferences.toJson(),
      };

  static Profile fromJson(Map<String, Object?> json) => Profile(
        collections: [
          for (final entry
              in (json['collections'] as List<Object?>? ?? const []))
            if (entry is Map)
              MediaCollection.fromJson(entry.cast<String, Object?>()),
        ],
        preferences: json['preferences'] is Map
            ? Preferences.fromJson(
                (json['preferences']! as Map).cast<String, Object?>())
            : const Preferences(),
      );
}

/// Reads and writes the profile and per-video playback positions.
class ProfileRepository {
  ProfileRepository(this.store);

  final KeyValueStore store;

  static const String profileKey = 'profile';
  static const String playbackPositionPrefix = 'playback_position/';

  /// Loads the profile, returning defaults when there is none.
  ///
  /// A profile that fails to parse is treated as absent rather than as an
  /// error: losing preferences is recoverable, refusing to start is not.
  Future<Profile> loadProfile() async {
    final raw = await store.get(profileKey);
    if (raw == null) return const Profile();
    try {
      return Profile.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return const Profile();
    }
  }

  Future<void> saveProfile(Profile profile) async =>
      store.set(profileKey, jsonEncode(profile.toJson()));

  /// Key for one video's resume position.
  ///
  /// Both parts are percent-encoded, so a path containing a slash cannot
  /// collide with a different collection's video.
  static String playbackPositionKey(String collectionRoot, String videoId) =>
      '$playbackPositionPrefix${Uri.encodeComponent(collectionRoot)}/'
      '${Uri.encodeComponent(videoId)}';

  Future<Duration> loadPlaybackPosition(
    String collectionRoot,
    String videoId,
  ) async {
    final raw = await store.get(playbackPositionKey(collectionRoot, videoId));
    final millis = raw == null ? null : int.tryParse(raw);
    return Duration(milliseconds: millis ?? 0);
  }

  Future<void> savePlaybackPosition(
    String collectionRoot,
    String videoId,
    Duration position,
  ) async =>
      store.set(
        playbackPositionKey(collectionRoot, videoId),
        '${position.isNegative ? 0 : position.inMilliseconds}',
      );

  Future<void> clearPlaybackPosition(
    String collectionRoot,
    String videoId,
  ) async =>
      store.remove(playbackPositionKey(collectionRoot, videoId));

  /// Loads resume positions for a whole collection, for progress badges in the
  /// library.
  Future<Map<String, Duration>> loadCollectionPositions(
    String collectionRoot,
    Iterable<String> videoIds,
  ) async {
    final keys = {
      for (final id in videoIds) playbackPositionKey(collectionRoot, id): id,
    };
    final values = await store.getAll(keys.keys);
    return {
      for (final entry in values.entries)
        keys[entry.key]!:
            Duration(milliseconds: int.tryParse(entry.value) ?? 0),
    };
  }
}
