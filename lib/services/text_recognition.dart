import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/timetable_ocr.dart';

/// Reads text out of a timetable image, on the device.
///
/// The ML Kit types stop here, the way the SAF types stop at [BackupFolder], so
/// the grid inference downstream stays plain Dart and the engine replaceable.
class TextRecognition {
  static OcrBox _boxOf(ui.Rect box) =>
      OcrBox(box.left, box.top, box.right, box.bottom);

  /// Enlarges a small screenshot before the recogniser sees it.
  ///
  /// A phone screenshot of a fifteen-row table arrives about 650px wide, which
  /// leaves the text around eight pixels tall: ML Kit read seven of the rows
  /// and misread one of those. The same image scaled up read twelve with every
  /// figure right. Nothing is added by the scaling — it just stops the
  /// recogniser working below the size it needs.
  static Future<Uint8List> _enlargeIfSmall(Uint8List bytes) async {
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } finally {
      buffer.dispose();
    }
    final int width = descriptor.width;
    final int height = descriptor.height;
    descriptor.dispose();
    if (width <= 0 || width >= _readableWidth) return bytes;

    final double scale = math.min(
      _readableWidth / width,
      _widestUpscale / width,
    );
    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: (width * scale).round(),
      targetHeight: (height * scale).round(),
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    try {
      final ByteData? png =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return png == null ? bytes : png.buffer.asUint8List();
    } finally {
      frame.image.dispose();
      codec.dispose();
    }
  }

  /// Below this the recogniser starts dropping whole lines of a dense table.
  static const int _readableWidth = 1800;

  /// And above this the upscale costs more memory than it buys accuracy.
  static const int _widestUpscale = 2600;

  /// Recognised lines, in no particular order — position comes from the boxes.
  ///
  /// Takes bytes because a file from Android's document picker is a
  /// `content://` URI with no filesystem path, and ML Kit will only read a
  /// real file.
  static Future<List<OcrLine>> readImage(Uint8List bytes) async {
    final Directory dir = await getTemporaryDirectory();
    final File file = File(p.join(dir.path, 'ocr_input'));
    await file.writeAsBytes(await _enlargeIfSmall(bytes), flush: true);

    final TextRecognizer recognizer = TextRecognizer();
    try {
      final RecognizedText result =
          await recognizer.processImage(InputImage.fromFilePath(file.path));
      return <OcrLine>[
        for (final TextBlock block in result.blocks)
          for (final TextLine line in block.lines)
            OcrLine(line.text, _boxOf(line.boundingBox)),
      ];
    } finally {
      await recognizer.close();
      // Best effort: a leftover temp file is harmless and the next read
      // overwrites it anyway, so a failure here must not lose the result.
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
