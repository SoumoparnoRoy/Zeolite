import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/endpoints.dart';

/// Asks the server for the oldest build it still supports. The server owns the
/// number, since a contract change there is what makes a build too old.
class MinBuildCheck {
  MinBuildCheck({http.Client? httpClient, Uri? baseUri})
      : _http = httpClient ?? http.Client(),
        _base = baseUri ?? Uri.parse(Endpoints.server);

  /// Short on purpose. A host that is asleep usually takes longer than this
  /// to wake, and then this launch simply is not checked; the next one is.
  static const Duration timeout = Duration(seconds: 10);

  final http.Client _http;
  final Uri _base;

  /// Offline, slow, refused or garbled all say false: the network must never
  /// be the reason the app does not open.
  Future<bool> isTooOld(int build) async {
    try {
      final http.Response response =
          await _http.get(_base.resolve('/version')).timeout(timeout);
      if (response.statusCode != 200) return false;
      final Object? body = jsonDecode(response.body);
      final Object? minimum =
          body is Map<String, Object?> ? body['minBuild'] : null;
      return minimum is int && build < minimum;
    } catch (_) {
      return false;
    }
  }

  void close() => _http.close();
}
