import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../core/report_error.dart';
import 'text_recognition.dart';

/// The plugin copies each pick into the app's cache and never removes it, so a
/// timetable photo would otherwise stay on the device long after its read.
abstract final class PickedFile {
  /// Null if the student backed out. The copy is gone once this returns or
  /// throws.
  static Future<Uint8List?> read({String? dialogTitle}) async {
    try {
      final PlatformFile? picked =
          await FilePicker.pickFile(dialogTitle: dialogTitle);
      return await picked?.readAsBytes();
    } finally {
      await _clearCopies();
    }
  }

  /// ML Kit's file only goes here, since a read on another screen may be using
  /// it.
  static Future<void> clearAtStart() async {
    await _clearCopies();
    await TextRecognition.deleteLeftoverInput();
  }

  /// A copy left behind must not cost the student the file they just picked.
  static Future<void> _clearCopies() async {
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (error, stack) {
      reportError(error, stack, where: 'clearing picked files');
    }
  }
}
