import 'package:flutter/foundation.dart';

import '../core/date_utils.dart';
import '../data/models/attendance_record.dart';
import '../data/models/attendance_status.dart';
import '../data/models/class_session.dart';

/// One row of a subject's attendance history.
///
/// Deliberately not a [ClassSession]: a row can exist for a mark whose class no
/// longer appears in the timetable, and such a row has no end time or room to
/// show.
@immutable
class AttendanceLogEntry {
  const AttendanceLogEntry({
    required this.date,
    required this.startMinutes,
    required this.status,
    this.endMinutes,
    this.room,
    this.weight = 1,
    this.tagId,
    this.isOrphaned = false,
  });

  final DateTime date;
  final int startMinutes;

  /// Null for an orphaned mark — the rule that defined the length is gone.
  final int? endMinutes;
  final String? room;

  final AttendanceStatus? status;

  /// What this occurrence counts as. Carried for the same reason as [tagId]:
  /// the row is replaced on write, so a status correction would otherwise
  /// reduce a two-period lab to one.
  final int weight;

  /// The mark's tag, carried so correcting a status here does not silently
  /// drop it — `setAttendance` replaces the whole row.
  final int? tagId;

  /// A mark with no matching scheduled occurrence.
  ///
  /// Deleting a weekly class removes the rule but not the marks recorded
  /// against it — `attendance` has no reference to `class_slots`, so nothing
  /// cascades. Those marks still count towards the subject's percentage, so
  /// hiding them here would leave a number the user cannot explain or correct.
  final bool isOrphaned;

  bool get isMarked => status != null;

  /// Past-and-unmarked, the thing worth chasing in this screen.
  bool get needsMarking => status == null;
}

/// Merges scheduled occurrences with recorded marks into one ordered history.
///
/// The two sets are not the same. An occurrence with no mark is a class you
/// forgot to record; a mark with no occurrence is history left behind by an
/// edited or deleted rule. Both matter, so this returns their union rather than
/// either one alone.
///
/// Pure and synchronous: no database access, no widget dependency.
List<AttendanceLogEntry> buildAttendanceLog({
  required int subjectId,
  required List<ClassSession> pastSessions,
  required List<AttendanceRecord> records,
}) {
  final Map<String, AttendanceRecord> bySubjectKey = <String, AttendanceRecord>{
    for (final AttendanceRecord r in records)
      if (r.subjectId == subjectId) r.key: r,
  };

  final List<AttendanceLogEntry> entries = <AttendanceLogEntry>[];
  final Set<String> claimed = <String>{};

  for (final ClassSession session in pastSessions) {
    if (session.subject.id != subjectId) continue;
    final String key = AttendanceRecord.keyFor(
      subjectId,
      session.date,
      session.startMinutes,
    );
    // A rule can produce the same slot twice if the data is odd; keep one row.
    if (!claimed.add(key)) continue;

    entries.add(
      AttendanceLogEntry(
        date: session.date,
        startMinutes: session.startMinutes,
        endMinutes: session.endMinutes,
        room: session.room,
        status: bySubjectKey[key]?.status,
        weight: bySubjectKey[key]?.weight ?? session.weight,
        tagId: bySubjectKey[key]?.tagId,
      ),
    );
  }

  for (final MapEntry<String, AttendanceRecord> left in bySubjectKey.entries) {
    if (claimed.contains(left.key)) continue;
    final AttendanceRecord record = left.value;
    entries.add(
      AttendanceLogEntry(
        date: record.date,
        startMinutes: record.startMinutes,
        status: record.status,
        weight: record.weight,
        tagId: record.tagId,
        isOrphaned: true,
      ),
    );
  }

  // Newest first: fixing a recent mistake is the common case.
  entries.sort((AttendanceLogEntry a, AttendanceLogEntry b) {
    final int byDate = Dates.keyOf(b.date).compareTo(Dates.keyOf(a.date));
    if (byDate != 0) return byDate;
    return b.startMinutes.compareTo(a.startMinutes);
  });

  return entries;
}
