import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/schedule_engine.dart';

/// A Monday, used as the anchor for every fixture below.
final DateTime monday = DateTime(2026, 8, 3);

Subject subjectFixture({int id = 1, String name = 'Physics'}) => Subject(
      id: id,
      name: name,
      colorValue: 0xFF7C6BFF,
    );

ClassSlot slotFixture({
  int id = 1,
  int subjectId = 1,
  int weekday = DateTime.monday,
  int start = 9 * 60,
  int end = 10 * 60,
  DateTime? startDate,
  DateTime? endDate,
}) =>
    ClassSlot(
      id: id,
      subjectId: subjectId,
      weekday: weekday,
      startMinutes: start,
      endMinutes: end,
      startDate: startDate ?? monday,
      endDate: endDate,
    );

ScheduleEngine buildEngine({
  List<Subject>? subjects,
  List<ClassSlot>? slots,
  List<ExtraClass>? extras,
  List<Holiday>? holidays,
  List<AttendanceRecord>? records,
  DateTime? semesterStart,
  DateTime? semesterEnd,
}) {
  return ScheduleEngine(
    subjects: subjects ?? <Subject>[subjectFixture()],
    slots: slots ?? <ClassSlot>[slotFixture()],
    extras: extras ?? <ExtraClass>[],
    holidays: holidays ?? <Holiday>[],
    records: records ?? <AttendanceRecord>[],
    semesterStart: semesterStart,
    semesterEnd: semesterEnd,
  );
}

