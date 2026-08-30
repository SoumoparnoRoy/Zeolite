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

  test('a value that is no longer readable reads as disconnected', () async {
    // The platform resets rather than throws on a key it cannot unwrap, so
    // what reaches this code is a surviving but meaningless value. Throwing
    // here would strand the user on a screen they cannot leave; reconnecting
    // is the recovery.
    stored['notion_connection'] = 'not json';

    expect(await store.read(), isNull);
  });
}
