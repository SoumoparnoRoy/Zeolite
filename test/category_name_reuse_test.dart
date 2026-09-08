import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/domain/sync/sync_target.dart';
import 'package:zeolite/services/firebase/firestore_sync_target.dart';
import 'package:zeolite/services/sync/sync_coordinator.dart';

/// Names are the key for a category, so a rename is a delete and a create and
/// the old name keeps a tombstone for the life of the account. What happens
/// when that name comes back is the question here.
void main() {
  const String uid = 'test-user';

  late Directory dir;
  late FakeFirebaseFirestore firestore;
  late SettingsService settings;
  final List<AppDatabase> open = <AppDatabase>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_reuse');
    firestore = FakeFirebaseFirestore();
    settings = SettingsService();
  });

  tearDown(() async {
    for (final AppDatabase db in open) {
      await db.close();
    }
    open.clear();
    await dir.delete(recursive: true);
  });

  FirestoreSyncTarget target() =>
      FirestoreSyncTarget(uid: uid, firestore: firestore);

  Future<ZeoliteRepository> device(String name) async {
    final AppDatabase db =
        AppDatabase.at('${dir.path}/$name.db', factory: databaseFactoryFfi);
    await db.database;
    open.add(db);
    return ZeoliteRepository(db: db);
  }

  SyncCoordinator syncFor(ZeoliteRepository repo) => SyncCoordinator(
        repository: repo,
        settings: settings,
        target: target(),
      );

  Future<List<String>> namesOn(ZeoliteRepository repo) async => <String>[
        for (final ClassCategory c in await repo.getCategories()) c.name,
      ];

  /// Content, so the device that syncs later reads as joining an account
  /// rather than starting one.
  Future<void> putContentOnTheAccount() => target().create(
        const SyncItem(
          kind: SyncKind.holiday,
          localKey: '20260101',
          fields: <String, Object?>{'name': 'Holiday 1'},
        ),
      );

  Future<void> buryTheName(String name) async {
    await target().create(
      SyncItem(
        kind: SyncKind.category,
        localKey: name,
        fields: const <String, Object?>{'defaultMinutes': 60},
      ),
    );
    await target().archive(SyncKind.category, name);
  }

  test('a seeded name the account buried long ago survives a join', () async {
    await putContentOnTheAccount();
    await buryTheName('Practical');

    // Seeded by this install, so made after the burial.
    final ZeoliteRepository joining = await device('joining');
    await syncFor(joining).run(force: true);

    expect(await namesOn(joining), contains('Practical'));
  });

  test('a burial still takes a row that predates it', () async {
    await putContentOnTheAccount();

    final ZeoliteRepository joining = await device('joining');
    await joining.insertCategory(
      ClassCategory(
        name: 'Workshop',
        defaultDurationMinutes: 60,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    await buryTheName('Workshop');

    await syncFor(joining).run(force: true);

    // The deletion is the newer fact, so it is still the one that wins.
    expect(await namesOn(joining), isNot(contains('Workshop')));
  });
}
