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
///
/// Every box handed back is in the coordinate space of the image as supplied,
/// whatever scaling happened on the way, so lines from two reads of the same
/// image can be compared.
class TextRecognition {
  /// The line height ML Kit wants before it starts dropping cells of a dense
  /// table altogether.
  static const double _readableLineHeight = 22;

  /// The widest an image is drawn before recognition. Beyond this the memory
  /// costs more than the accuracy buys — the same page read identically at
  /// 2600 and at 3400.
  static const int _widestUpscale = 2600;

  /// And a ceiling on the whole bitmap, since a tall narrow crop blown up to
  /// [_widestUpscale] can be far larger than a page ever is.
  static const int _mostPixels = 9000000;

  /// Recognised lines of the whole image.
  ///
  /// Read once at native size and again larger if the text came back too small,
  /// which is the difference between reading a dense table and losing a third
  /// of its rows.
  static Future<List<OcrLine>> readImage(Uint8List bytes) async {
    final TextRecognizer recognizer = TextRecognizer();
    try {
      final List<OcrLine> first = await _read(recognizer, bytes);
      if (!_tooSmall(first)) return first;
      return await _readScaled(recognizer, bytes, null) ?? first;
    } finally {
      await recognizer.close();
    }
  }

  /// Recognised lines of one part of the image, drawn as large as the caps
  /// allow.
  ///
  /// A whole page can only be magnified so far before it stops fitting, which
  /// leaves an isolated digit too small to read even after [readImage] has done
  /// what it can — a lone digit in a wide bordered cell is the first thing the
  /// recogniser gives up on. Reading a narrow band on its own spends the whole
  /// budget on the part that needs it, which is four times the magnification
  /// the page gets.
  static Future<List<OcrLine>> readRegion(
    Uint8List bytes,
    OcrBox region,
  ) async {
    final TextRecognizer recognizer = TextRecognizer();
    try {
      return await _readScaled(recognizer, bytes, region) ?? const <OcrLine>[];
    } finally {
      await recognizer.close();
    }
  }

  static bool _tooSmall(List<OcrLine> lines) {
    if (lines.isEmpty) return false;
    final List<double> heights = <double>[
      for (final OcrLine line in lines) line.box.height,
    ]..sort();
    final double median = heights[heights.length ~/ 2];
    return median > 0 && median < _readableLineHeight;
  }

  /// Draws [region] (or the whole image) as large as the caps allow, reads it,
  /// and puts the boxes back into the original image's coordinates.
  static Future<List<OcrLine>?> _readScaled(
    TextRecognizer recognizer,
    Uint8List bytes,
    OcrBox? region,
  ) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image source = frame.image;
    try {
      final ui.Rect src = region == null
          ? ui.Rect.fromLTWH(
              0,
              0,
              source.width.toDouble(),
              source.height.toDouble(),
            )
          : ui.Rect.fromLTRB(
              region.left.clamp(0, source.width.toDouble()),
              region.top.clamp(0, source.height.toDouble()),
              region.right.clamp(0, source.width.toDouble()),
              region.bottom.clamp(0, source.height.toDouble()),
            );
      if (src.width < 1 || src.height < 1) return null;

      final double scale = _scaleFor(src);
      if (scale <= 1) return null;
      final int width = (src.width * scale).round();
      final int height = (src.height * scale).round();

      final Uint8List? drawn = await _draw(source, src, width, height);
      if (drawn == null) return null;

      final List<OcrLine> lines = await _read(recognizer, drawn);
      return <OcrLine>[
        for (final OcrLine line in lines)
          OcrLine(
            line.text,
            OcrBox(
              src.left + line.box.left / scale,
              src.top + line.box.top / scale,
              src.left + line.box.right / scale,
              src.top + line.box.bottom / scale,
            ),
          ),
      ];
    } finally {
      source.dispose();
      codec.dispose();
    }
  }

  /// As wide as the cap allows, then pulled back if the bitmap would be too
  /// large.
  static double _scaleFor(ui.Rect src) {
    final double byWidth = _widestUpscale / src.width;
    final double byArea = _mostPixels / (src.width * src.height);
    return byArea <= 0 ? byWidth : math.min(byWidth, math.sqrt(byArea));
  }

  /// Redrawn onto a canvas rather than resized by the codec, which scales with
  /// a box filter: at this magnification that leaves the digits soft enough to
  /// cost a row the sharper filter keeps.
  static Future<Uint8List?> _draw(
    ui.Image source,
    ui.Rect src,
    int width,
    int height,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      src,
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image drawn;
    try {
      drawn = await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
    try {
      final ByteData? png =
          await drawn.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      drawn.dispose();
    }
  }

  /// ML Kit will only read a real file, and a file from Android's document
  /// picker is a `content://` URI with no filesystem path.
  static Future<List<OcrLine>> _read(
    TextRecognizer recognizer,
    Uint8List bytes,
  ) async {
    final Directory dir = await getTemporaryDirectory();
    final File file = File(p.join(dir.path, 'ocr_input'));
    await file.writeAsBytes(bytes, flush: true);
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
      // Best effort: a leftover temp file is harmless and the next read
      // overwrites it anyway, so a failure here must not lose the result.
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
