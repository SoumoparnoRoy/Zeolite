import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/date_utils.dart';
import '../core/words.dart';
import '../data/models/attendance_record.dart';
import '../data/models/attendance_status.dart';
import '../data/models/class_session.dart';
import '../data/models/subject.dart';
import '../data/settings/app_settings.dart';

/// How a subject is doing against its attendance requirement.
enum AttendanceHealth {
  /// Comfortably above target with room to spare.
  safe,

  /// At or just above target — one miss could break it.
  tight,

  /// Below target but still recoverable before the semester ends.
  atRisk,

  /// Below target and mathematically impossible to recover.
  lost,

  /// Nothing marked yet.
  empty,
}

/// Attendance maths for a single subject.
///
/// The interesting part is not the percentage — it is the two forward-looking
/// answers: how many classes you can still afford to miss, and how many you
/// must attend in a row to climb back.
class SubjectStats {
  const SubjectStats({
    required this.subject,
    required this.present,
    required this.absent,
    required this.cancelled,
    required this.target,
    required this.plannedFromSlots,
    this.weighted = false,
  });

  final Subject subject;

  /// Counted in periods, not in marks: a class worth two contributes two. The
  /// three read as marks for every subject where nothing counts twice, which
  /// is what [weighted] distinguishes.
  final int present;
  final int absent;
  final int cancelled;

  /// Required attendance as a fraction, e.g. 0.75.
  final double target;

  /// Classes still scheduled before the semester ends, projected from the
  /// slots. Only used when the subject does not say its own term total.
  final int plannedFromSlots;

  /// Whether any class here counts as more than one. Only the wording depends
  /// on it — "two more periods" is honest where skipping one lab costs two,
  /// and nobody else should have to meet the word.
  final bool weighted;

  /// The unit the headlines count in.
  String get _unit => weighted ? 'period' : 'class';

  String get _units => weighted ? 'periods' : 'classes';

  int get priorHeld => subject.priorHeld;
  int get priorAttended => subject.priorAttended;

  /// Classes that count towards the percentage. Cancelled ones don't.
  int get held => present + absent + priorHeld;

  /// [present] stays what was marked here, so the log still reconciles.
  int get attended => present + priorAttended;

  /// Derived from the term total when there is one, so nothing has to be kept
  /// up to date: every class marked moves [held] and this follows.
  int get remainingPlanned {
    final int? total = subject.expectedTotal;
    if (total == null) return plannedFromSlots;
    return math.max(0, total - held);
  }

  bool get hasData => held > 0;

  /// Current attendance as a fraction of held classes.
  double get ratio => held == 0 ? 0 : attended / held;

  double get percent => ratio * 100;

  bool get meetsTarget => held == 0 || ratio >= target - 1e-9;

  /// How many more classes you can miss and still hold the target.
  ///
  /// Solve `attended / (held + x) >= target` for the largest whole `x`:
  ///   `x = floor(attended / target) - held`
  int get canSkip {
    if (target <= 0) return 999;
    if (attended == 0) return 0;
    final int maxTotal = (attended / target).floor();
    return math.max(0, maxTotal - held);
  }

  /// How many classes you must attend, back to back, to reach the target.
  ///
  /// Solve `(attended + y) / (held + y) >= target` for the smallest whole `y`:
  ///   `y = ceil((target * held - attended) / (1 - target))`
  int get needToAttend {
    if (meetsTarget) return 0;
    if (target >= 1) return remainingPlanned;
    final double numerator = target * held - attended;
    if (numerator <= 0) return 0;
    return math.max(0, (numerator / (1 - target)).ceil());
  }

  /// The best percentage still achievable if you attend everything left.
  double get maxAchievableRatio {
    final int total = held + remainingPlanned;
    if (total == 0) return 1;
    return (attended + remainingPlanned) / total;
  }

  /// True when even a perfect run from here cannot reach the target.
  bool get isUnrecoverable =>
      !meetsTarget &&
      remainingPlanned > 0 &&
      maxAchievableRatio < target - 1e-9;

