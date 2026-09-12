import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/vision_read.dart';
import 'package:zeolite/services/timetable/vision_client.dart';

final Uri _base = Uri.parse('https://example.test');

final Uint8List _image = Uint8List.fromList(<int>[1, 2, 3, 4]);

VisionClient _client(MockClient mock) =>
    VisionClient(httpClient: mock, baseUri: _base);

Future<VisionRead> _answering(String body, int status) => _client(
      MockClient((_) async => http.Response(body, status)),
    ).read(image: _image, text: 'AAA1001');

void main() {
  test('the image and the transcript both go, and nothing else', () async {
    late http.Request sent;
    await _client(MockClient((http.Request r) async {
      sent = r;
      return http.Response('{"classes":[]}', 200);
    })).read(image: _image, text: 'AAA1001 R101');

    expect(sent.url.path, '/timetable/read');
    expect(jsonDecode(sent.body), <String, String>{
      'image': base64Encode(_image),
      'text': 'AAA1001 R101',
    });
  });

  test('both reply shapes survive the trip', () async {
    final VisionRead read = await _answering(
      '{"classes":[{"subject":"AAA1001","weekday":1,"first":2,"last":3,'
      '"room":"R101"},'
      '{"subject":"BBB2002","weekday":3,"from":610,"to":660,"room":null}]}',
      200,
    );

    expect(read.ok, isTrue);
    expect(read.classes.first.byColumn, isTrue);
    expect(read.classes.first.last, 3);
    expect(read.classes.last.byColumn, isFalse);
    expect(read.classes.last.from, 610);
  });

  // The caller has to tell these apart: only one of them is worth a retry, and
  // none of them may carry anything about the provider.
  test('each refusal arrives as the reason the student can act on', () async {
    expect(
      (await _answering('{"error":"nope"}', 503)).failure,
      VisionFailure.unavailable,
    );
    expect(
      (await _answering('{"error":"nope"}', 429)).failure,
      VisionFailure.busy,
    );
    expect(
      (await _answering('{"error":"nope"}', 502)).failure,
      VisionFailure.failed,
    );
  });

  test('a reply holding no usable class reads as unreadable', () async {
    final VisionRead read = await _answering(
      '{"classes":[{"subject":"","weekday":1,"first":1,"last":1},'
      '{"subject":"AAA1001","weekday":9,"first":1,"last":1}]}',
      200,
    );

    expect(read.failure, VisionFailure.unreadable);
  });

  test('a socket failure is offline rather than an exception', () async {
    final VisionRead read = await _client(
      MockClient((_) async => throw http.ClientException('down')),
    ).read(image: _image, text: '');

    expect(read.failure, VisionFailure.offline);
  });
}
