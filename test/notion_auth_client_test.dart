import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/notion/notion_auth_client.dart';

final Uri _base = Uri.parse('https://example.test');

const String _tokenPayload = '{"access_token":"secret-token",'
    '"refresh_token":"secret-refresh","bot_id":"bot-1",'
    '"workspace_id":"ws-1","workspace_name":"Study"}';

NotionAuthClient _client(MockClient mock) =>
    NotionAuthClient(httpClient: mock, baseUri: _base);

void main() {
  test('the browser is sent the challenge and nothing else', () {
    final Uri uri = _client(MockClient((_) async => http.Response('', 200)))
        .startUri('a-challenge');

    expect(uri.path, '/notion/start');
    expect(uri.queryParameters, <String, String>{'challenge': 'a-challenge'});
  });

  test('a claim trades the verifier for the workspace', () async {
    late http.Request sent;
    final NotionAuthClient client = _client(MockClient((http.Request r) async {
      sent = r;
      return http.Response(_tokenPayload, 200);
    }));

    final NotionAuthResult result =
        await client.claim(session: 'session-1', verifier: 'a-verifier');

    expect(sent.url.path, '/notion/claim');
    expect(jsonDecode(sent.body), <String, String>{
      'session': 'session-1',
      'verifier': 'a-verifier',
    });
    expect(result.ok, isTrue);
    expect(result.tokens!.accessToken, 'secret-token');
    expect(result.tokens!.workspaceName, 'Study');
  });

  test('a code read off the callback page is normalised before it is sent',
      () async {
    late http.Request sent;
    final NotionAuthClient client = _client(MockClient((http.Request r) async {
      sent = r;
      return http.Response(_tokenPayload, 200);
    }));

    await client.claim(pairingCode: ' k7m n4pq ', verifier: 'a-verifier');

    // The service matches the code exactly, so the spaces and case a person
    // types have to come off here or a correct code is refused.
    expect(jsonDecode(sent.body), <String, String>{
      'code': 'K7MN4PQ',
      'verifier': 'a-verifier',
    });
  });

  test('a refused claim and a throttled one are told apart', () async {
    final NotionAuthResult refused = await _client(
      MockClient((_) async => http.Response('{"error":"no"}', 400)),
    ).claim(session: 'session-1', verifier: 'a-verifier');

    final NotionAuthResult throttled = await _client(
      MockClient((_) async => http.Response('', 429)),
    ).claim(session: 'session-1', verifier: 'a-verifier');

    expect(refused.failure, SyncFailure.rejected);
    expect(throttled.failure, SyncFailure.rateLimited);
  });

  test('a refresh without a new refresh token still yields a usable one',
      () async {
    final NotionAuthResult result = await _client(
      MockClient((_) async => http.Response('{"access_token":"fresh"}', 200)),
    ).refresh('secret-refresh');

    expect(result.ok, isTrue);
    expect(result.tokens!.accessToken, 'fresh');
    expect(result.tokens!.refreshToken, isNull);
  });

  test('an unreachable service is offline, not a rejection', () async {
    final NotionAuthResult result = await _client(
      MockClient((_) async => throw http.ClientException('no route')),
    ).refresh('secret-refresh');

    // The difference decides whether the connection is retried or the user is
    // asked to authorise again, so a dead network must never look like a
    // refused token.
    expect(result.failure, SyncFailure.offline);
  });

  test('the wake-up call reports whether the host answered', () async {
    final bool awake =
        await _client(MockClient((_) async => http.Response('ok', 200)))
            .health();
    final bool asleep = await _client(
      MockClient((_) async => throw http.ClientException('timed out')),
    ).health();

    expect(awake, isTrue);
    expect(asleep, isFalse);
  });
}
