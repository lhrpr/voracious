/// Finding and opening libmpv at runtime.
///
/// The library is loaded dynamically on every platform. That is a licensing
/// requirement rather than a convenience: an LGPL library used by a
/// proprietary application must remain replaceable by the user, which static
/// linking would defeat. It also means the exact binary being loaded is
/// identifiable at runtime, which is what [MpvLibrary.describe] is for — the
/// about screen has to be able to state which libmpv the user is running.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'mpv_bindings.dart';

/// Where a loaded libmpv came from.
class MpvLibrary {
  MpvLibrary._(this.path, this.bindings);

  /// The file the library was actually loaded from.
  ///
  /// Resolved from the loaded image rather than echoing back the candidate
  /// that worked, and both readers of it need that. The about screen has to
  /// name the exact library the user is running, and `@rpath/libmpv.dylib` —
  /// which is the candidate that succeeds inside an app bundle — names
  /// nothing. The video output has to hand the path to native code, and an
  /// `@rpath` is resolved against the *loading* image, so a path that opened
  /// here can fail to open two frames later from a different one. Only when
  /// the real path cannot be determined does this fall back to the candidate.
  final String path;

  final MpvBindings bindings;

  /// libmpv client API version, as `major.minor`.
  String get clientApiVersion {
    final raw = bindings.clientApiVersion();
    return '${(raw >> 16) & 0xFFFF}.${raw & 0xFFFF}';
  }

  String describe() => 'libmpv $clientApiVersion ($path)';

  /// Opens libmpv.
  ///
  /// [explicitPath] is authoritative: if it is given and cannot be loaded, this
  /// throws rather than searching the system. A shipped build passes the
  /// libmpv it bundles, and falling back would load whichever libmpv the
  /// machine happens to have — very possibly a default (GPL) build, which is
  /// the outcome the whole dynamic-linking arrangement exists to avoid. It also
  /// turns a broken bundle path into a silent per-machine behaviour difference
  /// instead of an error. Only when no path is given is the platform's
  /// conventional list searched.
  ///
  /// Throws [MpvLibraryNotFoundException] listing everything that was tried,
  /// because "failed to load" on a user's machine is otherwise unactionable.
  static MpvLibrary open({String? explicitPath}) {
    final candidates =
        explicitPath != null ? [explicitPath] : defaultCandidates();

    final failures = <String, String>{};
    for (final candidate in candidates) {
      try {
        final library = candidate == _processCandidate
            ? DynamicLibrary.process()
            : DynamicLibrary.open(candidate);
        final bindings = MpvBindings(library);
        return MpvLibrary._(
          resolveLoadedPath(library) ?? candidate,
          bindings,
        );
      } on Object catch (error) {
        failures[candidate] = error.toString();
      }
    }

    throw MpvLibraryNotFoundException(failures);
  }

  /// Marker meaning "already linked into the process", which is how an iOS or
  /// tvOS build sees an embedded framework.
  static const String _processCandidate = '<process>';

  /// Library names to try, in order, for the current platform.
  static List<String> defaultCandidates() {
    if (Platform.isWindows) {
      // mpv's Windows builds ship the DLL under two names depending on vintage.
      return ['libmpv-2.dll', 'mpv-2.dll', 'libmpv.dll', 'mpv-1.dll'];
    }
    if (Platform.isMacOS) {
      return [
        // Bundled inside the .app, which is where a shipped build finds it.
        '@rpath/libmpv.dylib',
        'libmpv.2.dylib',
        'libmpv.dylib',
        '/opt/homebrew/lib/libmpv.dylib',
        '/usr/local/lib/libmpv.dylib',
      ];
    }
    if (Platform.isIOS) {
      // An embedded dynamic framework is already in the process image.
      return [_processCandidate, '@rpath/mpv.framework/mpv'];
    }
    if (Platform.isAndroid) {
      return ['libmpv.so', 'libplayer.so'];
    }
    return ['libmpv.so.2', 'libmpv.so.1', 'libmpv.so'];
  }
}

/// `Dl_info`, filled in by `dladdr`.
final class _DlInfo extends Struct {
  external Pointer<Utf8> fileName;
  external Pointer<Void> baseAddress;
  external Pointer<Utf8> symbolName;
  external Pointer<Void> symbolAddress;
}

typedef _DladdrNative = Int32 Function(Pointer<Void>, Pointer<_DlInfo>);
typedef _DladdrDart = int Function(Pointer<Void>, Pointer<_DlInfo>);

/// The file [library] was loaded from, or null if it cannot be determined.
///
/// Works by asking the dynamic loader where one of the library's own symbols
/// lives, which is the only way to get an answer that is a real path rather
/// than a repeat of the request. `@rpath/libmpv.dylib`, `libmpv.so.2` and
/// `libmpv.dylib` all load successfully and none of them is a file the user
/// could go and look at.
///
/// Returns null on Windows, which has no `dladdr`, and on any platform where
/// the lookup fails. Callers fall back to the candidate name.
String? resolveLoadedPath(DynamicLibrary library) {
  try {
    // Any symbol the library exports will do; this one is in every libmpv
    // that has ever shipped a client API.
    final symbol = library.lookup<Void>('mpv_client_api_version');
    final dladdr = DynamicLibrary.process()
        .lookupFunction<_DladdrNative, _DladdrDart>('dladdr');

    final info = calloc<_DlInfo>();
    try {
      if (dladdr(symbol.cast<Void>(), info) == 0) return null;
      final name = info.ref.fileName;
      return name == nullptr ? null : name.toDartString();
    } finally {
      calloc.free(info);
    }
  } on Object {
    // No dladdr, no such symbol, or a loader that will not say. The candidate
    // name is a worse answer but not a wrong one.
    return null;
  }
}

/// Thrown when no libmpv could be loaded.
class MpvLibraryNotFoundException implements Exception {
  const MpvLibraryNotFoundException(this.attempts);

  /// Candidate path to the error it produced.
  final Map<String, String> attempts;

  @override
  String toString() {
    final buffer = StringBuffer('MpvLibraryNotFoundException: could not load '
        'libmpv. Tried:');
    attempts.forEach((path, error) => buffer.write('\n  $path: $error'));
    return buffer.toString();
  }
}
