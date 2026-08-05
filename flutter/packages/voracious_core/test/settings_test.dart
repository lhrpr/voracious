import 'dart:convert';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';

void main() {
  group('Preferences', () {
    test('round trips through JSON', () {
      const original = Preferences(
        showRuby: false,
        subtitleMode: SubtitleMode.listen,
        subtitleOrder: ['jpn', 'eng'],
        subtitleIgnores: ['deu'],
        disabledDictionaries: {'Old dictionary'},
        dictionaryOrder: ['JMdict'],
        playbackSpeed: 0.85,
        rubyStyle: RubyStyle.katakana,
        subtitleFontScale: 1.25,
        anki: AnkiExportSettings(
          deckName: 'Japanese',
          modelName: 'Sentence',
          fieldMap: {'Expression': AnkiFieldSource.text},
        ),
      );

      final restored = Preferences.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
      );

      expect(restored.showRuby, isFalse);
      expect(restored.subtitleMode, SubtitleMode.listen);
      expect(restored.subtitleOrder, ['jpn', 'eng']);
      expect(restored.subtitleIgnores, ['deu']);
      expect(restored.disabledDictionaries, {'Old dictionary'});
      expect(restored.playbackSpeed, 0.85);
      expect(restored.rubyStyle, RubyStyle.katakana);
      expect(restored.subtitleFontScale, 1.25);
      expect(restored.anki.deckName, 'Japanese');
    });

    test('an empty object yields the defaults', () {
      final preferences = Preferences.fromJson(const {});
      expect(preferences.showRuby, isTrue);
      expect(preferences.subtitleMode, SubtitleMode.manual);
      expect(preferences.subtitleOrder, isEmpty);
    });

    test('a damaged value falls back rather than failing the profile', () {
      final preferences = Preferences.fromJson(const {
        'showRuby': 'not a bool',
        'subtitleMode': 'a mode that no longer exists',
        'subtitleOrder': 'not a list',
        'playbackSpeed': 'fast',
        'anki': 'nonsense',
      });

      expect(preferences.showRuby, isTrue);
      expect(preferences.subtitleMode, SubtitleMode.manual);
      expect(preferences.subtitleOrder, isEmpty);
      expect(preferences.playbackSpeed, 1);
      expect(preferences.anki.deckName, isNull);
    });

    test('copyWith changes one field and leaves the rest', () {
      const preferences = Preferences(subtitleOrder: ['jpn']);
      final updated = preferences.copyWith(showRuby: false);
      expect(updated.showRuby, isFalse);
      expect(updated.subtitleOrder, ['jpn']);
    });

    test('reads the mode names the Electron profile used', () {
      final preferences =
          Preferences.fromJson(const {'subtitleMode': 'qcheck'});
      expect(preferences.subtitleMode, SubtitleMode.quickCheck);
    });
  });

  group('InMemoryKeyValueStore', () {
    test('stores, reads, lists and removes', () async {
      final store = InMemoryKeyValueStore();
      await store.set('a', '1');
      await store.set('b/c', '2');

      expect(await store.get('a'), '1');
      expect(await store.get('missing'), isNull);
      expect(await store.keys(), ['a', 'b/c']);
      expect(await store.keys(prefix: 'b/'), ['b/c']);

      await store.remove('a');
      expect(await store.get('a'), isNull);
    });

    test('getAll skips missing keys', () async {
      final store = InMemoryKeyValueStore({'a': '1'});
      expect(await store.getAll(['a', 'b']), {'a': '1'});
    });
  });

  group('ProfileRepository', () {
    test('an absent profile yields defaults', () async {
      final repository = ProfileRepository(InMemoryKeyValueStore());
      final profile = await repository.loadProfile();
      expect(profile.collections, isEmpty);
      expect(profile.preferences.showRuby, isTrue);
    });

    test('saves and reloads a profile', () async {
      final store = InMemoryKeyValueStore();
      final repository = ProfileRepository(store);

      await repository.saveProfile(const Profile(
        collections: [
          MediaCollection(name: 'Anime', rootPath: '/media/anime'),
          MediaCollection(name: 'Film', rootPath: '/media/film'),
        ],
        preferences: Preferences(subtitleOrder: ['jpn', 'eng']),
      ));

      final loaded = await repository.loadProfile();
      expect(loaded.collections, hasLength(2));
      expect(loaded.collections.first.name, 'Anime');
      expect(loaded.preferences.subtitleOrder, ['jpn', 'eng']);
    });

    test('a corrupt profile falls back to defaults rather than throwing',
        () async {
      final store = InMemoryKeyValueStore({'profile': '{not json'});
      final profile = await ProfileRepository(store).loadProfile();
      expect(profile.collections, isEmpty);
    });

    test('stores playback positions per collection and video', () async {
      final repository = ProfileRepository(InMemoryKeyValueStore());

      await repository.savePlaybackPosition(
        '/media/anime',
        'Show/S01E01.mkv',
        const Duration(minutes: 12, seconds: 30),
      );

      expect(
        await repository.loadPlaybackPosition(
            '/media/anime', 'Show/S01E01.mkv'),
        const Duration(minutes: 12, seconds: 30),
      );
      expect(
        await repository.loadPlaybackPosition('/media/anime', 'Other.mkv'),
        Duration.zero,
      );
    });

    test('keys cannot collide across collections', () {
      // Both parts are percent-encoded, so a video id containing a slash
      // cannot be confused with a different collection root.
      final a = ProfileRepository.playbackPositionKey('/a', 'b/c.mkv');
      final b = ProfileRepository.playbackPositionKey('/a/b', 'c.mkv');
      expect(a, isNot(b));
    });

    test('clamps a negative position', () async {
      final repository = ProfileRepository(InMemoryKeyValueStore());
      await repository.savePlaybackPosition(
        '/a',
        'v.mkv',
        const Duration(seconds: -5),
      );
      expect(
          await repository.loadPlaybackPosition('/a', 'v.mkv'), Duration.zero);
    });

    test('loads a whole collection of positions at once', () async {
      final repository = ProfileRepository(InMemoryKeyValueStore());
      await repository.savePlaybackPosition(
          '/media', 'a.mkv', const Duration(seconds: 10));
      await repository.savePlaybackPosition(
          '/media', 'b.mkv', const Duration(seconds: 20));

      final positions = await repository
          .loadCollectionPositions('/media', ['a.mkv', 'b.mkv', 'c.mkv']);

      expect(positions, {
        'a.mkv': const Duration(seconds: 10),
        'b.mkv': const Duration(seconds: 20),
      });
    });

    test('clearing removes the position', () async {
      final repository = ProfileRepository(InMemoryKeyValueStore());
      await repository.savePlaybackPosition(
          '/media', 'a.mkv', const Duration(seconds: 10));
      await repository.clearPlaybackPosition('/media', 'a.mkv');
      expect(
        await repository.loadPlaybackPosition('/media', 'a.mkv'),
        Duration.zero,
      );
    });
  });

  group('third-party notices', () {
    test('every copyleft component offers corresponding source', () {
      // Linking to the upstream project is not enough; the obligation is to
      // publish the source of the build actually shipped.
      for (final notice in noticesRequiringSource) {
        expect(
          notice.sourceUrl,
          isNotNull,
          reason: '${notice.name} is ${notice.license} and needs a source URL',
        );
        expect(notice.sourceUrl, isNotEmpty);
      }
      expect(noticesRequiringSource, isNotEmpty);
    });

    test('copyleft components are linked dynamically', () {
      for (final notice in noticesRequiringSource) {
        expect(
          notice.linkage,
          LinkageKind.dynamicLibrary,
          reason: '${notice.name} must stay replaceable by the user',
        );
      }
    });

    test('mpv and FFmpeg are declared', () {
      final names = thirdPartyNotices.map((n) => n.name).toList();
      expect(names, contains('mpv (libmpv)'));
      expect(names, contains('FFmpeg'));
    });

    test('renders a notice text that names the source offer', () {
      final text = renderNoticesAsText(versions: {'mpv (libmpv)': '0.40.0'});
      expect(text, contains('mpv (libmpv) 0.40.0'));
      expect(text, contains('LGPL-2.1-or-later'));
      expect(text, contains(correspondingSourceUrl));
      expect(text, contains('dynamically linked'));
    });

    test('permissive components need no source offer', () {
      final libass = thirdPartyNotices.firstWhere((n) => n.name == 'libass');
      expect(libass.requiresSourceOffer, isFalse);
    });
  });
}
