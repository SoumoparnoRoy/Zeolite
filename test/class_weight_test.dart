import 'package:flutter_test/flutter_test.dart';
import 'package:zeolite/core/date_utils.dart';
import 'package:zeolite/data/models/attendance_record.dart';
import 'package:zeolite/data/models/attendance_status.dart';
import 'package:zeolite/data/models/class_category.dart';
import 'package:zeolite/data/models/class_session.dart';
import 'package:zeolite/data/models/class_slot.dart';
import 'package:zeolite/data/models/extra_class.dart';
import 'package:zeolite/data/models/holiday.dart';
import 'package:zeolite/data/models/subject.dart';
import 'package:zeolite/domain/attendance_log.dart';
import 'package:zeolite/domain/attendance_stats.dart';
import 'package:zeolite/domain/class_weight.dart';
import 'package:zeolite/domain/schedule_engine.dart';

const Subject maths = Subject(id: 1, name: 'Maths', colorValue: 0xFF7C6BFF);

ClassSession sessionAt(
  DateTime date,
  int start, {
  int weight = 1,
  AttendanceStatus? status,
  int? recordWeight,
}) {
  return ClassSession(
    subject: maths,
    date: date,
    startMinutes: start,
    endMinutes: start + 60,
    weight: weight,
    record: status == null
        ? null
        : AttendanceRecord(
            subjectId: 1,
            date: date,
            startMinutes: start,
            status: status,
            weight: recordWeight ?? weight,
          ),
  );
}

void main() {
  final DateTime monday = DateTime(2026, 8, 24);

  group('what a class is worth', () {
    test('a two-period lab moves held and attended by two', () {
      final SubjectStats stats = SubjectStats.fromSessions(
        subject: maths,
        target: 0.75,
        sessions: <ClassSession>[
          sessionAt(monday, 540, status: AttendanceStatus.present),
          sessionAt(monday, 600, weight: 2, status: AttendanceStatus.present),
          sessionAt(monday, 720, weight: 2, status: AttendanceStatus.absent),
        ],
      );
      expect(stats.present, 3);
      expect(stats.absent, 2);
      expect(stats.held, 5);
      expect(stats.percent, 60);
    });

    test('the mark keeps what it was worth when the rule is re-weighted', () {
      // The slot now says two, but this mark was made when it said one.
      final SubjectStats stats = SubjectStats.fromSessions(
        subject: maths,
        target: 0.75,
        sessions: <ClassSession>[
          sessionAt(
            monday,
            600,
            weight: 2,
            status: AttendanceStatus.present,
            recordWeight: 1,
          ),
        ],
      );
      expect(stats.attended, 1);
    });

    test('headlines count periods only where something is weighted', () {
      SubjectStats of({required bool weighted}) => SubjectStats(
            subject: maths,
            present: 9,
            absent: 1,
            cancelled: 0,
            target: 0.75,
            plannedFromSlots: 0,
            weighted: weighted,
          );
      expect(of(weighted: false).headline, 'You can skip 2 more classes');
      expect(of(weighted: true).headline, 'You can skip 2 more periods');
    });
  });

  group('projection', () {
    test('classes still to come are counted in periods too', () {
      final ScheduleEngine engine = ScheduleEngine(
        subjects: <Subject>[maths],
        slots: <ClassSlot>[
          ClassSlot(
            id: 1,
            subjectId: 1,
            weekday: DateTime.tuesday,
            startMinutes: 600,
            endMinutes: 720,
            weight: 2,
            startDate: monday,
          ),
        ],
        extras: const <ExtraClass>[],
        holidays: const <Holiday>[],
        records: const <AttendanceRecord>[],
        semesterStart: monday,
        semesterEnd: Dates.addDays(monday, 14),
      );
      // Two Tuesdays fall in the window, each worth two.
      expect(engine.remainingSessionsFor(1, from: monday), 4);
    });
  });

  group('round trips', () {
    test('a weight survives the map a backup is written from', () {
      final ClassSlot slot = ClassSlot(
        subjectId: 1,
        weekday: DateTime.monday,
        startMinutes: 600,
        endMinutes: 720,
        weight: 2,
        startDate: monday,
      );
      expect(ClassSlot.fromMap(slot.toMap()).weight, 2);
    });

    test('a backup written before weights existed reads as one', () {
      expect(
        AttendanceRecord.fromMap(<String, Object?>{
          'subject_id': 1,
          'date': 20260824,
          'start_minutes': 600,
          'status': 'present',
        }).weight,
        1,
      );
      expect(
        AttendanceRecord.fromMap(<String, Object?>{
          'subject_id': 1,
          'date': 20260824,
          'start_minutes': 600,
          'status': 'present',
          'weight': 0,
        }).weight,
        0,
      );
      expect(
        AttendanceRecord.fromMap(<String, Object?>{
          'subject_id': 1,
          'date': 20260824,
          'start_minutes': 600,
          'status': 'present',
          'weight': -3,
        }).weight,
        0,
      );
    });
  });

  group('which weight a new class gets', () {
    test('a category answers for its own subjects', () {
      const ClassCategory lab = ClassCategory(
        id: 1,
        name: 'Lab',
        defaultDurationMinutes: 120,
        weight: 3,
      );
      expect(weightFor(lab), 3);
    });

    // A subject in no category has to behave as it did before any of this.
    test('a subject in no category is worth one', () {
      expect(weightFor(null), 1);
    });

    test('a category worth nothing is honoured, not read as unset', () {
      const ClassCategory unassessed = ClassCategory(
        id: 2,
        name: 'Seminar',
        defaultDurationMinutes: 60,
        weight: 0,
      );
      expect(weightFor(unassessed), 0);
    });
  });

  group('a class worth nothing', () {
    final DateTime monday = Dates.addDays(Dates.today(), -7);

    test('counts towards neither side of the percentage', () {
      final SubjectStats stats = SubjectStats.fromSessions(
        subject: maths,
        sessions: <ClassSession>[
          sessionAt(monday, 540, status: AttendanceStatus.present),
          sessionAt(monday, 600, status: AttendanceStatus.absent, weight: 0),
        ],
        target: 0.75,
        plannedFromSlots: 0,
      );

      expect(stats.held, 1);
      expect(stats.attended, 1);
      expect(stats.percent, 100);
    });

    test('does not make the subject read in periods', () {
      final SubjectStats stats = SubjectStats.fromSessions(
        subject: maths,
        sessions: <ClassSession>[
          sessionAt(monday, 540, status: AttendanceStatus.present, weight: 0),
        ],
        target: 0.75,
        plannedFromSlots: 0,
      );

      expect(stats.weighted, isFalse);
    });
  });

  group('the attendance log', () {
    test('correcting a status hands the weight back', () {
      final List<AttendanceLogEntry> log = buildAttendanceLog(
        subjectId: 1,
        pastSessions: <ClassSession>[
          sessionAt(monday, 600, weight: 2, status: AttendanceStatus.present),
        ],
        records: <AttendanceRecord>[
          AttendanceRecord(
            subjectId: 1,
            date: monday,
            startMinutes: 600,
            status: AttendanceStatus.present,
            weight: 2,
          ),
        ],
      );
      expect(log.single.weight, 2);
    });
  });
}
