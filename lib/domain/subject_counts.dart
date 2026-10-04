import 'dart:math' as math;

import '../data/models/attendance_record.dart';
import '../data/models/attendance_status.dart';
import '../data/models/subject.dart';
import 'attendance_stats.dart';

/// One subject on the Counts page: three totals, and where a change to one
/// of them lands.
///
/// Each total is marked plus carried, so it agrees with the stats card. Only
/// the carried part can be typed over; the marked part moves with its marks.
class SubjectCounts {
  const SubjectCounts({
    required this.stats,
    this.untimed = const <AttendanceStatus, int>{},
  });

  final SubjectStats stats;

  /// This term's marks with no class time, by status — what a minus can take
  /// back before it starts on the carried balance.
  final Map<AttendanceStatus, int> untimed;

  Subject get subject => stats.subject;

  int get _priorMissed => stats.priorHeld - stats.priorAttended;

  int totalOf(AttendanceStatus status) => switch (status) {
        AttendanceStatus.present => stats.present + stats.priorAttended,
        AttendanceStatus.absent => stats.absent + _priorMissed,
        AttendanceStatus.cancelled => stats.cancelledTotal,
      };

  int markedOf(AttendanceStatus status) => switch (status) {
        AttendanceStatus.present => stats.present,
        AttendanceStatus.absent => stats.absent,
        AttendanceStatus.cancelled => stats.cancelled,
      };

  int carriedOf(AttendanceStatus status) => totalOf(status) - markedOf(status);

  /// Marks made on the timetable are corrected where they were made, so a
  /// figure made only of those has nothing here to take away.
  bool canRemove(AttendanceStatus status) =>
      carriedOf(status) > 0 || (untimed[status] ?? 0) > 0;

  /// The subject with [status]'s total moved to [total] through the carried
  /// part alone, or null when [total] is below what is already marked. The
  /// other two totals stay where they were.
  Subject? withTotal(AttendanceStatus status, int total) {
    final int carried = total - markedOf(status);
    if (carried < 0) return null;
    return switch (status) {
      AttendanceStatus.present => subject.copyWith(
          priorAttended: carried,
          priorHeld: carried + _priorMissed,
        ),
      AttendanceStatus.absent =>
        subject.copyWith(priorHeld: stats.priorAttended + carried),
      AttendanceStatus.cancelled => subject.copyWith(priorCancelled: carried),
    };
  }

  /// Where the next untimed mark of a day goes: after the last one, so two
  /// taps on one day never land on the same key.
  static int nextUntimedStart(Iterable<AttendanceRecord> sameDay) {
    int last = 0;
    for (final AttendanceRecord record in sameDay) {
      if (AttendanceRecord.isTimed(record.startMinutes)) continue;
      last = math.max(last, -record.startMinutes);
    }
    return AttendanceRecord.untimed(last + 1);
  }

  /// The untimed mark a minus takes back: the latest day's, and on that day
  /// the last one given.
  static AttendanceRecord? newestUntimed(
    Iterable<AttendanceRecord> records,
    AttendanceStatus status,
  ) {
    AttendanceRecord? newest;
    for (final AttendanceRecord record in records) {
      if (record.status != status ||
          AttendanceRecord.isTimed(record.startMinutes)) {
        continue;
      }
      final AttendanceRecord? best = newest;
      if (best == null ||
          record.date.isAfter(best.date) ||
          (record.date == best.date &&
              record.startMinutes < best.startMinutes)) {
        newest = record;
      }
    }
    return newest;
  }
}
