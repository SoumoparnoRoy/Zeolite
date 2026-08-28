import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';
import 'package:zeolite/data/db/zeolite_repository.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/data/settings/app_settings.dart';
import 'package:zeolite/services/backup_service.dart';

/// A backup is how attendance reaches a second device, so the subject uuid has
/// to survive the round trip. Reissuing it there would leave the same course
/// syncing under two identities, which no amount of conflict handling fixes.
void main() {
  late Directory dir;
  final List<Database> open = <Database>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp('zeolite_backup');
  });

  tearDown(() async {
    for (final Database db in open) {
      await db.close();
    }
    open.clear();
    await dir.delete(recursive: true);
  });

  Future<ZeoliteRepository> repoAt(String name) async {
    final AppDatabase appDb =
        AppDatabase.at('${dir.path}/$name.db', factory: databaseFactoryFfi);
    open.add(await appDb.database);
    return ZeoliteRepository(db: appDb);
  }

  test('a subject keeps its uuid across an export and a restore', () async {
    final ZeoliteRepository source = await repoAt('source');
    await source.insertSubject(
      const Subject(name: 'Generic Course', colorValue: 0xFF336699),
    );

    final List<Subject> before = await source.getSubjects();
    final String issued = before.single.uuid!;
    expect(issued, isNotEmpty);

    final String json = await BackupService(source, SettingsService())
        .exportToJsonString();
    expect(json, contains(issued));

    // A different database entirely, which is the case that was broken: the
    // restore rebuilt the subject field by field and left the uuid behind.
    final ZeoliteRepository target = await repoAt('target');
    await BackupService(target, SettingsService()).importFromJsonString(json);

    final List<Subject> after = await target.getSubjects();
    expect(after.single.uuid, issued);
  });

  test('a backup written before v8 is given a uuid on the way in', () async {
    final ZeoliteRepository source = await repoAt('source');
    final String json = await BackupService(source, SettingsService())
        .exportToJsonString();

    final Map<String, Object?> data =
        jsonDecode(json) as Map<String, Object?>;
    data['subjects'] = <Object?>[
      <String, Object?>{
        'id': 1,
        'name': 'Older Course',
        'color': 0xFF336699,
        'created_at': 1,
      },
    ];

    final ZeoliteRepository target = await repoAt('target');
    await BackupService(target, SettingsService())
        .importFromJsonString(jsonEncode(data));

    final List<Subject> after = await target.getSubjects();
    expect(after.single.uuid, isNotNull);
    expect(after.single.uuid, isNotEmpty);
  });
}
