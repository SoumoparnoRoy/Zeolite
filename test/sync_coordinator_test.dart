import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

import 'fake_sync_target.dart';

final DateTime _day = DateTime(2026, 3, 4);
final DateTime _early = DateTime(2026, 3, 4, 9);
final DateTime _late = DateTime(2026, 3, 4, 18);

void main() {
  late Directory dir;
  late ZeoliteRepository repo;
  late FakeSyncTarget target;
  Database? open;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zeolite_sync');
    final AppDatabase appDb =
        AppDatabase.at('${dir.path}/sync.db', factory: databaseFactoryFfi);
    open = await appDb.database;
    repo = ZeoliteRepository(db: appDb);
    target = FakeSyncTarget()..trustsPulls = true;
  });

  tearDown(() async {
    await open?.close();
    await dir.delete(recursive: true);
  });

  SyncCoordinator coordinator() =>
      SyncCoordinator(repository: repo, target: target);

  /// One subject with one mark, which is the smallest thing worth syncing.
  Future<Subject> seed({AttendanceStatus? status, DateTime? markedAt}) async {
    final int id = await repo.insertSubject(
      const Subject(name: 'Generic Course', colorValue: 0xFF336699),
    );
    if (status != null) {
      await repo.setAttendance(
        AttendanceRecord(
          subjectId: id,
          date: _day,
          startMinutes: 540,
          status: status,
          markedAt: markedAt ?? _early,
        ),
      );
    }
    return (await repo.getSubjects()).single;
  }

  RemoteState subjectRow(String uuid) => RemoteState(
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
        editedAt: _early,
      );

  RemoteState mark(
    String uuid, {
    String status = 'present',
    int weight = 1,
    DateTime? editedAt,
    bool deleted = false,
  }) {
    final String key = SyncItem.keyFor(uuid, _day, 540);
    final Map<String, Object?> fields = <String, Object?>{
      'status': status,
      'weight': weight,
      'note': null,
    };
    return RemoteState(
      kind: SyncKind.attendance,
      localKey: key,
      remoteId: key,
      hash: deleted
          ? 'deleted'
          : SyncItem(
              kind: SyncKind.attendance,
              localKey: key,
              fields: fields,
            ).hash,
      fields: deleted ? const <String, Object?>{} : fields,
      editedAt: editedAt,
      deleted: deleted,
    );
  }

  test('a first run pushes both kinds and a second one pushes nothing',
      () async {
    await seed(status: AttendanceStatus.present);

    final SyncRunResult first = await coordinator().run();
    expect(first.outcome, SyncRunOutcome.synced);
    expect(first.pushed, 2);

    // The subject has to reach the target before the mark that is keyed on it.
    expect(target.calls.indexWhere((String c) => c.startsWith('create ')),
        lessThan(target.calls.lastIndexWhere((String c) => c.contains(':'))));

    target.remote = <RemoteState>[];
    final SyncRunResult second = await coordinator().run();
    expect(second.pushed, 0);
    expect(second.outcome, SyncRunOutcome.synced);
  });

  test('deleting a mark archives it and forgets the link', () async {
    final Subject subject = await seed(status: AttendanceStatus.present);
    await coordinator().run();

    await repo.clearAttendance(subject.id!, _day, 540);
    final SyncRunResult result = await coordinator().run();

    expect(result.archived, 1);
    expect(await repo.getRemoteLinks(target.id, SyncKind.attendance), isEmpty);
  });

  test('a fresh install takes the whole account down', () async {
    const String uuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';
    target.remote = <RemoteState>[
      subjectRow(uuid),
      mark(uuid, editedAt: _early),
    ];

    final SyncRunResult result = await coordinator().run();

    expect(result.outcome, SyncRunOutcome.synced);
    expect(result.pulled, 2);

    final Subject written = (await repo.getSubjects()).single;
    expect(written.uuid, uuid);
    expect(
      (await repo.getAttendanceAt(written.id!, _day, 540))?.status,
      AttendanceStatus.present,
    );
    expect(
      (await repo.getRemoteLinks(target.id, SyncKind.attendance))
          .single
          .localKey,
      SyncItem.keyFor(uuid, _day, 540),
    );
  });

  test('a tombstone removes the mark instead of importing it', () async {
    final Subject subject = await seed(status: AttendanceStatus.present);
    await coordinator().run();

    target.remote = <RemoteState>[mark(subject.uuid!, deleted: true)];
    final SyncRunResult result = await coordinator().run();

    expect(result.pulled, 1);
    expect(await repo.getAttendanceAt(subject.id!, _day, 540), isNull);
    expect(await repo.getRemoteLinks(target.id, SyncKind.attendance), isEmpty);
  });

  test('the later edit wins on a target holding only this app writes',
      () async {
    final Subject subject = await seed(
      status: AttendanceStatus.present,
      markedAt: _early,
    );
    await coordinator().run();

    // Changed here and there since that run: absent locally, cancelled there.
    await repo.setAttendance(
      AttendanceRecord(
        subjectId: subject.id!,
        date: _day,
        startMinutes: 540,
        status: AttendanceStatus.absent,
        markedAt: _early,
      ),
    );
    target.remote = <RemoteState>[
      mark(subject.uuid!, status: 'cancelled', editedAt: _late),
    ];

    final SyncRunResult result = await coordinator().run();

    expect(result.pulled, 1);
    expect(result.overwritten, 0);
    expect(
      (await repo.getAttendanceAt(subject.id!, _day, 540))?.status,
      AttendanceStatus.cancelled,
    );
  });

  test('an older remote edit is overwritten and counted', () async {
    final Subject subject = await seed(
      status: AttendanceStatus.present,
      markedAt: _late,
    );
    await coordinator().run();

    await repo.setAttendance(
      AttendanceRecord(
        subjectId: subject.id!,
        date: _day,
        startMinutes: 540,
        status: AttendanceStatus.absent,
        markedAt: _late,
      ),
    );
    target.remote = <RemoteState>[
      mark(subject.uuid!, status: 'cancelled', editedAt: _early),
    ];

    final SyncRunResult result = await coordinator().run();

    expect(result.overwritten, 1);
    expect(
      (await repo.getAttendanceAt(subject.id!, _day, 540))?.status,
      AttendanceStatus.absent,
    );
  });

  test('a first run with data on both sides merges nothing', () async {
    final Subject subject = await seed(status: AttendanceStatus.present);
    target.remote = <RemoteState>[
      mark(subject.uuid!, status: 'absent', editedAt: _late),
    ];

    final SyncRunResult result = await coordinator().run();

    expect(result.outcome, SyncRunOutcome.reviewNeeded);
    expect(result.review, isNotEmpty);
    expect(target.calls.where((String c) => c != 'fetch'), isEmpty);
    expect(
      (await repo.getAttendanceAt(subject.id!, _day, 540))?.status,
      AttendanceStatus.present,
    );
    expect(await repo.getRemoteLinks(target.id, SyncKind.attendance), isEmpty);
  });

  test('going offline ends the run and holds the next one back', () async {
    await seed(status: AttendanceStatus.present);
    target.failNext = SyncFailure.offline;

    final SyncCoordinator sync = coordinator();
    final SyncRunResult result = await sync.run();

    expect(result.outcome, SyncRunOutcome.failed);
    expect(result.failure, SyncFailure.offline);
    expect(sync.canRunNow(), isFalse);
    expect((await sync.run()).outcome, SyncRunOutcome.deferred);
  });
}
