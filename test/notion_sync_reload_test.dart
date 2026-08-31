import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';
import 'package:zeolite/services/sync/sync_scheduler.dart';
import 'package:zeolite/state/notion_sync_providers.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_sync_target.dart';

/// The Notion half of the sync wiring, which had two gaps the account half
/// had already closed: a run that pulled never told the screens, and the
/// scheduler was torn down by any settings write — its own stamp included.
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
        InMemorySharedPreferencesAsync.withData(<String, Object>{
      // Stops the scheduler running the moment it is built, which is a resume,
      // not the debounced run these tests are about.
      'ut.lastNotionSync': DateTime.now().millisecondsSinceEpoch,
    });
    dir = await Directory.systemTemp.createTemp('zeolite_notion_reload');
    appDb = AppDatabase.at('${dir.path}/n.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    target = FakeSyncTarget()..trustsPulls = true;
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  ProviderContainer build() {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
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

  test('a row pulled from Notion reaches the screens without a restart',
      () async {
    final ProviderContainer container = build();
    target.remote = <RemoteState>[
      RemoteState(
        kind: SyncKind.subject,
        localKey: 'aabbccdd',
        remoteId: 'aabbccdd',
        hash: 'subject-hash',
        fields: <String, Object?>{
          'name': 'Generic Course',
          'code': 'GEN101',
          'teacher': null,
          'color': 0xFF336699,
          'targetPercent': null,
          'priorHeld': 0,
          'priorAttended': 0,
          'expectedTotal': null,
        },
      ),
    ];

    await container.read(settingsProvider.future);
    container.listen(timetableProvider, (_, __) {});
    await container.read(timetableProvider.future);

    await container.read(notionSyncStatusProvider.notifier).run(force: true);

    final List<Subject> subjects =
        (await container.read(timetableProvider.future)).subjects;
    expect(subjects.map((Subject s) => s.name), contains('Generic Course'));
  });

  test('a settings write leaves the pending run armed', () async {
    final ProviderContainer container = build();
    final AppSettings settings = await container.read(settingsProvider.future);

    final SyncScheduler? scheduler = container.read(notionSchedulerProvider);
    scheduler!.onLocalChange();
    expect(scheduler.hasPendingRun, isTrue);

    await container
        .read(settingsProvider.notifier)
        .save(settings.copyWith(themeMode: AppThemeMode.light));

    expect(container.read(notionSchedulerProvider), same(scheduler));
    expect(scheduler.hasPendingRun, isTrue);
  });
}
