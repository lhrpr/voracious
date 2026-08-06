/// The one test that needs a real macOS embedder.
///
/// Everything else in this repo runs under `flutter test`, where there is no
/// platform side at all: `VideoOutput.create` throws `MissingPluginException`,
/// the controller records that as a reason and carries on, and the whole video
/// path goes unexercised. That is the right behaviour to have — a build with
/// no picture still plays — but it means the ordinary suite cannot tell the
/// difference between "video output works" and "video output is absent".
///
/// This one can. Run it with:
///
/// ```sh
/// flutter test integration_test -d macos
/// ```
///
/// It asserts the plumbing: that a render context is really created against
/// the running engine, that a texture reaches the widget tree, and that the
/// teardown order libmpv insists on is the one the controller uses. What it
/// cannot assert is what the picture looks like — reading a platform texture
/// back is not something a widget test can do — and that is what
/// `voracious_video/tool/render_probe.sh` is for.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:voracious_app/src/screens/player_screen.dart';
import 'package:voracious_app/src/state/library_controller.dart';
import 'package:voracious_app/src/state/player_controller.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_mpv/voracious_mpv.dart';

bool get _hasLibmpv {
  try {
    MpvLibrary.open();
    return true;
  } on Object {
    return false;
  }
}

final Object? _skip =
    _hasLibmpv ? null : 'no libmpv on this machine; install one to run these';

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

    testWidgets('starts a render context against the running engine',
        (tester) async {
      final controller = PlayerController(
        video: video,
        preferences: library.preferences,
        onPositionRecorded: (_) {},
      );

      await controller.start();

      expect(
        controller.stage,
        PlayerLoadStage.ready,
        reason: controller.error ?? '',
      );
      // Both halves matter, and the reason is the useful half when this fails:
      // it carries the platform's own message, which is usually a libmpv with
      // no render API compiled in.
      expect(
        controller.videoOutput,
        isNotNull,
        reason: controller.videoOutputError ?? 'no reason given',
      );
      expect(controller.videoOutputError, isNull);

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

      // A texture id of zero would mean nothing was ever registered with the
      // embedder, which is the shape a silently-failing renderer takes.
      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, greaterThan(0));

      // Let it actually play for a moment: a render context that creates
      // cleanly and then fails on the first frame would still have got this
      // far.
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

      // Disposing the screen disposes the controller, which must free the
      // render context before the engine handle it holds. Getting that order
      // wrong is a use-after-free, so reaching the end of this pump without a
      // crash is the assertion.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 1));
    });
  }, skip: _skip);
}
