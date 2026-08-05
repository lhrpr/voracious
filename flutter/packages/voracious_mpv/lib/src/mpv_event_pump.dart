/// Runs libmpv's event loop on its own isolate.
///
/// `mpv_wait_event` blocks, and it must be called from exactly one thread for
/// the life of the handle. Calling it on the Dart main isolate would stall the
/// UI between events, so the loop runs in a background isolate and posts
/// decoded events back. The mpv handle is shared as a raw address, which is
/// safe because libmpv's client API is thread-safe and the handle outlives the
/// isolate.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:voracious_core/voracious_core.dart';

import 'mpv_bindings.dart';
import 'mpv_library.dart';

/// Property names paired with the mpv format to observe them in.
///
/// `track-list` is observed as [MpvFormat.none] deliberately: it is a node,
/// and decoding an mpv node through FFI is a great deal of work for a value
/// that `mpv_get_property_string` will hand over as JSON.
const Map<String, int> observedProperties = {
  MpvProperty.pause: MpvFormat.flag,
  MpvProperty.pausedForCache: MpvFormat.flag,
  MpvProperty.eofReached: MpvFormat.flag,
  MpvProperty.seeking: MpvFormat.flag,
  MpvProperty.idleActive: MpvFormat.flag,
  MpvProperty.mute: MpvFormat.flag,
  MpvProperty.timePos: MpvFormat.double_,
  MpvProperty.duration: MpvFormat.double_,
  MpvProperty.speed: MpvFormat.double_,
  MpvProperty.volume: MpvFormat.double_,
  MpvProperty.subDelay: MpvFormat.double_,
  MpvProperty.audioDelay: MpvFormat.double_,
  MpvProperty.width: MpvFormat.int64,
  MpvProperty.height: MpvFormat.int64,
  MpvProperty.path: MpvFormat.string,
  MpvProperty.hwdecCurrent: MpvFormat.string,
  MpvProperty.audioId: MpvFormat.string,
  MpvProperty.subtitleId: MpvFormat.string,
  MpvProperty.trackList: MpvFormat.none,
};

/// Message keys used between the pump isolate and the player. Kept as
/// constants so a typo is a compile error rather than a silently ignored
/// event.
abstract final class _Key {
  static const String kind = 'kind';
  static const String name = 'name';
  static const String value = 'value';
  static const String reason = 'reason';
  static const String error = 'error';
  static const String text = 'text';
}

/// Starts the event loop and streams decoded events.
class MpvEventPump {
  MpvEventPump._(this._isolate, this._receivePort, this.events);

  final Isolate _isolate;
  final ReceivePort _receivePort;

  /// Decoded engine events, in order.
  final Stream<MpvEvent> events;

  /// Spawns the loop for [handle], loading libmpv from [libraryPath] inside
  /// the new isolate.
  static Future<MpvEventPump> start({
    required int handleAddress,
    required String libraryPath,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _pumpEntryPoint,
      _PumpConfig(
        sendPort: receivePort.sendPort,
        handleAddress: handleAddress,
        libraryPath: libraryPath,
      ),
      debugName: 'mpv-event-pump',
    );

    final controller = StreamController<MpvEvent>.broadcast();
    receivePort.listen((Object? message) {
      if (message is! Map) return;
      final event = _decodeMessage(message.cast<String, Object?>());
      if (event != null) controller.add(event);
    });

    return MpvEventPump._(isolate, receivePort, controller.stream);
  }