void main() {
  group('date helpers', () {
    test('keyOf and fromKey round-trip', () {
      final DateTime date = DateTime(2026, 8, 11);
      expect(Dates.keyOf(date), 20260811);
      expect(Dates.fromKey(20260811), date);
    });

    test('startOfWeek returns the Monday', () {
      // 2026-08-11 is a Tuesday.
      expect(Dates.startOfWeek(DateTime(2026, 8, 11)), DateTime(2026, 8, 10));
      // A Monday is its own week start.
      expect(Dates.startOfWeek(DateTime(2026, 8, 10)), DateTime(2026, 8, 10));
      // A Sunday belongs to the week that began six days earlier.
      expect(Dates.startOfWeek(DateTime(2026, 8, 16)), DateTime(2026, 8, 10));
    });

    test('addDays crosses month and year boundaries', () {
      expect(Dates.addDays(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 1));
      expect(Dates.addDays(DateTime(2026, 12, 31), 1), DateTime(2027, 1, 1));
      expect(Dates.addDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
    });

    test('daysBetween counts whole days', () {
      expect(Dates.daysBetween(monday, Dates.addDays(monday, 7)), 7);
      expect(Dates.daysBetween(Dates.addDays(monday, 7), monday), -7);
    });
  });

  group('clock formatting', () {
    test('formats 12-hour times', () {
      expect(Clock.format(0), '12:00 AM');
      expect(Clock.format(9 * 60 + 5), '9:05 AM');
      expect(Clock.format(12 * 60), '12:00 PM');
      expect(Clock.format(13 * 60 + 30), '1:30 PM');
    });

    test('formats 24-hour times', () {
      expect(Clock.format(9 * 60 + 5, use24Hour: true), '09:05');
      expect(Clock.format(13 * 60 + 30, use24Hour: true), '13:30');
    });
  });

  group('end time from a start', () {
    test('adds the category length to the start', () {
      expect(Clock.endFromStart(9 * 60, 120), 11 * 60);
      expect(Clock.endFromStart(9 * 60, 60), 10 * 60);
    });

    test('keeps the end after the start when the length is zero', () {
      expect(Clock.endFromStart(9 * 60, 0), 9 * 60 + 5);
    });

    test('does not spill past midnight', () {
      expect(Clock.endFromStart(23 * 60, 120), Clock.minutesPerDay - 1);
    });

    test('a start too late for the five-minute floor still ends after it', () {
      final int start = Clock.minutesPerDay - 2;
      expect(Clock.endFromStart(start, 60), Clock.minutesPerDay - 1);
      expect(Clock.endFromStart(start, 60), greaterThan(start));
    });
  });

  group('recurrence', () {
    test('a weekly slot appears on its weekday every week', () {
      final ScheduleEngine engine = buildEngine();

      expect(engine.sessionsOn(monday), hasLength(1));
      expect(engine.sessionsOn(Dates.addDays(monday, 7)), hasLength(1));
      expect(engine.sessionsOn(Dates.addDays(monday, 70)), hasLength(1));
    });

    test('it does not appear on other weekdays', () {
      final ScheduleEngine engine = buildEngine();
      for (int i = 1; i <= 6; i++) {
        expect(
          engine.sessionsOn(Dates.addDays(monday, i)),
          isEmpty,
          reason: 'day +$i should have no classes',
        );
      }
    });

    test('it does not appear before its start date', () {
      final ScheduleEngine engine = buildEngine();
      expect(engine.sessionsOn(Dates.addDays(monday, -7)), isEmpty);
    });

    test('an end date stops the recurrence', () {
      final ScheduleEngine engine = buildEngine(
        slots: <ClassSlot>[
          slotFixture(endDate: Dates.addDays(monday, 7)),
        ],
      );
      expect(engine.sessionsOn(monday), hasLength(1));
      expect(engine.sessionsOn(Dates.addDays(monday, 7)), hasLength(1));
      expect(engine.sessionsOn(Dates.addDays(monday, 14)), isEmpty);
    });

    test('multiple slots on one day come back in time order', () {
      final ScheduleEngine engine = buildEngine(
        slots: <ClassSlot>[
          slotFixture(id: 1, start: 14 * 60, end: 15 * 60),
          slotFixture(id: 2, start: 9 * 60, end: 10 * 60),
        ],
      );
      final List<ClassSession> sessions = engine.sessionsOn(monday);
      expect(sessions, hasLength(2));
      expect(sessions.first.startMinutes, 9 * 60);
      expect(sessions.last.startMinutes, 14 * 60);
    });
  });

  group('holidays and semester bounds', () {
    test('holidays suppress recurring classes', () {
      final ScheduleEngine engine = buildEngine(
        holidays: <Holiday>[Holiday(date: monday, name: 'Founders Day')],
      );
      expect(engine.sessionsOn(monday), isEmpty);
      expect(engine.holidayOn(monday)?.name, 'Founders Day');
      // The following week is unaffected.
      expect(engine.sessionsOn(Dates.addDays(monday, 7)), hasLength(1));
    });

    test('a one-off class still runs on a holiday', () {
      final ScheduleEngine engine = buildEngine(
        holidays: <Holiday>[Holiday(date: monday, name: 'Holiday')],
        extras: <ExtraClass>[
          ExtraClass(
            id: 1,
            subjectId: 1,
            date: monday,
            startMinutes: 11 * 60,
            endMinutes: 12 * 60,
          ),
        ],
      );
      final List<ClassSession> sessions = engine.sessionsOn(monday);
      expect(sessions, hasLength(1));
      expect(sessions.single.isExtra, isTrue);
    });

    test('nothing is generated outside the semester', () {
      final ScheduleEngine engine = buildEngine(
        semesterStart: Dates.addDays(monday, 7),
        semesterEnd: Dates.addDays(monday, 21),
      );
      expect(engine.sessionsOn(monday), isEmpty);
      expect(engine.sessionsOn(Dates.addDays(monday, 7)), hasLength(1));
      expect(engine.sessionsOn(Dates.addDays(monday, 28)), isEmpty);
      expect(engine.isOutsideSemester(monday), isTrue);
    });
  });

  group('attendance attachment', () {
    test('a mark is attached to the matching occurrence only', () {
      final ScheduleEngine engine = buildEngine(
        records: <AttendanceRecord>[
          AttendanceRecord(
            subjectId: 1,
            date: monday,
            startMinutes: 9 * 60,
            status: AttendanceStatus.present,
          ),
        ],
      );

      expect(engine.sessionsOn(monday).single.status, AttendanceStatus.present);
      expect(engine.sessionsOn(Dates.addDays(monday, 7)).single.isMarked,
          isFalse);
    });

    test('two subjects at the same time do not share a mark', () {
      final ScheduleEngine engine = buildEngine(
        subjects: <Subject>[
          subjectFixture(),
          subjectFixture(id: 2, name: 'Maths'),
        ],
        slots: <ClassSlot>[
          slotFixture(id: 1, subjectId: 1),
          slotFixture(id: 2, subjectId: 2),
        ],
        records: <AttendanceRecord>[
          AttendanceRecord(
            subjectId: 2,
            date: monday,
            startMinutes: 9 * 60,
            status: AttendanceStatus.absent,
          ),
        ],
      );

      final List<ClassSession> sessions = engine.sessionsOn(monday);
      expect(sessions, hasLength(2));
      final ClassSession physics =
          sessions.firstWhere((ClassSession s) => s.subject.id == 1);
      final ClassSession maths =
          sessions.firstWhere((ClassSession s) => s.subject.id == 2);
      expect(physics.isMarked, isFalse);
      expect(maths.status, AttendanceStatus.absent);
    });
  });

  group('range expansion', () {
    test('a four-week range yields four occurrences', () {
      final ScheduleEngine engine = buildEngine();
      final List<ClassSession> sessions =
          engine.sessionsBetween(monday, Dates.addDays(monday, 27));
      expect(sessions, hasLength(4));
    });

    test('an inverted range is empty rather than throwing', () {
      final ScheduleEngine engine = buildEngine();
      expect(
        engine.sessionsBetween(Dates.addDays(monday, 7), monday),
        isEmpty,
      );
    });

    test('remaining sessions are counted up to the semester end', () {
      final ScheduleEngine engine = buildEngine(
        slots: <ClassSlot>[slotFixture(startDate: Dates.addDays(monday, -70))],
        semesterEnd: Dates.addDays(monday, 21),
      );
      // Counting forward from the Monday: +7, +14 and +21 remain.
      expect(engine.remainingSessionsFor(1, from: monday), 3);
      expect(engine.remainingSessionsBySubject(from: monday)[1], 3);
    });

    test('a future class already cancelled is not one still to attend', () {
      final ScheduleEngine engine = buildEngine(
        slots: <ClassSlot>[slotFixture(startDate: Dates.addDays(monday, -70))],
        records: <AttendanceRecord>[
          AttendanceRecord(
            subjectId: 1,
            date: Dates.addDays(monday, 7),
            startMinutes: 9 * 60,
            status: AttendanceStatus.cancelled,
          ),
        ],
        semesterEnd: Dates.addDays(monday, 21),
      );
      expect(engine.remainingSessionsFor(1, from: monday), 2);
      expect(engine.remainingSessionsBySubject(from: monday)[1], 2);
    });

    test('one marked ahead of its date is counted as held, not as remaining',
        () {
      final ScheduleEngine engine = buildEngine(
        slots: <ClassSlot>[slotFixture(startDate: Dates.addDays(monday, -70))],
        records: <AttendanceRecord>[
          AttendanceRecord(
            subjectId: 1,
            date: Dates.addDays(monday, 14),
            startMinutes: 9 * 60,
            status: AttendanceStatus.present,
          ),
        ],
        semesterEnd: Dates.addDays(monday, 21),
      );
      expect(engine.remainingSessionsFor(1, from: monday), 2);
    });
  });
}
