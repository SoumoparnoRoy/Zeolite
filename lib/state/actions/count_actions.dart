import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/date_utils.dart';
import '../../data/models/attendance_record.dart';
import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../data/settings/app_settings.dart';
import '../../domain/subject_counts.dart';
import '../app_providers.dart';

import 'action_core.dart';

/// The Counts page's writes. A tap is a mark dated today with no class time; a
/// typed total moves the carried balance. Going back to counting on the
/// balance alone is a change to [add] and [remove] and nothing else.
class CountActions {
  CountActions(this._core);

  final ActionCore _core;

  Future<void> add(SubjectCounts counts, AttendanceStatus status) async {
    final int? subjectId = counts.subject.id;
    if (subjectId == null) return;
    final DateTime today = Dates.today();
    final Iterable<AttendanceRecord> sameDay =
        (await _core.repo.getAttendanceBetween(today, today))
            .where((AttendanceRecord r) => r.subjectId == subjectId);
    await _core.repo.setAttendance(
      AttendanceRecord(
        subjectId: subjectId,
        date: today,
        startMinutes: SubjectCounts.nextUntimedStart(sameDay),
        status: status,
        markedAt: DateTime.now(),
      ),
    );
    await _core.refresh();
    unawaited(_core.analytics.attendanceMarked());
  }

  /// Takes back the newest counted mark of [status], then the carried balance
  /// once those run out. Marks with a class time are left to the log.
  Future<void> remove(SubjectCounts counts, AttendanceStatus status) async {
    final int? subjectId = counts.subject.id;
    if (subjectId == null) return;
    final AppSettings settings =
        _core.ref.read(settingsProvider).value ?? const AppSettings();
    final AttendanceRecord? newest = SubjectCounts.newestUntimed(
      (await _core.repo.getAttendance()).where(
        (AttendanceRecord r) =>
            r.subjectId == subjectId &&
            settings.countsTowardsPercentage(r.date),
      ),
      status,
    );
    if (newest != null) {
      await _core.repo
          .clearAttendance(subjectId, newest.date, newest.startMinutes);
    } else if (counts.carriedOf(status) > 0) {
      await _core.repo.updateSubject(
        counts.withTotal(status, counts.totalOf(status) - 1)!,
      );
    } else {
      return;
    }
    await _core.refresh();
  }

  /// False when [total] is below what is already marked, which only the marks
  /// themselves can lower.
  Future<bool> setTotal(
    SubjectCounts counts,
    AttendanceStatus status,
    int total,
  ) async {
    final Subject? subject = counts.withTotal(status, total);
    if (subject == null) return false;
    await _core.repo.updateSubject(subject);
    await _core.refresh();
    return true;
  }
}

final countActionsProvider = Provider<CountActions>(
  (ref) => CountActions(ref.read(actionCoreProvider)),
);
