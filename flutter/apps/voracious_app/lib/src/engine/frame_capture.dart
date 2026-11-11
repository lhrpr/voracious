/// The paused video frame, sized for a flashcard.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Widest picture sent to the vocab server. A card shows it at a few hundred
/// pixels, and a 4K frame at full size would be several megabytes per word
/// in a collection that syncs to every device.
const int maxPictureWidth = 1280;

/// The server refuses pictures over 5 MB; stay well clear of it.
const int maxPictureBytes = 4 * 1024 * 1024;

/// Scales [jpeg] down to [maxPictureWidth] and re-encodes it at a card's
/// quality, off the UI isolate. Returns null when the bytes can't be decoded
/// or the result is still too large.
Future<Uint8List?> shrinkFrame(Uint8List jpeg) => Isolate.run(() {
      final decoded = img.decodeImage(jpeg);
      if (decoded == null) return null;
      final scaled = decoded.width > maxPictureWidth
          ? img.copyResize(decoded,
              width: maxPictureWidth, interpolation: img.Interpolation.average)
          : decoded;
      final out = img.encodeJpg(scaled, quality: 85);
      return out.length > maxPictureBytes ? null : out;
    });
