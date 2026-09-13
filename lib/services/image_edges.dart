import 'dart:typed_data';
import 'dart:ui' as ui;

import '../domain/grid_lines.dart';

/// Finds the table a timetable image draws around itself.
///
/// The decode side of [GridLines], kept here for the reason the ML Kit types
/// stop at [TextRecognition]: the geometry stays plain Dart and testable, and
/// only this file knows about `dart:ui`.
class ImageEdges {
  /// Wide enough that a rule is several pixels of ink, narrow enough that the
  /// whole pass stays inside a frame. A page read at 2600 finds the same rules.
  static const int _work = 1400;

  /// Null when the image draws nothing that looks like a table — a photograph,
  /// or a sheet that rules nothing.
  ///
  /// The lattice comes back in the coordinates of [bytes] as supplied, so it
  /// lines up with the boxes [TextRecognition] hands back.
  static Future<TableLattice?> rulesOf(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image source = frame.image;
    try {
      final double scale = source.width > _work ? _work / source.width : 1;
      final int width = (source.width * scale).round();
      final int height = (source.height * scale).round();
      if (width < 2 || height < 2) return null;

      final Uint8List? grey = await _grey(source, width, height);
      if (grey == null) return null;

      final TableLattice? found =
          GridLines.read(InkMap.from(grey, width, height));
      if (found == null || scale == 1) return found;
      return found.scaled(1 / scale);
    } finally {
      source.dispose();
      codec.dispose();
    }
  }

  /// One byte of luminance per pixel, at [width] by [height].
  static Future<Uint8List?> _grey(
    ui.Image source,
    int width,
    int height,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      ui.Rect.fromLTWH(
        0,
        0,
        source.width.toDouble(),
        source.height.toDouble(),
      ),
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
      final ByteData? raw =
          await drawn.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (raw == null) return null;
      final Uint8List rgba = raw.buffer.asUint8List();
      final Uint8List grey = Uint8List(width * height);
      for (int i = 0; i < grey.length; i++) {
        final int p = i * 4;
        // Rec. 601 luma in integers; a coloured cell has to darken the same
        // way the eye sees it or the threshold reads the fill as ink.
        grey[i] =
            (rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/ 1000;
      }
      return grey;
    } finally {
      drawn.dispose();
    }
  }
}
