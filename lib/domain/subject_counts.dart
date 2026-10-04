import '../data/models/attendance_status.dart';
import '../data/models/subject.dart';
import 'attendance_stats.dart';

/// One subject on the Counts page: three totals, and where a change to one
/// of them lands.
///
/// Each total is marked plus carried, so it agrees with the stats card. Only
/// the carried part changes here; the marked part moves with its marks.
class SubjectCounts {
  const SubjectCounts({required this.stats});

  final SubjectStats stats;

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

  /// Marks are corrected where they were made, so a figure made only of
  /// marks has nothing here to take away.
  bool canRemove(AttendanceStatus status) => carriedOf(status) > 0;

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
}
