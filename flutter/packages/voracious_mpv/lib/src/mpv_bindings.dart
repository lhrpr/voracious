/// Raw FFI declarations for the libmpv client API.
///
/// Only the subset the player uses is declared. The library is opened with
/// `DynamicLibrary.open` rather than statically linked, which is not an
/// implementation detail: dynamic linking is the condition under which an
/// LGPL-licensed libmpv can be used by a proprietary application, because the
/// user remains able to replace it.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Opaque `mpv_handle*`.
typedef MpvHandle = Pointer<Void>;

/// `mpv_event_id`.
abstract final class MpvEventId {
  static const int none = 0;
  static const int shutdown = 1;
  static const int logMessage = 2;
  static const int getPropertyReply = 3;
  static const int setPropertyReply = 4;
  static const int commandReply = 5;
  static const int startFile = 6;
  static const int endFile = 7;
  static const int fileLoaded = 8;
  static const int clientMessage = 16;
  static const int videoReconfig = 17;
  static const int audioReconfig = 18;
  static const int seek = 20;
  static const int playbackRestart = 21;
  static const int propertyChange = 22;
  static const int queueOverflow = 24;
  static const int hook = 25;
}

/// `mpv_format`.
abstract final class MpvFormat {
  static const int none = 0;
  static const int string = 1;
  static const int osdString = 2;
  static const int flag = 3;
  static const int int64 = 4;
  static const int double_ = 5;
  static const int node = 6;
  static const int nodeArray = 7;
  static const int nodeMap = 8;
  static const int byteArray = 9;
}

/// `mpv_end_file_reason`.
abstract final class MpvEndFileReasonCode {
  static const int eof = 0;
  static const int stop = 2;
  static const int quit = 3;
  static const int error = 4;
  static const int redirect = 5;
}

/// `mpv_event`.
final class MpvEventStruct extends Struct {
  @Int32()
  external int eventId;

  @Int32()
  external int error;

  @Uint64()
  external int replyUserdata;

  external Pointer<Void> data;
}

/// `mpv_event_property`.
final class MpvEventPropertyStruct extends Struct {
  external Pointer<Utf8> name;

  @Int32()
  external int format;

  external Pointer<Void> data;
}

/// `mpv_event_end_file`.
final class MpvEventEndFileStruct extends Struct {
  @Int32()
  external int reason;

  @Int32()
  external int error;

  @Int64()
  external int playlistEntryId;
}

/// `mpv_event_log_message`.
final class MpvEventLogMessageStruct extends Struct {
  external Pointer<Utf8> prefix;
  external Pointer<Utf8> level;
  external Pointer<Utf8> text;

  @Int32()
  external int logLevel;
}

// C signatures.
typedef _MpvCreateNative = MpvHandle Function();
typedef _MpvInitializeNative = Int32 Function(MpvHandle);
typedef _MpvInitializeDart = int Function(MpvHandle);
typedef _MpvTerminateDestroyNative = Void Function(MpvHandle);
typedef _MpvTerminateDestroyDart = void Function(MpvHandle);
typedef _MpvSetOptionStringNative = Int32 Function(
    MpvHandle, Pointer<Utf8>, Pointer<Utf8>);
typedef _MpvSetOptionStringDart = int Function(
    MpvHandle, Pointer<Utf8>, Pointer<Utf8>);
typedef _MpvCommandNative = Int32 Function(MpvHandle, Pointer<Pointer<Utf8>>);
typedef _MpvCommandDart = int Function(MpvHandle, Pointer<Pointer<Utf8>>);
typedef _MpvSetPropertyStringNative = Int32 Function(
    MpvHandle, Pointer<Utf8>, Pointer<Utf8>);
typedef _MpvSetPropertyStringDart = int Function(
    MpvHandle, Pointer<Utf8>, Pointer<Utf8>);
typedef _MpvGetPropertyStringNative = Pointer<Utf8> Function(
    MpvHandle, Pointer<Utf8>);
typedef _MpvFreeNative = Void Function(Pointer<Void>);
typedef _MpvFreeDart = void Function(Pointer<Void>);
typedef _MpvObservePropertyNative = Int32 Function(
    MpvHandle, Uint64, Pointer<Utf8>, Int32);
typedef _MpvObservePropertyDart = int Function(
    MpvHandle, int, Pointer<Utf8>, int);
typedef _MpvWaitEventNative = Pointer<MpvEventStruct> Function(
    MpvHandle, Double);
