import 'package:flutter/material.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zeolite/features/settings/notion_connect_screen.dart';
import 'package:zeolite/services/notion/notion_auth_client.dart';
import 'package:zeolite/services/notion/notion_connection_store.dart';
import 'package:zeolite/state/notion_providers.dart';

const String _tokenPayload =
    '{"access_token":"token","workspace_name":"Study"}';

Widget _app(MockClient client, {bool retakeTemplate = false}) => ProviderScope(
      overrides: [
        notionAuthClientProvider.overrideWithValue(
          NotionAuthClient(
            httpClient: client,
            baseUri: Uri.parse('https://example.test'),
          ),
        ),
        notionConnectionStoreProvider.overrideWithValue(
          NotionConnectionStore(storage: const FlutterSecureStorage()),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: NotionConnectScreen(retakeTemplate: retakeTemplate),
      ),
    );

void main() {
  late Map<String, String> stored;

  setUp(() {
    stored = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(stored);
  });

  testWidgets('both ways back are offered before either is tried',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(MockClient((_) async => http.Response('ok', 200))),
    );
    await tester.pumpAndSettle();

    // The typed code is present from the start rather than after a timeout —
    // a browser that drops the redirect gives no signal to time out on.
    expect(find.text('Connect Notion'), findsWidgets);
    expect(find.text('Or type the code from the browser'), findsOneWidget);
  });

  testWidgets('a connected workspace is named and can be disconnected',
      (WidgetTester tester) async {
    stored['notion_connection'] = _tokenPayload;

    await tester.pumpWidget(
      _app(MockClient((_) async => http.Response('ok', 200))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Study'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(stored, isEmpty);
  });

  testWidgets('taking a newer template offers consent, not Disconnect',
      (WidgetTester tester) async {
    stored['notion_connection'] = _tokenPayload;

    await tester.pumpWidget(
      _app(
        MockClient((_) async => http.Response('ok', 200)),
        retakeTemplate: true,
      ),
    );
    await tester.pumpAndSettle();

    // Without this the screen offers a connected workspace nothing but
    // Disconnect, and a new template could only be taken by tearing the
    // working connection down first.
    expect(find.text('Take the template'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  testWidgets('taking a newer template offers consent, not Disconnect',
      (WidgetTester tester) async {
    stored['notion_connection'] = _tokenPayload;

    await tester.pumpWidget(
      _app(
        MockClient((_) async => http.Response('ok', 200)),
        retakeTemplate: true,
      ),
    );
    await tester.pumpAndSettle();

    // A connected workspace was offered nothing but Disconnect, so the only
    // way to a newer template was tearing down a working connection first.
    expect(find.text('Take the template'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  testWidgets('an attempt left in the browser is picked back up',
      (WidgetTester tester) async {
    stored['notion_pending'] =
        '{"verifier":"a-verifier","startedAt":${DateTime.now().millisecondsSinceEpoch}}';

    await tester.pumpWidget(
      _app(MockClient((_) async => http.Response('ok', 200))),
    );
    await tester.pumpAndSettle();

    // Pressing back out of this screen used to end the attempt silently and
    // strand the user with a pairing code that could no longer be claimed.
    final Finder finish =
        find.widgetWithText(OutlinedButton, 'Finish connecting');
    expect(tester.widget<OutlinedButton>(finish).onPressed, isNotNull);
    expect(find.textContaining('tap Connect Notion first'), findsNothing);

    // Back here with the attempt outstanding is the hijack's signature.
    expect(find.textContaining("Didn't get back from Notion?"), findsOneWidget);
    expect(find.textContaining('using Email'), findsOneWidget);
  });

  testWidgets('a claim that is refused says so and keeps nothing',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(MockClient((_) async => http.Response('{"error":"no"}', 400))),
    );
    await tester.pumpAndSettle();

    // Nothing can be claimed until the browser has been opened, because the
    // verifier is generated at that moment and there is nothing to prove.
    final Finder finish =
        find.widgetWithText(OutlinedButton, 'Finish connecting');
    expect(tester.widget<OutlinedButton>(finish).onPressed, isNull);
    // Disabled is not enough on its own — the screen has to say why.
    expect(find.textContaining('tap Connect Notion first'), findsOneWidget);
    expect(find.textContaining("Didn't get back from Notion?"), findsNothing);
    expect(stored, isEmpty);
  });
}
