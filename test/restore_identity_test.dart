import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/core/app_theme.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/restore_identity.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/backup_service.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

import 'fake_sync_target.dart';

/// A backup written before schema v8 carries no subject uuid and one before v9
/// no slot uuid, so restoring either used to issue fresh identities and offer
/// the account a second copy of a term it already held. The natural key is the
/// only evidence left that the two rows are one, and it is trusted only where
/// it is unambiguous.
void main() {
  group('matching by key', () {
    test('a subject code identifies it regardless of case or padding', () {
      final Map<int, String> matched = matchByKey(
        unknown: <RowIdentity>[RowIdentity(key: subjectKey(' aaa101 '))],
        known: <RowIdentity>[
          RowIdentity(key: subjectKey('AAA101'), uuid: 'kept'),
        ],
      );

      expect(matched, <int, String>{0: 'kept'});
    });

    test('a blank or absent key matches nothing', () {
      final Map<int, String> matched = matchByKey(
        unknown: const <RowIdentity>[
          RowIdentity(key: null),
          RowIdentity(key: '  '),
        ],
        known: const <RowIdentity>[
          RowIdentity(key: null, uuid: 'one'),
          RowIdentity(key: 'BBB202', uuid: 'two'),
        ],
      );

      expect(matched, isEmpty);
    });

    test('a key worn twice on either side identifies neither row', () {
      final Map<int, String> sharedThere = matchByKey(
        unknown: const <RowIdentity>[RowIdentity(key: 'CCC303')],
        known: const <RowIdentity>[
          RowIdentity(key: 'CCC303', uuid: 'one'),
          RowIdentity(key: 'CCC303', uuid: 'two'),
        ],
      );
      final Map<int, String> sharedHere = matchByKey(
        unknown: const <RowIdentity>[
          RowIdentity(key: 'DDD404'),
          RowIdentity(key: 'DDD404'),
        ],
        known: const <RowIdentity>[RowIdentity(key: 'DDD404', uuid: 'one')],
      );

      expect(sharedThere, isEmpty);
      expect(sharedHere, isEmpty);
    });

    test('a class is keyed on its subject, not on times that get corrected',
        () {
      expect(slotKey('subject-uuid', 3, 540), slotKey('subject-uuid', 3, 540));
      expect(slotKey('subject-uuid', 3, 540),
          isNot(slotKey('other-uuid', 3, 540)));
      expect(slotKey(null, 3, 540), isNull);
    });
  });

  group('on a restore and a first run', () {
    late Directory dir;
    late ZeoliteRepository repo;
    late SettingsService settings;
    AppDatabase? appDb;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      dir = await Directory.systemTemp.createTemp('zeolite_identity');
      appDb = AppDatabase.at('${dir.path}/id.db', factory: databaseFactoryFfi);
      await appDb!.database;
      repo = ZeoliteRepository(db: appDb!);
      settings = SettingsService();
    });

    tearDown(() async {
      await appDb?.close();
      await dir.delete(recursive: true);
    });

    /// One subject with a weekly class and a one-off against it.
    Future<void> seed() async {
      final int subjectId = await repo.insertSubject(
        const Subject(name: 'First Course', code: 'AAA101', colorValue: 1),
      );
      await repo.insertSlot(
        ClassSlot(
          subjectId: subjectId,
          weekday: 3,
          startMinutes: 540,
          endMinutes: 600,
          startDate: DateTime(2026, 8, 3),
        ),
      );
      await repo.insertExtraClass(
        ExtraClass(
          subjectId: subjectId,
          date: DateTime(2026, 8, 12),
          startMinutes: 660,
          endMinutes: 720,
        ),
      );
    }

    /// An export with the uuids stripped back out, which is what a file
    /// written before schema v8 looks like.
    Future<String> legacyBackup() async {
      final Map<String, Object?> data =
          await BackupService(repo, settings).buildBackup();
      for (final String key in <String>['subjects', 'slots', 'extraClasses']) {
        for (final Object? raw in data[key]! as List<Object?>) {
          (raw! as Map<String, Object?>).remove('uuid');
        }
      }
      return jsonEncode(data);
    }

    test('a restore carries every identity the file holds', () async {
      await seed();
      final String slot = (await repo.getSlots()).single.uuid!;
      final String extra = (await repo.getExtraClasses()).single.uuid!;

      final String json = await BackupService(repo, settings)
          .exportToJsonString();
      await BackupService(repo, settings).importFromJsonString(json);

      expect((await repo.getSlots()).single.uuid, slot);
      expect((await repo.getExtraClasses()).single.uuid, extra);
    });

    test('an older file takes the identities already held for its keys',
        () async {
      await seed();
      await repo.insertSubject(
        const Subject(name: 'Second Course', colorValue: 2),
      );
      final String subject = (await repo.getSubjects())
          .firstWhere((Subject s) => s.code == 'AAA101')
          .uuid!;
      final String slot = (await repo.getSlots()).single.uuid!;
      final String extra = (await repo.getExtraClasses()).single.uuid!;
      final String uncoded = (await repo.getSubjects())
          .firstWhere((Subject s) => s.code == null)
          .uuid!;

      final String json = await legacyBackup();
      expect(json, isNot(contains(slot)));
      await BackupService(repo, settings).importFromJsonString(json);

      final List<Subject> after = await repo.getSubjects();
      expect(after.firstWhere((Subject s) => s.code == 'AAA101').uuid, subject);
      expect((await repo.getSlots()).single.uuid, slot);
      expect((await repo.getExtraClasses()).single.uuid, extra);
      // Nothing identifies the second subject, so it restores as a new course
      // rather than being guessed onto the first.
      expect(
        after.firstWhere((Subject s) => s.code == null).uuid,
        isNot(uncoded),
      );
    });

    test('a restore brings back the app as it was, minus this install',
        () async {
      await seed();
      await settings.save(const AppSettings(
        themeMode: AppThemeMode.light,
        accentColour: AccentColour.teal,
        launchAnimation: LaunchAnimation.short,
        targetPercent: 60,
        onboarded: true,
      ));
      final String json =
          await BackupService(repo, settings).exportToJsonString();

      // The device restoring it: default look, past the welcome screen, and
      // already reconciled with an account.
      await settings.save(const AppSettings(
        welcomeShown: true,
        onboarded: true,
        syncedAccountId: 'account-1',
      ));

      await BackupService(repo, settings).importFromJsonString(json);

      final AppSettings after = await settings.load();
      expect(after.themeMode, AppThemeMode.light);
      expect(after.accentColour, AccentColour.teal);
      expect(after.launchAnimation, LaunchAnimation.short);
      expect(after.targetPercent, 60);
      // From the file, these put the welcome screen back and re-point a sync.
      expect(after.welcomeShown, isTrue);
      expect(after.syncedAccountId, 'account-1');
    });

    test('a first run re-points a restored term onto the account', () async {
      await seed();
      final String fresh = (await repo.getSlots()).single.uuid!;

      final FakeSyncTarget target = FakeSyncTarget()..remote = account();
      await SyncCoordinator(
        repository: repo,
        settings: settings,
        target: target,
      ).run(force: true);

      final Subject subject = (await repo.getSubjects()).single;
      expect(subject.uuid, 'account-subject');
      // Adopting an identity is not an edit, and a stamp here would win the
      // next conflict against a rename the account made first.
      expect(subject.updatedAt, isNull);
      expect((await repo.getSlots()).single.uuid, 'account-slot');
      expect((await repo.getSlots()).single.uuid, isNot(fresh));
      expect((await repo.getExtraClasses()).single.uuid, 'account-extra');
    });

    test('a run with a ledger behind it leaves identities alone', () async {
      await seed();
      final String fresh = (await repo.getSubjects()).single.uuid!;
      await repo.setRemoteLinks(<RemoteLink>[
        RemoteLink(
          target: 'fake',
          kind: SyncKind.subject,
          localKey: fresh,
          remoteId: 'page-1',
          localHash: 'hash',
          remoteHash: 'hash',
          origin: SyncOrigin.app,
        ),
      ]);

      final FakeSyncTarget target = FakeSyncTarget()
        ..trustsPulls = true
        ..remote = account();
      await SyncCoordinator(
        repository: repo,
        settings: settings,
        target: target,
      ).run(force: true);

      expect((await repo.getSubjects()).first.uuid, fresh);
    });
  });
}

