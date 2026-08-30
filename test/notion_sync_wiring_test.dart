import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/sync/sync_status.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/features/settings/sync_status_line.dart';
import 'package:zeolite/services/notion/notion_auth_client.dart';
import 'package:zeolite/services/notion/notion_connection_store.dart';
import 'package:zeolite/state/notion_providers.dart';
import 'package:zeolite/state/notion_sync_providers.dart';

NotionProperty _p(String id, String name, String type) =>
    NotionProperty(id: id, name: name, type: type);

/// A mapping with the three columns a row cannot be read without.
NotionMapping _complete() => NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Attendance',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', 'select'),
        NotionField.date: _p('p2', 'Date', 'date'),
        NotionField.status: _p('p3', 'Status', 'select'),
      },
    );

ProviderContainer _container() => ProviderContainer(
      overrides: [
        notionConnectionStoreProvider.overrideWithValue(
          NotionConnectionStore(storage: const FlutterSecureStorage()),
        ),
      ],
    );

void main() {
  late Map<String, String> stored;
  late NotionConnectionStore store;

  setUp(() {
    stored = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(stored);
    store = NotionConnectionStore(storage: const FlutterSecureStorage());
  });

  test('nothing is written to Notion until it is both connected and mapped',
      () async {
    final ProviderContainer container = _container();
    addTearDown(container.dispose);

    // Neither.
    await container.read(notionConnectionProvider.future);
    expect(container.read(notionSyncTargetProvider), isNull);

    // Connected, but nowhere to file a mark.
    await store.write(const NotionTokens(accessToken: 'a-token'));
    container.invalidate(notionConnectionProvider);
    await container.read(notionConnectionProvider.future);
    await container.read(notionMappingProvider.future);
    expect(container.read(notionSyncTargetProvider), isNull);

    // Both.
    await store.writeMapping(_complete());
    container.invalidate(notionMappingProvider);
    await container.read(notionMappingProvider.future);
    expect(container.read(notionSyncTargetProvider), isNotNull);
  });

  test('a half-answered mapping is not somewhere to write either', () async {
    await store.write(const NotionTokens(accessToken: 'a-token'));
    await store.writeMapping(NotionMapping(
      databaseId: 'db-1',
      dataSourceId: 'ds-1',
      title: 'Attendance',
      fields: <NotionField, NotionProperty>{
        NotionField.course: _p('p1', 'Course', 'select'),
      },
    ));

    final ProviderContainer container = _container();
    addTearDown(container.dispose);
    await container.read(notionConnectionProvider.future);
    await container.read(notionMappingProvider.future);

    // Pushing against it would fail validation on every single row.
    expect(container.read(notionSyncTargetProvider), isNull);
  });

  test('a refused sync tells you how to fix the target it was refused by', () {
    const SyncStatus refused =
        SyncStatus(state: SyncState.failed, failure: SyncFailure.auth);

    expect(
      syncStatusLine(refused, null),
      contains('Sign out and back in'),
    );
    // Sending someone to sign out of their account when it is Notion that
    // stopped accepting writes is worse than saying nothing.
    expect(
      syncStatusLine(
        refused,
        null,
        authAdvice: 'Disconnect Notion and connect it again.',
      ),
      contains('Disconnect Notion'),
    );
  });
}
