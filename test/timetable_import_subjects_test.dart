import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/day_grid.dart';
import 'package:zeolite/domain/timetable_import.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';
import 'fake_notifications.dart';

const DayGrid _noGrid = DayGrid(
  dayStartMinutes: 9 * 60,
  dayEndMinutes: 17 * 60,
  blockMinutes: 0,
);

TimetableImportResult _parse(String text, {bool byCourse = false}) =>
    TimetableImport.parse(text, grid: _noGrid, byCourse: byCourse);

const List<ExistingSubject> _held = <ExistingSubject>[
  (id: 1, name: 'Course 1', code: 'AAA101L'),
  (id: 2, name: 'Course 1 Lab', code: 'AAA101P'),
  (id: 3, name: 'Course 2', code: 'BBB202'),
];

void main() {
  group('finding a subject the device already has', () {
    test('by name, then code, then code without its letter', () {
      expect(TimetableImport.existingFor('course 1 lab', _held), 2);
      expect(TimetableImport.existingFor('AAA101L', _held), 1);
      expect(TimetableImport.existingFor('BBB202T', _held), 3);
      expect(TimetableImport.existingFor('CCC303L', _held), isNull);
    });

    test('two subjects that fit equally are left for the student', () {
      // Grouped under its course, the sheet says AAA101 for both of them.
      expect(TimetableImport.existingFor('AAA101', _held), isNull);
    });

    test('a class filed under its course keeps its letter', () {
      final TimetableImportResult result = _parse(
        'BBB202L, Mo, 09:00-10:00\nBBB202T, Tu, 09:00-10:00',
        byCourse: true,
      );
      expect(result.subjectNames, <String>['BBB202']);
      expect(result.classes.map((ImportedClass c) => c.letter),
          <String>['L', 'T']);
    });

    test('the split starts the way the subjects here are already split', () {
      // AAA101L and AAA101P are one course kept apart, which outweighs
      // BBB202 being coded bare.
      expect(TimetableImport.groupedLike(_held), isFalse);
      expect(TimetableImport.groupedLike(_held.sublist(2)), isTrue);
      expect(TimetableImport.groupedLike(const <ExistingSubject>[]), isNull);
    });

    test('two sheet subjects sent to one subject cannot share a slot', () {
      final TimetableImportResult result = _parse(
        'BBB202L, Mo, 09:00-10:00\nBBB202T, Mo, 09:00-10:00\n'
        'BBB202T, Tu, 11:00-12:00',
      );
      final List<ImportedClass> clashes = TimetableImport.clashesInto(
        result,
        <String, int>{'bbb202l': 3, 'bbb202t': 3},
        held: const <({int subjectId, int weekday, int startMinutes})>[
          (subjectId: 3, weekday: DateTime.tuesday, startMinutes: 11 * 60),
        ],
      );
      expect(
        clashes.map((ImportedClass c) => (c.subjectName, c.weekday)),
        <(String, int)>[
          ('BBB202T', DateTime.monday),
          ('BBB202T', DateTime.tuesday),
        ],
      );
    });
  });

  group('importing into subjects already here', () {
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
      dir = await Directory.systemTemp.createTemp('zeolite_tt_subjects');
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

    test('joins the chosen subject, makes only the rest, and types by letter',
        () async {
      for (final ClassCategory c in ClassCategory.defaults) {
        if ((await repo.getCategories()).every((ClassCategory x) =>
            x.name != c.name)) {
          await repo.insertCategory(c);
        }
      }
      final int lecture = (await repo.getCategories())
          .firstWhere((ClassCategory c) => c.name == 'Lecture')
          .id!;
      final int tutorial = (await repo.getCategories())
          .firstWhere((ClassCategory c) => c.name == 'Tutorial')
          .id!;
      final int practical = (await repo.getCategories())
          .firstWhere((ClassCategory c) => c.name == 'Practical')
          .id!;
      final int course = await repo.insertSubject(Subject(
        name: 'Course 2',
        code: 'BBB202',
        colorValue: 0,
        categoryId: lecture,
      ));
      await container.read(settingsProvider.future);
      await container.read(timetableProvider.future);

      await container.read(importActionsProvider).importTimetable(
            _parse('BBB202L, Mo, 09:00-10:00\nBBB202T, Tu, 09:00-10:00\n'
                'CCC303P, We, 09:00-11:00'),
            into: <String, int>{'bbb202l': course, 'bbb202t': course},
          );

      final List<Subject> subjects = await repo.getSubjects();
      expect(subjects.map((Subject s) => s.name),
          unorderedEquals(<String>['Course 2', 'CCC303P']));
      final Subject made =
          subjects.firstWhere((Subject s) => s.name == 'CCC303P');
      expect(made.categoryId, practical);

      final List<ClassSlot> slots = await repo.getSlots();
      ClassSlot on(int weekday) =>
          slots.firstWhere((ClassSlot s) => s.weekday == weekday);
      expect(on(DateTime.monday).subjectId, course);
      expect(on(DateTime.monday).categoryId, isNull);
      expect(on(DateTime.tuesday).subjectId, course);
      expect(on(DateTime.tuesday).categoryId, tutorial);
      expect(on(DateTime.wednesday).subjectId, made.id);
      expect(on(DateTime.wednesday).categoryId, isNull);
    });
  });
}