/// The same term as [seed], as the account already holds it.
List<RemoteState> account() => <RemoteState>[
      RemoteState(
        kind: SyncKind.subject,
        localKey: 'account-subject',
        remoteId: 'account-subject',
        hash: 'subject-hash',
        fields: <String, Object?>{
          'name': 'First Course',
          'code': 'AAA101',
          'teacher': null,
          'color': 1,
          'targetPercent': null,
          'priorHeld': 0,
          'priorAttended': 0,
          'expectedTotal': null,
        },
      ),
      RemoteState(
        kind: SyncKind.slot,
        localKey: 'account-slot',
        remoteId: 'account-slot',
        hash: 'slot-hash',
        fields: <String, Object?>{
          'subject': 'account-subject',
          'weekday': 3,
          'startMinutes': 540,
          'endMinutes': 600,
          'room': null,
          'weight': 1,
          'startDate': Dates.keyOf(DateTime(2026, 8, 3)),
          'endDate': null,
        },
      ),
      RemoteState(
        kind: SyncKind.extraClass,
        localKey: 'account-extra',
        remoteId: 'account-extra',
        hash: 'extra-hash',
        fields: <String, Object?>{
          'subject': 'account-subject',
          'date': Dates.keyOf(DateTime(2026, 8, 12)),
          'startMinutes': 660,
          'endMinutes': 720,
          'room': null,
          'weight': 1,
          'note': null,
        },
      ),
    ];
