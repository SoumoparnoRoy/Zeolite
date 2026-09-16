import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/room.dart';
import 'package:zeolite/data/models/slot_override.dart';
import 'package:zeolite/data/models/subject.dart';

void main() {
  late Directory directory;
  late AppDatabase database;
  late ZeoliteRepository repository;
  late int slotId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zeolite_override_undo');
    database = AppDatabase.at(
      '${directory.path}/undo.db',
      factory: databaseFactoryFfi,
    );
    repository = ZeoliteRepository(db: database);
    final int subjectId = await repository.insertSubject(
      const Subject(name: 'Physics', colorValue: 0xFF6750A4),
    );
    slotId = await repository.insertSlot(
      ClassSlot(
        subjectId: subjectId,
        weekday: DateTime.monday,
        startMinutes: 540,
        endMinutes: 600,
        startDate: DateTime(2026, 9, 1),
      ),
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  SlotOverride exception() => SlotOverride(
        slotId: slotId,
        date: DateTime(2026, 9, 7),
        room: 'Lab 2',
      );

  test('an unrelated undo preserves an existing slot exception', () async {
    await repository.setSlotOverride(exception());
    final DatabaseSnapshot before = await repository.snapshot();

    await repository.insertRoom(const Room(name: 'Temporary'));
    await repository.restore(before);

    expect(await repository.getSlotOverrides(), hasLength(1));
    expect((await repository.getSlotOverrides()).single.room, 'Lab 2');
  });

  test('undoing creation of an exception removes it', () async {
    final DatabaseSnapshot before = await repository.snapshot();

    await repository.setSlotOverride(exception());
    await repository.restore(before);

    expect(await repository.getSlotOverrides(), isEmpty);
  });

  test('undoing a reset restores slot exceptions', () async {
    await repository.setSlotOverride(exception());
    final DatabaseSnapshot before = await repository.snapshot();

    await repository.clearAll();
    await repository.restore(before);

    expect(await repository.getSlotOverrides(), hasLength(1));
    expect(await repository.getSlots(), hasLength(1));
  });
}
