import 'dart:async';
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
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/state/home_widget_providers.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';
import 'fake_notifications.dart';

class _CountingNotifications extends QuietNotifications {
  int laidDown = 0;

  @override
  Future<void> rescheduleAll({
    required AppSettings settings,
    required List<ClassSession> upcoming,
    required List<ClassSession> eveningSessions,
    required OverallStats stats,
  }) async {
    laidDown++;
  }
}

class _FailingRepository extends ZeoliteRepository {
  _FailingRepository({required super.db});

  @override
  Future<void> setAttendance(AttendanceRecord record) =>
      throw StateError('disk full');
}

/// A widget tap may already be drawn as made before Dart wakes, so whatever
/// becomes of it here, the widget has to be redrawn from the database — and
/// soon, which is why the reminders wait until after.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late AppDatabase appDb;
  late ZeoliteRepository repo;
  late _CountingNotifications notifications;
  late ProviderContainer container;
  late int subject;

  final DateTime day = DateTime(2026, 10, 12);
  const int nine = 9 * 60;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_external_mark');
    appDb = AppDatabase.at('${dir.path}/m.db', factory: databaseFactoryFfi);
    await appDb.database;
    repo = ZeoliteRepository(db: appDb);
    subject = await repo.insertSubject(
      const Subject(name: 'Course 1', colorValue: 0xFF336699),
    );
    await repo.insertExtraClass(
      ExtraClass(
        subjectId: subject,
        date: day,
        startMinutes: nine,
        endMinutes: nine + 60,
      ),
    );
    notifications = _CountingNotifications();
    container = ProviderContainer(
      overrides: [
        notificationsProvider.overrideWithValue(notifications),
        repositoryProvider.overrideWithValue(repo),
        analyticsProvider.overrideWithValue(FakeAnalytics()),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    await appDb.close();
    await dir.delete(recursive: true);
  });

  ExternalMarkRequest tap({int? subjectId}) => ExternalMarkRequest(
        subjectId: subjectId ?? subject,
        dateKey: Dates.keyOf(day),
        startMinutes: nine,
        status: AttendanceStatus.present,
      );

  test('the widget is redrawn before the reminders are laid down', () async {
    AttendanceStatus? savedAtRedraw;
    int laidDownAtRedraw = -1;

    final bool marked = await applyExternalMark(
      container,
      tap(),
      toggles: true,
      redraw: () async {
        savedAtRedraw =
            (await repo.getAttendanceAt(subject, day, nine))?.status;
        laidDownAtRedraw = notifications.laidDown;
      },
    );

    expect(marked, isTrue);
    expect(savedAtRedraw, AttendanceStatus.present);
    expect(laidDownAtRedraw, 0);
    // Left to the caller, which does it once the widget is right.
    expect(notifications.laidDown, 0);
  });

  test('a tap on a class that has gone writes nothing and still redraws',
      () async {
    int redraws = 0;

    final bool marked = await applyExternalMark(
      container,
      tap(subjectId: subject + 1),
      toggles: true,
      redraw: () async => redraws++,
    );

    expect(marked, isFalse);
    expect(redraws, 1);
    expect(await repo.getAttendanceAt(subject, day, nine), isNull);
  });

  test('a save that fails still redraws, and the failure surfaces', () async {
    int redraws = 0;
    final ProviderContainer failing = ProviderContainer(
      overrides: [
        notificationsProvider.overrideWithValue(notifications),
        repositoryProvider.overrideWithValue(_FailingRepository(db: appDb)),
        analyticsProvider.overrideWithValue(FakeAnalytics()),
      ],
    );
    addTearDown(failing.dispose);

    await expectLater(
      applyExternalMark(
        failing,
        tap(),
        toggles: true,
        redraw: () async => redraws++,
      ),
      throwsA(anything),
    );
    expect(redraws, 1);
  });

  test('two quick taps on one button clear the mark they made', () async {
    Future<bool> again() => oneAtATime(
          () => applyExternalMark(
            container,
            tap(),
            toggles: true,
            redraw: () async {},
          ),
        );

    await Future.wait(<Future<bool>>[again(), again()]);

    expect(await repo.getAttendanceAt(subject, day, nine), isNull);
  });

  test('a redraw that fails does not hide the mark it followed', () async {
    final bool marked = await applyExternalMark(
      container,
      tap(),
      toggles: true,
      redraw: () async => throw StateError('launcher refused'),
    );

    expect(marked, isTrue);
    expect(
      (await repo.getAttendanceAt(subject, day, nine))?.status,
      AttendanceStatus.present,
    );
  });

  test('a second tap is saved without waiting for the first one\'s reminders',
      () async {
    final Completer<void> slowReminders = Completer<void>();
    final List<String> done = <String>[];

    final Future<void> first = markThenRemind(
      mark: () async {
        done.add('mark 1');
        return true;
      },
      remind: () => slowReminders.future,
    );
    final Future<void> second = markThenRemind(
      mark: () async {
        done.add('mark 2');
        return true;
      },
      remind: () async => done.add('remind 2'),
    );
    await pumpEventQueue();

    expect(done, <String>['mark 1', 'mark 2']);

    slowReminders.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(done, <String>['mark 1', 'mark 2', 'remind 2']);
  });
}
