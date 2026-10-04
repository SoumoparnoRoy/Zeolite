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
/// only the balance can be typed over and a tap is a mark with no time.
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

    test(
        'plus files a mark with no time under today, and minus takes the '
        'newest back before the balance, never a timed mark', () async {
      final int id = await repo.insertSubject(
        const Subject(
          name: 'Course 1',
          colorValue: 0xFF336699,
          priorHeld: 1,
          priorAttended: 1,
        ),
      );
      final DateTime today = Dates.today();
      await repo.setAttendance(
        AttendanceRecord(
          subjectId: id,
          date: today,
          startMinutes: 9 * 60,
          status: AttendanceStatus.present,
        ),
      );
      final CountActions actions = container.read(countActionsProvider);
      const AttendanceStatus present = AttendanceStatus.present;

      await actions.add(await current(), present);
      await actions.add(await current(), present);
      expect(
        (await repo.getAttendance())
            .map((AttendanceRecord r) => r.startMinutes)
            .toList()
          ..sort(),
        <int>[-2, -1, 9 * 60],
      );
      expect((await current()).totalOf(present), 4);

      await actions.remove(await current(), present);
      expect(await repo.getAttendanceAt(id, today, -2), isNull);
      expect(await repo.getAttendanceAt(id, today, -1), isNotNull);

      await actions.remove(await current(), present);
      await actions.remove(await current(), present);
      // The balance went once the counted marks had.
      expect((await repo.getSubjects()).single.priorAttended, 0);

      final SubjectCounts left = await current();
      expect(left.totalOf(present), 1);
      expect(left.canRemove(present), isFalse);
      await actions.remove(left, present);
      expect(await repo.getAttendanceAt(id, today, 9 * 60), isNotNull);
    });
  });
}
