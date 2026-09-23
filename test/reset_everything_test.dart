import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/subject.dart';
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
    dir = await Directory.systemTemp.createTemp('zeolite_reset');
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

  test('a reset leaves the three installed class types, as on day one',
      () async {
    await repo.insertCategory(
      const ClassCategory(name: 'Seminar', defaultDurationMinutes: 90),
    );
    await repo.insertSubject(
      const Subject(name: 'Generic Course', colorValue: 0xFF336699),
    );
    await container.read(settingsProvider.future);
    await container.read(timetableProvider.future);

    await container.read(dataActionsProvider).resetEverything();

    expect(await repo.getSubjects(), isEmpty);
    expect(
      (await repo.getCategories()).map((ClassCategory c) => c.name),
      unorderedEquals(<String>['Lecture', 'Practical', 'Tutorial']),
    );
  });
}
