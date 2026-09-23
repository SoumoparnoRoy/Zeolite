import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/class_category.dart';
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
    dir = await Directory.systemTemp.createTemp('zeolite_notion_undo');
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

  test('imported subjects get a type, reusing one of the same name', () async {
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);
    NotionRow row(String course, NotionKind kind, String label) =>
        NotionRow.read(
          component: '',
          course: course,
          kind: kind,
          date: DateTime(2026, 9, 1),
          status: 'Present',
          held: 1,
          credit: 1,
          kindLabel: label,
        );
    final NotionPlan plan = NotionPlan.from(
      export: NotionExport(
        rows: <NotionRow>[
          row('Generic Course', NotionKind.lecture, 'lecture'),
          row('Another Course', NotionKind.practical, 'Lab'),
        ],
        problems: const <String>[],
      ),
      grouping: NotionGrouping.grouped,
      subjects: const <Subject>[],
      slots: const <ClassSlot>[],
      records: const <AttendanceRecord>[],
    );

    await container.read(importActionsProvider).importNotionLog(plan.subjects);

    final List<ClassCategory> categories = await repo.getCategories();
    final List<Subject> subjects = await repo.getSubjects();
    String? nameOf(String subject) {
      final int? id =
          subjects.firstWhere((Subject s) => s.name == subject).categoryId;
      return categories
          .where((ClassCategory c) => c.id == id)
          .firstOrNull
          ?.name;
    }

    // The installed "Lecture", not a second one; "Lab" had none to reuse.
    expect(nameOf('Generic Course'), 'Lecture');
    expect(nameOf('Another Course'), 'Lab');
    expect(
      categories.where((ClassCategory c) => c.name.toLowerCase() == 'lecture'),
      hasLength(1),
    );
  });

  test('undoing an import puts the cancelled setting back with the marks',
      () async {
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);
    final NotionPlan plan = NotionPlan.from(
      export: NotionExport(
        rows: <NotionRow>[
          NotionRow.read(
            component: 'GEN101L',
            course: 'Generic Course',
            kind: NotionKind.lecture,
            date: DateTime(2026, 9, 1),
            status: 'Cancelled',
            held: 1,
            credit: 1,
          ),
        ],
        problems: const <String>[],
      ),
      grouping: NotionGrouping.grouped,
      subjects: const <Subject>[],
      slots: const <ClassSlot>[],
      records: const <AttendanceRecord>[],
    );

    await container.read(importActionsProvider).importNotionLog(
          plan.subjects,
          cancelledCounts: plan.countsCancelled,
        );
    expect(
      (await container.read(settingsProvider.future))
          .cancelledCountsAsAttended,
      isTrue,
    );
    expect(
      (await repo.getAttendance()).single.status,
      AttendanceStatus.cancelled,
    );

    final int token = container.read(actionCoreProvider).pendingUndoToken!;
    await container.read(actionCoreProvider).undo(token);

    expect(await repo.getAttendance(), isEmpty);
    expect(
      (await container.read(settingsProvider.future))
          .cancelledCountsAsAttended,
      isFalse,
    );
  });
}
