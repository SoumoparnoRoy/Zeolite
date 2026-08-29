import 'dart:io';

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

import 'fake_sync_target.dart';

/// Without a date of its own a rename could not be compared across devices, so
/// a subject always kept whichever copy the device happened to hold.
void main() {
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
    dir = await Directory.systemTemp.createTemp('zeolite_updated');
    appDb = AppDatabase.at('${dir.path}/u.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    target = FakeSyncTarget()..trustsPulls = true;
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  Future<Subject> only() async => (await repo.getSubjects()).single;

  test('renaming a subject dates the change', () async {
    await repo.insertSubject(
      Subject(
        name: 'Generic Course',
        colorValue: 0xFF336699,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    expect((await only()).updatedAt, isNull, reason: 'never edited yet');

    await repo.updateSubject((await only()).copyWith(name: 'Renamed Course'));

    final Subject after = await only();
    expect(after.name, 'Renamed Course');
    expect(after.updatedAt, isNotNull);
    expect(after.createdAt, DateTime(2026, 1, 1), reason: 'creation is not an edit');
  });

  test('an unedited subject is dated from when it was created', () {
    final SyncItem item = SyncItem.subject(
      Subject(
        name: 'Generic Course',
        colorValue: 0xFF336699,
        createdAt: DateTime(2026, 1, 1),
      ),
    );

    expect(item.changedAt, DateTime(2026, 1, 1));
  });

  // The row already exists, so the pull goes through `updateSubject` — which
  // is the branch `touch` guards and the one an earlier version of this test
  // missed entirely.
  test('a pulled change keeps the timestamp it arrived with', () async {
    final DateTime theirs = DateTime(2026, 4, 2, 10);
    await repo.insertSubject(
      Subject(
        name: 'Generic Course',
        colorValue: 0xFF336699,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final String uuid = (await only()).uuid!;

    final SyncCoordinator sync = SyncCoordinator(
      repository: repo,
      settings: SettingsService(),
      target: target,
    );
    // First run links the two sides, so the second can be a plain pull.
    await sync.run(force: true);

    target.remote = <RemoteState>[
      RemoteState(
        kind: SyncKind.subject,
        localKey: uuid,
        remoteId: uuid,
        hash: 'renamed-there',
        editedAt: theirs,
        fields: <String, Object?>{
          'name': 'Renamed There',
          'code': null,
          'teacher': null,
          'color': 0xFF336699,
          'targetPercent': null,
          'priorHeld': 0,
          'priorAttended': 0,
          'expectedTotal': null,
        },
      ),
    ];
    await sync.run(force: true);

    final Subject after = await only();
    expect(after.name, 'Renamed There', reason: 'the pull applied');
    expect(after.updatedAt, theirs);
  });
}
