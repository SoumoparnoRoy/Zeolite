import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/attendance_status.dart';
import '../../data/models/subject.dart';
import '../../domain/subject_counts.dart';
import '../app_providers.dart';

import 'action_core.dart';

/// The Counts page's writes, all on the carried balance: it has no dates, so
/// a count always counts, and it travels with the subject when it syncs.
///
/// One write at a time, each reading the subject as it stands when it runs.
/// Two quick taps read from the screen's copy would both write the same
/// figure, and one of them would be lost.
class CountActions {
  CountActions(this._core);

  final ActionCore _core;

  Future<void> _last = Future<void>.value();

  Future<T> _inTurn<T>(Future<T> Function() write) {
    final Future<T> next = _last.then((_) => write());
    _last = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  SubjectCounts? _now(int subjectId) {
    for (final SubjectCounts counts in _core.ref.read(subjectCountsProvider)) {
      if (counts.subject.id == subjectId) return counts;
    }
    return null;
  }

  Future<void> add(int subjectId, AttendanceStatus status) => _inTurn(() async {
        final SubjectCounts? counts = _now(subjectId);
        if (counts == null) return;
        await _save(counts.withTotal(status, counts.totalOf(status) + 1));
        unawaited(_core.analytics.attendanceMarked());
      });

  /// Never below what is marked: [SubjectCounts.withTotal] refuses it.
  Future<void> remove(int subjectId, AttendanceStatus status) =>
      _inTurn(() async {
        final SubjectCounts? counts = _now(subjectId);
        if (counts == null) return;
        await _save(counts.withTotal(status, counts.totalOf(status) - 1));
      });

  /// False when [total] is below what is already marked, which only the marks
  /// themselves can lower.
  Future<bool> setTotal(int subjectId, AttendanceStatus status, int total) =>
      _inTurn(() async {
        final Subject? subject = _now(subjectId)?.withTotal(status, total);
        if (subject == null) return false;
        await _save(subject);
        return true;
      });

  Future<void> _save(Subject? subject) async {
    if (subject == null) return;
    await _core.repo.updateSubject(subject);
    await _core.refresh();
  }
}

final countActionsProvider = Provider<CountActions>(
  (ref) => CountActions(ref.read(actionCoreProvider)),
);
