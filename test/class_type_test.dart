import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/notion_export.dart';
import 'package:zeolite/domain/notion_import.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';
import 'fake_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ZeoliteRepository repo;
  late ProviderContainer container;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_class_type');
    appDb = AppDatabase.at('${dir.path}/a.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    container = ProviderContainer(
      overrides: [
        notificationsProvider.overrideWithValue(QuietNotifications()),
        repositoryProvider.overrideWithValue(repo),
        analyticsProvider.overrideWithValue(FakeAnalytics()),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  Future<int> typeNamed(String name) async => (await repo.getCategories())
      .firstWhere((ClassCategory c) => c.name == name)
      .id!;

  test('a lab slot in a lecture course is marked as a lab, and stays one',
      () async {
    final int lecture = await typeNamed('Lecture');
    final int practical = await typeNamed('Practical');
    final int subject = await repo.insertSubject(
      Subject(name: 'Generic Course', colorValue: 0xFF336699, categoryId: lecture),
    );
    final DateTime day = DateTime(2026, 9, 1);
    await repo.insertSlot(
      ClassSlot(
        subjectId: subject,
        weekday: day.weekday,
        startMinutes: 14 * 60,
        endMinutes: 16 * 60,
        categoryId: practical,
        startDate: DateTime(2026, 8, 1),
      ),
    );
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);

    final ClassSession session =
        container.read(scheduleEngineProvider)!.sessionsOn(day).single;
    expect(session.effectiveCategoryId, practical);

    await container
        .read(attendanceActionsProvider)
        .mark(session, AttendanceStatus.present);
    // Corrected from the log, which has no session to read the type from.
    await container.read(attendanceActionsProvider).setStatusAt(
          subjectId: subject,
          date: day,
          startMinutes: 14 * 60,
          current: AttendanceStatus.present,
          status: AttendanceStatus.absent,
        );

    final AttendanceRecord mark = (await repo.getAttendance()).single;
    expect(mark.status, AttendanceStatus.absent);
    expect(mark.categoryId, practical);
  });

  test('a lab filed inside its course keeps its own type from Notion',
      () async {
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);
    NotionRow row(int day, NotionKind kind, String label) => NotionRow.read(
          component: '',
          course: 'Generic Course',
          kind: kind,
          date: DateTime(2026, 9, day),
          status: 'Present',
          held: kind == NotionKind.practical ? 2 : 1,
          credit: kind == NotionKind.practical ? 2 : 1,
          kindLabel: label,
        );
    final NotionPlan plan = NotionPlan.from(
      export: NotionExport(
        rows: <NotionRow>[
          row(1, NotionKind.lecture, 'Lecture'),
          row(2, NotionKind.lecture, 'Lecture'),
          row(3, NotionKind.practical, 'Practical'),
        ],
        problems: const <String>[],
      ),
      grouping: NotionGrouping.grouped,
      subjects: const <Subject>[],
      slots: const <ClassSlot>[],
      records: const <AttendanceRecord>[],
    );

    expect(plan.typeWeights, <String, int>{'Lecture': 1, 'Practical': 2});
    await container.read(importActionsProvider).importNotionLog(
          plan.subjects,
          typeWeights: plan.typeWeights,
        );

    // A lab added later counts as this table counts its labs.
    final ClassCategory lab = (await repo.getCategories())
        .firstWhere((ClassCategory c) => c.name == 'Practical');
    expect(lab.weight, 2);
    final Subject course = (await repo.getSubjects()).single;
    expect(course.categoryId, await typeNamed('Lecture'));
    final Map<int, int?> types = <int, int?>{
      for (final AttendanceRecord r in await repo.getAttendance())
        r.date.day: r.categoryId,
    };
    // The lectures follow the course; only the lab says anything of its own.
    expect(types, <int, int?>{
      1: null,
      2: null,
      3: await typeNamed('Practical'),
    });
  });
}
