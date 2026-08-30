import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/ids.dart';

/// Owns the SQLite connection and the schema.
///
/// Everything is local to the device: no accounts, no network, works on a train
/// with no signal.
class AppDatabase {
  AppDatabase._()
      : _factory = null,
        _path = null;

  /// Lets the migration test run the real `onUpgrade` on desktop SQLite.
  @visibleForTesting
  AppDatabase.at(String path, {required DatabaseFactory factory})
      : _path = path,
        _factory = factory;

  static final AppDatabase instance = AppDatabase._();

  final DatabaseFactory? _factory;
  final String? _path;

  // Keeps its pre-Zeolite name deliberately: the filename is how an existing
  // install finds its data, so renaming it would strand every database in
  // place and read as a wipe. It is never shown to the user.
  static const String fileName = 'attend_it.db';
  static const int schemaVersion = 11;

  Database? _db;

  Future<Database> get database async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    final String path = _path ?? p.join(await getDatabasesPath(), fileName);
    return (_factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (Database db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (Database db, int version) async {
          await _createSchema(db);
        },
        onUpgrade: (Database db, int oldVersion, int newVersion) async {
          // Migrations run in order so an old install can climb to current
          // without losing anything already recorded.
          if (oldVersion < 2) {
            // v2 introduced class categories (Theory, Lab, ...) which carry a
            // default class length, and linked subjects to them.
            await db.execute(_categoriesTable);
            await db.execute(
              'ALTER TABLE subjects ADD COLUMN category_id INTEGER',
            );
            await _seedCategories(db);
          }
          if (oldVersion < 3) {
            // v3 added the saved room list. Nothing is seeded and no existing
            // column changes: `class_slots.room` stays free text, so an install
            // that never opens the new screen behaves exactly as before.
            await db.execute(_roomsTable);
          }
          if (oldVersion < 4) {
            // v4 added attendance tags. The column is nullable with no default,
            // so every existing mark reads as untagged — which is what it is.
            // Nothing is seeded: the three statuses already cover the common
            // case and an empty tag list costs nothing on screen.
            await db.execute(_tagsTable);
            await db.execute('ALTER TABLE attendance ADD COLUMN tag_id INTEGER');
          }
          if (oldVersion < 5) {
            // v5 lets a subject carry attendance that predates the app, and say
            // how many classes it holds all term. Defaulting the two counters to
            // zero leaves every existing subject's maths exactly as it was;
            // expected_total stays null, which means "keep projecting from the
            // slots".
            await db.execute(
              'ALTER TABLE subjects ADD COLUMN prior_held INTEGER NOT NULL '
              'DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE subjects ADD COLUMN prior_attended INTEGER NOT NULL '
              'DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE subjects ADD COLUMN expected_total INTEGER',
            );
          }
          if (oldVersion < 6) {
            // v6 lets one class count as more than one towards attendance, for
            // an institution that counts a two-period lab twice. Defaulting to 1
            // everywhere leaves every existing figure exactly as it was, and a
            // student whose classes all count once never meets the field.
            for (final String table in <String>[
              'class_slots',
              'extra_classes',
              'attendance',
            ]) {
              await db.execute(
                'ALTER TABLE $table ADD COLUMN weight INTEGER NOT NULL DEFAULT 1',
              );
            }
          }
          if (oldVersion < 7) {
            // v7 adds the sync ledger. Nothing existing changes, and an empty
            // table reads as "nothing has ever been synced", which is true.
            await db.execute(_remoteLinksTable);
          }
          if (oldVersion < 8) {
            // A key built on subjects.id means one thing only on the install
            // that issued it, so two devices would file the same mark under
            // different subjects. Added nullable, filled row by row, then made
            // unique by index.
            await db.execute('ALTER TABLE subjects ADD COLUMN uuid TEXT');
            final List<Map<String, Object?>> rows =
                await db.query('subjects', columns: <String>['id']);
            for (final Map<String, Object?> row in rows) {
              await db.update(
                'subjects',
                <String, Object?>{'uuid': newId()},
                where: 'id = ?',
                whereArgs: <Object?>[row['id']],
              );
            }
            // Every stored key is in the old format. Sync has never shipped,
            // so this is empty on every real install.
            await db.delete('remote_links');
          }
          if (oldVersion < 9) {
            // Only these two: see [ClassSlot.uuid] for why they cannot key on
            // their own contents. Holidays, tags, rooms and categories go on
            // keying by date and by name.
            for (final String table in <String>[
              'class_slots',
              'extra_classes',
            ]) {
              await db.execute('ALTER TABLE $table ADD COLUMN uuid TEXT');
              final List<Map<String, Object?>> rows =
                  await db.query(table, columns: <String>['id']);
              for (final Map<String, Object?> row in rows) {
                await db.update(
                  table,
                  <String, Object?>{'uuid': newId()},
                  where: 'id = ?',
                  whereArgs: <Object?>[row['id']],
                );
              }
            }
            // The ledger deliberately survives. Keys are unchanged, and a null
            // field hashes as absent, so a row that never had a category or a
            // tag still matches what was pushed for it. Only rows that
            // actually use one look changed, which is true.
          }
          if (oldVersion < 10) {
            // Renaming a subject had no date on it, so two devices could not
            // settle which name was newer. Left null rather than backfilled,
            // and the ledger survives: `changedAt` is outside the hash, so no
            // row looks changed by this.
            await db.execute('ALTER TABLE subjects ADD COLUMN updated_at INTEGER');
          }
          if (oldVersion < 11) {
            // v11 lets a category say what its classes are worth. Existing
            // slots and marks keep theirs, so nothing moves until asked.
            await db.execute(_categoryWeightColumn);
          }
          await db.execute(_subjectUuidIndex);
          await db.execute(_slotUuidIndex);
          await db.execute(_extraUuidIndex);
        },
      ),
    );
  }

  /// Uniqueness lives in an index rather than a column constraint so the
  /// create path and the v8 migration can run the exact same statement —
  /// `ALTER TABLE ... ADD COLUMN` cannot carry `UNIQUE`.
  static const String _subjectUuidIndex =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_subjects_uuid ON subjects (uuid)';

  static const String _slotUuidIndex =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_slots_uuid ON class_slots (uuid)';

  static const String _extraUuidIndex =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_extras_uuid '
      'ON extra_classes (uuid)';

  /// Frozen at the shape v2 created, which the v2 migration has to reproduce.
  static const String _categoriesTable = '''
      CREATE TABLE categories (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        name            TEXT    NOT NULL,
        default_minutes INTEGER NOT NULL,
        created_at      INTEGER NOT NULL
      )
    ''';

  /// Shared by the create path and v11: inside [_categoriesTable] the v2
  /// migration would add it early and v11 would fail on a duplicate.
  static const String _categoryWeightColumn =
      'ALTER TABLE categories ADD COLUMN weight INTEGER NOT NULL DEFAULT 1';

  /// Same reasoning as [_categoriesTable]: shared by the create path and the
  /// v3 migration so the two cannot drift.
  static const String _roomsTable = '''
      CREATE TABLE rooms (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        name     TEXT    NOT NULL,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''';

  /// Same reasoning as the two tables above.
  static const String _tagsTable = '''
      CREATE TABLE tags (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        name     TEXT    NOT NULL,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''';

  /// What a target was last known to hold. Not a queue — see SyncPlan.
  static const String _remoteLinksTable = '''
      CREATE TABLE remote_links (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        target      TEXT    NOT NULL,
        kind        TEXT    NOT NULL,
        local_key   TEXT    NOT NULL,
        remote_id   TEXT    NOT NULL,
        local_hash  TEXT    NOT NULL,
        remote_hash TEXT    NOT NULL,
        synced_at   INTEGER NOT NULL,
        origin      TEXT    NOT NULL,
        UNIQUE (target, kind, local_key) ON CONFLICT REPLACE
      )
    ''';

  /// The three categories most timetables need on day one. They are ordinary
  /// rows — the user can rename, retime or delete them like any other.
  static Future<void> _seedCategories(Database db) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Batch batch = db.batch();
    batch.insert('categories', <String, Object?>{
      'name': 'Theory',
      'default_minutes': 60,
      'created_at': now,
    });
    batch.insert('categories', <String, Object?>{
      'name': 'Lab',
      'default_minutes': 120,
      'created_at': now,
    });
    batch.insert('categories', <String, Object?>{
      'name': 'Tutorial',
      'default_minutes': 60,
      'created_at': now,
    });
    await batch.commit(noResult: true);
  }

  Future<void> _createSchema(Database db) async {
    final Batch batch = db.batch();

    batch.execute(_categoriesTable);
    batch.execute(_categoryWeightColumn);
    batch.execute(_roomsTable);
    batch.execute(_tagsTable);
    batch.execute(_remoteLinksTable);

    batch.execute('''
      CREATE TABLE subjects (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        -- Nullable because the v8 migration cannot add it otherwise, and both
        -- paths must declare it identically. The repository is what guarantees
        -- every row carries one.
        uuid           TEXT,
        name           TEXT    NOT NULL,
        code           TEXT,
        teacher        TEXT,
        color          INTEGER NOT NULL,
        target_percent REAL,
        category_id    INTEGER,
        created_at     INTEGER NOT NULL,
        -- Null until the subject is first edited: see [Subject.updatedAt].
        updated_at     INTEGER,
        prior_held     INTEGER NOT NULL DEFAULT 0,
        prior_attended INTEGER NOT NULL DEFAULT 0,
        expected_total INTEGER,
        FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE SET NULL
      )
    ''');
    batch.execute(_subjectUuidIndex);

    // A recurring weekly rule. Dates are stored as yyyymmdd integers.
    batch.execute('''
      CREATE TABLE class_slots (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid          TEXT,
        subject_id    INTEGER NOT NULL,
        weekday       INTEGER NOT NULL,
        start_minutes INTEGER NOT NULL,
        end_minutes   INTEGER NOT NULL,
        room          TEXT,
        weight        INTEGER NOT NULL DEFAULT 1,
        start_date    INTEGER NOT NULL,
        end_date      INTEGER,
        FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE CASCADE
      )
    ''');

    // One-off classes outside the weekly pattern.
    batch.execute('''
      CREATE TABLE extra_classes (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid          TEXT,
        subject_id    INTEGER NOT NULL,
        date          INTEGER NOT NULL,
        start_minutes INTEGER NOT NULL,
        end_minutes   INTEGER NOT NULL,
        room          TEXT,
        weight        INTEGER NOT NULL DEFAULT 1,
        note          TEXT,
        FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE CASCADE
      )
    ''');

    // One row per marked occurrence, keyed by subject + day + start time.
    batch.execute('''
      CREATE TABLE attendance (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        subject_id    INTEGER NOT NULL,
        date          INTEGER NOT NULL,
        start_minutes INTEGER NOT NULL,
        status        TEXT    NOT NULL,
        weight        INTEGER NOT NULL DEFAULT 1,
        tag_id        INTEGER,
        note          TEXT,
        marked_at     INTEGER NOT NULL,
        UNIQUE (subject_id, date, start_minutes) ON CONFLICT REPLACE,
        FOREIGN KEY (subject_id) REFERENCES subjects (id) ON DELETE CASCADE,
        FOREIGN KEY (tag_id) REFERENCES tags (id) ON DELETE SET NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE holidays (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        date INTEGER NOT NULL UNIQUE,
        name TEXT    NOT NULL
      )
    ''');

    batch.execute(
      'CREATE INDEX idx_slots_subject ON class_slots (subject_id)',
    );
    batch.execute('CREATE INDEX idx_slots_weekday ON class_slots (weekday)');
    batch.execute('CREATE INDEX idx_extra_date ON extra_classes (date)');
    batch.execute('CREATE INDEX idx_attendance_date ON attendance (date)');
    batch.execute(
      'CREATE INDEX idx_attendance_subject ON attendance (subject_id)',
    );

    await batch.commit(noResult: true);
    await _seedCategories(db);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Wipes every table. Used by "reset all data" and by import.
  Future<void> clearAll() async {
    final Database db = await database;
    final Batch batch = db.batch();
    batch.delete('attendance');
    batch.delete('extra_classes');
    batch.delete('class_slots');
    batch.delete('holidays');
    batch.delete('subjects');
    batch.delete('categories');
    batch.delete('rooms');
    batch.delete('tags');
    // The ledger goes with the data it describes; a later run re-links to
    // pages that are still there rather than duplicating them.
    batch.delete('remote_links');
    await batch.commit(noResult: true);
  }
}
