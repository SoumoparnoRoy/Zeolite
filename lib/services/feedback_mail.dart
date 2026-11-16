import 'package:flutter/services.dart';

import '../core/endpoints.dart';

/// The draft Settings > Send feedback hands to the email app.
abstract final class FeedbackMail {
  static const MethodChannel _device = MethodChannel('zeolite/device');

  static const String subject = 'Zeolite feedback';

  /// "16 (API 36)", or null when the platform can't say.
  static Future<String?> androidVersion() async {
    try {
      return await _device.invokeMethod<String>('androidVersion');
    } on Exception {
      return null;
    }
  }

  // Built by hand: Uri's queryParameters writes spaces as '+', and mail apps
  // show them that way.
  static Uri draft({required String app, String? android}) {
    final String body = '\n\n\n---\nZeolite $app'
        '${android == null ? '' : '\nAndroid $android'}';
    return Uri.parse(
      'mailto:${Endpoints.support}'
      '?subject=${Uri.encodeComponent(subject)}'
      '&body=${Uri.encodeComponent(body)}',
    );
  }
}
