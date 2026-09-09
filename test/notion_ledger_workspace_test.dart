import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/domain/notion/notion_mapping.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/notion/notion_sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';
import 'package:zeolite/state/notion_providers.dart';
import 'package:zeolite/state/notion_sync_providers.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_sync_target.dart';

/// Says which database is connected without a workspace behind it.
/// [refreshTitle] would reach for the client, and a run ends by calling it.
class _MappingOf extends NotionMappingController {
  _MappingOf(this._mapping);

  final NotionMapping _mapping;

  @override
  Future<NotionMapping?> build() async => _mapping;

  @override
  Future<void> refreshTitle() async {}
}

NotionMapping _mappingOn(String databaseId) => NotionMapping(
      databaseId: databaseId,
      dataSourceId: '$databaseId-source',
      title: 'Zeolite Classes',
      fields: const <NotionField, NotionProperty>{},
    );

/// Reconnecting to a different workspace left every mark carrying a link into
/// the workspace just left, so the new database was filled with nothing while
/// Settings reported a run that had succeeded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ZeoliteRepository repo;
  late FakeSyncTarget target;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
    dir = await Directory.systemTemp.createTemp('zeolite_notion_ledger');
    appDb = AppDatabase.at('${dir.path}/n.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    target = FakeSyncTarget()..trustsPulls = true;
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  Future<void> ledgerHolds(String localKey) => repo.setRemoteLinks(
        <RemoteLink>[
          RemoteLink(
            target: NotionSyncTarget.targetId,
            kind: SyncKind.attendance,
            localKey: localKey,
            remoteId: 'page-in-the-old-workspace',
            localHash: 'h',
            remoteHash: 'h',
            origin: SyncOrigin.app,
          ),
        ],
      );

  ProviderContainer connectedTo(String databaseId) {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        notionMappingProvider.overrideWith(
          () => _MappingOf(_mappingOn(databaseId)),
        ),
        notionSyncTargetProvider.overrideWithValue(target),
        notionCoordinatorProvider.overrideWith(
          (Ref ref) => SyncCoordinator(
            repository: repo,
            settings: ref.watch(settingsServiceProvider),
            target: target,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<int> notionLinks() async =>
      (await repo.getRemoteLinks(NotionSyncTarget.targetId, SyncKind.attendance))
          .length;

  test('connecting a different database forgets the old ledger', () async {
    final ProviderContainer first = connectedTo('db-first');
    await first.read(settingsProvider.future);
    await first.read(notionMappingProvider.future);
    await first.read(notionSyncStatusProvider.notifier).run(force: true);

    // What that run left behind, pointing into the workspace being left.
    await ledgerHolds('record-1');
    expect(await notionLinks(), 1);

    // Disconnected, and connected to a workspace with a database of its own.
    final ProviderContainer second = connectedTo('db-second');
    await second.read(settingsProvider.future);
    await second.read(notionMappingProvider.future);
    await second.read(notionSyncStatusProvider.notifier).run(force: true);

    expect(await notionLinks(), 0);
    expect(
      second.read(settingsProvider).value?.syncedNotionDatabaseId,
      'db-second',
    );
  });

  test('the same database keeps its ledger', () async {
    final ProviderContainer container = connectedTo('db-first');
    await container.read(settingsProvider.future);
    await container.read(notionMappingProvider.future);
    await container.read(notionSyncStatusProvider.notifier).run(force: true);

    await ledgerHolds('record-1');
    await container.read(notionSyncStatusProvider.notifier).run(force: true);

    expect(await notionLinks(), 1);
  });

  /// An install upgrading into this cannot say which database its ledger was
  /// built against, so it is forgotten once and stamped from then on.
  test('an install that never recorded a database forgets it once', () async {
    await ledgerHolds('record-1');

    final ProviderContainer container = connectedTo('db-first');
    await container.read(settingsProvider.future);
    await container.read(notionMappingProvider.future);
    await container.read(notionSyncStatusProvider.notifier).run(force: true);

    expect(await notionLinks(), 0);
    expect(
      container.read(settingsProvider).value?.syncedNotionDatabaseId,
      'db-first',
    );

    // Stamped now, so the run after it is an ordinary one.
    await ledgerHolds('record-2');
    await container.read(notionSyncStatusProvider.notifier).run(force: true);
    expect(await notionLinks(), 1);
  });

  /// A database nothing had been written to yet read "Synced 9 min ago" — a
  /// run against the workspace just left.
  test('the last-run time does not survive a database change', () async {
    final ProviderContainer container = connectedTo('db-first');
    await container.read(settingsProvider.future);
    await container.read(notionMappingProvider.future);
    await container.read(settingsProvider.notifier).save(
          container.read(settingsProvider).value!.copyWith(
                syncedNotionDatabaseId: 'db-first',
                lastNotionSyncAt: DateTime(2026, 9, 9, 19),
              ),
        );

    await container
        .read(notionMappingProvider.notifier)
        .save(_mappingOn('db-second'));

    expect(container.read(settingsProvider).value?.lastNotionSyncAt, isNull);
  });

  test('the last-run time survives a mapping saved on the same database',
      () async {
    final ProviderContainer container = connectedTo('db-first');
    await container.read(settingsProvider.future);
    await container.read(notionMappingProvider.future);
    await container.read(settingsProvider.notifier).save(
          container.read(settingsProvider).value!.copyWith(
                syncedNotionDatabaseId: 'db-first',
                lastNotionSyncAt: DateTime(2026, 9, 9, 19),
              ),
        );

    // What refreshing the title does: same database, a new name.
    await container
        .read(notionMappingProvider.notifier)
        .save(_mappingOn('db-first'));

    expect(
      container.read(settingsProvider).value?.lastNotionSyncAt,
      DateTime(2026, 9, 9, 19),
    );
  });
}
