/// Tests for the Dart half of the video output.
///
/// The renderer itself cannot be reached from here — it needs a real libmpv, a
/// GL context and a texture registry, none of which exist under `flutter
/// test`. That half is covered by `tool/render_probe.sh`, which renders a
/// frame and inspects it. What is left is the boundary, and the boundary is
/// where the mistakes are cheap to make and invisible: an argument named
/// wrongly still compiles, and a dispose that fires twice still runs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:voracious_video/voracious_video.dart';

void main() {
  const channel = MethodChannel('voracious_video');
  final calls = <MethodCall>[];

  /// Installs a handler returning [textureId] from `create`, or throwing
  /// [error] from every call.
  void mockPlatform({int textureId = 7, Object? error}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (error != null) throw error;
      return call.method == 'create' ? textureId : null;
    });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('VideoOutput', () {
    test('passes the engine handle and library path through unchanged',
        () async {
      mockPlatform(textureId: 42);

      final output = await VideoOutput.create(
        mpvHandle: 0x7f0000abcdef,
        libraryPath: '/opt/homebrew/lib/libmpv.dylib',
        initialSize: const Size(640, 360),
      );

      expect(output.textureId, 42);
      expect(calls.single.method, 'create');
      expect(calls.single.arguments, {
        'handle': 0x7f0000abcdef,
        'libraryPath': '/opt/homebrew/lib/libmpv.dylib',
        'width': 640,
        'height': 360,
      });
    });

    test('reports a platform without an implementation as unimplemented',
        () async {
      mockPlatform(error: MissingPluginException('no implementation'));

      await expectLater(
        VideoOutput.create(mpvHandle: 1, libraryPath: 'libmpv.dylib'),
        throwsA(isA<VideoOutputException>()
            .having((e) => e.code, 'code', 'unimplemented')),
      );
    });

    test('carries the platform message, which names the real problem',
        () async {
      // The message that matters most is a libmpv with no render API; it has
      // to survive the trip or the user is told nothing useful.
      mockPlatform(
        error: PlatformException(
          code: 'render-init',
          message: 'libmpv.dylib does not export mpv_render_context_create',
        ),
      );

      await expectLater(
        VideoOutput.create(mpvHandle: 1, libraryPath: 'libmpv.dylib'),
        throwsA(isA<VideoOutputException>()
            .having((e) => e.code, 'code', 'render-init')
            .having((e) => e.message, 'message', contains('render_context'))),
      );
    });

    test('rounds the surface size to whole pixels', () async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );
      calls.clear();

      await output.setSurfaceSize(const Size(800.6, 449.2));

      expect(calls.single.arguments, {
        'textureId': 7,
        'width': 801,
        'height': 449,
      });
    });

    test('never asks for a zero-sized surface', () async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );
      calls.clear();

      // A widget can be laid out at zero height for a frame; a framebuffer of
      // that size is not something to hand to a GL driver.
      await output.setSurfaceSize(Size.zero);

      expect(calls.single.arguments, {'textureId': 7, 'width': 1, 'height': 1});
    });

    test('disposes once, however many times it is asked', () async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );
      calls.clear();

      await output.dispose();
      await output.dispose();

      // Freeing the render context twice would be a double free of the GL
      // objects mpv allocated, so this is not merely tidiness.
      expect(calls.map((c) => c.method), ['dispose']);
    });

    test('stops sizing a surface it has already released', () async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );
      await output.dispose();
      calls.clear();

      // The widget can be laid out one more time after the controller has torn
      // the output down.
      await output.setSurfaceSize(const Size(100, 100));

      expect(calls, isEmpty);
    });

    test('a failure to tear down does not become the caller\'s problem',
        () async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );
      mockPlatform(error: PlatformException(code: 'boom'));

      // dispose() runs inside other teardown; throwing here would mask
      // whatever the caller was actually disposing.
      await expectLater(output.dispose(), completes);
    });
  });

  group('VideoSurface', () {
    testWidgets('renders the output\'s texture', (tester) async {
      mockPlatform(textureId: 11);
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: VideoSurface(output: output),
        ),
      );

      expect(
        tester.widget<Texture>(find.byType(Texture)).textureId,
        11,
      );
    });

    testWidgets('asks for a surface in physical pixels, not logical ones',
        (tester) async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );
      calls.clear();

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 400,
                height: 225,
                child: VideoSurface(output: output),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Rendering at logical size on a Retina display would show a picture at
      // half the resolution the screen can actually draw.
      expect(
        calls.single.arguments,
        {'textureId': 7, 'width': 800, 'height': 450},
      );
    });

    testWidgets('does not re-ask on a rebuild at the same size',
        (tester) async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );

      Widget build() => MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: SizedBox(
                  width: 320,
                  height: 180,
                  child: VideoSurface(output: output),
                ),
              ),
            ),
          );

      await tester.pumpWidget(build());
      await tester.pump();
      calls.clear();

      await tester.pumpWidget(build());
      await tester.pump();

      // Every size change reallocates two IOSurfaces on the platform side, so
      // a rebuild that changes nothing must cost nothing.
      expect(calls, isEmpty);
    });

    testWidgets('follows the box when it changes size', (tester) async {
      mockPlatform();
      final output = await VideoOutput.create(
        mpvHandle: 1,
        libraryPath: 'libmpv.dylib',
      );

      Widget build(double width) => MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: SizedBox(
                  width: width,
                  height: 180,
                  child: VideoSurface(output: output),
                ),
              ),
            ),
          );

      await tester.pumpWidget(build(320));
      await tester.pump();
      calls.clear();

      await tester.pumpWidget(build(640));
      await tester.pump();

      expect(
        calls.single.arguments,
        {'textureId': 7, 'width': 640, 'height': 180},
      );
    });
  });
}
