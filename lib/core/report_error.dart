import 'package:flutter/foundation.dart';

/// Where a failure goes besides the log. Set by `main` once Firebase is up;
/// a function rather than an import keeps Firebase out of `core/`.
void Function(Object error, StackTrace? stack, String where)? errorSink;

/// One format for every failure the user is not told about, and one place
/// for the crash reporter to hear about it.
void reportError(Object error, StackTrace? stack, {required String where}) {
  debugPrint('Zeolite: $where failed: $error');
  if (stack != null) debugPrintStack(stackTrace: stack, maxFrames: 8);
  errorSink?.call(error, stack, where);
}
