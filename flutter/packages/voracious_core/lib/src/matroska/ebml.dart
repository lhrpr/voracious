/// Just enough EBML to walk a Matroska file without reading all of it.
///
/// Matroska is a tree of elements, each an ID, a size and a payload. Reading
/// subtitles out of a two-hour film means visiting every block header to find
/// the few belonging to a subtitle track, while skipping the video and audio
/// payloads between them. So the reader works on byte offsets over a
/// random-access [ByteSource] rather than on a stream, and only ever reads
/// headers plus the payloads it actually wants.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Random access to the bytes of a file.
///
/// Synchronous on purpose: extraction makes hundreds of thousands of small
/// reads, and a host runs the whole walk on a background isolate where a
/// blocking read is both simpler and much faster than an awaited one.
abstract interface class ByteSource {
  /// Total length in bytes.
  int get length;

  /// Up to [count] bytes starting at [offset]; fewer only at the end of the
  /// source.
  Uint8List read(int offset, int count);
}

/// A [ByteSource] over bytes already in memory. For tests and small files.
class MemoryByteSource implements ByteSource {
  MemoryByteSource(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    if (offset >= bytes.length) return Uint8List(0);
    final end = offset + count > bytes.length ? bytes.length : offset + count;
    return Uint8List.sublistView(bytes, offset, end);
  }
}

/// Reads through a [ByteSource] with a small window cache, so the many short
/// reads of neighbouring headers (audio blocks are a few hundred bytes apart)
/// don't each hit the file.
class EbmlReader {
  EbmlReader(this.source);

  final ByteSource source;

  static const _windowSize = 64 * 1024;

  Uint8List _window = Uint8List(0);
  int _windowStart = 0;

  int get length => source.length;

  /// [count] bytes at [offset], or fewer at the end of the source.
  Uint8List bytesAt(int offset, int count) {
    final inWindow = offset >= _windowStart &&
        offset + count <= _windowStart + _window.length;
    if (!inWindow) {
      if (count > _windowSize) return source.read(offset, count);
      _window = source.read(offset, _windowSize);
      _windowStart = offset;
    }
    final start = offset - _windowStart;
    final end = start + count > _window.length ? _window.length : start + count;
    return Uint8List.sublistView(_window, start, end);
  }

  /// The element header at [offset], or null at the end of the source.
  EbmlHeader? headerAt(int offset) {
    if (offset >= length) return null;
    final bytes = bytesAt(offset, 12);
    if (bytes.isEmpty) return null;

    final idLength = vintLength(bytes[0]);
    if (idLength > 4 || idLength > bytes.length) {
      throw FormatException('bad element ID at offset $offset');
    }
    var id = 0;
    for (var i = 0; i < idLength; i++) {
      id = (id << 8) | bytes[i];
    }

    if (idLength >= bytes.length) {
      throw FormatException('truncated element header at offset $offset');
    }
    final sizeLength = vintLength(bytes[idLength]);
    if (sizeLength > 8 || idLength + sizeLength > bytes.length) {
      throw FormatException('bad element size at offset $offset');
    }
    var size = bytes[idLength] & (0xFF >> sizeLength);
    var allOnes = size == (0xFF >> sizeLength);
    for (var i = 1; i < sizeLength; i++) {
      final b = bytes[idLength + i];
      size = (size << 8) | b;
      if (b != 0xFF) allOnes = false;
    }

    return EbmlHeader(
      id: id,
      offset: offset,
      dataOffset: offset + idLength + sizeLength,
      size: allOnes ? null : size,
    );
  }

  /// The payload of an element, read whole.
  Uint8List payload(EbmlHeader header) =>
      bytesAt(header.dataOffset, header.size ?? 0);

  int readUint(EbmlHeader header) => decodeUint(payload(header));

  double readFloat(EbmlHeader header) {
    final data = payload(header);
    final view = ByteData.sublistView(data);
    return switch (data.length) {
      4 => view.getFloat32(0),
      8 => view.getFloat64(0),
      _ => 0,
    };
  }

  String readString(EbmlHeader header) {
    final data = payload(header);
    // Strings may be zero-padded.
    var end = data.length;
    while (end > 0 && data[end - 1] == 0) {
      end--;
    }
    return _decodeUtf8(Uint8List.sublistView(data, 0, end));
  }

  /// The direct children of [parent], read lazily.
  Iterable<EbmlHeader> children(EbmlHeader parent) sync* {
    final end = parent.size == null ? length : parent.dataOffset + parent.size!;
    var offset = parent.dataOffset;
    while (offset < end) {
      final child = headerAt(offset);
      if (child == null) return;
      yield child;
      if (child.size == null) return; // Unknown size: can't skip past it.
      offset = child.end;
    }
  }
}

/// One element's ID, position and payload size.
class EbmlHeader {
  const EbmlHeader({
    required this.id,
    required this.offset,
    required this.dataOffset,
    required this.size,
  });

  final int id;

  /// Where the element (its ID) starts.
  final int offset;

  /// Where its payload starts.
  final int dataOffset;

  /// Payload length, or null when the file declares it unknown (live
  /// recordings write clusters this way).
  final int? size;

  /// Offset just past the element. Only meaningful when [size] is known.
  int get end => dataOffset + (size ?? 0);
}

/// Length in bytes of a variable-length integer, from its first byte: one plus
/// the number of leading zero bits.
int vintLength(int firstByte) {
  for (var i = 0; i < 8; i++) {
    if (firstByte & (0x80 >> i) != 0) return i + 1;
  }
  return 9; // Invalid: no marker bit in the first byte.
}

/// Reads a size-style vint (marker bit removed) from the start of [bytes].
/// Returns the value and how many bytes it took.
(int value, int length) readVint(Uint8List bytes, [int start = 0]) {
  if (start >= bytes.length) throw const FormatException('truncated vint');
  final length = vintLength(bytes[start]);
  if (length > 8 || start + length > bytes.length) {
    throw const FormatException('bad vint');
  }
  var value = bytes[start] & (0xFF >> length);
  for (var i = 1; i < length; i++) {
    value = (value << 8) | bytes[start + i];
  }
  return (value, length);
}

int decodeUint(Uint8List bytes) {
  var value = 0;
  for (final b in bytes) {
    value = (value << 8) | b;
  }
  return value;
}

/// UTF-8 decoding that tolerates bad bytes, so one broken character doesn't
/// fail a whole track.
String _decodeUtf8(Uint8List bytes) =>
    const Utf8Decoder(allowMalformed: true).convert(bytes);

/// Re-exported so callers can decode block payloads the same way.
String decodeUtf8Lenient(Uint8List bytes) => _decodeUtf8(bytes);
