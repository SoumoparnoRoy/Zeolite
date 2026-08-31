import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/state/providers.dart';

import 'fake_analytics.dart';

/// What the app reports about itself is a promise the privacy policy makes, so
/// what matters is both that the events fire and that they carry nothing
/// somebody typed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ZeoliteRepository repo;
  late FakeAnalytics analytics;
  late ProviderContainer container;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_analytics');
    appDb = AppDatabase.at('${dir.path}/a.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    analytics = FakeAnalytics();
    container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        analyticsProvider.overrideWithValue(analytics),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  test('marking reports that a class was marked, and nothing about it',
      () async {
    final int id = await repo.insertSubject(
      const Subject(
        name: 'Generic Course',
        code: 'GEN101',
        colorValue: 0xFF336699,
      ),
    );
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);

    await container.read(actionsProvider).setStatusAt(
          subjectId: id,
          date: DateTime(2026, 9, 1),
          startMinutes: 540,
          current: null,
          status: AttendanceStatus.absent,
        );

    expect(analytics.events, <String>['attendance_marked']);
    // The status, the subject and the date all stayed here.
    expect(analytics.events.single, isNot(contains('absent')));
    expect(analytics.events.single, isNot(contains('Generic')));
  });

  test('undo is reported', () async {
    final int id = await repo.insertSubject(
      const Subject(
        name: 'Generic Course',
        code: 'GEN101',
        colorValue: 0xFF336699,
      ),
    );
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);

    await container.read(actionsProvider).deleteSubject(id);
    final int token = container.read(actionsProvider).pendingUndoToken!;
    await container.read(actionsProvider).undo(token);

    expect(analytics.events, contains('undo_used'));
  });
}
