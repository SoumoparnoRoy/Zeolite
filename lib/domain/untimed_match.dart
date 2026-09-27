import '../core/date_utils.dart';
import '../data/models/attendance_record.dart';
import '../data/models/class_session.dart';
import 'schedule_engine.dart';

/// A mark kept with no time, and the class on the timetable it belongs to.
class UntimedMatch {
  const UntimedMatch({required this.record, required this.session});

  final AttendanceRecord record;
  final ClassSession session;

  AttendanceRecord get moved =>
      record.copyWith(startMinutes: session.startMinutes);
}

/// Pairs marks imported with no time to classes the timetable has since
/// gained on that day.
///
/// Only a class still unmarked is offered, so a mark made on it by hand is
/// never overwritten. A mark goes to a class of its own type before any other,
/// which keeps a lecture and a tutorial imported for one day from swapping;
/// the rest pair in order, the first untimed mark to the earliest class. A day
/// with more untimed marks than free classes keeps the extra ones untimed.
List<UntimedMatch> matchUntimed({
  required ScheduleEngine engine,
  required List<AttendanceRecord> records,
  Set<int>? subjects,
}) {
  final Map<String, List<AttendanceRecord>> byDay =
      <String, List<AttendanceRecord>>{};
  for (final AttendanceRecord record in records) {
    if (AttendanceRecord.isTimed(record.startMinutes)) continue;
    if (subjects != null && !subjects.contains(record.subjectId)) continue;
    byDay
        .putIfAbsent(
          '${record.subjectId}:${Dates.keyOf(record.date)}',
          () => <AttendanceRecord>[],
        )
        .add(record);
  }

  final List<UntimedMatch> out = <UntimedMatch>[];
  for (final List<AttendanceRecord> day in byDay.values) {
    day.sort((AttendanceRecord a, AttendanceRecord b) =>
        AttendanceRecord.compareStarts(a.startMinutes, b.startMinutes));
    final int subjectId = day.first.subjectId;
    final List<ClassSession> free = engine
        .sessionsOn(day.first.date)
        .where((ClassSession s) => s.subject.id == subjectId && !s.isMarked)
        .toList();
    if (free.isEmpty) continue;
    final int? subjectType = free.first.subject.categoryId;

    final List<AttendanceRecord> waiting = <AttendanceRecord>[];
    for (final AttendanceRecord record in day) {
      final int? type = record.categoryId ?? subjectType;
      final int at = free.indexWhere(
        (ClassSession s) => type != null && s.effectiveCategoryId == type,
      );
      if (at < 0) {
        waiting.add(record);
        continue;
      }
      out.add(UntimedMatch(record: record, session: free.removeAt(at)));
    }
    for (final AttendanceRecord record in waiting) {
      if (free.isEmpty) break;
      out.add(UntimedMatch(record: record, session: free.removeAt(0)));
    }
  }
  out.sort((UntimedMatch a, UntimedMatch b) =>
      Dates.keyOf(a.record.date).compareTo(Dates.keyOf(b.record.date)));
  return out;
}
