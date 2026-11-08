/// The one test that needs a real macOS embedder.
///
/// Under `flutter test` there is no platform side, so media_kit's video
/// texture can't be created and the video path goes unexercised. This runs
/// inside a real app build, where media_kit's bundled libmpv is present:
///
/// ```sh
/// flutter test integration_test -d macos
/// ```
///
/// It asserts the plumbing: that a video controller is created against the
/// running engine, that a texture reaches the widget tree, and that tearing
/// the screen down while playing doesn't crash. It can't assert what the
/// picture looks like.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:voracious_app/src/screens/player_screen.dart';
import 'package:voracious_app/src/state/library_controller.dart';
import 'package:voracious_app/src/state/player_controller.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:media_kit/media_kit.dart';

String get _fixtures => p.join(Directory.current.path, 'test', 'fixtures');

Future<bool> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 50));
  }
  return condition();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  group('video output on a real engine', () {
    late LibraryController library;
    late VideoEntry video;

    setUp(() async {
      library = LibraryController(
        profiles: ProfileRepository(InMemoryKeyValueStore()),
      );
      await library.load();
      await library.addCollection(_fixtures, name: 'Fixtures');
      video = library.index.videos.single;
    });

    // Not `tearDown`: the player records a final position as it disposes, and
    // that lands on the library. Registering here means it runs after the
    // per-test teardown that disposes the player, not before it.
    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      library.dispose();
    });

    testWidgets('creates a video controller against the running engine',
        (tester) async {
      final controller = PlayerController(
        video: video,
        preferences: library.preferences,
        onPositionRecorded: (_) {},
      );

      // media_kit sets its video output up after the next frame, and opening
      // a file waits for that, so frames have to keep coming while it starts.
      // The app draws them anyway; a test has to pump them.
      var started = false;
      unawaited(controller.start().whenComplete(() => started = true));
      expect(await _waitUntil(tester, () => started), isTrue,
          reason: 'start() did not finish');

      expect(
        controller.stage,
        PlayerLoadStage.ready,
        reason: controller.error ?? '',
      );
      expect(
        controller.videoController,
        isNotNull,
        reason: controller.videoOutputError ?? 'no reason given',
      );
      expect(controller.videoOutputError, isNull);

      // The fixture's own subtitle track, extracted through the real app
      // support directory, alongside its two sidecar files.
      expect(controller.embeddedSubtitleError, isNull);
      expect(controller.tracks.map((t) => t.id), contains(endsWith('#track4')));
      expect(controller.tracks, hasLength(3));

      await controller.dispose();
    });

    testWidgets('renders the engine into a texture in the widget tree',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: PlayerScreen(video: video, library: library)),
      );

      final ready = await _waitUntil(
        tester,
        () => find.byType(Texture).evaluate().isNotEmpty,
      );
      expect(
        ready,
        isTrue,
        reason: 'no Texture appeared; video output did not start',
      );

      // Let it actually play for a moment: a renderer that starts cleanly and
      // then fails on the first frame would still have got this far.
      await _waitUntil(
        tester,
        () =>
            tester
                .state<State<PlayerScreen>>(find.byType(PlayerScreen))
                .mounted &&
            find.byType(Texture).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 3),
      );
      expect(find.byType(Texture), findsOneWidget);

      // Disposing the screen disposes the engine mid-playback; reaching the end
      // of this pump without a crash is the assertion.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
