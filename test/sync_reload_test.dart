import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/state/providers.dart';
import 'package:zeolite/state/sync_providers.dart';

import 'fake_sync_target.dart';

/// Pins the bug this file exists for: a tablet that had just pulled its whole
/// timetable down still said "No subjects yet" until it was restarted.
void main() {
  late Directory dir;
  late ZeoliteRepository repo;
  late FakeSyncTarget target;
  late ProviderContainer container;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_reload');
    appDb = AppDatabase.at('${dir.path}/reload.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    target = FakeSyncTarget()..trustsPulls = true;

    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        syncTargetProvider.overrideWithValue(target),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  test('a pulled subject reaches the timetable without a restart', () async {
    const String uuid = 'aabbccdd';
    target.remote = <RemoteState>[
      RemoteState(
        kind: SyncKind.subject,
        localKey: uuid,
        remoteId: uuid,
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

    // A listener is what the screens are: without one, a stale reading proves
    // nothing about a provider nobody was watching.
    container.listen(timetableProvider, (_, __) {});
    await container.read(timetableProvider.future);
    expect(container.read(timetableProvider).value?.subjects, isEmpty);

    await container.read(syncStatusProvider.notifier).run(force: true);
    expect(await repo.getSubjects(), isNotEmpty, reason: 'the pull landed');

    final List<Subject> subjects =
        (await container.read(timetableProvider.future)).subjects;
    expect(subjects.map((Subject s) => s.name), contains('Generic Course'));
  });
}
