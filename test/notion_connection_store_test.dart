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

    final List<RetiredNotionDatabase> kept = await store.readRetired();
    expect(kept.single.id, 'db-old');
    expect(kept.single.title, 'Zeolite Attendance (old)');

    await store.clearRetired();
    expect(await store.readRetired(), isEmpty);
  });

  test('a second one left behind does not displace the first', () async {
    // Retake, dismiss the prompt, retake again. The first page used to be
    // overwritten here, stranding it in Notion with no way back to it.
    await store.writeRetired('db-first', 'Zeolite Attendance (old)');
    await store.writeRetired('db-second', 'Zeolite Attendance (older)');

    final List<RetiredNotionDatabase> kept = await store.readRetired();

    expect(kept.map((RetiredNotionDatabase e) => e.id),
        <String>['db-first', 'db-second']);
  });

  test('dealing with one leaves the other still waiting', () async {
    await store.writeRetired('db-first', 'Zeolite Attendance (old)');
    await store.writeRetired('db-second', 'Zeolite Attendance (older)');

    await store.removeRetired('db-first');

    expect(await store.readRetired(), hasLength(1));
    expect((await store.readRetired()).single.id, 'db-second');
  });

  test('recording the same one again replaces it', () async {
    // The rename path writes it again under the name the rename settled on.
    await store.writeRetired('db-old', 'Zeolite Attendance', pageId: 'page-1');
    await store.writeRetired('db-old', 'Zeolite Attendance (old)',
        pageId: 'page-1');

    final List<RetiredNotionDatabase> kept = await store.readRetired();

    expect(kept, hasLength(1));
    expect(kept.single.title, 'Zeolite Attendance (old)');
    expect(kept.single.pageId, 'page-1');
  });

  test('each one remembers when it was left behind', () async {
    // Every retake produces the same template name, so the moment is the
    // only thing telling two rows apart.
    final DateTime at = DateTime(2026, 9, 6, 20, 34);
    await store.writeRetired('db-old', 'Zeolite Attendance', retiredAt: at);

    expect((await store.readRetired()).single.retiredAt, at);
  });

  test('an offer stored by an earlier version is still readable', () async {
    // One object rather than a list, which is how this was kept before.
    stored['notion_retired_database'] =
        '{"id":"db-old","title":"Zeolite Attendance (old)","pageId":"page-1"}';

    final List<RetiredNotionDatabase> kept = await store.readRetired();

    expect(kept.single.id, 'db-old');
    expect(kept.single.pageId, 'page-1');
    expect(kept.single.retiredAt, isNull);
  });

  test('they go with the connection, like the mapping does', () async {
    // They name databases in one workspace, so outliving the connection could
    // only leave them pointing somewhere the user no longer is.
    await store.write(const NotionTokens(accessToken: 'a-token'));
    await store.writeRetired('db-first', 'Zeolite Attendance (old)');
    await store.writeRetired('db-second', 'Zeolite Attendance (older)');

    await store.clear();

    expect(await store.readRetired(), isEmpty);
  });

  test('a retired entry that no longer parses reads as nothing to offer',
      () async {
    stored['notion_retired_database'] = 'not json';
    expect(await store.readRetired(), isEmpty);
  });
}
