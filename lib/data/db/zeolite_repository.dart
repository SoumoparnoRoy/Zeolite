import 'package:sqflite/sqflite.dart';

import '../../core/date_utils.dart';
import '../models/attendance_record.dart';
import '../models/attendance_status.dart';
import '../models/class_category.dart';
import '../models/class_slot.dart';
import '../models/extra_class.dart';
import '../models/holiday.dart';
import '../models/room.dart';
import '../models/subject.dart';
import '../models/tag.dart';
import 'app_database.dart';

/// One row per table, exactly as SQLite handed it over.
typedef DatabaseSnapshot = Map<String, List<Map<String, Object?>>>;

/// Single entry point for all persistence.
///
/// The UI never touches SQL — it asks the repository for typed models, which
/// keeps the widget layer testable and the schema replaceable.
class ZeoliteRepository {
  ZeoliteRepository({AppDatabase? db}) : _appDb = db ?? AppDatabase.instance;

  final AppDatabase _appDb;

  Future<Database> get _db => _appDb.database;

  // -------------------------------------------------------------- categories

  Future<List<ClassCategory>> getCategories() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.query('categories', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(ClassCategory.fromMap).toList();
  }

  Future<int> insertCategory(ClassCategory category) async {
    final Database db = await _db;
    return db.insert('categories', category.toMap());
  }

  Future<void> updateCategory(ClassCategory category) async {
    if (category.id == null) return;
    final Database db = await _db;
    await db.update(
      'categories',
      category.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[category.id],
    );
  }