  AttendanceHealth get health {
    if (!hasData) return AttendanceHealth.empty;
    if (meetsTarget) {
      return canSkip >= 2 ? AttendanceHealth.safe : AttendanceHealth.tight;
    }
    if (remainingPlanned > 0 && maxAchievableRatio < target - 1e-9) {
      return AttendanceHealth.lost;
    }
    return AttendanceHealth.atRisk;
  }

  /// The one-line verdict shown under each subject.
  String get headline {
    switch (health) {
      case AttendanceHealth.empty:
        return 'No classes marked yet';
      case AttendanceHealth.safe:
        return canSkip == 1
            ? 'You can skip 1 more $_unit'
            : 'You can skip $canSkip more $_units';
      case AttendanceHealth.tight:
        return canSkip == 0
            ? 'Right on target — attending the next one keeps you here'
            : 'You can skip 1 more $_unit';
      case AttendanceHealth.atRisk:
        return needToAttend == 1
            ? 'One more $_unit brings you back to target'
            : 'Attending the next $needToAttend brings you back to target';
      case AttendanceHealth.lost:
        return 'Target is out of reach this semester';
    }
  }

  static SubjectStats fromSessions({
    required Subject subject,
    required Iterable<ClassSession> sessions,
    required double target,
    int plannedFromSlots = 0,
  }) {
    int present = 0;
    int absent = 0;
    int cancelled = 0;
    bool weighted = false;
    for (final ClassSession session in sessions) {
      final AttendanceStatus? status = session.status;
      if (status == null) continue;
      // The mark's own weight, not the rule's: editing a slot must not restate
      // what a past class was worth.
      final int weight = session.record?.weight ?? session.weight;
      if (weight != 1) weighted = true;
      if (status == AttendanceStatus.present) {
        present += weight;
      } else if (status == AttendanceStatus.absent) {
        absent += weight;
      } else {
        cancelled += weight;
      }
    }
    return SubjectStats(
      subject: subject,
      present: present,
      absent: absent,
      cancelled: cancelled,
      target: target,
      plannedFromSlots: plannedFromSlots,
      weighted: weighted,
    );
  }
}

/// Aggregate view across every subject.
class OverallStats {
  const OverallStats({required this.subjects, required this.target});

  final List<SubjectStats> subjects;
  final double target;

  int get present =>
      subjects.fold<int>(0, (int sum, SubjectStats s) => sum + s.present);

  int get absent =>
      subjects.fold<int>(0, (int sum, SubjectStats s) => sum + s.absent);

  int get cancelled =>
      subjects.fold<int>(0, (int sum, SubjectStats s) => sum + s.cancelled);

  /// Carried balances included, so the total agrees with the cards above it.
  int get attended =>
      subjects.fold<int>(0, (int sum, SubjectStats s) => sum + s.attended);

  int get held =>
      subjects.fold<int>(0, (int sum, SubjectStats s) => sum + s.held);

  bool get hasData => held > 0;

  double get ratio => held == 0 ? 0 : attended / held;

  double get percent => ratio * 100;

  /// Classes the whole term will hold: what has happened plus what is left.
  int get expectedTotal => subjects.fold<int>(
        0,
        (int sum, SubjectStats s) => sum + s.held + s.remainingPlanned,
      );

  /// True once every subject with attendance names its own term total. Short
  /// of that the figure is part declared and part projected from the
  /// timetable, which is a mixture no portal would report.
  bool get knowsTerm {
    final List<SubjectStats> withData =
        subjects.where((SubjectStats s) => s.hasData).toList();
    return withData.isNotEmpty &&
        withData.every((SubjectStats s) => s.subject.expectedTotal != null);
  }

  /// The figure a portal prints: attendance over the whole term rather than
  /// over what has been held, so it counts classes that have not happened yet
  /// as missed. Always the lower of the two, and shown alongside [percent]
  /// rather than instead of it — the subject cards are all [ratio].
  double? get termPercent => !knowsTerm || expectedTotal == 0
      ? null
      : attended * 100 / expectedTotal;

