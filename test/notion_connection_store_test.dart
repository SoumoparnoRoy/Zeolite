import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/services/notion/notion_auth_client.dart';
import 'package:zeolite/services/notion/notion_connection_store.dart';

void main() {
  late Map<String, String> stored;
  late NotionConnectionStore store;

  setUp(() {
    stored = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(stored);
    store = NotionConnectionStore(storage: const FlutterSecureStorage());
  });

  test('nothing is connected until something is written', () async {
    expect(await store.read(), isNull);
  });

  test('a connection survives a round trip whole', () async {
    await store.write(const NotionTokens(
      accessToken: 'token',
      refreshToken: 'refresh',
      botId: 'bot',
      workspaceId: 'ws',
      workspaceName: 'Study',
      workspaceIcon: 'https://example.test/icon.png',
    ));

    final NotionTokens? read = await store.read();

    expect(read!.accessToken, 'token');
    expect(read.refreshToken, 'refresh');
    expect(read.workspaceName, 'Study');
    expect(read.workspaceIcon, 'https://example.test/icon.png');
  });

  test('disconnecting leaves nothing behind', () async {
    await store.write(const NotionTokens(accessToken: 'token'));

    await store.clear();

    expect(await store.read(), isNull);
    expect(stored, isEmpty);
  });

  test('an attempt in the browser outlives the screen', () async {
    await store.writePending('a-verifier');

    expect(await store.readPending(), 'a-verifier');

    await store.clearPending();
    expect(await store.readPending(), isNull);
  });

  test('an attempt the service has already dropped reads as nothing', () async {
    final DateTime began = DateTime(2026, 8, 30, 12);
    await store.writePending('a-verifier', startedAt: began);

    // One second inside the service's session window, and one second past it.
    expect(
      await store.readPending(
        now: began.add(NotionConnectionStore.pendingLifetime -
            const Duration(seconds: 1)),
      ),
      'a-verifier',
    );
    expect(
      await store.readPending(
        now: began.add(NotionConnectionStore.pendingLifetime),
      ),
      isNull,
    );
  });

  test('a value that is no longer readable reads as disconnected', () async {
    // The platform resets rather than throws on a key it cannot unwrap, so
    // what reaches this code is a surviving but meaningless value. Throwing
    // here would strand the user on a screen they cannot leave; reconnecting
    // is the recovery.
    stored['notion_connection'] = 'not json';

    expect(await store.read(), isNull);
  });

  test('the database a migration left behind outlives the moment it was made',
      () async {
    // "Leave it for now" used to be final: there was no way back to the offer.
    await store.writeRetired('db-old', 'Zeolite Attendance (old)');

    final RetiredNotionDatabase? kept = await store.readRetired();
    expect(kept?.id, 'db-old');
    expect(kept?.title, 'Zeolite Attendance (old)');

    await store.clearRetired();
    expect(await store.readRetired(), isNull);
  });

  test('it goes with the connection, like the mapping does', () async {
    // It names a database in one workspace, so outliving the connection could
    // only leave it pointing somewhere the user no longer is.
    await store.write(const NotionTokens(accessToken: 'a-token'));
    await store.writeRetired('db-old', 'Zeolite Attendance (old)');

    await store.clear();

    expect(await store.readRetired(), isNull);
  });

  test('a retired entry that no longer parses reads as nothing to offer',
      () async {
    stored['notion_retired_database'] = 'not json';
    expect(await store.readRetired(), isNull);
  });
}
