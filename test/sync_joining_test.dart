import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

import 'fake_sync_target.dart';

/// Pins both halves: a joining device takes the account's schedule, and a
/// device with a term of its own still does not.
void main() {
  late Directory dir;
  late ZeoliteRepository repo;
  late SettingsService settings;
  late FakeSyncTarget target;
  AppDatabase? appDb;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_joining');
    appDb = AppDatabase.at('${dir.path}/join.db', factory: databaseFactoryFfi);
    await appDb!.database;
    repo = ZeoliteRepository(db: appDb!);
    settings = SettingsService();
    target = FakeSyncTarget()..trustsPulls = true;
  });

  tearDown(() async {
    await appDb?.close();
    await dir.delete(recursive: true);
  });

  SyncCoordinator coordinator() => SyncCoordinator(
        repository: repo,
        settings: settings,
        target: target,
      );

  /// A term the user set up somewhere else.
  RemoteState accountSettings() => RemoteState(
        kind: SyncKind.settings,
        localKey: SyncItem.settingsKey,
        remoteId: SyncItem.settingsKey,
        hash: 'settings-hash',
        fields: <String, Object?>{
          'semesterStart': Dates.keyOf(DateTime(2026, 1, 12)),
          'semesterEnd': Dates.keyOf(DateTime(2026, 5, 8)),
          'targetPercent': 80.0,
          'defaultClassMinutes': 50,
          'dayStartMinutes': 8 * 60,
          'dayEndMinutes': 18 * 60,
          'blockMinutes': 50,
          'breakAfterBlock': 3,
          'breakMinutes': 30,
        },
      );

  RemoteState accountSubject(String uuid) => RemoteState(
        kind: SyncKind.subject,
        localKey: uuid,
        remoteId: uuid,
        hash: 'subject-hash',
        fields: <String, Object?>{
          'name': 'Generic Course',
          'code': 'GEN101',
          'teacher': null,
          'color': 0xFF336699,
          'targetPercent': null,
          'priorHeld': 0,
          'priorAttended': 0,
          'expectedTotal': null,
        },
      );

  /// What onboarding leaves behind: dates chosen just now, nothing else.
  Future<void> onboard() => settings.save(
        AppSettings(
          semesterStart: DateTime(2026, 8, 29),
          semesterEnd: DateTime(2026, 12, 27),
          onboarded: true,
          scheduleChangedAt: DateTime.now(),
        ),
      );

  test('a joining device takes the account schedule, not its own defaults',
      () async {
    await onboard();
    target.remote = <RemoteState>[accountSettings(), accountSubject('aabb')];

    await coordinator().run(force: true);

    final AppSettings after = await settings.load();
    expect(after.semesterStart, DateTime(2026, 1, 12));
    expect(after.targetPercent, 80.0);
    expect(after.blockMinutes, 50);
  });

  test('an account with a term leaves the device set up', () async {
    // Nothing saved first: signing in happens on the welcome screen, before
    // the first-run questions. If the pull does not settle them, they are
    // asked anyway and the answer goes back up over the account's term.
    target.remote = <RemoteState>[accountSettings(), accountSubject('aabb')];

    await coordinator().run(force: true);

    final AppSettings after = await settings.load();
    expect(after.semesterStart, DateTime(2026, 1, 12));
    expect(after.onboarded, isTrue);
  });

  test('an account with no term of its own leaves the questions to ask',
      () async {
    target.remote = <RemoteState>[
      RemoteState(
        kind: SyncKind.settings,
        localKey: SyncItem.settingsKey,
        remoteId: SyncItem.settingsKey,
        hash: 'settings-hash',
        fields: const <String, Object?>{'targetPercent': 80.0},
      ),
      accountSubject('aabb'),
    ];

    await coordinator().run(force: true);

    expect((await settings.load()).onboarded, isFalse);
  });

  test('a device with a term of its own still states what it has', () async {
    await onboard();
    await repo.insertSubject(
      const Subject(name: 'Local Course', colorValue: 0xFF112233),
    );
    // No remote content, so this is not a device joining anything — the guard
    // must not fire and the local schedule has to survive.
    target.remote = <RemoteState>[accountSettings()];

    await coordinator().run(force: true);

    final AppSettings after = await settings.load();
    expect(after.semesterStart, DateTime(2026, 8, 29));
  });
}