typedef _MpvWaitEventDart = Pointer<MpvEventStruct> Function(MpvHandle, double);
typedef _MpvWakeupNative = Void Function(MpvHandle);
typedef _MpvWakeupDart = void Function(MpvHandle);
typedef _MpvErrorStringNative = Pointer<Utf8> Function(Int32);
typedef _MpvErrorStringDart = Pointer<Utf8> Function(int);
typedef _MpvRequestLogMessagesNative = Int32 Function(MpvHandle, Pointer<Utf8>);
typedef _MpvRequestLogMessagesDart = int Function(MpvHandle, Pointer<Utf8>);
typedef _MpvClientApiVersionNative = Uint64 Function();
typedef _MpvClientApiVersionDart = int Function();

/// Resolved entry points of a loaded libmpv.
class MpvBindings {
  MpvBindings(this.library)
      : create = library
            .lookupFunction<_MpvCreateNative, _MpvCreateNative>('mpv_create'),
        initialize =
            library.lookupFunction<_MpvInitializeNative, _MpvInitializeDart>(
                'mpv_initialize'),
        terminateDestroy = library.lookupFunction<_MpvTerminateDestroyNative,
            _MpvTerminateDestroyDart>('mpv_terminate_destroy'),
        setOptionString = library.lookupFunction<_MpvSetOptionStringNative,
            _MpvSetOptionStringDart>('mpv_set_option_string'),
        command = library
            .lookupFunction<_MpvCommandNative, _MpvCommandDart>('mpv_command'),
        setPropertyString = library.lookupFunction<_MpvSetPropertyStringNative,
            _MpvSetPropertyStringDart>('mpv_set_property_string'),
        getPropertyString = library.lookupFunction<_MpvGetPropertyStringNative,
            _MpvGetPropertyStringNative>('mpv_get_property_string'),
        free = library.lookupFunction<_MpvFreeNative, _MpvFreeDart>('mpv_free'),
        observeProperty = library.lookupFunction<_MpvObservePropertyNative,
            _MpvObservePropertyDart>('mpv_observe_property'),
        waitEvent =
            library.lookupFunction<_MpvWaitEventNative, _MpvWaitEventDart>(
                'mpv_wait_event'),
        wakeup = library
            .lookupFunction<_MpvWakeupNative, _MpvWakeupDart>('mpv_wakeup'),
        errorString =
            library.lookupFunction<_MpvErrorStringNative, _MpvErrorStringDart>(
                'mpv_error_string'),
        requestLogMessages = library.lookupFunction<
            _MpvRequestLogMessagesNative,
            _MpvRequestLogMessagesDart>('mpv_request_log_messages'),
        clientApiVersion = library.lookupFunction<_MpvClientApiVersionNative,
            _MpvClientApiVersionDart>('mpv_client_api_version');

  final DynamicLibrary library;

  final MpvHandle Function() create;
  final int Function(MpvHandle) initialize;
  final void Function(MpvHandle) terminateDestroy;
  final int Function(MpvHandle, Pointer<Utf8>, Pointer<Utf8>) setOptionString;
  final int Function(MpvHandle, Pointer<Pointer<Utf8>>) command;
  final int Function(MpvHandle, Pointer<Utf8>, Pointer<Utf8>) setPropertyString;
  final Pointer<Utf8> Function(MpvHandle, Pointer<Utf8>) getPropertyString;
  final void Function(Pointer<Void>) free;
  final int Function(MpvHandle, int, Pointer<Utf8>, int) observeProperty;
  final Pointer<MpvEventStruct> Function(MpvHandle, double) waitEvent;
  final void Function(MpvHandle) wakeup;
  final Pointer<Utf8> Function(int) errorString;
  final int Function(MpvHandle, Pointer<Utf8>) requestLogMessages;
  final int Function() clientApiVersion;

  /// Reads a string property and copies it into Dart, freeing the C string.
  ///
  /// Returns null when the property is unset or unavailable — which mpv
  /// reports by returning NULL, not by an error code.
  String? readStringProperty(MpvHandle handle, String name) {
    final namePointer = name.toNativeUtf8();
    try {
      final result = getPropertyString(handle, namePointer);
      if (result == nullptr) return null;
      try {
        return result.toDartString();
      } finally {
        free(result.cast<Void>());
      }
    } finally {
      calloc.free(namePointer);
    }
  }

  /// Human-readable form of an mpv error code.
  String describeError(int code) {
    final pointer = errorString(code);
    return pointer == nullptr ? 'error $code' : pointer.toDartString();
  }
}
