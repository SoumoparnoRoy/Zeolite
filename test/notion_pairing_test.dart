import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/services/notion/notion_auth_client.dart';
import 'package:zeolite/services/notion/notion_connection_store.dart';
import 'package:zeolite/state/notion_pairing.dart';
import 'package:zeolite/state/notion_providers.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';

void main() {
  late Map<String, String> stored;

  setUp(() {
    stored = <String, String>{
      'notion_pending':
          '{"verifier":"a-verifier","startedAt":${DateTime.now().millisecondsSinceEpoch}}',
    };
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(stored);
  });

  ProviderContainer container(http.Response Function(String path) answer) {
    final ProviderContainer c = ProviderContainer(
      overrides: [
        notionAuthClientProvider.overrideWithValue(
          NotionAuthClient(
            httpClient: MockClient(
              (http.Request request) async => answer(request.url.path),
            ),
            baseUri: Uri.parse('https://example.test'),
          ),
        ),
        notionConnectionStoreProvider.overrideWithValue(
          NotionConnectionStore(storage: const FlutterSecureStorage()),
        ),
        analyticsProvider.overrideWithValue(FakeAnalytics()),
      ],
    );
    addTearDown(c.dispose);
    c.listen(notionPairingProvider, (_, __) {});
    return c;
  }

  test('a claim on a workspace of its own connects and asks for columns',
      () async {
    final ProviderContainer c = container(
      (String path) => path == '/notion/claim'
          ? http.Response('{"access_token":"t","workspace_name":"Study"}', 200)
          : http.Response('ok', 200),
    );
    await pumpEventQueue();
    expect(c.read(notionPairingProvider).verifier, 'a-verifier');

    final NotionClaimOutcome? outcome = await c
        .read(notionPairingProvider.notifier)
        .claim(pairingCode: 'abcd 1234');

    expect(outcome, NotionClaimOutcome.needsMapping);
    expect(c.read(notionConnectionProvider).value?.workspaceName, 'Study');
    // A finished attempt must not be offered back on the next open.
    expect(stored.containsKey('notion_pending'), isFalse);
  });

  test('a refused claim keeps the attempt so the code can be retyped',
      () async {
    final ProviderContainer c = container(
      (String path) => path == '/notion/claim'
          ? http.Response('{"error":"no"}', 400)
          : http.Response('ok', 200),
    );
    await pumpEventQueue();

    final NotionClaimOutcome? outcome = await c
        .read(notionPairingProvider.notifier)
        .claim(pairingCode: 'WRONG123');

    final NotionPairing pairing = c.read(notionPairingProvider);
    expect(outcome, NotionClaimOutcome.refused);
    expect(pairing.stage, NotionPairingStage.waiting);
    expect(pairing.verifier, 'a-verifier');
    expect(pairing.error, isNotNull);
    expect(stored.containsKey('notion_connection'), isFalse);
  });
}
