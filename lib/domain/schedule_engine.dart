import '../core/date_utils.dart';
import '../data/models/attendance_record.dart';
import '../data/models/class_session.dart';
import '../data/models/class_slot.dart';
import '../data/models/extra_class.dart';
import '../data/models/holiday.dart';
import '../data/models/subject.dart';

/// Turns recurrence *rules* into concrete class occurrences.
///
/// Nothing about a specific week is stored. Given the weekly slots, the one-off
/// extras, the holidays and the semester bounds, this expands any date range
/// into the sessions that actually happen — then attaches whatever attendance
/// mark exists for each one.
///
/// Doing it this way means editing a weekly rule instantly reshapes every
/// future week, and the database stays small no matter how long the term runs.
class ScheduleEngine {
  ScheduleEngine({
    required List<Subject> subjects,
    required List<ClassSlot> slots,
    required List<ExtraClass> extras,
    required List<Holiday> holidays,
    required List<AttendanceRecord> records,
    this.semesterStart,
    this.semesterEnd,
  })  : _subjectsById = <int, Subject>{
          for (final Subject s in subjects)
            if (s.id != null) s.id!: s,
        },
        _slots = slots,
        _extras = extras,
        _holidayKeys = <int, Holiday>{
          for (final Holiday h in holidays) Dates.keyOf(h.date): h,
        },
        _recordsByKey = <String, AttendanceRecord>{
          for (final AttendanceRecord r in records) r.key: r,
        };

  final Map<int, Subject> _subjectsById;
  final List<ClassSlot> _slots;
  final List<ExtraClass> _extras;
  final Map<int, Holiday> _holidayKeys;
  final Map<String, AttendanceRecord> _recordsByKey;

  /// Classes are only generated inside the semester. Null means unbounded.
  final DateTime? semesterStart;
  final DateTime? semesterEnd;

  /// True when [date] falls outside the configured semester.
  bool isOutsideSemester(DateTime date) {
    final int key = Dates.keyOf(date);
    if (semesterStart != null && key < Dates.keyOf(semesterStart!)) return true;
    if (semesterEnd != null && key > Dates.keyOf(semesterEnd!)) return true;
    return false;
  }

  Holiday? holidayOn(DateTime date) => _holidayKeys[Dates.keyOf(date)];

  /// Every class happening on [date], sorted by start time.
  ///
  /// Returns empty for holidays and for days outside the semester. One-off
  /// extra classes are always included — an extra lecture scheduled on a
  /// holiday is a deliberate act, so it is honoured.
  List<ClassSession> sessionsOn(DateTime date) {
    final DateTime day = Dates.dayOf(date);
    final List<ClassSession> sessions = <ClassSession>[];

    final bool blocked = isOutsideSemester(day) || holidayOn(day) != null;

    if (!blocked) {
      for (final ClassSlot slot in _slots) {
        if (!slot.appliesOn(day)) continue;
        final Subject? subject = _subjectsById[slot.subjectId];
        if (subject == null) continue;
        sessions.add(
          ClassSession(
            subject: subject,
            date: day,
            startMinutes: slot.startMinutes,
            endMinutes: slot.endMinutes,
            room: slot.room,
            weight: slot.weight,
            slotId: slot.id,
            record: _lookupRecord(subject.id, day, slot.startMinutes),
          ),
        );
      }
    }

    final int dayKey = Dates.keyOf(day);
    for (final ExtraClass extra in _extras) {
      if (Dates.keyOf(extra.date) != dayKey) continue;
      final Subject? subject = _subjectsById[extra.subjectId];
      if (subject == null) continue;
      sessions.add(
        ClassSession(
          subject: subject,
          date: day,
          startMinutes: extra.startMinutes,
          endMinutes: extra.endMinutes,
          room: extra.room,
          weight: extra.weight,
          extraClassId: extra.id,
          record: _lookupRecord(subject.id, day, extra.startMinutes),
        ),
      );
    }

    sessions.sort(ClassSession.compare);
    return sessions;
  }

  AttendanceRecord? _lookupRecord(int? subjectId, DateTime date, int start) {
    if (subjectId == null) return null;
    return _recordsByKey[AttendanceRecord.keyFor(subjectId, date, start)];
  }