  bool get meetsTarget => held == 0 || ratio >= target - 1e-9;

  /// Subjects that have fallen below their own target.
  List<SubjectStats> get atRisk =>
      subjects.where((SubjectStats s) => s.hasData && !s.meetsTarget).toList();

  /// Subjects sitting on the edge — one absence away from dropping below.
  List<SubjectStats> get tight => subjects
      .where((SubjectStats s) => s.hasData && s.meetsTarget && s.canSkip == 0)
      .toList();

  /// How many classes you can miss before something breaks. The binding
  /// constraint is the tightest subject, not the aggregate — an overall 94% is
  /// no comfort when one lab is sitting on its own target.
  int get canSkip {
    final List<SubjectStats> withData =
        subjects.where((SubjectStats s) => s.hasData).toList();
    if (withData.isEmpty) return 0;
    return withData
        .map((SubjectStats s) => s.canSkip)
        .reduce((int a, int b) => a < b ? a : b);
  }

  /// Total classes that must be attended to bring every subject back to its
  /// own target. A sum rather than a maximum, because two subjects below
  /// target need both runs, not the longer of the two.
  int get needToAttend => atRisk.fold<int>(
        0,
        (int sum, SubjectStats s) => sum + s.needToAttend,
      );

  /// The home screen's headline — the answer to "can I skip the next one?".
  /// Here rather than in the widget so it can be tested without a device.
  String get verdict {
    if (!hasData) return 'Nothing marked yet';

    final List<SubjectStats> lost = subjects
        .where((SubjectStats s) => s.health == AttendanceHealth.lost)
        .toList();
    if (lost.isNotEmpty) {
      return lost.length == 1
          ? 'One out of reach'
          : '${Words.count(lost.length)} out of reach';
    }

    if (atRisk.isNotEmpty) return '${Words.count(needToAttend)} to make up';

    final int spare = canSkip;
    return spare == 0 ? 'None to spare' : '${Words.count(spare)} to spare';
  }

  SubjectStats? get weakest {
    final List<SubjectStats> withData =
        subjects.where((SubjectStats s) => s.hasData).toList();
    if (withData.isEmpty) return null;
    withData
        .sort((SubjectStats a, SubjectStats b) => a.ratio.compareTo(b.ratio));
    return withData.first;
  }
}

/// The marks sitting outside the semester dates, which the figures above them
/// otherwise say nothing about.
///
/// Reported whether or not they are being counted, because the point is that
/// their absence from a percentage should never be silent — that silence cost
/// a full debugging round once already.
@immutable
class OutOfTermMarks {
  const OutOfTermMarks({required this.count, this.earliest, this.latest});

  final int count;

  /// The span they cover, which is what an offer to widen the term onto them
  /// needs. Null when there are none.
  final DateTime? earliest;
  final DateTime? latest;

  bool get isEmpty => count == 0;

  static OutOfTermMarks from(
    Iterable<AttendanceRecord> records,
    AppSettings term,
  ) {
    int count = 0;
    DateTime? earliest;
    DateTime? latest;
    for (final AttendanceRecord record in records) {
      // Deliberately not [AppSettings.countsTowardsPercentage]: these stay
      // worth naming even once the user has said to count them.
      if (term.countsInTerm(record.date)) continue;
      count++;
      final DateTime day = Dates.dayOf(record.date);
      if (earliest == null || day.isBefore(earliest)) earliest = day;
      if (latest == null || day.isAfter(latest)) latest = day;
    }
    return OutOfTermMarks(count: count, earliest: earliest, latest: latest);
  }

  /// The dates a term would need in order to take these marks in. Only the end
  /// that has strays beyond it moves, so widening never shrinks the term.
  (DateTime, DateTime)? widenedTerm(AppSettings term) {
    final DateTime? start = term.semesterStart;
    final DateTime? end = term.semesterEnd;
    if (start == null || end == null || isEmpty) return null;
    return (
      earliest!.isBefore(start) ? earliest! : start,
      latest!.isAfter(end) ? latest! : end,
    );
  }
}
