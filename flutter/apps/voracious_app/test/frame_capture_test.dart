import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voracious_app/src/engine/frame_capture.dart';

void main() {
  test('a 4K frame comes back as a 1280-wide JPEG', () async {
    final frame = img.encodeJpg(img.Image(width: 3840, height: 2160));
    final shrunk = await shrinkFrame(frame);
    final decoded = img.decodeJpg(shrunk!)!;
    expect((decoded.width, decoded.height), (1280, 720));
  });

  test('a small frame keeps its size, and junk is refused', () async {
    final frame = img.encodeJpg(img.Image(width: 640, height: 360));
    expect(img.decodeJpg((await shrinkFrame(frame))!)!.width, 640);
    expect(await shrinkFrame(frame.sublist(0, 10)), isNull);
  });
}
