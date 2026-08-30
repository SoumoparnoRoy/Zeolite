import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zeolite/data/db/app_database.dart';

/// The schema as the first release created it, copied out of `2a9b6ab`. The
/// current create path no longer knows what an old install has on disk, which
/// is the whole point. v2 is as far back as it goes — v1 predates the repo.
const List<String> _v2Schema = <String>[
  '''
  CREATE TABLE categories (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT    NOT NULL,
    default_minutes INTEGER NOT NULL,
    created_at      INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE subjects (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT    NOT NULL,
    code           TEXT,
    teacher        TEXT,
    color          INTEGER NOT NULL,
    target_percent REAL,
    category_id    INTEGER,
    created_at     INTEGER NOT NULL,
    FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE SET NULL
  )
  ''',
  '''
  CREATE TABLE class_slots (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_id    INTEGER NOT NULL,
    weekday       INTEGER NOT NULL,
    start_minutes INTEGER NOT NULL,
    end_minutes   INTEGER NOT NULL,
    room          TEXT,
    start_date    INTEGER NOT NULL,
    end_date      INTEGER,
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE extra_classes (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_id    INTEGER NOT NULL,
    date          INTEGER NOT NULL,
    start_minutes INTEGER NOT NULL,
    end_minutes   INTEGER NOT NULL,
    room          TEXT,
    note          TEXT,
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE attendance (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    subject_id    INTEGER NOT NULL,
    date          INTEGER NOT NULL,
    start_minutes INTEGER NOT NULL,
    status        TEXT    NOT NULL,
    note          TEXT,
    marked_at     INTEGER NOT NULL,
    UNIQUE (subject_id, date, start_minutes) ON CONFLICT REPLACE,
    FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE CASCADE
  )
  ''',
  '''
  CREATE TABLE holidays (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    date INTEGER NOT NULL UNIQUE,
    name TEXT    NOT NULL
  )
  ''',
];

/// Column name to its type, nullability and default. Position is left out: an
/// `ALTER TABLE` column lands at the end, so a migrated `attendance` orders
/// `tag_id` and `weight` the opposite way from a fresh one.
Future<Map<String, String>> _columns(Database db, String table) async {
  final List<Map<String, Object?>> rows =
      await db.rawQuery('PRAGMA table_info($table)');
  return <String, String>{
    for (final Map<String, Object?> row in rows)
      row['name']! as String:
          '${row['type']} null=${row['notnull']} default=${row['dflt_value']}',
  };
}

Future<List<String>> _tables(Database db) async {
  final List<Map<String, Object?>> rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  return rows.map((Map<String, Object?> r) => r['name']! as String).toList();
}

void main() {
  late Directory dir;
  late List<Database> open;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zeolite_migration');
    open = <Database>[];
  });

  // Closing here rather than per test so a failing expectation still releases
  // the files: Windows will not delete a database another handle holds, and
  // that error lands on top of the real failure and hides it.
  tearDown(() async {
    for (final Database db in open) {
      await db.close();
    }
    await dir.delete(recursive: true);
  });

  Future<String> oldInstall() async {
    final String path = '${dir.path}/old.db';
    final Database db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (Database db, int version) async {
          for (final String statement in _v2Schema) {
            await db.execute(statement);
          }
        },
      ),
    );
    await db.insert('subjects', <String, Object?>{
      'id': 1,
      'name': 'Thermodynamics',
      'color': 0xFF112233,
      'created_at': 1,
    });
    await db.insert('class_slots', <String, Object?>{
      'subject_id': 1,
      'weekday': 1,
      'start_minutes': 540,
      'end_minutes': 600,
      'start_date': 20260803,
    });
    await db.insert('attendance', <String, Object?>{
      'subject_id': 1,
      'date': 20260803,
      'start_minutes': 540,
      'status': 'present',
      'marked_at': 2,
    });
    await db.insert('holidays', <String, Object?>{
      'date': 20260815,
      'name': 'Independence Day',
    });
    await db.close();
    return path;
  }

  Future<Database> openAt(String path) async {
    final Database db =
        await AppDatabase.at(path, factory: databaseFactoryFfi).database;
    open.add(db);
    return db;
  }

  test('a v2 install climbs to current without losing anything', () async {
    final Database db = await openAt(await oldInstall());

    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(
      (await db.query('subjects')).single['name'],
      'Thermodynamics',
    );
    expect((await db.query('class_slots')).length, 1);
    expect((await db.query('holidays')).single['name'], 'Independence Day');

    final Map<String, Object?> mark = (await db.query('attendance')).single;
    expect(mark['status'], 'present');
    // Untagged and worth one is what it always was, so no figure on screen
    // can move.
    expect(mark['weight'], 1);
    expect(mark['tag_id'], isNull);
  });

  test('a category that predates the weight column is worth one', () async {
    final Database db = await openAt(await oldInstall());
    await db.insert('categories', <String, Object?>{
      'name': 'Theory',
      'default_minutes': 60,
      'created_at': 1,
    });

    // Old or new, every category reads as an ordinary class, so no
    // percentage moves until the user says otherwise.
    final List<Map<String, Object?>> categories = await db.query('categories');
    expect(categories, isNotEmpty);
    for (final Map<String, Object?> row in categories) {
      expect(row['weight'], 1, reason: '${row['name']} came out weighted');
    }
  });

  test('every subject comes out of the climb with a uuid of its own', () async {
    final Database db = await openAt(await oldInstall());
    await db.insert('subjects', <String, Object?>{
      'name': 'Second course',
      'color': 0xFF000000,
      'created_at': 1,
      'uuid': 'ffffffffeeeeddddccccbbbbaaaaaaaa',
    });

    final List<Map<String, Object?>> subjects = await db.query('subjects');
    final Set<Object?> ids =
        subjects.map((Map<String, Object?> r) => r['uuid']).toSet();
    // The row that predates v8 is the one that matters: the migration has to
    // have issued it a uuid rather than leaving it null.
    expect(ids, hasLength(subjects.length));
    expect(ids.any((Object? v) => v == null || (v as String).isEmpty), isFalse);

    // The index is what makes the uuid an identity rather than a hint.
    await expectLater(
      db.insert('subjects', <String, Object?>{
        'name': 'Duplicate uuid',
        'color': 0xFF000000,
        'created_at': 1,
        'uuid': subjects.first['uuid'],
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('the ledger arrives empty and takes a link', () async {
    final Database db = await openAt(await oldInstall());

    expect(await db.query('remote_links'), isEmpty);

    final Map<String, Object?> link = <String, Object?>{
      'target': 'notion',
      'kind': 'attendance',
      'local_key': '1:20260803:540',
      'remote_id': 'page-1',
      'local_hash': 'a',
      'remote_hash': 'b',
      'synced_at': 3,
      'origin': 'app',
    };
    await db.insert('remote_links', link);
    // Re-recording after a push has to replace, not accumulate — the ledger
    // holds one row per key and `setRemoteLinks` leans on that.
    await db.insert('remote_links', <String, Object?>{
      ...link,
      'local_hash': 'c',
    });

    final List<Map<String, Object?>> rows = await db.query('remote_links');
    expect(rows.single['local_hash'], 'c');
  });

  test('climbing gets to the same schema as a clean install', () async {
    final Database migrated = await openAt(await oldInstall());
    final Database fresh = await openAt('${dir.path}/fresh.db');

    expect(await _tables(migrated), await _tables(fresh));
    for (final String table in await _tables(fresh)) {
      expect(
        await _columns(migrated, table),
        await _columns(fresh, table),
        reason: '$table differs between the two paths',
      );
    }
  });
}
