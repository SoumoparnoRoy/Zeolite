import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/domain/subject_counts.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';
import 'fake_notifications.dart';

/// The Counts page: three totals made of marks plus a carried balance, where
/// taps and typed totals both move only the balance.
void main() {
  SubjectCounts countsOf(
    Subject subject, {
    int present = 0,
    int absent = 0,
    int cancelled = 0,
    bool cancelledCounts = false,
  }) =>
      SubjectCounts(
        stats: SubjectStats(
          subject: subject,
          present: present,
          absent: absent,
          cancelled: cancelled,
          target: 0.75,
          plannedFromSlots: 0,
          cancelledCounts: cancelledCounts,
        ),
      );

  group('a typed total', () {
    const Subject carried = Subject(
      id: 1,
      name: 'Course 1',
      colorValue: 0xFF336699,
      priorHeld: 10,
      priorAttended: 8,
    );

    test('moves only the carried part and leaves the other figures', () {
      final SubjectCounts counts = countsOf(carried, present: 5, absent: 1);
      expect(counts.totalOf(AttendanceStatus.present), 13);
      expect(counts.totalOf(AttendanceStatus.absent), 3);

      final Subject attended = counts.withTotal(AttendanceStatus.present, 20)!;
      expect(attended.priorAttended, 15);
      // Missed stays at 3: two carried plus the one marked.
      expect(attended.priorHeld - attended.priorAttended, 2);

      final Subject missed = counts.withTotal(AttendanceStatus.absent, 7)!;
      expect(missed.priorAttended, 8);
      expect(missed.priorHeld, 14);
    });

    test('cannot go below what is marked in the app', () {
      final SubjectCounts counts = countsOf(carried, present: 5);
      expect(counts.withTotal(AttendanceStatus.present, 4), isNull);
      expect(counts.withTotal(AttendanceStatus.present, 5)!.priorAttended, 0);
    });
  });

  test('carried cancelled classes count only where the setting says', () {
    const Subject subject = Subject(
      id: 1,
      name: 'Course 1',
      colorValue: 0xFF336699,
      priorHeld: 8,
      priorAttended: 6,
      priorCancelled: 2,
    );
    final SubjectStats off = countsOf(subject, cancelled: 1).stats;
    expect(off.cancelledTotal, 3);
    expect(off.held, 8);
    expect(off.attended, 6);

    final SubjectStats on =
        countsOf(subject, cancelled: 1, cancelledCounts: true).stats;
    expect(on.held, 11);
    expect(on.attended, 9);
  });

  group('the steps', () {
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
      dir = await Directory.systemTemp.createTemp('zeolite_counts');
      appDb = AppDatabase.at('${dir.path}/c.db', factory: databaseFactoryFfi);
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

    Future<SubjectCounts> current() async {
      await container.read(settingsProvider.future);
      await container.read(timetableProvider.future);
      return container.read(subjectCountsProvider).single;
    }

    test('plus and minus move the carried balance, never a mark', () async {
      final int id = await repo.insertSubject(
        const Subject(name: 'Course 1', colorValue: 0xFF336699),
      );
      await repo.setAttendance(
        AttendanceRecord(
          subjectId: id,
          date: Dates.today(),
          startMinutes: 9 * 60,
          status: AttendanceStatus.present,
        ),
      );
      await current();
      final CountActions actions = container.read(countActionsProvider);

      await actions.add(id, AttendanceStatus.present);
      await actions.add(id, AttendanceStatus.absent);
      await actions.add(id, AttendanceStatus.cancelled);
      Subject saved = (await repo.getSubjects()).single;
      expect(saved.priorAttended, 1);
      expect(saved.priorHeld, 2);
      expect(saved.priorCancelled, 1);
      expect(await repo.getAttendance(), hasLength(1));

      await actions.remove(id, AttendanceStatus.present);
      await actions.remove(id, AttendanceStatus.present);
      saved = (await repo.getSubjects()).single;
      expect(saved.priorAttended, 0);
      expect(saved.priorHeld, 1, reason: 'the missed one stays');
      expect((await current()).totalOf(AttendanceStatus.present), 1);
      expect(await repo.getAttendance(), hasLength(1));
    });

    test('quick taps each count, however fast they come', () async {
      final int id = await repo.insertSubject(
        const Subject(name: 'Course 1', colorValue: 0xFF336699),
      );
      await current();
      final CountActions actions = container.read(countActionsProvider);

      await Future.wait(<Future<void>>[
        actions.add(id, AttendanceStatus.present),
        actions.add(id, AttendanceStatus.present),
        actions.add(id, AttendanceStatus.present),
      ]);
      expect((await repo.getSubjects()).single.priorAttended, 3);

      await Future.wait(<Future<void>>[
        actions.remove(id, AttendanceStatus.present),
        actions.remove(id, AttendanceStatus.present),
      ]);
      expect((await repo.getSubjects()).single.priorAttended, 1);
    });
  });
}
