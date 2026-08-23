import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/timetable_ocr.dart';

/// Reads text out of a timetable image, on the device.
///
/// The ML Kit types stop here, the way the SAF types stop at [BackupFolder], so
/// the grid inference downstream stays plain Dart and the engine replaceable.
class TextRecognition {
  /// Recognised lines, in no particular order — position comes from the boxes.
  ///
  /// Takes bytes because a file from Android's document picker is a `content://`
  /// URI with no filesystem path, and ML Kit will only read a real file.
  static Future<List<OcrLine>> readImage(Uint8List bytes) async {
    final Directory dir = await getTemporaryDirectory();
    final File file = File(p.join(dir.path, 'ocr_input'));
    await file.writeAsBytes(bytes, flush: true);

    final TextRecognizer recognizer = TextRecognizer();
    try {
      final RecognizedText result =
          await recognizer.processImage(InputImage.fromFilePath(file.path));
      return <OcrLine>[
        for (final TextBlock block in result.blocks)
          for (final TextLine line in block.lines)
            OcrLine(
              line.text,
              OcrBox(
                line.boundingBox.left,
                line.boundingBox.top,
                line.boundingBox.right,
                line.boundingBox.bottom,
              ),
            ),
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
