import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:http/http.dart' as http;

import '../../domain/vision_read.dart';

/// The device's half of `POST /timetable/read`.
///
/// Reached only when `TimetableOcr.confidenceOf` has already doubted a local
/// read and the student has agreed to that read leaving the device. Nothing
/// here decides either of those things.
class VisionClient {
  VisionClient({
    http.Client? httpClient,
    Uri? baseUri,
    Future<String?> Function()? appCheckToken,
  })  : _http = httpClient ?? http.Client(),
        _base = baseUri ?? Uri.parse(defaultBaseUrl),
        _appCheckToken =
            appCheckToken ?? (() => FirebaseAppCheck.instance.getToken());

  static const String defaultBaseUrl = 'https://zeolite.onrender.com';

  /// Long, for the same reason the Notion client's wake timeout is: a free
  /// host spins down when idle, and this call is usually the one waking it.
  /// The model itself then takes its time on a dense sheet.
  static const Duration _timeout = Duration(seconds: 120);

  final http.Client _http;
  final Uri _base;
  final Future<String?> Function() _appCheckToken;

  Future<VisionRead> read({
    required Uint8List image,
    required String text,
  }) async {
    try {
      // The service refuses a read without one, so there is no point sending
      // the image when the device could not get a token.
      final String? token = await _appCheckToken();
      if (token == null || token.isEmpty) {
        return const VisionRead.failed(VisionFailure.failed);
      }
      final http.Response response = await _http
          .post(
            _base.resolve('/timetable/read'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'X-Firebase-AppCheck': token,
            },
            body: jsonEncode(<String, Object?>{
              'image': base64Encode(image),
              if (text.isNotEmpty) 'text': text,
            }),
          )
          .timeout(_timeout);
      return _readFrom(response);
    } on TimeoutException {
      return const VisionRead.failed(VisionFailure.offline);
    } catch (_) {
      // Socket and handshake failures both land here and mean the same thing
      // to the student: the service could not be reached.
      return const VisionRead.failed(VisionFailure.offline);
    }
  }

  VisionRead _readFrom(http.Response response) {
    switch (response.statusCode) {
      case 200:
        break;
      case 503:
        return const VisionRead.failed(VisionFailure.unavailable);
      case 429:
        return const VisionRead.failed(VisionFailure.busy);
      default:
        return const VisionRead.failed(VisionFailure.failed);
    }

    final Object? body = jsonDecode(response.body);
    if (body is! Map<String, Object?>) {
      return const VisionRead.failed(VisionFailure.failed);
    }
    final Object? classes = body['classes'];
    if (classes is! List<Object?>) {
      return const VisionRead.failed(VisionFailure.failed);
    }
    final List<VisionClass> read = <VisionClass>[
      for (final Object? entry in classes)
        if (entry is Map<String, Object?>) VisionClass.fromJson(entry),
    ].where((VisionClass c) => c.isUsable).toList();
    return read.isEmpty
        ? const VisionRead.failed(VisionFailure.unreadable)
        : VisionRead.done(read);
  }

  void close() => _http.close();
}
