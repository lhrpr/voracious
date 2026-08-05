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

import 'mpv_bindings.dart';

/// Where a loaded libmpv came from.
class MpvLibrary {
  MpvLibrary._(this.path, this.bindings);

  /// The name or path passed to `DynamicLibrary.open`.
  final String path;

  final MpvBindings bindings;

  /// libmpv client API version, as `major.minor`.
  String get clientApiVersion {
    final raw = bindings.clientApiVersion();
    return '${(raw >> 16) & 0xFFFF}.${raw & 0xFFFF}';
  }

  String describe() => 'libmpv $clientApiVersion ($path)';

  /// Opens libmpv, trying [explicitPath] first and then the platform's
  /// conventional names.
  ///
  /// Throws [MpvLibraryNotFoundException] listing everything that was tried,
  /// because "failed to load" on a user's machine is otherwise unactionable.
  static MpvLibrary open({String? explicitPath}) {
    final candidates = [
      if (explicitPath != null) explicitPath,
      ...defaultCandidates(),
    ];

    final failures = <String, String>{};
    for (final candidate in candidates) {
      try {
        final library = candidate == _processCandidate
            ? DynamicLibrary.process()
            : DynamicLibrary.open(candidate);
        return MpvLibrary._(candidate, MpvBindings(library));
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
