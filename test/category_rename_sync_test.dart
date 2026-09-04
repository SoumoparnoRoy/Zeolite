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

/// Two devices against one account, through the real Firestore target so the
/// tombstone it writes is the one read back. Categories key on their name, so
/// a rename is a delete and a create, and what the old key leaves behind on
/// the account is the whole question.
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
    dir = await Directory.systemTemp.createTemp('zeolite_rename');
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

  Future<List<String>> categoryNamesOn(ZeoliteRepository repo) async =>
      <String>[
        for (final ClassCategory c in await repo.getCategories()) c.name,
      ];

  test('a category renamed on one device does not arrive twice on the next',
      () async {
    // Put there by an earlier device, so the one that renames it holds a row
    // it pulled rather than one it made.
    await target().create(
      const SyncItem(
        kind: SyncKind.category,
        localKey: 'Workshop',
        fields: <String, Object?>{'defaultMinutes': 60},
      ),
    );

    final ZeoliteRepository phone = await device('phone');
    await syncFor(phone).run(force: true);
    final ClassCategory pulled = (await phone.getCategories())
        .firstWhere((ClassCategory c) => c.name == 'Workshop');

    await phone.updateCategory(
      ClassCategory(
        id: pulled.id,
        name: 'Studio',
        defaultDurationMinutes: pulled.defaultDurationMinutes,
        createdAt: pulled.createdAt,
      ),
    );
    await syncFor(phone).run(force: true);

    final ZeoliteRepository tablet = await device('tablet');
    await syncFor(tablet).run(force: true);

    // The seeded defaults are on both sides and combine by name.
    expect(await categoryNamesOn(tablet), contains('Studio'));
    expect(await categoryNamesOn(tablet), isNot(contains('Workshop')));
    expect(await categoryNamesOn(phone), isNot(contains('Workshop')));
  });
}
