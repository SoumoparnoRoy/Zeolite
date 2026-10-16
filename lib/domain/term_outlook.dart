import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../core/words.dart';
import 'attendance_stats.dart';

/// Where a subject can still finish the term, counting the classes to come.
///
/// [SubjectStats.canSkip] answers "how many in a row could I miss from here",
/// which ignores everything still scheduled. This answers the planning
/// question instead: of the classes left, how many can go and the term still
/// end on target. The two disagree on purpose, so they are never worded alike.
@immutable
class TermOutlook {
  const TermOutlook._(this.stats, this.budget);

  final SubjectStats stats;

  /// Classes (periods, where a class counts twice) that can still be missed
  /// with the term ending on target. Zero when it cannot be reached at all.
  final int budget;

  int get remaining => stats.remainingPlanned;

  /// Every remaining class attended: the best this term can end on.
  double get bestRatio => stats.maxAchievableRatio;

  /// The whole [budget] spent: the lowest the term can end and still be on
  /// target, or [bestRatio] when there is nothing to spend.
  double get spentRatio {
    final int total = stats.held + remaining;
    if (total == 0) return 1;
    return (stats.attended + remaining - budget) / total;
  }

  /// The same rule as [SubjectStats.isUnrecoverable], read forwards.
  bool get reachable => bestRatio >= stats.target - 1e-9;

  /// The colour the line takes, on the scale the subject cards already use.
  AttendanceHealth get health {
    if (!reachable) return AttendanceHealth.lost;
    if (remaining == 0) return AttendanceHealth.safe;
    return budget == 0 ? AttendanceHealth.tight : AttendanceHealth.safe;
  }

  /// What the subject's line says, on Today and in the Plan view.
  String get line {
    if (!reachable) return 'Target is out of reach this term';
    // A budget of zero with nothing ahead is not a call to attend anything.
    if (remaining == 0) return 'No classes left this term';
    // Short enough for one line at a large font; the amber says attend.
    if (budget == 0) return 'Skip budget this term: none';
    final String unit = stats.weighted ? 'period' : 'class';
    return 'Skip budget this term: '
        '${Words.plural(budget, unit, stats.weighted ? 'periods' : 'classes')}';
  }

  /// Null when the app cannot see the end of the term for this subject:
  /// without a term total or an end date there is nothing honest to plan
  /// against, which is the same stop [SubjectStats.after] observes. Null too
  /// for a subject with nothing held and nothing ahead, which has no term to
  /// plan.
  static TermOutlook? of(SubjectStats stats, {required bool termEndKnown}) {
    if (!termEndKnown && stats.subject.expectedTotal == null) return null;
    final int left = stats.remainingPlanned;
    if (stats.held + left == 0) return null;
    if (stats.target <= 0) return TermOutlook._(stats, left);
    // Solve `(attended + left - x) / (held + left) >= target` for the largest
    // whole `x`, kept within what is actually left.
    final double room =
        stats.attended + left - stats.target * (stats.held + left);
    final int budget = (room + 1e-9).floor();
    return TermOutlook._(stats, math.min(left, math.max(0, budget)));
  }
}

/// Every subject's outlook, and the term as a whole.
@immutable
class TermPlan {
  const TermPlan(this.subjects);

  /// Tightest first: out of reach, then the smallest budgets.
  final List<TermOutlook> subjects;

  static TermPlan of(OverallStats overall, {required bool termEndKnown}) {
    final List<TermOutlook> outlooks = <TermOutlook>[
      for (final SubjectStats s in overall.subjects)
        if (TermOutlook.of(s, termEndKnown: termEndKnown)
            case final TermOutlook outlook)
          outlook,
    ];
    outlooks.sort((TermOutlook a, TermOutlook b) {
      if (a.reachable != b.reachable) return a.reachable ? 1 : -1;
      final int byBudget = a.budget.compareTo(b.budget);
      return byBudget != 0 ? byBudget : a.bestRatio.compareTo(b.bestRatio);
    });
    return TermPlan(List<TermOutlook>.unmodifiable(outlooks));
  }

  bool get isEmpty => subjects.isEmpty;

  int get _held =>
      subjects.fold<int>(0, (int n, TermOutlook o) => n + o.stats.held);

  int get _attended =>
      subjects.fold<int>(0, (int n, TermOutlook o) => n + o.stats.attended);

  int get remaining =>
      subjects.fold<int>(0, (int n, TermOutlook o) => n + o.remaining);

  /// The term's percentage with everything left attended.
  double get bestPercent {
    final int total = _held + remaining;
    return total == 0 ? 100 : (_attended + remaining) * 100 / total;
  }

  /// With every subject's budget spent. Budgets are per subject and do not
  /// pool: a spare class in one subject cannot cover a miss in another.
  double get spentPercent {
    final int total = _held + remaining;
    if (total == 0) return 100;
    final int spent = subjects.fold<int>(
      0,
      (int n, TermOutlook o) => n + (o.reachable ? o.budget : 0),
    );
    return (_attended + remaining - spent) * 100 / total;
  }

  TermOutlook? forSubject(int? id) {
    for (final TermOutlook outlook in subjects) {
      if (outlook.stats.subject.id == id) return outlook;
    }
    return null;
  }
}
