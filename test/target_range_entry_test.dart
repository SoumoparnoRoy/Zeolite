import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/backup_service.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

import 'fake_sync_target.dart';

/// A target of 0 sends the skip maths to its "no target" answer and one over
/// 100 can never be met, and neither can be picked on a slider any more. Each
/// way a target reaches the device from outside is held to 1-100, and the
/// stored value is read raw so a clamp that only happens on display cannot
/// pass for one that happens on the way in.
void main() {
  late Directory dir;
  late AppDatabase appDb;
  late ZeoliteRepository repo;
  late SettingsService settings;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_target_range');
    appDb = AppDatabase.at('${dir.path}/range.db', factory: databaseFactoryFfi);
    await appDb.database;
    repo = ZeoliteRepository(db: appDb);
    settings = SettingsService();
  });

  tearDown(() async {
    await appDb.close();
    await dir.delete(recursive: true);
  });

  Future<double?> storedSettingsTarget() =>
      SharedPreferencesAsync().getDouble('ut.targetPercent');

  Future<Object?> storedSubjectTarget() async {
    final List<Map<String, Object?>> rows =
        await (await appDb.database).query('subjects');
    return rows.single['target_percent'];
  }

  group('a sync pull', () {
    Future<void> pull({required double settingsTarget, double? subject}) {
      final FakeSyncTarget target = FakeSyncTarget()..trustsPulls = true;
      target.remote = <RemoteState>[
        RemoteState(
          kind: SyncKind.settings,
          localKey: SyncItem.settingsKey,
          remoteId: SyncItem.settingsKey,
          hash: 'settings-$settingsTarget',
          fields: <String, Object?>{'targetPercent': settingsTarget},
        ),
        RemoteState(
          kind: SyncKind.subject,
          localKey: 'aabb',
          remoteId: 'aabb',
          hash: 'subject-$subject',
          fields: <String, Object?>{
            'name': 'Generic Course',
            'color': 0xFF336699,
            'targetPercent': subject,
            'priorHeld': 0,
            'priorAttended': 0,
          },
        ),
      ];
      return SyncCoordinator(
        repository: repo,
        settings: settings,
        target: target,
      ).run(force: true);
    }

    test('raises a target of 0 to 1', () async {
      await pull(settingsTarget: 0, subject: 0);
      expect(await storedSettingsTarget(), 1);
      expect(await storedSubjectTarget(), 1);
    });

    test('lowers a target of 150 to 100', () async {
      await pull(settingsTarget: 150, subject: 150);
      expect(await storedSettingsTarget(), 100);
      expect(await storedSubjectTarget(), 100);
    });
  });

  group('a backup restore', () {
    Future<void> restore({required double settingsTarget, double? subject}) {
      final Map<String, Object?> data = <String, Object?>{
        'app': BackupService.appTag,
        'formatVersion': BackupService.formatVersion,
        'settings': <String, Object?>{'targetPercent': settingsTarget},
        'subjects': <Map<String, Object?>>[
          <String, Object?>{
            'id': 1,
            'name': 'Generic Course',
            'color': 0xFF336699,
            'target_percent': subject,
          },
        ],
      };
      return BackupService(repo, settings)
          .importFromJsonString(jsonEncode(data));
    }

    test('raises a target of 0 to 1', () async {
      await restore(settingsTarget: 0, subject: 0);
      expect(await storedSettingsTarget(), 1);
      expect(await storedSubjectTarget(), 1);
    });

    test('lowers a target of 150 to 100', () async {
      await restore(settingsTarget: 150, subject: 150);
      expect(await storedSettingsTarget(), 100);
      expect(await storedSubjectTarget(), 100);
    });
  });

  group('a stored value read back', () {
    test("a subject's override is held to 1-100, and none stays none", () {
      Subject read(Object? target) => Subject.fromMap(<String, Object?>{
            'name': 'Generic Course',
            'target_percent': target,
          });

      expect(read(0).targetPercent, 1);
      expect(read(150).targetPercent, 100);
      expect(read(null).targetPercent, isNull);
    });

    test('the saved minimum is held to 1-100', () async {
      await SharedPreferencesAsync().setDouble('ut.targetPercent', 0);
      expect((await settings.load()).targetPercent, 1);
      await SharedPreferencesAsync().setDouble('ut.targetPercent', 150);
      expect((await settings.load()).targetPercent, 100);
    });

    test('settings read from JSON are held to 1-100', () {
      expect(
          AppSettings.fromJson(const <String, Object?>{'targetPercent': 0})
              .targetPercent,
          1);
      expect(
          AppSettings.fromJson(const <String, Object?>{'targetPercent': 150})
              .targetPercent,
          100);
    });
  });
}
