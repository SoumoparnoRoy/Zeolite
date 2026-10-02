import 'package:flutter/foundation.dart';

/// One format for every failure the user is not told about, and one place for
/// a crash reporter to hook in if the app ever gets one.
void reportError(Object error, StackTrace? stack, {required String where}) {
  debugPrint('Zeolite: $where failed: $error');
  if (stack != null) debugPrintStack(stackTrace: stack, maxFrames: 8);
}
