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
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/models/tag.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';
import 'fake_notifications.dart';

/// Clearing a mark by tapping its own status has to be undoable: on a stray
/// mark there is no row left to tap again.
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
    dir = await Directory.systemTemp.createTemp('zeolite_clear_undo');
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

  final DateTime day = DateTime(2026, 9, 3);
  const int nine = 9 * 60;

  Future<AttendanceRecord> seedMark() async {
    final int subject = await repo.insertSubject(
      const Subject(name: 'Course 1', colorValue: 0xFF336699),
    );
    final int tag = await repo.insertTag(const Tag(name: 'Tag 1'));
    final AttendanceRecord record = AttendanceRecord(
      subjectId: subject,
      date: day,
      startMinutes: nine,
      status: AttendanceStatus.present,
      weight: 2,
      tagId: tag,
      markedAt: DateTime(2026, 9, 3, 9, 50),
    );
    await repo.setAttendance(record);
    return record;
  }

  Future<bool> tap(AttendanceRecord on, AttendanceStatus status) =>
      container.read(attendanceActionsProvider).setStatusAt(
            subjectId: on.subjectId,
            date: on.date,
            startMinutes: on.startMinutes,
            current: on.status,
            status: status,
            weight: on.weight,
            tagId: on.tagId,
          );

  test('tapping the lit status clears the mark and undo restores all of it',
      () async {
    final AttendanceRecord before = await seedMark();

    expect(await tap(before, AttendanceStatus.present), isTrue);
    expect(await repo.getAttendanceAt(before.subjectId, day, nine), isNull);

    final ActionCore core = container.read(actionCoreProvider);
    expect(await core.undo(core.pendingUndoToken!), isTrue);

    final AttendanceRecord? back =
        await repo.getAttendanceAt(before.subjectId, day, nine);
    expect(back?.status, AttendanceStatus.present);
    expect(back?.weight, 2);
    expect(back?.tagId, before.tagId);
    expect(back?.markedAt, before.markedAt);
  });

  test('changing a status is not a clear and offers nothing back', () async {
    final AttendanceRecord before = await seedMark();

    expect(await tap(before, AttendanceStatus.absent), isFalse);
    expect(container.read(actionCoreProvider).pendingUndoToken, isNull);
  });
}