  /// Deleting a category leaves its subjects intact — they simply fall back to
  /// the global default length (`ON DELETE SET NULL`).
  Future<void> deleteCategory(int id) async {
    final Database db = await _db;
    await db.delete('categories', where: 'id = ?', whereArgs: <Object?>[id]);
    // Older rows created before foreign keys were enforced may still point at
    // the deleted row, so clear them explicitly.
    await db.update(
      'subjects',
      <String, Object?>{'category_id': null},
      where: 'category_id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// How many subjects sit in a category, used before offering to delete it.
  Future<int> countSubjectsInCategory(int categoryId) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM subjects WHERE category_id = ?',
      <Object?>[categoryId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['c'] as int?) ?? 0;
  }

  // ------------------------------------------------------------------- rooms

  Future<List<Room>> getRooms() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'rooms',
      orderBy: 'position ASC, name COLLATE NOCASE ASC',
    );
    return rows.map(Room.fromMap).toList();
  }

  /// Appends a room at the end of the list, which is where someone adding one
  /// expects it to land.
  Future<int> insertRoom(Room room) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.rawQuery('SELECT MAX(position) AS m FROM rooms');
    final int next = ((rows.first['m'] as int?) ?? -1) + 1;
    return db.insert('rooms', room.copyWith(position: next).toMap());
  }

  Future<void> updateRoom(Room room) async {
    if (room.id == null) return;
    final Database db = await _db;
    await db.update(
      'rooms',
      room.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[room.id],
    );
  }

  /// Classes keep whatever room text they were given — the list is only the set
  /// of suggestions, so removing an entry never edits a class.
  Future<void> deleteRoom(int id) async {
    final Database db = await _db;
    await db.delete('rooms', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  // -------------------------------------------------------------------- tags

  Future<List<Tag>> getTags() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'tags',
      orderBy: 'position ASC, name COLLATE NOCASE ASC',
    );
    return rows.map(Tag.fromMap).toList();
  }

  Future<int> insertTag(Tag tag) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.rawQuery('SELECT MAX(position) AS m FROM tags');
    final int next = ((rows.first['m'] as int?) ?? -1) + 1;
    return db.insert('tags', tag.copyWith(position: next).toMap());
  }

  /// Renaming reaches every mark at once, which is the whole reason marks
  /// store a tag id rather than a copy of its name.
  Future<void> updateTag(Tag tag) async {
    if (tag.id == null) return;
    final Database db = await _db;
    await db.update(
      'tags',
      tag.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[tag.id],
    );
  }

  /// The marks themselves survive — `attendance.tag_id` is `ON DELETE SET
  /// NULL`, so they go back to being untagged rather than disappearing. Same
  /// reasoning as deleting a weekly class leaving its attendance behind: the
  /// class was still attended, and removing a label is not a reason to forget
  /// that.
  Future<void> deleteTag(int id) async {
    final Database db = await _db;
    await db.delete('tags', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// How many marks carry [tagId]. The Settings delete prompt says this out
  /// loud, so removing a tag in use is a decision rather than a surprise.
  Future<int> countMarksWithTag(int tagId) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM attendance WHERE tag_id = ?',
      <Object?>[tagId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  // ---------------------------------------------------------------- subjects

  Future<List<Subject>> getSubjects() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.query('subjects', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(Subject.fromMap).toList();
  }

  Future<Subject?> getSubject(int id) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.query('subjects', where: 'id = ?', whereArgs: <Object?>[id]);
    if (rows.isEmpty) return null;
    return Subject.fromMap(rows.first);
  }

  Future<int> insertSubject(Subject subject) async {
    final Database db = await _db;
    return db.insert('subjects', subject.toMap());
  }

  Future<void> updateSubject(Subject subject) async {
    if (subject.id == null) return;
    final Database db = await _db;
    await db.update(
      'subjects',
      subject.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[subject.id],
    );
  }

  /// Removes a subject and, via `ON DELETE CASCADE`, all of its slots, extra
  /// classes and attendance history.
  Future<void> deleteSubject(int id) async {
    final Database db = await _db;
    await db.delete('subjects', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  // ------------------------------------------------------------------- slots

  Future<List<ClassSlot>> getSlots() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.query('class_slots', orderBy: 'weekday ASC, start_minutes ASC');
    return rows.map(ClassSlot.fromMap).toList();
  }

  Future<List<ClassSlot>> getSlotsForSubject(int subjectId) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'class_slots',
      where: 'subject_id = ?',
      whereArgs: <Object?>[subjectId],
      orderBy: 'weekday ASC, start_minutes ASC',
    );
    return rows.map(ClassSlot.fromMap).toList();
  }

  /// Returns the new ids in the order given, which is how an import matches its
  /// slots back to the subjects it just created.
  Future<List<int>> insertSubjects(List<Subject> subjects) async {
    if (subjects.isEmpty) return <int>[];
    final Database db = await _db;
    final List<int> ids = <int>[];
    await db.transaction((Transaction txn) async {
      for (final Subject subject in subjects) {
        ids.add(await txn.insert('subjects', subject.toMap()));
      }
    });
    return ids;
  }

  Future<void> insertSlots(List<ClassSlot> slots) async {
    if (slots.isEmpty) return;
    final Database db = await _db;
    final Batch batch = db.batch();
    for (final ClassSlot slot in slots) {
      batch.insert('class_slots', slot.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<int> insertSlot(ClassSlot slot) async {
    final Database db = await _db;
    return db.insert('class_slots', slot.toMap());
  }

  Future<void> updateSlot(ClassSlot slot) async {
    if (slot.id == null) return;
    final Database db = await _db;
    await db.update(
      'class_slots',
      slot.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[slot.id],
    );
  }

  Future<void> deleteSlot(int id) async {
    final Database db = await _db;
    await db.delete('class_slots', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// Stops a recurring class from [date] onwards without destroying the history
  /// already recorded against it. This is the "remove from now on" action.
  Future<void> endSlotBefore(int slotId, DateTime date) async {
    final Database db = await _db;
    await db.update(
      'class_slots',
      <String, Object?>{'end_date': Dates.keyOf(Dates.addDays(date, -1))},
      where: 'id = ?',
      whereArgs: <Object?>[slotId],
    );
  }

  // ----------------------------------------------------------- extra classes

  Future<List<ExtraClass>> getExtraClasses() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.query('extra_classes', orderBy: 'date ASC, start_minutes ASC');
    return rows.map(ExtraClass.fromMap).toList();
  }

  Future<int> insertExtraClass(ExtraClass extra) async {
    final Database db = await _db;
    return db.insert('extra_classes', extra.toMap());
  }

  Future<void> updateExtraClass(ExtraClass extra) async {
    if (extra.id == null) return;
    final Database db = await _db;
    await db.update(
      'extra_classes',
      extra.toMap(),
      where: 'id = ?',
      whereArgs: <Object?>[extra.id],
    );
  }

  Future<void> deleteExtraClass(int id) async {
    final Database db = await _db;
    await db.delete('extra_classes', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  // -------------------------------------------------------------- attendance

  Future<List<AttendanceRecord>> getAttendance() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query('attendance');
    return rows.map(AttendanceRecord.fromMap).toList();
  }

  Future<List<AttendanceRecord>> getAttendanceBetween(
    DateTime from,
    DateTime to,
  ) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'attendance',
      where: 'date >= ? AND date <= ?',
      whereArgs: <Object?>[Dates.keyOf(from), Dates.keyOf(to)],
    );
    return rows.map(AttendanceRecord.fromMap).toList();
  }

  /// The mark on one occurrence, or null when it is unmarked.
  ///
  /// Needed because [setAttendance] replaces the whole row: anything editing
  /// one field of a mark has to read the rest of it first.
  Future<AttendanceRecord?> getAttendanceAt(
    int subjectId,
    DateTime date,
    int startMinutes,
  ) async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.query(
      'attendance',
      where: 'subject_id = ? AND date = ? AND start_minutes = ?',
      whereArgs: <Object?>[subjectId, Dates.keyOf(date), startMinutes],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return AttendanceRecord.fromMap(rows.first);
  }

  /// Inserts or replaces the mark for one occurrence. The unique index on
  /// `(subject_id, date, start_minutes)` makes re-marking idempotent.
  Future<void> setAttendance(AttendanceRecord record) async {
    final Database db = await _db;
    final Map<String, Object?> values = record.toMap()..remove('id');
    await db.insert(
      'attendance',
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Removes a mark, returning the occurrence to "unmarked".
  Future<void> clearAttendance(
    int subjectId,
    DateTime date,
    int startMinutes,
  ) async {
    final Database db = await _db;
    await db.delete(
      'attendance',
      where: 'subject_id = ? AND date = ? AND start_minutes = ?',
      whereArgs: <Object?>[subjectId, Dates.keyOf(date), startMinutes],
    );
  }

  /// Marks every unmarked occurrence in one shot — used by "mark all present".
  Future<void> setManyAttendance(List<AttendanceRecord> records) async {
    if (records.isEmpty) return;
    final Database db = await _db;
    final Batch batch = db.batch();
    for (final AttendanceRecord record in records) {
      batch.insert(
        'attendance',
        record.toMap()..remove('id'),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Aggregated present/absent counts per subject, computed in SQL so the app
  /// never has to load the whole history into memory.
  Future<Map<int, Map<AttendanceStatus, int>>> getStatusCounts() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT subject_id, status, COUNT(*) AS c '
      'FROM attendance GROUP BY subject_id, status',
    );
    final Map<int, Map<AttendanceStatus, int>> result =
        <int, Map<AttendanceStatus, int>>{};
    for (final Map<String, Object?> row in rows) {
      final int subjectId = (row['subject_id'] as int?) ?? 0;
      final AttendanceStatus? status =
          AttendanceStatus.fromName(row['status'] as String?);
      if (status == null) continue;
      final int count = (row['c'] as int?) ?? 0;
      result.putIfAbsent(subjectId, () => <AttendanceStatus, int>{});
      result[subjectId]![status] = count;
    }
    return result;
  }

  // ---------------------------------------------------------------- holidays

  Future<List<Holiday>> getHolidays() async {
    final Database db = await _db;
    final List<Map<String, Object?>> rows =
        await db.query('holidays', orderBy: 'date ASC');
    return rows.map(Holiday.fromMap).toList();
  }

  Future<int> insertHoliday(Holiday holiday) async {
    final Database db = await _db;
    return db.insert(
      'holidays',
      holiday.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertHolidays(List<Holiday> holidays) async {
    if (holidays.isEmpty) return;
    final Database db = await _db;
    final Batch batch = db.batch();
    for (final Holiday holiday in holidays) {
      batch.insert(
        'holidays',
        holiday.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteHoliday(int id) async {
    final Database db = await _db;
    await db.delete('holidays', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<void> deleteHolidays(List<int> ids) async {
    if (ids.isEmpty) return;
    final Database db = await _db;
    final String placeholders = List<String>.filled(ids.length, '?').join(', ');
    await db.delete(
      'holidays',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  // ------------------------------------------------------------------- admin

  Future<void> clearAll() => _appDb.clearAll();

  /// Every table, parents before children — the order rows have to go back in
  /// while foreign keys are on.
  static const List<String> _tables = <String>[
    'categories',
    'rooms',
    'tags',
    'subjects',
    'class_slots',
    'extra_classes',
    'attendance',
    'holidays',
  ];

  Future<DatabaseSnapshot> snapshot() async {
    final Database db = await _db;
    final DatabaseSnapshot snapshot = <String, List<Map<String, Object?>>>{};
    for (final String table in _tables) {
      snapshot[table] = await db.query(table);
    }
    return snapshot;
  }

  /// Puts [snapshot] back, primary keys and all.
  ///
  /// Ids are written verbatim rather than reassigned the way a backup import
  /// does: these are the same run's own rows, so nothing can collide once the
  /// tables are empty, and a screen still holding an id keeps working. The
  /// transaction is so a failure cannot leave the database half restored.
  Future<void> restore(DatabaseSnapshot snapshot) async {
    final Database db = await _db;
    await db.transaction((Transaction txn) async {
      for (final String table in _tables.reversed) {
        await txn.delete(table);
      }
      for (final String table in _tables) {
        for (final Map<String, Object?> row
            in snapshot[table] ?? const <Map<String, Object?>>[]) {
          await txn.insert(table, row);
        }
      }
    });
  }
}