  /// Stops the loop and releases the isolate.
  void stop() {
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  static MpvEvent? _decodeMessage(Map<String, Object?> message) {
    final kind = message[_Key.kind] as String?;
    return switch (kind) {
      'property' => MpvEvent.property(
          message[_Key.name]! as String,
          message[_Key.value],
        ),
      'start-file' => const MpvEvent(kind: MpvEventKind.startFile),
      'file-loaded' => const MpvEvent(kind: MpvEventKind.fileLoaded),
      'end-file' => MpvEvent(
          kind: MpvEventKind.endFile,
          endFileReason: _decodeEndFileReason(message[_Key.reason] as int?),
          errorCode: message[_Key.error] as int?,
          errorMessage: message[_Key.text] as String?,
        ),
      'seek' => const MpvEvent(kind: MpvEventKind.seek),
      'playback-restart' => const MpvEvent(kind: MpvEventKind.playbackRestart),
      'idle' => const MpvEvent(kind: MpvEventKind.idle),
      'shutdown' => const MpvEvent(kind: MpvEventKind.shutdown),
      _ => null,
    };
  }

  static MpvEndFileReason _decodeEndFileReason(int? code) => switch (code) {
        MpvEndFileReasonCode.eof => MpvEndFileReason.eof,
        MpvEndFileReasonCode.stop => MpvEndFileReason.stop,
        MpvEndFileReasonCode.quit => MpvEndFileReason.quit,
        MpvEndFileReasonCode.error => MpvEndFileReason.error,
        MpvEndFileReasonCode.redirect => MpvEndFileReason.redirect,
        _ => MpvEndFileReason.unknown,
      };
}

class _PumpConfig {
  const _PumpConfig({
    required this.sendPort,
    required this.handleAddress,
    required this.libraryPath,
  });

  final SendPort sendPort;
  final int handleAddress;
  final String libraryPath;
}

/// The isolate body: block on mpv, decode, post, repeat.
void _pumpEntryPoint(_PumpConfig config) {
  final library = MpvLibrary.open(explicitPath: config.libraryPath);
  final bindings = library.bindings;
  final handle = Pointer<Void>.fromAddress(config.handleAddress);

  while (true) {
    // A long timeout rather than an infinite one, so a handle that goes away
    // without a shutdown event does not wedge the isolate forever.
    final eventPointer = bindings.waitEvent(handle, 1);
    if (eventPointer == nullptr) continue;

    final event = eventPointer.ref;
    switch (event.eventId) {
      case MpvEventId.none:
        continue;

      case MpvEventId.shutdown:
        config.sendPort.send({_Key.kind: 'shutdown'});
        return;

      case MpvEventId.startFile:
        config.sendPort.send({_Key.kind: 'start-file'});

      case MpvEventId.fileLoaded:
        config.sendPort.send({_Key.kind: 'file-loaded'});

      case MpvEventId.endFile:
        final endFile = event.data.cast<MpvEventEndFileStruct>();
        final error = endFile == nullptr ? 0 : endFile.ref.error;
        config.sendPort.send({
          _Key.kind: 'end-file',
          _Key.reason: endFile == nullptr ? null : endFile.ref.reason,
          _Key.error: error,
          if (error != 0) _Key.text: bindings.describeError(error),
        });

      case MpvEventId.seek:
        config.sendPort.send({_Key.kind: 'seek'});

      case MpvEventId.playbackRestart:
        config.sendPort.send({_Key.kind: 'playback-restart'});

      case MpvEventId.propertyChange:
        final message = _decodeProperty(bindings, handle, event);
        if (message != null) config.sendPort.send(message);

      default:
        continue;
    }
  }
}

/// Reads the value out of a property-change event.
Map<String, Object?>? _decodeProperty(
  MpvBindings bindings,
  Pointer<Void> handle,
  MpvEventStruct event,
) {
  final propertyPointer = event.data.cast<MpvEventPropertyStruct>();
  if (propertyPointer == nullptr) return null;

  final property = propertyPointer.ref;
  if (property.name == nullptr) return null;
  final name = property.name.toDartString();

  // A null data pointer means the property became unavailable, which is
  // information in itself: `time-pos` goes null between files.
  final data = property.data;

  final Object? value;
  switch (property.format) {
    case MpvFormat.none:
      // Observed formatless (track-list); fetch the JSON now that we know it
      // changed.
      value = bindings.readStringProperty(handle, name);

    case MpvFormat.flag:
      value = data == nullptr ? null : data.cast<Int32>().value != 0;

    case MpvFormat.int64:
      value = data == nullptr ? null : data.cast<Int64>().value;

    case MpvFormat.double_:
      value = data == nullptr ? null : data.cast<Double>().value;

    case MpvFormat.string:
    case MpvFormat.osdString:
      if (data == nullptr) {
        value = null;
      } else {
        final stringPointer = data.cast<Pointer<Utf8>>().value;
        value = stringPointer == nullptr ? null : stringPointer.toDartString();
      }

    default:
      return null;
  }

  return {_Key.kind: 'property', _Key.name: name, _Key.value: value};
}
