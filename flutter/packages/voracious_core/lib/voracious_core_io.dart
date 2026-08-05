/// `dart:io`-backed implementations of the core interfaces.
///
/// Kept out of `voracious_core.dart` so that the core library itself stays
/// free of platform imports and can be used anywhere Dart runs — including
/// contexts where `dart:io` is unavailable.
library;

export 'src/io/io_anki_transport.dart';
export 'src/io/local_file_system.dart';
