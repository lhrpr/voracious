/// Tests for the parts of the binding layer that do not need libmpv present.
///
/// Anything that actually calls into the library needs a real build on the
/// machine, so those live in the integration suite that runs on a device.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:voracious_core/voracious_core.dart';
import 'package:voracious_mpv/voracious_mpv.dart';

void main() {
  group('library discovery', () {
    test('offers candidates for the host platform', () {
      final candidates = MpvLibrary.defaultCandidates();
      expect(candidates, isNotEmpty);

      if (Platform.isLinux) {
        expect(candidates, contains('libmpv.so.2'));
      } else if (Platform.isMacOS) {
        expect(candidates.any((c) => c.endsWith('.dylib')), isTrue);
      } else if (Platform.isWindows) {
        expect(candidates.any((c) => c.endsWith('.dll')), isTrue);
      }
    });

    test('a failed load names everything it tried', () {
      const exception = MpvLibraryNotFoundException({
        'libmpv.so.2': 'cannot open shared object file',
        'libmpv.so': 'cannot open shared object file',
      });

      final message = exception.toString();
      expect(message, contains('libmpv.so.2'));
      expect(message, contains('cannot open shared object file'));
    });

    test('an explicit path that cannot be loaded is not silently replaced', () {
      // Deterministic whether or not this machine has a libmpv: an explicit
      // path is authoritative, so a bad one throws rather than falling back to
      // whatever the system happens to provide.
      expect(
        () => MpvLibrary.open(explicitPath: '/nonexistent/libnothing.so'),
        throwsA(isA<MpvLibraryNotFoundException>()),
      );
    });
  });

  group('property observation', () {
    test('observes every property the state machine consumes', () {
      // A property the state machine handles but the pump never observes would
      // simply never arrive, and the resulting state would be silently stale.
      for (final property in MpvProperty.observed) {
        expect(
          observedProperties.containsKey(property),
          isTrue,
          reason: '$property is in MpvProperty.observed but is not observed '
              'by the event pump',
        );
      }
    });

    test('track-list is observed formatless and fetched as JSON', () {
      // Decoding an mpv node through FFI is a lot of work for a value
      // mpv_get_property_string hands over as JSON.
      expect(observedProperties[MpvProperty.trackList], MpvFormat.none);
    });

    test('flags, numbers and strings use their natural formats', () {
      expect(observedProperties[MpvProperty.pause], MpvFormat.flag);
      expect(observedProperties[MpvProperty.timePos], MpvFormat.double_);
      expect(observedProperties[MpvProperty.width], MpvFormat.int64);
      expect(observedProperties[MpvProperty.path], MpvFormat.string);
    });

    test('track ids are observed as strings, since mpv reports "no"', () {
      expect(observedProperties[MpvProperty.audioId], MpvFormat.string);
      expect(observedProperties[MpvProperty.subtitleId], MpvFormat.string);
    });
  });

  group('constants', () {
    test('event ids match the client API', () {
      expect(MpvEventId.shutdown, 1);
      expect(MpvEventId.startFile, 6);
      expect(MpvEventId.endFile, 7);
      expect(MpvEventId.fileLoaded, 8);
      expect(MpvEventId.seek, 20);
      expect(MpvEventId.playbackRestart, 21);
      expect(MpvEventId.propertyChange, 22);
    });

    test('end-file reasons match the client API', () {
      expect(MpvEndFileReasonCode.eof, 0);
      expect(MpvEndFileReasonCode.stop, 2);
      expect(MpvEndFileReasonCode.quit, 3);
      expect(MpvEndFileReasonCode.error, 4);
    });

    test('formats match the client API', () {
      expect(MpvFormat.none, 0);
      expect(MpvFormat.string, 1);
      expect(MpvFormat.flag, 3);
      expect(MpvFormat.int64, 4);
      expect(MpvFormat.double_, 5);
      expect(MpvFormat.node, 6);
    });
  });
}
