import '../core/date_utils.dart';
import '../data/models/attendance_record.dart';
import '../data/models/class_session.dart';
import '../data/models/class_slot.dart';
import '../data/models/extra_class.dart';
import '../data/models/holiday.dart';
import '../data/models/slot_override.dart';
import '../data/models/subject.dart';

/// Turns recurrence *rules* into concrete class occurrences.
///
/// Nothing about a specific week is stored. Given the weekly slots, the one-off
/// extras, the holidays and the term bounds, this expands any date range
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
    List<SlotOverride> overrides = const <SlotOverride>[],
    this.termStart,
    this.termEnd,
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
        },
        _overrides = <({int slot, int date}), SlotOverride>{
          for (final SlotOverride o in overrides)
            (slot: o.slotId, date: Dates.keyOf(o.date)): o,
        };

  final Map<int, Subject> _subjectsById;
  final List<ClassSlot> _slots;
  final List<ExtraClass> _extras;
  final Map<int, Holiday> _holidayKeys;
  final Map<String, AttendanceRecord> _recordsByKey;
  final Map<({int slot, int date}), SlotOverride> _overrides;

  /// Classes are only generated inside the term. Null means unbounded.
  final DateTime? termStart;
  final DateTime? termEnd;

  /// True when [date] falls outside the configured term.
  bool isOutsideTerm(DateTime date) {
    final int key = Dates.keyOf(date);
    if (termStart != null && key < Dates.keyOf(termStart!)) return true;
    if (termEnd != null && key > Dates.keyOf(termEnd!)) return true;
    return false;
  }

  Holiday? holidayOn(DateTime date) => _holidayKeys[Dates.keyOf(date)];

  /// Every class happening on [date], sorted by start time.
  ///
  /// Returns empty for holidays and for days outside the term. One-off
  /// extra classes are always included — an extra lecture scheduled on a
  /// holiday is a deliberate act, so it is honoured.
  List<ClassSession> sessionsOn(DateTime date) {
    final DateTime day = Dates.dayOf(date);
    final List<ClassSession> sessions = <ClassSession>[];

    final bool blocked = isOutsideTerm(day) || holidayOn(day) != null;

    if (!blocked) {
      for (final ClassSlot rule in _slots) {
        if (!rule.appliesOn(day)) continue;
        // Applied before anything is read off the slot: an override can move
        // the subject or the start time, and those two are most of the
        // attendance key, so reading first would fetch another mark entirely.
        final SlotOverride? exception = _overrideOn(rule, day);
        final ClassSlot? slot =
            exception == null ? rule : exception.applyTo(rule);
        // Null means the date was skipped, which is how an override removes a
        // single occurrence.
        if (slot == null) continue;
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
            categoryId: slot.categoryId,
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
          categoryId: extra.categoryId,
          extraClassId: extra.id,
          record: _lookupRecord(subject.id, day, extra.startMinutes),
        ),
      );
    }

    sessions.sort(ClassSession.compare);
    return sessions;
  }

  /// The exception this rule carries on [day], if any.
  SlotOverride? overrideOn(ClassSlot slot, DateTime day) =>
      _overrideOn(slot, day);

  SlotOverride? _overrideOn(ClassSlot slot, DateTime day) => slot.id == null
      ? null
      : _overrides[(slot: slot.id!, date: Dates.keyOf(day))];

  AttendanceRecord? _lookupRecord(int? subjectId, DateTime date, int start) {
    if (subjectId == null) return null;
    return _recordsByKey[AttendanceRecord.keyFor(subjectId, date, start)];
  }

  /// Expands an inclusive date range.
  ///
  /// Guarded at 400 days so a mis-typed term end can never spin the UI.
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
      byDay
          .putIfAbsent(Dates.keyOf(session.date), () => <ClassSession>[])
          .add(session);
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
  List<ClassSession> unmarkedSessions({
    int lookbackDays = 14,
    DateTime? now,
  }) {
    final DateTime at = now ?? DateTime.now();
    final DateTime today = Dates.dayOf(at);
    final DateTime from = Dates.addDays(today, -lookbackDays);
    final List<ClassSession> pending = sessionsBetween(from, today)
        .where((ClassSession s) => !s.isMarked && at.isAfter(s.endDateTime))
        .toList();
    pending
        .sort((ClassSession a, ClassSession b) => ClassSession.compare(b, a));
    return pending;
  }

  /// Sessions still to come for each subject before the term ends, counted
  /// from [now]: today's classes not yet over, then every later day's. Used
  /// to work out whether a target is still mathematically reachable.
  ///
  /// A session already marked is not one of them — a cancelled class will not
  /// be attended, and one marked early is already in the held total. One under
  /// way stays until it ends or is marked: dropping it at its start took it out
  /// of the term while the student sat in it, and the budget dipped until the
  /// mark put it back.
  ///
  /// Counted in the same unit as [SubjectStats.held], so a class that counts
  /// twice contributes two. Mixing the units here would put a weighted class
  /// on both sides of `maxAchievableRatio` at different sizes.
  Map<int, int> remainingSessionsBySubject({DateTime? now}) {
    final Map<int, int> counts = <int, int>{};
    if (termEnd == null) return counts;
    final DateTime at = now ?? DateTime.now();
    final DateTime today = Dates.dayOf(at);
    if (Dates.keyOf(today) > Dates.keyOf(termEnd!)) return counts;
    for (final ClassSession session in sessionsBetween(today, termEnd!)) {
      final int? id = session.subject.id;
      if (id == null || session.isMarked) continue;
      // One that has ended is waiting to be marked, not still to attend.
      if (!session.endDateTime.isAfter(at)) continue;
      counts[id] = (counts[id] ?? 0) + session.weight;
    }
    return counts;
  }

  /// The next moment a screen of classes changes by itself: one of today's
  /// classes starting or ending, or failing those, midnight.
  DateTime nextChange(DateTime now) {
    DateTime next = Dates.addDays(Dates.dayOf(now), 1);
    for (final ClassSession session in sessionsOn(now)) {
      for (final DateTime at in <DateTime>[
        session.startDateTime,
        session.endDateTime,
      ]) {
        if (at.isAfter(now) && at.isBefore(next)) next = at;
      }
    }
    return next;
  }

  /// The next class from [now], looking up to [withinDays] ahead.
  ClassSession? nextSession({int withinDays = 14, DateTime? now}) {
    final DateTime at = now ?? DateTime.now();
    final DateTime today = Dates.dayOf(at);
    for (int i = 0; i <= withinDays; i++) {
      final DateTime day = Dates.addDays(today, i);
      for (final ClassSession session in sessionsOn(day)) {
        if (session.startDateTime.isAfter(at)) return session;
      }
    }
    return null;
  }

  /// Sessions whose end is still ahead, used for both start and end reminders.
  List<ClassSession> upcomingSessions({int withinDays = 7}) {
    final DateTime now = DateTime.now();
    final DateTime today = Dates.dayOf(now);
    final List<ClassSession> upcoming = <ClassSession>[];
    for (int i = 0; i <= withinDays; i++) {
      final DateTime day = Dates.addDays(today, i);
      for (final ClassSession session in sessionsOn(day)) {
        if (session.endDateTime.isAfter(now)) upcoming.add(session);
      }
    }
    return upcoming;
  }
}
