import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_merge.dart';
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
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
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

  SyncCoordinator coordinator() => SyncCoordinator(
        repository: repo,
        settings: SettingsService(),
        target: target,
      );

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

  test('a first run pushes every kind and a second one pushes nothing',
      () async {
    await seed(status: AttendanceStatus.present);

    final SyncRunResult first = await coordinator().run();
    expect(first.outcome, SyncRunOutcome.synced);
    // The subject, its mark, the settings row, and the three categories the
    // app seeds itself.
    expect(first.pushed, 6);

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

  test('a target is never asked to file a kind it does not keep', () async {
    await seed(status: AttendanceStatus.present);
    target.kinds = <SyncKind>{SyncKind.attendance};

    final SyncRunResult result = await coordinator().run();

    // Notion holds rows of classes and nothing else, so a room offered to it
    // has to be skipped outright rather than reported as filed.
    expect(result.outcome, SyncRunOutcome.synced);
    expect(target.calls.where((String c) => c.startsWith('create ')).length, 1);
    expect(
      await repo.getRemoteLinks(target.id, SyncKind.category),
      isEmpty,
    );
  });

  test('two runs at once file the mark one time, not twice', () async {
    await seed(status: AttendanceStatus.present);
    final SyncCoordinator sync = coordinator();
    final Completer<void> gate = Completer<void>();
    target.hold = gate.future;

    final Future<SyncRunResult> first = sync.run();
    final Future<SyncRunResult> second = sync.run();
    gate.complete();
    await Future.wait<SyncRunResult>(<Future<SyncRunResult>>[first, second]);

    // A second run reaching `create` before the first wrote its link is a
    // duplicate page nothing would clean up.
    expect(
      target.calls.where((String c) => c.startsWith('create ')).length,
      6,
    );
  });

  test('a mark made during a run is picked up by the run that follows',
      () async {
    final Subject subject = await seed(status: AttendanceStatus.present);
    final SyncCoordinator sync = coordinator();
    final Completer<void> gate = Completer<void>();
    target.holdCreate = gate.future;

    final Future<SyncRunResult> running = sync.run();
    // Past the local read, so what follows is invisible to this run.
    await target.reachedCreate.future;
    await repo.setAttendance(
      AttendanceRecord(
        subjectId: subject.id!,
        date: _day,
        startMinutes: 600,
        status: AttendanceStatus.absent,
        markedAt: _late,
      ),
    );
    final Future<SyncRunResult> joined = sync.run();
    target.holdCreate = null;
    gate.complete();
    await running;

    // A shared result cannot hold the later mark; the owed re-run does.
    expect((await joined).pushed, (await running).pushed);
    await _settle(() async =>
        (await repo.getRemoteLinks(target.id, SyncKind.attendance)).length ==
        2);
    expect(
      await repo.getRemoteLinks(target.id, SyncKind.attendance),
      hasLength(2),
    );
  });

  test('a merge answer waits for its own run rather than joining one',
      () async {
    final Subject subject = await seed(status: AttendanceStatus.present);
    target.remote = <RemoteState>[
      mark(subject.uuid!, status: 'absent', editedAt: _late),
    ];
    final SyncCoordinator sync = coordinator();
    final Completer<void> gate = Completer<void>();
    target.hold = gate.future;

    final Future<SyncRunResult> asking = sync.run();
    final Future<SyncRunResult> answering = sync.run(
      force: true,
      merge: <String, SyncSide>{
        SyncItem.keyFor(subject.uuid!, _day, 540): SyncSide.here,
      },
    );
    target.hold = null;
    gate.complete();

    expect((await asking).outcome, SyncRunOutcome.reviewNeeded);
    // Folding this into the run above would have dropped the decision and
    // asked the user the same question again.
    expect((await answering).outcome, SyncRunOutcome.synced);
  });

  test('a merge decision to keep the account overrides the local row',
      () async {
    final Subject subject = await seed(
      status: AttendanceStatus.present,
      markedAt: _late,
    );
    final String key = SyncItem.keyFor(subject.uuid!, _day, 540);
    target.remote = <RemoteState>[
      mark(subject.uuid!, status: 'absent', editedAt: _early),
    ];

    // Deliberately against the newer side, so only the decision can explain
    // the result.
    final SyncRunResult result = await coordinator().run(
      merge: <String, SyncSide>{key: SyncSide.there},
    );

    expect(result.outcome, SyncRunOutcome.synced);
    expect(
      (await repo.getAttendanceAt(subject.id!, _day, 540))?.status,
      AttendanceStatus.absent,
    );
  });

  test('answering the merge stops it being asked again', () async {
    final Subject subject = await seed(status: AttendanceStatus.present);
    target.remote = <RemoteState>[
      mark(subject.uuid!, status: 'absent', editedAt: _late),
    ];

    final SyncCoordinator sync = coordinator();
    expect((await sync.run()).outcome, SyncRunOutcome.reviewNeeded);

    final SyncRunResult merged = await sync.run(
      force: true,
      merge: <String, SyncSide>{
        SyncItem.keyFor(subject.uuid!, _day, 540): SyncSide.here,
      },
    );

    expect(merged.outcome, SyncRunOutcome.synced);
    // A ledger now exists, so an ordinary run no longer sees a first run.
    target.remote = <RemoteState>[];
    expect((await sync.run(force: true)).outcome, SyncRunOutcome.synced);
  });

  test('a merge preview reads both sides and writes nothing', () async {
    final Subject subject = await seed(status: AttendanceStatus.present);
    target.remote = <RemoteState>[
      mark(subject.uuid!, status: 'absent', editedAt: _late),
    ];

    final SyncMergePlan? plan = await coordinator().previewMerge();

    expect(plan!.differing, hasLength(1));
    expect(target.calls.where((String c) => c != 'fetch'), isEmpty);
    expect(await repo.getRemoteLinks(target.id, SyncKind.attendance), isEmpty);
  });

  test('a preview against an unreadable account offers no merge', () async {
    await seed(status: AttendanceStatus.present);
    target.remote = null;

    expect(await coordinator().previewMerge(), isNull);
  });

  test('a timetable reaches a second device with its classes intact', () async {
    // What the account holds: one course, one weekly class naming it, one
    // holiday and one class type. The device has none of it.
    const String uuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';
    const String slotUuid = 'ccccccccddddeeeeffff000011112222';
    target.remote = <RemoteState>[
      subjectRow(uuid),
      RemoteState(
        kind: SyncKind.category,
        localKey: 'Lecture',
        remoteId: 'Lecture',
        hash: 'c',
        fields: const <String, Object?>{'defaultMinutes': 50},
      ),
      RemoteState(
        kind: SyncKind.holiday,
        localKey: '20260315',
        remoteId: '20260315',
        hash: 'h',
        fields: const <String, Object?>{'name': 'Reading week'},
      ),
      RemoteState(
        kind: SyncKind.slot,
        localKey: slotUuid,
        remoteId: slotUuid,
        hash: 's',
        fields: const <String, Object?>{
          'subject': uuid,
          'weekday': DateTime.tuesday,
          'startMinutes': 540,
          'endMinutes': 600,
          'room': 'R101',
          'weight': 1,
          'startDate': 20260301,
          'endDate': null,
        },
      ),
    ];

    final SyncRunResult result = await coordinator().run();
    expect(result.outcome, SyncRunOutcome.synced);

    // The slot is the point: without it the marks have no occurrences to
    // attach to and the device shows a term of empty days.
    final ClassSlot slot = (await repo.getSlots()).single;
    final Subject subject = (await repo.getSubjects()).single;
    expect(slot.subjectId, subject.id);
    expect(slot.weekday, DateTime.tuesday);
    expect(slot.startMinutes, 540);
    expect(slot.uuid, slotUuid);

    expect((await repo.getHolidays()).single.name, 'Reading week');
  });

  test('a course keeps the class type it was filed under', () async {
    const String uuid = 'aaaaaaaabbbbccccddddeeeeeeeeeeee';
    target.remote = <RemoteState>[
      RemoteState(
        kind: SyncKind.category,
        localKey: 'Seminar',
        remoteId: 'Seminar',
        hash: 'c',
        fields: const <String, Object?>{'defaultMinutes': 90},
      ),
      RemoteState(
        kind: SyncKind.subject,
        localKey: uuid,
        remoteId: uuid,
        hash: 'subject-hash',
        fields: const <String, Object?>{
          'name': 'Generic Course',
          'color': 0xFF336699,
          'category': 'Seminar',
        },
      ),
    ];

    await coordinator().run();

    // Categories sync before subjects precisely so this lookup succeeds.
    final Subject subject = (await repo.getSubjects()).single;
    final ClassCategory category = (await repo.getCategories())
        .firstWhere((ClassCategory c) => c.name == 'Seminar');
    expect(subject.categoryId, category.id);
  });

  test('a field nobody uses does not make every row look changed', () async {
    // The upgrade case: the payload gained `category` and `tag`, and a row
    // that uses neither must still match what was pushed before they existed.
    final SyncItem before = SyncItem(
      kind: SyncKind.subject,
      localKey: 'x',
      fields: const <String, Object?>{'name': 'Generic Course'},
    );
    final SyncItem after = SyncItem(
      kind: SyncKind.subject,
      localKey: 'x',
      fields: const <String, Object?>{
        'name': 'Generic Course',
        'category': null,
      },
    );

    expect(after.hash, before.hash);
  });
}

/// The owed re-run hands back no future, so it is waited for by its effect.
Future<void> _settle(Future<bool> Function() done) async {
  for (int i = 0; i < 50; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
