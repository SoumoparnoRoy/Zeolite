import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/slot_override.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

import 'fake_sync_target.dart';

final DateTime _term = DateTime(2026, 3, 2);
final DateTime _week = DateTime(2026, 3, 10);

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
    dir = await Directory.systemTemp.createTemp('zeolite_override_sync');
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

  /// A Tuesday rule for an exception to hang off.
  Future<ClassSlot> seedRule() async {
    final int subjectId = await repo.insertSubject(
      const Subject(name: 'Generic Course', colorValue: 0xFF336699),
    );
    await repo.insertSlot(
      ClassSlot(
        subjectId: subjectId,
        weekday: DateTime.tuesday,
        startMinutes: 540,
        endMinutes: 600,
        room: 'B204',
        startDate: _term,
      ),
    );
    return (await repo.getSlots()).single;
  }

  RemoteState overrideRow(
    String slotUuid, {
    bool skipped = false,
    int? startMinutes,
    String? room,
  }) {
    final String key = SyncItem.overrideKeyFor(slotUuid, _week);
    final Map<String, Object?> fields = <String, Object?>{
      'skipped': skipped,
      'subject': null,
      'startMinutes': startMinutes,
      'endMinutes': null,
      'room': room,
    };
    return RemoteState(
      kind: SyncKind.slotOverride,
      localKey: key,
      remoteId: key,
      hash: SyncItem(
        kind: SyncKind.slotOverride,
        localKey: key,
        fields: fields,
      ).hash,
      fields: fields,
    );
  }

  Future<List<RemoteLink>> overrideLinks() =>
      repo.getRemoteLinks(target.id, SyncKind.slotOverride);

  test('an exception travels under its rule and its week', () async {
    final ClassSlot slot = await seedRule();
    await repo.setSlotOverride(
      SlotOverride(slotId: slot.id!, date: _week, room: 'B415'),
    );

    await coordinator().run();

    expect(
      overrideLinks().then((List<RemoteLink> l) => l.single.localKey),
      completion('${slot.uuid}:${Dates.keyOf(_week)}'),
    );
  });

  test('a second device inherits everything the exception leaves out',
      () async {
    final ClassSlot slot = await seedRule();
    await coordinator().run();

    target.remote = <RemoteState>[overrideRow(slot.uuid!, room: 'B415')];
    final SyncRunResult result = await coordinator().run();

    expect(result.pulled, 1);
    final SlotOverride written = (await repo.getSlotOverrides()).single;
    expect(written.room, 'B415');
    // Null is the whole point: the occurrence keeps the rule's time, so a
    // later edit to the rule still moves it.
    expect(written.startMinutes, isNull);
    expect(written.applyTo(slot)?.startMinutes, 540);
  });

  test('a skipped week arrives as a skip', () async {
    final ClassSlot slot = await seedRule();
    await coordinator().run();

    target.remote = <RemoteState>[overrideRow(slot.uuid!, skipped: true)];
    await coordinator().run();

    final SlotOverride written = (await repo.getSlotOverrides()).single;
    expect(written.skipped, isTrue);
    expect(written.applyTo(slot), isNull);
  });

  test('an exception to a rule this device does not hold is left alone',
      () async {
    await coordinator().run();

    target.remote = <RemoteState>[
      overrideRow('aaaaaaaabbbbccccddddeeeeeeeeeeee', room: 'B415'),
    ];
    await coordinator().run();

    expect(await repo.getSlotOverrides(), isEmpty);
    expect(await overrideLinks(), isEmpty);
  });

  test('undoing an exception takes the remote row with it', () async {
    final ClassSlot slot = await seedRule();
    await repo.setSlotOverride(
      SlotOverride(slotId: slot.id!, date: _week, room: 'B415'),
    );
    await coordinator().run();

    await repo.clearSlotOverride(slot.id!, _week);
    final SyncRunResult result = await coordinator().run();

    expect(result.archived, 1);
    expect(await overrideLinks(), isEmpty);
  });
}
