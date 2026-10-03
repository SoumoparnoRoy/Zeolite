import 'dart:convert';
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
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/room.dart';
import 'package:zeolite/data/models/slot_override.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/models/tag.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/services/backup_service.dart';

/// A backup is how attendance reaches a second device, so the subject uuid has
/// to survive the round trip. Reissuing it there would leave the same course
/// syncing under two identities, which no amount of conflict handling fixes.
void main() {
  late Directory dir;
  final List<Database> open = <Database>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_backup');
  });

  tearDown(() async {
    for (final Database db in open) {
      await db.close();
    }
    open.clear();
    await dir.delete(recursive: true);
  });

  Future<ZeoliteRepository> repoAt(String name) async {
    final AppDatabase appDb =
        AppDatabase.at('${dir.path}/$name.db', factory: databaseFactoryFfi);
    open.add(await appDb.database);
    return ZeoliteRepository(db: appDb);
  }

  test('a subject keeps its uuid across an export and a restore', () async {
    final ZeoliteRepository source = await repoAt('source');
    await source.insertSubject(
      const Subject(name: 'Generic Course', colorValue: 0xFF336699),
    );

    final List<Subject> before = await source.getSubjects();
    final String issued = before.single.uuid!;
    expect(issued, isNotEmpty);

    final String json =
        await BackupService(source, SettingsService()).exportToJsonString();
    expect(json, contains(issued));

    // A different database entirely, which is the case that was broken: the
    // restore rebuilt the subject field by field and left the uuid behind.
    final ZeoliteRepository target = await repoAt('target');
    await BackupService(target, SettingsService()).importFromJsonString(json);

    final List<Subject> after = await target.getSubjects();
    expect(after.single.uuid, issued);
  });

  test('a backup written before v8 is given a uuid on the way in', () async {
    final ZeoliteRepository source = await repoAt('source');
    final String json =
        await BackupService(source, SettingsService()).exportToJsonString();

    final Map<String, Object?> data = jsonDecode(json) as Map<String, Object?>;
    data['subjects'] = <Object?>[
      <String, Object?>{
        'id': 1,
        'name': 'Older Course',
        'color': 0xFF336699,
        'created_at': 1,
      },
    ];

    final ZeoliteRepository target = await repoAt('target');
    await BackupService(target, SettingsService())
        .importFromJsonString(jsonEncode(data));

    final List<Subject> after = await target.getSubjects();
    expect(after.single.uuid, isNotNull);
    expect(after.single.uuid, isNotEmpty);
  });

  test('a malformed backup leaves the current database untouched', () async {
    final ZeoliteRepository repository = await repoAt('target');
    await repository.insertSubject(
      const Subject(name: 'Keep me', colorValue: 0xFF336699),
    );
    final Map<String, Object?> data = <String, Object?>{
      'app': BackupService.appTag,
      'formatVersion': BackupService.formatVersion,
      'subjects': <Object?>[
        <String, Object?>{
          'id': 1,
          'name': 'Partially restored',
          'color': 0xFF112233,
        },
        <String, Object?>{
          'id': 2,
          'name': 'Invalid row',
          'color': 0xFF445566,
          'created_at': 'not a timestamp',
        },
      ],
    };

    final ImportResult result = await BackupService(
      repository,
      SettingsService(),
    ).importFromJsonString(jsonEncode(data));

    expect(result.success, isFalse);
    expect(result.outcome, ImportOutcome.failed);
    expect(
      (await repository.getSubjects()).map((Subject subject) => subject.name),
      <String>['Keep me'],
    );
  });

  test('a restore brings back every column, not just the ones it names',
      () async {
    final ZeoliteRepository source = await repoAt('full');
    final int lab = await source.insertCategory(
      const ClassCategory(name: 'Lab', defaultDurationMinutes: 120, weight: 2),
    );
    await source.insertRoom(const Room(name: 'Room 1'));
    final int proxy = await source.insertTag(const Tag(name: 'Proxy'));
    final int subject = await source.insertSubject(
      Subject(
        name: 'Subject 1',
        code: 'AAA1001',
        colorValue: 0xFF336699,
        categoryId: lab,
        priorHeld: 4,
        priorAttended: 3,
        expectedTotal: 40,
      ),
    );
    final int slot = await source.insertSlot(
      ClassSlot(
        subjectId: subject,
        weekday: 1,
        startMinutes: 540,
        endMinutes: 660,
        room: 'Room 1',
        weight: 2,
        categoryId: lab,
        startDate: DateTime(2026, 7, 13),
      ),
    );
    await source.insertSlotOverrides(<SlotOverride>[
      SlotOverride(slotId: slot, date: DateTime(2026, 7, 20), room: 'Room 2'),
    ]);
    await source.insertExtraClass(
      ExtraClass(
        subjectId: subject,
        date: DateTime(2026, 7, 22),
        startMinutes: 600,
        endMinutes: 660,
        note: 'Make-up',
      ),
    );
    await source.setManyAttendance(<AttendanceRecord>[
      AttendanceRecord(
        subjectId: subject,
        date: DateTime(2026, 7, 13),
        startMinutes: 540,
        status: AttendanceStatus.present,
        weight: 2,
        categoryId: lab,
        tagId: proxy,
        note: 'Signed late',
        markedAt: DateTime(2026, 7, 13, 11),
      ),
    ]);
    await source.insertHoliday(
      Holiday(date: DateTime(2026, 8, 15), name: 'Holiday 1'),
    );

    final String first =
        await BackupService(source, SettingsService()).exportToJsonString();
    final ZeoliteRepository target = await repoAt('copy');
    await BackupService(target, SettingsService()).importFromJsonString(first);
    final String second =
        await BackupService(target, SettingsService()).exportToJsonString();

    // Ids are reissued on the way in, so only they may differ. Anything else
    // that changes is a column the restore did not carry.
    Object? withoutIds(Object? node) => switch (node) {
          final Map<String, Object?> map => <String, Object?>{
              for (final MapEntry<String, Object?> e in map.entries)
                if (e.key != 'id' &&
                    !e.key.endsWith('_id') &&
                    e.key != 'exportedAt')
                  e.key: withoutIds(e.value),
            },
          final List<Object?> list => list.map(withoutIds).toList(),
          _ => node,
        };
    expect(withoutIds(jsonDecode(second)), withoutIds(jsonDecode(first)));
  });
}
