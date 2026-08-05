/// Short unique identifiers for objects that need stable identity in memory
/// (cues, export jobs) without the cost of a UUID.
library;

import 'dart:math';

final Random _random = Random();
int _counter = 0;

/// Generates an identifier unique within this process.
///
/// A monotonic counter guarantees uniqueness; the random suffix keeps ids from
/// two runs of the app from colliding if one is ever persisted by accident.
String generateUid([String prefix = '']) {
  final count = (_counter++).toRadixString(36);
  final noise = _random.nextInt(1 << 32).toRadixString(36);
  return '$prefix$count-$noise';
}
