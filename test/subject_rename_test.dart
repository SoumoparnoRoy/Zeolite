import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

import 'fake_sync_target.dart';
import 'package:zeolite/domain/sync/sync_merge.dart';
import 'package:zeolite/domain/sync/sync_target.dart';

/// Two devices that have both renamed the same subject — the case schema v10
/// gave a subject its own edit date in order to settle.
const String _uuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';
final DateTime _created = DateTime(2026, 1, 5, 8);
final DateTime _early = DateTime(2026, 3, 4, 9);
final DateTime _late = DateTime(2026, 3, 4, 18);

SyncItem _here(String name, {DateTime? renamedAt}) => SyncItem.subject(
      Subject(
        uuid: _uuid,
        name: name,
        colorValue: 1,
        createdAt: _created,
        updatedAt: renamedAt,
      ),
    );

RemoteState _there(String name, {DateTime? renamedAt}) {
  final SyncItem item = _here(name);
  return RemoteState(
    kind: SyncKind.subject,
    localKey: _uuid,
    remoteId: _uuid,
    hash: item.hash,
    fields: item.fields,
    editedAt: renamedAt,
  );
}

SyncMergeRow _rowFor(SyncItem mine, RemoteState theirs) => SyncMergePlan.from(
      local: <SyncItem>[mine],
      remote: <RemoteState>[theirs],
    ).differing.single;

void main() {
  group('deciding which rename wins', () {
    test('the rename made later is the one the row opens on', () {
      expect(
        _rowFor(
          _here('Old name', renamedAt: _early),
          _there('New name', renamedAt: _late),
        ).newer,
        SyncSide.there,
      );

      expect(
        _rowFor(
          _here('New name', renamedAt: _late),
          _there('Old name', renamedAt: _early),
        ).newer,
        SyncSide.here,
      );
    });

    test('a subject never renamed here loses to one renamed there', () {
      // Falls back to creation; before v10 there was no date to fall back to.
      final SyncMergeRow row = _rowFor(
        _here('Original'),
        _there('Renamed there', renamedAt: _late),
      );

      expect(row.local!.changedAt, _created);
      expect(row.newer, SyncSide.there);
    });

    test('an undated account row cannot take a rename made here', () {
      expect(
        _rowFor(
          _here('Renamed here', renamedAt: _early),
          _there('Whatever it was'),
        ).newer,
        SyncSide.here,
      );
    });

    test('the same name on both sides is agreement, however it is dated', () {
      // Why the migration caused no re-push storm: the date sits outside the
      // hash, so one name is agreement however the two sides date it.
      final SyncMergePlan plan = SyncMergePlan.from(
        local: <SyncItem>[_here('Same name', renamedAt: _late)],
        remote: <RemoteState>[_there('Same name', renamedAt: _early)],
      );

      expect(plan.differing, isEmpty);
      expect(plan.agreed, hasLength(1));
    });
  });

  // What a second device actually hits, and what the merge screen never sees:
  // both sides linked and both renamed, so the run settles it alone.
  group('a run that finds both sides renamed', () {
    late Directory dir;
    late ZeoliteRepository repo;
    late SettingsService settings;
    late FakeSyncTarget target;
    AppDatabase? appDb;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      dir = await Directory.systemTemp.createTemp('zeolite_rename');
      appDb =
          AppDatabase.at('${dir.path}/rename.db', factory: databaseFactoryFfi);
      await appDb!.database;
      repo = ZeoliteRepository(db: appDb!);
      settings = SettingsService();
      target = FakeSyncTarget()..trustsPulls = true;
    });

    tearDown(() async {
      await appDb?.close();
      await dir.delete(recursive: true);
    });

    /// Renamed here, with a ledger still holding the last agreed name.
    Future<void> seedRenamedHere(DateTime renamedAt) async {
      final int id = await repo.insertSubject(
        Subject(
          uuid: _uuid,
          name: 'Agreed name',
          colorValue: 1,
          createdAt: _created,
        ),
      );
      final String agreedHash = _here('Agreed name').hash;
      await repo.updateSubject(
        Subject(
          id: id,
          uuid: _uuid,
          name: 'Renamed here',
          colorValue: 1,
          createdAt: _created,
          updatedAt: renamedAt,
        ),
        touch: false,
      );
      await repo.setRemoteLinks(<RemoteLink>[
        RemoteLink(
          target: 'fake',
          kind: SyncKind.subject,
          localKey: _uuid,
          remoteId: _uuid,
          localHash: agreedHash,
          remoteHash: agreedHash,
          origin: SyncOrigin.app,
        ),
      ]);
    }

    Future<SyncRunResult> run() => SyncCoordinator(
          repository: repo,
          settings: settings,
          target: target,
        ).run(force: true);

    Future<String> localName() async => (await repo.getSubjects()).single.name;

    test('the account wins when it renamed the subject later', () async {
      await seedRenamedHere(_early);
      target.remote = <RemoteState>[_there('Renamed there', renamedAt: _late)];

      final SyncRunResult result = await run();

      expect(await localName(), 'Renamed there');
      expect(result.pulled, 1);
    });

    test('this device keeps its name when it renamed the subject later',
        () async {
      await seedRenamedHere(_late);
      target.remote = <RemoteState>[_there('Renamed there', renamedAt: _early)];

      final SyncRunResult result = await run();

      expect(await localName(), 'Renamed here');
      // Counted as an overwrite, not a plain update — which is what says the
      // run went through the conflict branch and the far side's copy is gone.
      expect(result.overwritten, 1);
      expect(target.calls.any((String c) => c.startsWith('update')), isTrue);
    });
  });
}
