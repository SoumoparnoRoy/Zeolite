import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/slot_override.dart';
import 'package:zeolite/data/models/subject.dart';

/// Against real SQLite rather than a fake, because the two things worth
/// checking here are both the database's own doing: the unique index that keeps
/// one exception per week, and the cascade that clears them with their rule.
void main() {
  setUpAll(sqfliteFfiInit);

  final DateTime monday = DateTime(2026, 8, 3);
  late Directory dir;
  late ZeoliteRepository repo;
  late AppDatabase db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zeolite_overrides');
    db = AppDatabase.at('${dir.path}/app.db', factory: databaseFactoryFfi);
    repo = ZeoliteRepository(db: db);
    await repo.insertSubject(
      const Subject(id: 1, name: 'Physics', colorValue: 0xFF7C6BFF),
    );
  });

  tearDown(() async {
    await (await db.database).close();
    await dir.delete(recursive: true);
  });

  Future<int> aSlot() => repo.insertSlot(
        ClassSlot(
          subjectId: 1,
          weekday: DateTime.monday,
          startMinutes: 9 * 60,
          endMinutes: 10 * 60,
          room: 'R101',
          startDate: monday,
        ),
      );

  test('one exception per rule per week, the newest winning', () async {
    final int slotId = await aSlot();
    await repo.setSlotOverride(
      SlotOverride(slotId: slotId, date: monday, room: 'R204'),
    );
    await repo.setSlotOverride(
      SlotOverride(slotId: slotId, date: monday, room: 'R311'),
    );

    final List<SlotOverride> saved = await repo.getSlotOverrides();
    expect(saved, hasLength(1));
    expect(saved.single.room, 'R311');
  });

  test('a week edited back to match its rule stops being an exception',
      () async {
    final int slotId = await aSlot();
    await repo.setSlotOverride(
      SlotOverride(slotId: slotId, date: monday, room: 'R204'),
    );
    expect(await repo.getSlotOverrides(), hasLength(1));

    // Nothing left to say, so the row goes rather than sitting there as a
    // no-op that a later reader has to work out is harmless.
    await repo.setSlotOverride(SlotOverride(slotId: slotId, date: monday));

    expect(await repo.getSlotOverrides(), isEmpty);
  });

  test('deleting the rule takes its exceptions with it', () async {
    final int slotId = await aSlot();
    await repo.setSlotOverride(
      SlotOverride(slotId: slotId, date: monday, skipped: true),
    );
    await repo.setSlotOverride(
      SlotOverride(
        slotId: slotId,
        date: Dates.addDays(monday, 7),
        room: 'R204',
      ),
    );
    expect(await repo.getSlotOverrides(), hasLength(2));

    await repo.deleteSlot(slotId);

    expect(await repo.getSlotOverrides(), isEmpty);
  });

  test('every exception is given a uuid of its own', () async {
    final int slotId = await aSlot();
    await repo.setSlotOverride(
      SlotOverride(slotId: slotId, date: monday, room: 'R204'),
    );

    expect(await repo.getSlotOverrides(), hasLength(1));
    expect((await repo.getSlotOverrides()).single.uuid, isNotNull);
  });
}