  /// Expands an inclusive date range.
  ///
  /// Guarded at 400 days so a mis-typed semester end can never spin the UI.
  List<ClassSession> sessionsBetween(DateTime from, DateTime to) {
    final List<ClassSession> all = <ClassSession>[];
    final int span = Dates.daysBetween(from, to);
    if (span < 0) return all;
    final int days = span > 400 ? 400 : span;
    for (int i = 0; i <= days; i++) {
      all.addAll(sessionsOn(Dates.addDays(from, i)));
    }
    return all;
  }

  /// Sessions grouped by day key, handy for week and month views.
  Map<int, List<ClassSession>> sessionsByDayBetween(
    DateTime from,
    DateTime to,
  ) {
    final Map<int, List<ClassSession>> byDay = <int, List<ClassSession>>{};
    for (final ClassSession session in sessionsBetween(from, to)) {
      byDay.putIfAbsent(Dates.keyOf(session.date), () => <ClassSession>[]).add(session);
    }
    return byDay;
  }

  /// The seven days of the week containing [date].
  Map<int, List<ClassSession>> sessionsForWeekOf(DateTime date) {
    final DateTime monday = Dates.startOfWeek(date);
    return sessionsByDayBetween(monday, Dates.addDays(monday, 6));
  }

  /// Past sessions you have not marked yet, newest first.
  ///
  /// Only looks back [lookbackDays] so the Today screen never guilt-trips you
  /// about a lecture from three months ago.
  List<ClassSession> unmarkedSessions({int lookbackDays = 14}) {
    final DateTime today = Dates.today();
    final DateTime from = Dates.addDays(today, -lookbackDays);
    final List<ClassSession> pending = sessionsBetween(from, today)
        .where((ClassSession s) => s.needsMarking)
        .toList();
    pending.sort((ClassSession a, ClassSession b) => ClassSession.compare(b, a));
    return pending;
  }

  /// Sessions still to come for a subject before the semester ends. Used to
  /// work out whether a target is still mathematically reachable.
  ///
  /// A session already marked is not one of them — a cancelled class will not
  /// be attended, and one marked early is already in the held total.
  ///
  /// Counted in the same unit as [SubjectStats.held], so a class that counts
  /// twice contributes two. Mixing the units here would put a weighted class
  /// on both sides of `maxAchievableRatio` at different sizes.
  int remainingSessionsFor(int subjectId, {DateTime? from}) {
    if (semesterEnd == null) return 0;
    final DateTime start = Dates.addDays(from ?? Dates.today(), 1);
    if (Dates.keyOf(start) > Dates.keyOf(semesterEnd!)) return 0;
    return sessionsBetween(start, semesterEnd!)
        .where((ClassSession s) => s.subject.id == subjectId && !s.isMarked)
        .fold<int>(0, (int sum, ClassSession s) => sum + s.weight);
  }

  /// Remaining sessions for every subject in one pass — much cheaper than
  /// calling [remainingSessionsFor] per subject.
  Map<int, int> remainingSessionsBySubject({DateTime? from}) {
    final Map<int, int> counts = <int, int>{};
    if (semesterEnd == null) return counts;
    final DateTime start = Dates.addDays(from ?? Dates.today(), 1);
    if (Dates.keyOf(start) > Dates.keyOf(semesterEnd!)) return counts;
    for (final ClassSession session in sessionsBetween(start, semesterEnd!)) {
      final int? id = session.subject.id;
      if (id == null || session.isMarked) continue;
      counts[id] = (counts[id] ?? 0) + session.weight;
    }
    return counts;
  }

  /// The next class from now, looking up to [withinDays] ahead.
  ClassSession? nextSession({int withinDays = 14}) {
    final DateTime now = DateTime.now();
    final DateTime today = Dates.dayOf(now);
    for (int i = 0; i <= withinDays; i++) {
      final DateTime day = Dates.addDays(today, i);
      for (final ClassSession session in sessionsOn(day)) {
        if (session.startDateTime.isAfter(now)) return session;
      }
    }
    return null;
  }

  /// Upcoming sessions used to schedule "class starting soon" notifications.
  List<ClassSession> upcomingSessions({int withinDays = 7}) {
    final DateTime now = DateTime.now();
    final DateTime today = Dates.dayOf(now);
    final List<ClassSession> upcoming = <ClassSession>[];
    for (int i = 0; i <= withinDays; i++) {
      final DateTime day = Dates.addDays(today, i);
      for (final ClassSession session in sessionsOn(day)) {
        if (session.startDateTime.isAfter(now)) upcoming.add(session);
      }
    }
    return upcoming;
  }
}
