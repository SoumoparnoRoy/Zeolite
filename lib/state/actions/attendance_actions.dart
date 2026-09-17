import 'dart:async';

import '../../data/db/zeolite_repository.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/class_session.dart';
import '../providers.dart';

import 'action_core.dart';

/// Marking a class, by session or by the natural key a mark is filed under.
class AttendanceActions {
  AttendanceActions(this._core);

  final ActionCore _core;

  // attendance -------------------------------------------------------------

  /// Marks one occurrence. Tapping the status it already has clears the mark,
  /// which makes the Today screen fully reversible with a single gesture.
  Future<void> mark(ClassSession session, AttendanceStatus status) async {
    final int? subjectId = session.subject.id;
    if (subjectId == null) return;
    await setStatusAt(
      subjectId: subjectId,
      date: session.date,
      startMinutes: session.startMinutes,
      current: session.status,
      status: status,
      weight: session.record?.weight ?? session.weight,
      // Carried across a status change on purpose. `setAttendance` replaces the
      // row, so without this, correcting Present to Absent would silently drop
      // the tag — and the tag describes the class, not the verdict. Clearing
      // the mark still takes the tag with it, which is the one case where the
      // occurrence genuinely has nothing left to label.
      tagId: session.record?.tagId,
    );
  }

  /// The same toggle rule addressed by natural key instead of by session.
  ///
  /// The attendance log needs this: a mark left behind by a deleted rule has no
  /// [ClassSession] to pass, but must still be correctable. Keeping one
  /// implementation means the "tap the current status to clear it" behaviour
  /// cannot drift between the two screens.
  Future<void> setStatusAt({
    required int subjectId,
    required DateTime date,
    required int startMinutes,
    required AttendanceStatus? current,
    required AttendanceStatus status,
    int weight = 1,
    int? tagId,
  }) async {
    if (current == status) {
      await clearStatusAt(
        subjectId: subjectId,
        date: date,
        startMinutes: startMinutes,
      );
      return;
    }
    await _core.repo.setAttendance(
      AttendanceRecord(
        subjectId: subjectId,
        date: date,
        startMinutes: startMinutes,
        status: status,
        weight: weight,
        tagId: tagId,
        markedAt: DateTime.now(),
      ),
    );
    await _core.refresh();
    // Both screens that mark come through here, so this is the one place it
    // has to be counted.
    unawaited(_core.analytics.attendanceMarked());
  }

  /// Attaches or removes the tag on a marked occurrence, leaving the status
  /// alone. Passing the tag it already has clears it, same as the status
  /// buttons.
  ///
  /// Reads the record first because `setAttendance` replaces the whole row — a
  /// record built from a tag alone would drop the status and the mark time.
  Future<void> setTagAt({
    required int subjectId,
    required DateTime date,
    required int startMinutes,
    required int? tagId,
  }) async {
    final AttendanceRecord? current = await _core.repo.getAttendanceAt(
      subjectId,
      date,
      startMinutes,
    );
    // Nothing to tag: a tag describes a mark, so there is no meaning in one
    // floating on an unmarked class.
    if (current == null) return;
    final bool clearing = tagId == null || current.tagId == tagId;
    await _core.repo.setAttendance(
      current.copyWith(tagId: clearing ? null : tagId, clearTag: clearing),
    );
    await _core.refresh();
  }

  /// Removes a mark outright, by natural key.
  ///
  /// The attendance log offers this explicitly for a mark whose weekly class
  /// has been deleted: clearing it by tapping its own status again works, but
  /// is not something anyone would guess at for a row they did not create.
  Future<void> clearStatusAt({
    required int subjectId,
    required DateTime date,
    required int startMinutes,
  }) async {
    await _core.repo.clearAttendance(subjectId, date, startMinutes);
    await _core.refresh();
  }

  /// [clearStatusAt] addressed by session rather than by natural key.
  Future<void> clearMark(ClassSession session) async {
    final int? subjectId = session.subject.id;
    if (subjectId == null) return;
    await clearStatusAt(
      subjectId: subjectId,
      date: session.date,
      startMinutes: session.startMinutes,
    );
  }

  /// Marks every unmarked class in [sessions] with [status] in one batch.
  Future<int> markAll(
    List<ClassSession> sessions,
    AttendanceStatus status,
  ) async {
    final List<AttendanceRecord> records = <AttendanceRecord>[];
    for (final ClassSession session in sessions) {
      final int? subjectId = session.subject.id;
      if (subjectId == null || session.isMarked) continue;
      records.add(
        AttendanceRecord(
          subjectId: subjectId,
          date: session.date,
          startMinutes: session.startMinutes,
          status: status,
          weight: session.weight,
          markedAt: DateTime.now(),
        ),
      );
    }
    if (records.isEmpty) return 0;
    final DatabaseSnapshot before = await _core.repo.snapshot();
    await _core.repo.setManyAttendance(records);
    await _core.refresh();
    _core.arm(before);
    return records.length;
  }
}
